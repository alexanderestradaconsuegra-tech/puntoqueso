-- ══════════════════════════════════════════════════════════════════
--  Migración 001 — Autenticación real (JWT) en PostgREST
-- ══════════════════════════════════════════════════════════════════
--  ANTES: un solo rol anónimo (web_anon) para todo. Cualquiera que
--  llamara la API directo podía leer y escribir TODAS las tablas: las
--  claves de Mercado Pago / OpenAI / Evolution, clientes, ventas, y
--  hasta cambiarle la contraseña al admin con set_password_hash.
--
--  AHORA hay dos roles:
--   · web_anon  (público, sin token) → SOLO lo que el catálogo necesita:
--       leer productos activos (sin costo ni precio mayorista), leer los
--       datos públicos del negocio, crear un pedido con
--       crear_pedido_publico (el precio lo calcula el servidor) y login.
--   · pq_admin  (token firmado que entrega login) → acceso completo.
--
--  Se corre con:
--    psql -v ON_ERROR_STOP=1 -v jwt_secret=<secreto> -f 001_auth_jwt.sql
--  El mismo <secreto> va en PGRST_JWT_SECRET del contenedor PostgREST.
--  Es idempotente y va en UNA transacción: si algo falla, no se aplica nada.
-- ══════════════════════════════════════════════════════════════════
begin;

-- ── 1. Rol autenticado ──────────────────────────────────────────────
do $$
begin
  if not exists (select from pg_roles where rolname = 'pq_admin') then
    create role pq_admin nologin;
  end if;
end $$;
grant pq_admin to authenticator;
grant usage on schema public to pq_admin;

-- ── 2. Secreto de firma, en un schema que PostgREST NO expone ───────
create schema if not exists private;
revoke all on schema private from public;
create table if not exists private.secretos (clave text primary key, valor text not null);
insert into private.secretos (clave, valor) values ('jwt_secret', :'jwt_secret')
  on conflict (clave) do update set valor = excluded.valor;

-- ── 3. Firma HS256 con pgcrypto ─────────────────────────────────────
-- encode(...,'base64') mete saltos de línea cada 76 caracteres: se sacan.
create or replace function private.b64url(b bytea) returns text
language sql immutable as $$
  select translate(rtrim(replace(encode(b, 'base64'), E'\n', ''), '='), '+/', '-_')
$$;

create or replace function private.firmar_jwt(payload json) returns text
language plpgsql security definer set search_path = public, private as $$
declare
  secreto text;
  cabecera text;
  cuerpo text;
begin
  select valor into secreto from private.secretos where clave = 'jwt_secret';
  if secreto is null then raise exception 'jwt_secret no configurado'; end if;
  cabecera := private.b64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'UTF8'));
  cuerpo   := private.b64url(convert_to(payload::text, 'UTF8'));
  return cabecera || '.' || cuerpo || '.' ||
         private.b64url(hmac(cabecera || '.' || cuerpo, secreto, 'sha256'));
end $$;
revoke all on function private.firmar_jwt(json) from public;

-- Texto libre que llega del público: sin < > " ` (evita inyectar HTML en el
-- panel admin, donde un script podría robar el token) y con largo acotado.
create or replace function private.limpiar_texto(t text, largo int) returns text
language sql immutable as $$
  select nullif(left(btrim(regexp_replace(coalesce(t, ''), '[<>"`]', '', 'g')), largo), '')
$$;

-- ── 4. Login que entrega el token ──────────────────────────────────
-- 7 días de vigencia: una caja no debería cerrar sesión a mitad del día.
create or replace function public.login(p_usuario text, p_password text) returns json
language plpgsql security definer set search_path = public, private as $$
declare u record;
begin
  select id, usuario, nombre, rol, permisos into u
    from usuarios
   where usuario = p_usuario and activo = true
     and password_hash = crypt(p_password, password_hash);
  if not found then return null; end if;
  return json_build_object(
    'token', private.firmar_jwt(json_build_object(
      'role', 'pq_admin', 'usuario', u.usuario, 'uid', u.id,
      'exp', extract(epoch from now() + interval '7 days')::bigint)),
    'usuario', json_build_object(
      'id', u.id, 'usuario', u.usuario, 'nombre', u.nombre, 'rol', u.rol,
      'permisos', coalesce(u.permisos, '{}'::jsonb)));
end $$;
revoke all on function public.login(text, text) from public;

-- ── 5. Pedido desde el catálogo público ────────────────────────────
-- El cliente solo manda qué productos y cuánto: el precio y el total los
-- calcula el servidor desde productos.precio (antes los mandaba el navegador,
-- así que se podía pedir un queso de $10.000 pagando $1).
create or replace function public.crear_pedido_publico(
  p_cliente_nombre   text,
  p_cliente_tel      text,
  p_direccion_calle  text default null,
  p_direccion_depto  text default null,
  p_direccion_comuna text default null,
  p_notas            text default null,
  p_items            jsonb default '[]'::jsonb
) returns bigint
language plpgsql security definer set search_path = public, private as $$
declare
  v_id    bigint;
  v_total numeric := 0;
  v_cant  numeric;
  it      jsonb;
  prod    record;
begin
  if private.limpiar_texto(p_cliente_nombre, 80) is null then raise exception 'Ingresa tu nombre'; end if;
  if private.limpiar_texto(p_cliente_tel, 30) is null then raise exception 'Ingresa tu teléfono'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El pedido no tiene productos';
  end if;
  if jsonb_array_length(p_items) > 50 then raise exception 'Demasiados productos en un solo pedido'; end if;

  insert into pedidos (cliente_nombre, cliente_tel, direccion_calle, direccion_depto,
                       direccion_comuna, notas, total, estado)
  values (private.limpiar_texto(p_cliente_nombre, 80),   private.limpiar_texto(p_cliente_tel, 30),
          private.limpiar_texto(p_direccion_calle, 150), private.limpiar_texto(p_direccion_depto, 60),
          private.limpiar_texto(p_direccion_comuna, 80), private.limpiar_texto(p_notas, 500),
          0, 'pendiente')
  returning id into v_id;

  for it in select * from jsonb_array_elements(p_items) loop
    v_cant := (it->>'cantidad')::numeric;
    if v_cant is null or v_cant <= 0 or v_cant > 1000 then raise exception 'Cantidad inválida'; end if;
    select id, nombre, precio into prod
      from productos where id = (it->>'producto_id')::bigint and activo = true;
    if not found then raise exception 'Un producto de tu pedido ya no está disponible'; end if;
    insert into pedido_items (pedido_id, producto_id, producto_nombre, cantidad, precio_unitario, subtotal)
    values (v_id, prod.id, prod.nombre, v_cant, prod.precio, prod.precio * v_cant);
    v_total := v_total + prod.precio * v_cant;
  end loop;

  update pedidos set total = v_total where id = v_id;
  return v_id;
end $$;
revoke all on function public.crear_pedido_publico(text, text, text, text, text, text, jsonb) from public;

-- ── 6. Quitarle TODO al público… ───────────────────────────────────
revoke all on all tables    in schema public from web_anon;
revoke all on all sequences in schema public from web_anon;
revoke all on all functions in schema public from web_anon;

-- ── 7. …y dárselo al rol autenticado ───────────────────────────────
grant usage, select on all sequences in schema public to pq_admin;

do $$
declare t text;
begin
  for t in select unnest(array[
    'productos','clientes','ventas','venta_items','pedidos','pedido_items',
    'gastos','stock_movimientos','config','auditlog',
    'proveedores','facturas_compra','factura_compra_items','cierres_caja',
    'gastos_recurrentes'
  ]) loop
    execute format('alter table %I enable row level security', t);
    execute format('grant select, insert, update, delete on %I to pq_admin', t);
    execute format('drop policy if exists "web_anon acceso total" on %I', t);
    execute format('drop policy if exists "pq_admin acceso total" on %I', t);
    execute format('create policy "pq_admin acceso total" on %I for all to pq_admin using (true) with check (true)', t);
  end loop;
end $$;

-- usuarios: ni siquiera el admin lee password_hash ni pin_hash
alter table usuarios enable row level security;
drop policy if exists "web_anon lectura basica"   on usuarios;
drop policy if exists "web_anon editar permisos"  on usuarios;
drop policy if exists "web_anon crear usuarios"   on usuarios;
drop policy if exists "pq_admin usuarios"         on usuarios;
grant select (id, usuario, nombre, rol, activo, permisos)                  on usuarios to pq_admin;
grant update (nombre, rol, activo, permisos)                               on usuarios to pq_admin;
grant insert (usuario, nombre, rol, activo, permisos, password_hash)       on usuarios to pq_admin;
create policy "pq_admin usuarios" on usuarios for all to pq_admin using (true) with check (true);

grant execute on function verificar_pin(bigint, text)     to pq_admin;
grant execute on function set_pin_hash(bigint, text)      to pq_admin;
grant execute on function set_password_hash(bigint, text) to pq_admin;
grant execute on function public.login(text, text)        to web_anon, pq_admin;
grant execute on function public.crear_pedido_publico(text, text, text, text, text, text, jsonb) to web_anon, pq_admin;

-- ── 8. Lo único que ve el público ──────────────────────────────────
-- Productos activos, sin costo, precio mayorista, stock ni códigos internos.
grant select (id, nombre, categoria, unidad, precio, vender_por_peso, imagen_b64, descripcion, activo)
  on productos to web_anon;
drop policy if exists "web_anon catalogo" on productos;
create policy "web_anon catalogo" on productos for select to web_anon using (activo = true);

-- Solo los datos del negocio que se muestran en el catálogo; nunca las claves.
grant select on config to web_anon;
drop policy if exists "web_anon config publica" on config;
create policy "web_anon config publica" on config for select to web_anon
  using (clave in ('nombre_negocio','whatsapp','negocio_nombre','negocio_razon_social','negocio_rut',
                   'negocio_direccion','negocio_telefono','negocio_instagram','negocio_tiktok',
                   'catalogo_url','google_review_url'));

notify pgrst, 'reload schema';
commit;
