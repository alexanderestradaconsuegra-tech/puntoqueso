-- ══════════════════════════════════════════════════════════════════
--  015 — Agente (Hermes): rol restringido y herramientas cerradas
--
--  El agente NO tiene acceso a las tablas. Entra con un usuario
--  (rol = 'agente') que recibe un token del rol pq_agente, y ese rol
--  solo puede ejecutar las funciones agente_* de este archivo.
--  Cada función valida lo que recibe y deja todo registrado como
--  usuario "agente" (auditoría y kardex).
--
--  Facturas de proveedor: el agente solo puede dejarlas en BORRADOR;
--  recién agente_factura_confirmar suma stock, costo y gasto, todo en
--  una sola transacción (o se aplica completa o nada).
--  No hay funciones para borrar, anular ventas ni tocar la configuración.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

do $$ begin
  if not exists (select from pg_roles where rolname = 'pq_agente') then create role pq_agente nologin; end if;
end $$;
grant pq_agente to authenticator;
grant usage on schema public to pq_agente;

-- login: el usuario con rol 'agente' recibe el rol pq_agente (12 h) en vez de pq_admin
create or replace function public.login(p_usuario text, p_password text) returns json
language plpgsql security definer set search_path = public, private as $$
declare u record; v_rol text;
begin
  select id, usuario, nombre, rol, permisos into u
    from usuarios
   where usuario = p_usuario and activo = true
     and password_hash = crypt(p_password, password_hash);
  if not found then return null; end if;
  v_rol := case when u.rol = 'agente' then 'pq_agente' else 'pq_admin' end;
  return json_build_object(
    'token', private.firmar_jwt(json_build_object(
      'role', v_rol, 'usuario', u.usuario, 'uid', u.id,
      'exp', extract(epoch from now() + case when u.rol = 'agente' then interval '12 hours' else interval '7 days' end)::bigint)),
    'usuario', json_build_object(
      'id', u.id, 'usuario', u.usuario, 'nombre', u.nombre, 'rol', u.rol,
      'permisos', coalesce(u.permisos, '{}'::jsonb)));
end $$;
revoke all on function public.login(text, text) from public;
grant execute on function public.login(text, text) to web_anon, pq_admin;

-- ── borradores de factura ──────────────────────────────────────────
create table if not exists facturas_borrador (
  id               bigserial primary key,
  estado           text not null default 'borrador' check (estado in ('borrador','confirmada','descartada')),
  proveedor_nombre text not null,
  proveedor_rut    text,
  numero_factura   text,
  fecha            date not null default current_date,
  total_documento  numeric,
  items            jsonb not null,
  avisos           jsonb not null default '[]'::jsonb,
  notas            text,
  factura_id       bigint references facturas_compra(id) on delete set null,
  created_at       timestamptz default now(),
  confirmada_at    timestamptz
);
alter table facturas_borrador add column if not exists proveedor_id bigint references proveedores(id) on delete set null;
alter table facturas_borrador enable row level security;
drop policy if exists "pq_admin acceso total" on facturas_borrador;
create policy "pq_admin acceso total" on facturas_borrador for all to pq_admin using (true) with check (true);
grant select, insert, update, delete on facturas_borrador to pq_admin;
grant usage, select on all sequences in schema public to pq_admin;

-- ── helpers ────────────────────────────────────────────────────────
create or replace function private.sin_tildes(t text) returns text
language sql immutable as $$ select translate(lower(coalesce(t, '')), 'áéíóúüñ', 'aeiouun') $$;

create or replace function private.agente_log(p_accion text, p_modulo text, p_detalle text) returns void
language sql as $$
  insert into auditlog (usuario, accion, modulo, detalle) values ('agente', p_accion, p_modulo, left(p_detalle, 500))
$$;

-- ── emparejado automático: el servidor une lo que dice la factura con tus productos ──
-- Alias aprendidos: cada vez que se confirma una factura, "texto de la factura" → producto
-- queda guardado (por proveedor) y la próxima vez se reconoce solo.
create table if not exists producto_alias (
  id           bigserial primary key,
  alias_norm   text not null,
  producto_id  bigint not null references productos(id) on delete cascade,
  proveedor_id bigint references proveedores(id) on delete cascade,
  created_at   timestamptz default now()
);
create unique index if not exists producto_alias_uq on producto_alias (alias_norm, coalesce(proveedor_id, 0));
alter table producto_alias enable row level security;
drop policy if exists "pq_admin acceso total" on producto_alias;
create policy "pq_admin acceso total" on producto_alias for all to pq_admin using (true) with check (true);
grant select, insert, update, delete on producto_alias to pq_admin;

create or replace function private.agente_norm(t text) returns text
language sql immutable as $$ select btrim(regexp_replace(private.sin_tildes(t), '[^a-z0-9]+', ' ', 'g')) $$;

-- Palabras con significado (sin números, medidas ni sufijos de empresa)
create or replace function private.agente_tokens(t text) returns text[]
language sql immutable as $$
  select coalesce(array_agg(distinct w), '{}'::text[])
    from unnest(regexp_split_to_array(private.agente_norm(t), ' ')) w
   where length(w) >= 2 and w !~ '[0-9]'
     and w <> all (array['de','del','la','el','los','las','con','sin','en','para','por','kg','kgs','kilo','kilos','gr','grs',
                         'und','unid','unidad','unidades','caja','cajas','pack','spa','ltda','limitada','sa','eirl','cia'])
$$;

-- 0 a 1: qué tanto se parecen dos listas de palabras (media armónica de las coberturas)
create or replace function private.agente_score(a text[], b text[]) returns numeric
language sql immutable as $$
  with x as (select count(*)::numeric sh from unnest(a) w
              where exists (select 1 from unnest(b) y
                             where y = w or (length(w) >= 3 and y like w || '%') or (length(y) >= 3 and w like y || '%')))
  select case when cardinality(a) = 0 or cardinality(b) = 0 or x.sh = 0 then 0
         else round(2 * (x.sh / cardinality(a)) * (x.sh / cardinality(b)) / ((x.sh / cardinality(a)) + (x.sh / cardinality(b))), 2) end
    from x
$$;

-- Hasta 3 productos candidatos para el texto de una línea de factura. Alias aprendido = puntaje 1.
create or replace function private.agente_candidatos(p_desc text, p_prov bigint) returns jsonb
language plpgsql stable as $$
declare v_dt text[] := private.agente_tokens(p_desc); v_al record;
begin
  select a.producto_id, p.nombre into v_al from producto_alias a join productos p on p.id = a.producto_id
   where a.alias_norm = private.agente_norm(p_desc) and (a.proveedor_id is null or a.proveedor_id = p_prov) and p.activo
   order by (a.proveedor_id is not null) desc limit 1;
  if found then
    return jsonb_build_array(jsonb_build_object('id', v_al.producto_id, 'nombre', v_al.nombre, 'score', 1, 'via', 'alias'));
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre, 'score', sc) order by sc desc, nombre) from (
            select p.id, p.nombre, private.agente_score(v_dt, private.agente_tokens(p.nombre)) sc
              from productos p where p.activo order by 3 desc, p.nombre limit 3) t where sc > 0), '[]'::jsonb);
end $$;

-- Proveedor registrado que corresponde al nombre de la factura (null si no hay uno claro)
create or replace function private.agente_proveedor_match(p_nombre text) returns bigint
language plpgsql stable as $$
declare v_id bigint; v_t text[] := private.agente_tokens(p_nombre); r jsonb;
begin
  select id into v_id from proveedores where activo and private.agente_norm(nombre) = private.agente_norm(p_nombre) limit 1;
  if v_id is not null then return v_id; end if;
  select jsonb_agg(jsonb_build_object('id', id, 'sc', sc) order by sc desc) into r from (
    select id, private.agente_score(v_t, private.agente_tokens(nombre)) sc from proveedores where activo) x where sc >= 0.6;
  if r is null then return null; end if;
  if jsonb_array_length(r) = 1 or (r->0->>'sc')::numeric - (r->1->>'sc')::numeric >= 0.2 then return (r->0->>'id')::bigint; end if;
  return null;
end $$;

-- ══ CONSULTAS ══════════════════════════════════════════════════════

-- Ventas del período (fechas en hora de Chile). Sin p_hasta = solo ese día.
create or replace function public.agente_ventas(p_desde date default null, p_hasta date default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare d date := coalesce(p_desde, (now() at time zone 'America/Santiago')::date);
        h date := coalesce(p_hasta, coalesce(p_desde, (now() at time zone 'America/Santiago')::date));
        r jsonb;
begin
  with v as (
    select * from ventas
     where not anulada and (created_at at time zone 'America/Santiago')::date between d and h
  )
  select jsonb_build_object(
    'desde', d, 'hasta', h,
    'ventas', (select count(*) from v),
    'total', (select coalesce(sum(total), 0) from v),
    'ticket_promedio', (select coalesce(round(avg(total)), 0) from v),
    'por_metodo', coalesce((select jsonb_object_agg(m, t) from (select coalesce(metodo_pago, 'otro') m, sum(total) t from v group by 1) x), '{}'::jsonb),
    'por_cobrar', (select coalesce(sum(total), 0) from v where estado_pago = 'pendiente'),
    'top_productos', coalesce((select jsonb_agg(row_to_json(x)) from (
        select vi.producto_nombre as producto, sum(vi.cantidad) as cantidad, sum(vi.subtotal) as total
          from venta_items vi join v on v.id = vi.venta_id
         group by vi.producto_nombre order by sum(vi.subtotal) desc limit 10) x), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- Buscar productos por nombre (cada palabra debe estar; sin tildes ni mayúsculas)
create or replace function public.agente_productos(p_texto text default null, p_stock_bajo boolean default false, p_limite int default 30)
returns jsonb language sql security definer set search_path = public, private, pg_temp as $$
  select coalesce(jsonb_agg(row_to_json(x)), '[]'::jsonb) from (
    select p.id, p.nombre, p.categoria, p.unidad, p.precio, p.precio_mayor, p.costo, p.stock, p.stock_minimo, p.activo, p.en_catalogo
      from productos p
     where (p_texto is null or btrim(p_texto) = '' or not exists (
             select 1 from unnest(string_to_array(btrim(p_texto), ' ')) w
              where w <> '' and private.sin_tildes(p.nombre) not like '%' || private.sin_tildes(w) || '%'))
       and (not p_stock_bajo or (p.activo and coalesce(p.stock, 0) <= coalesce(p.stock_minimo, 0)))
     order by p.activo desc, p.nombre
     limit least(greatest(coalesce(p_limite, 30), 1), 100)
  ) x
$$;

create or replace function public.agente_inventario()
returns jsonb language sql security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object(
    'productos_activos', count(*) filter (where activo),
    'sin_stock', count(*) filter (where activo and coalesce(stock, 0) <= 0),
    'valor_costo', coalesce(sum(greatest(stock, 0) * coalesce(costo, 0)) filter (where activo), 0),
    'valor_venta', coalesce(sum(greatest(stock, 0) * coalesce(precio, 0)) filter (where activo), 0))
  from productos
$$;

create or replace function public.agente_pedidos(p_estado text default null, p_limite int default 20)
returns jsonb language sql security definer set search_path = public, private, pg_temp as $$
  select coalesce(jsonb_agg(row_to_json(x) order by x.id desc), '[]'::jsonb) from (
    select p.id, p.cliente_nombre, p.cliente_tel, p.estado, p.estado_pago, p.total, p.tipo_entrega,
           concat_ws(', ', p.direccion_calle, p.direccion_depto, p.direccion_comuna) as direccion,
           p.costo_delivery, p.notas, p.created_at, (p.venta_id is not null) as facturado,
           (select jsonb_agg(jsonb_build_object('producto', i.producto_nombre, 'cantidad', i.cantidad, 'subtotal', i.subtotal))
              from pedido_items i where i.pedido_id = p.id) as items
      from pedidos p
     where case when p_estado is null then p.estado in ('pendiente','preparando','en_camino') else p.estado = p_estado end
     order by p.id desc
     limit least(greatest(coalesce(p_limite, 20), 1), 100)
  ) x
$$;

create or replace function public.agente_facturas_por_pagar()
returns jsonb language sql security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object(
    'total_por_pagar', coalesce(sum(total), 0),
    'facturas', coalesce(jsonb_agg(jsonb_build_object('id', id, 'proveedor', proveedor_nombre, 'numero', numero_factura, 'fecha', fecha, 'total', total) order by fecha), '[]'::jsonb))
  from facturas_compra where estado_pago = 'pendiente'
$$;

-- Clientes web: los que más compran y/o llevan días sin comprar
create or replace function public.agente_clientes_web(p_inactivo_dias int default null, p_limite int default 20)
returns jsonb language sql security definer set search_path = public, private, pg_temp as $$
  select coalesce(jsonb_agg(row_to_json(x)), '[]'::jsonb) from (
    select coalesce(nombre, tel_contacto) as nombre, tel_contacto as telefono, pedidos, total, ultimo_pedido,
           (current_date - ultimo_pedido::date) as dias_sin_comprar, acepta_promos and baja_at is null as acepta_promos
      from clientes_web_resumen()
     where p_inactivo_dias is null or (current_date - ultimo_pedido::date) >= p_inactivo_dias
     order by total desc nulls last
     limit least(greatest(coalesce(p_limite, 20), 1), 100)
  ) x
$$;

create or replace function public.agente_proveedores(p_texto text default null)
returns jsonb language sql security definer set search_path = public, private, pg_temp as $$
  select coalesce(jsonb_agg(row_to_json(x)), '[]'::jsonb) from (
    select id, nombre, telefono, contacto from proveedores
     where activo and (p_texto is null or btrim(p_texto) = '' or not exists (
             select 1 from unnest(string_to_array(btrim(p_texto), ' ')) w
              where w <> '' and private.sin_tildes(nombre) not like '%' || private.sin_tildes(w) || '%'))
     order by nombre limit 50
  ) x
$$;

-- ══ PEDIDOS ════════════════════════════════════════════════════════

-- p: {nombre, telefono, entrega: retiro|delivery, calle, depto, comuna, notas,
--     costo_delivery, mayorista, items:[{producto_id, cantidad}]}
create or replace function public.agente_crear_pedido(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_nombre text := private.limpiar_texto(p->>'nombre', 80);
  v_tel    text := private.limpiar_texto(p->>'telefono', 30);
  v_ent    text := coalesce(p->>'entrega', 'retiro');
  v_may    boolean := coalesce((p->>'mayorista')::boolean, false);
  v_deliv  numeric := greatest(0, coalesce(nullif(p->>'costo_delivery', '')::numeric, 0));
  v_id bigint; v_sub numeric := 0; it jsonb; prod record; v_cant numeric; v_precio numeric;
  v_avisos jsonb := '[]'::jsonb;
begin
  if v_nombre is null then raise exception 'Falta el nombre del cliente'; end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'El pedido no tiene productos'; end if;
  if jsonb_array_length(p->'items') > 50 then raise exception 'Demasiados productos'; end if;
  if v_ent not in ('delivery','retiro') then raise exception 'entrega debe ser retiro o delivery'; end if;
  if v_ent = 'delivery' and private.limpiar_texto(p->>'calle', 150) is null then raise exception 'Falta la dirección para el delivery'; end if;

  insert into pedidos (cliente_nombre, cliente_tel, cliente_tel_norm, direccion_calle, direccion_depto, direccion_comuna,
                       notas, total, estado, tipo_entrega, costo_delivery)
  values (v_nombre, v_tel, private.norm_tel(v_tel),
          case when v_ent = 'delivery' then private.limpiar_texto(p->>'calle', 150) end,
          case when v_ent = 'delivery' then private.limpiar_texto(p->>'depto', 60) end,
          case when v_ent = 'delivery' then private.limpiar_texto(p->>'comuna', 80) end,
          private.limpiar_texto(coalesce(p->>'notas', '') || ' [creado por agente]', 500), 0, 'pendiente', v_ent, v_deliv)
  returning id into v_id;

  for it in select * from jsonb_array_elements(p->'items') loop
    select id, nombre, precio, precio_mayor, stock into prod from productos
     where id = (it->>'producto_id')::bigint and activo = true;
    if not found then raise exception 'Producto % no existe o está inactivo', it->>'producto_id'; end if;
    v_cant := (it->>'cantidad')::numeric;
    if v_cant is null or v_cant <= 0 then raise exception 'Cantidad inválida para %', prod.nombre; end if;
    v_precio := case when v_may and coalesce(prod.precio_mayor, 0) > 0 then prod.precio_mayor else prod.precio end;
    insert into pedido_items (pedido_id, producto_id, producto_nombre, cantidad, precio_unitario, subtotal)
    values (v_id, prod.id, prod.nombre, v_cant, v_precio, round(v_cant * v_precio));
    v_sub := v_sub + round(v_cant * v_precio);
    if coalesce(prod.stock, 0) < v_cant then
      v_avisos := v_avisos || to_jsonb('Stock de ' || prod.nombre || ': hay ' || coalesce(prod.stock, 0) || ' y se piden ' || v_cant);
    end if;
  end loop;
  update pedidos set subtotal_productos = v_sub, total = v_sub + v_deliv where id = v_id;
  perform private.agente_log('Pedido creado por agente', 'pedidos', 'Pedido #' || v_id || ' · ' || v_nombre || ' · $' || (v_sub + v_deliv));
  return jsonb_build_object('pedido_id', v_id, 'subtotal', v_sub, 'delivery', v_deliv, 'total', v_sub + v_deliv, 'avisos', v_avisos);
end $$;

create or replace function public.agente_pedido_estado(p_id bigint, p_estado text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare ped record;
begin
  if p_estado not in ('pendiente','preparando','en_camino','entregado','anulado') then raise exception 'Estado inválido'; end if;
  select id, estado, venta_id into ped from pedidos where id = p_id for update;
  if not found then raise exception 'Pedido % no existe', p_id; end if;
  if p_estado = 'anulado' and ped.venta_id is not null then raise exception 'El pedido ya está facturado: se anula desde el panel'; end if;
  update pedidos set estado = p_estado where id = p_id;
  perform private.agente_log('Cambio de estado pedido', 'pedidos', 'Pedido #' || p_id || ' → ' || p_estado);
  return jsonb_build_object('pedido_id', p_id, 'antes', ped.estado, 'ahora', p_estado);
end $$;

create or replace function public.agente_pedido_pago(p_id bigint, p_pagado boolean)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  update pedidos set estado_pago = case when p_pagado then 'pagado' else 'pendiente' end where id = p_id;
  if not found then raise exception 'Pedido % no existe', p_id; end if;
  perform private.agente_log('Pago de pedido', 'pedidos', 'Pedido #' || p_id || ' → ' || case when p_pagado then 'pagado' else 'pendiente' end);
  return jsonb_build_object('pedido_id', p_id, 'estado_pago', case when p_pagado then 'pagado' else 'pendiente' end);
end $$;

-- ══ FACTURAS DE PROVEEDOR ══════════════════════════════════════════

-- p: {proveedor_nombre, proveedor_rut, numero, fecha, total_documento, notas,
--     items:[{producto_id|null, descripcion, cantidad, costo_unitario}]}
-- costo_unitario = precio neto por unidad que dice la factura.
create or replace function public.agente_factura_borrador(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_prov text := private.limpiar_texto(p->>'proveedor_nombre', 120);
  v_provid bigint := nullif(p->>'proveedor_id', '')::bigint;
  v_num  text := private.limpiar_texto(p->>'numero', 40);
  v_fecha date := coalesce(nullif(p->>'fecha', '')::date, current_date);
  v_tot  numeric := nullif(p->>'total_documento', '')::numeric;
  it jsonb; v_pid bigint; v_pnom text; v_auto boolean; v_cand jsonb; v_pcosto numeric; v_items jsonb := '[]'::jsonb; v_suma numeric := 0; v_avisos jsonb := '[]'::jsonb;
  v_cant numeric; v_costo numeric; v_dup bigint; v_id bigint; v_sin int := 0;
begin
  if v_provid is not null then
    select nombre into v_prov from proveedores where id = v_provid;
    if not found then raise exception 'Proveedor % no existe', v_provid; end if;
  end if;
  if v_prov is null then raise exception 'Falta el proveedor (usa proveedor_id o proveedor_nombre)'; end if;
  if v_provid is null then
    v_provid := private.agente_proveedor_match(v_prov);
    if v_provid is not null then
      select nombre into v_pnom from proveedores where id = v_provid;
      if private.agente_norm(v_pnom) <> private.agente_norm(v_prov) then
        v_avisos := v_avisos || to_jsonb('Proveedor identificado: "' || v_prov || '" → ' || v_pnom);
      end if;
      v_prov := v_pnom;
    else
      v_avisos := v_avisos || to_jsonb('Proveedor "' || v_prov || '" no está registrado: se creará al confirmar. Si es uno existente, indica cuál con proveedor_id.');
    end if;
  end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'La factura no tiene productos'; end if;
  if jsonb_array_length(p->'items') > 100 then raise exception 'Demasiadas líneas'; end if;
  if v_fecha > current_date + 1 or v_fecha < current_date - 400 then raise exception 'Fecha de factura sospechosa: %', v_fecha; end if;

  if v_num is not null then
    select id into v_dup from facturas_compra
     where numero_factura = v_num and private.sin_tildes(proveedor_nombre) = private.sin_tildes(v_prov) limit 1;
    if v_dup is not null then raise exception 'Esta factura ya está registrada (factura #%)', v_dup; end if;
    select id into v_dup from facturas_borrador
     where estado = 'borrador' and numero_factura = v_num and private.sin_tildes(proveedor_nombre) = private.sin_tildes(v_prov) limit 1;
    if v_dup is not null then raise exception 'Ya hay un borrador de esta factura (borrador #%). Confírmalo o descártalo', v_dup; end if;
  end if;

  for it in select * from jsonb_array_elements(p->'items') loop
    v_cant  := (it->>'cantidad')::numeric;
    v_costo := (it->>'costo_unitario')::numeric;
    if v_cant is null or v_cant <= 0 then raise exception 'Cantidad inválida en "%"', it->>'descripcion'; end if;
    if v_costo is null or v_costo < 0 then raise exception 'Costo inválido en "%"', it->>'descripcion'; end if;
    v_pid := null; v_pnom := null; v_pcosto := null; v_auto := false; v_cand := '[]'::jsonb;
    if nullif(it->>'producto_id', '') is not null then
      select id, nombre, costo into v_pid, v_pnom, v_pcosto from productos where id = (it->>'producto_id')::bigint;
      if not found then raise exception 'Producto % no existe', it->>'producto_id'; end if;
    else
      v_cand := private.agente_candidatos(it->>'descripcion', v_provid);
      if jsonb_array_length(v_cand) > 0 and (v_cand->0->>'score')::numeric >= 0.6
         and (jsonb_array_length(v_cand) = 1 or (v_cand->0->>'score')::numeric - (v_cand->1->>'score')::numeric >= 0.2) then
        select id, nombre, costo into v_pid, v_pnom, v_pcosto from productos where id = (v_cand->0->>'id')::bigint;
        v_auto := true; v_cand := '[]'::jsonb;
        v_avisos := v_avisos || to_jsonb('Emparejado solo: "' || coalesce(it->>'descripcion', '') || '" → ' || v_pnom || '. Revisa que sea correcto.');
      else
        v_sin := v_sin + 1;
      end if;
    end if;
    if v_pid is not null and coalesce(v_pcosto, 0) > 0 and v_costo > v_pcosto * 1.5 then
      v_avisos := v_avisos || to_jsonb(v_pnom || ': el costo sube más de 50% (de ' || v_pcosto || ' a ' || v_costo || '). Revisa unidad (caja/kg).');
    end if;
    v_items := v_items || jsonb_strip_nulls(jsonb_build_object('producto_id', v_pid, 'producto_nombre', coalesce(v_pnom, private.limpiar_texto(it->>'descripcion', 150)),
                 'descripcion', private.limpiar_texto(it->>'descripcion', 150), 'cantidad', v_cant, 'costo_unitario', v_costo, 'subtotal', round(v_cant * v_costo),
                 'auto', case when v_auto then true end, 'candidatos', case when jsonb_array_length(v_cand) > 0 then v_cand end));
    v_suma := v_suma + round(v_cant * v_costo);
  end loop;

  if v_tot is not null and abs(v_tot - v_suma) > greatest(10, v_suma * 0.01) and abs(v_tot - round(v_suma * 1.19)) > greatest(10, v_suma * 0.01) then
    v_avisos := v_avisos || to_jsonb('DESCUADRE: las líneas suman ' || v_suma || ' (neto) / ' || round(v_suma * 1.19) || ' (con IVA) y la factura dice ' || v_tot || '. Revisa que se leyó bien.');
  end if;
  if v_sin > 0 then v_avisos := v_avisos || to_jsonb(v_sin || ' línea(s) sin producto claro: pregúntale al dueño cuál es (mira candidatos) y usa factura_asignar_producto'); end if;

  insert into facturas_borrador (proveedor_id, proveedor_nombre, proveedor_rut, numero_factura, fecha, total_documento, items, avisos, notas)
  values (v_provid, v_prov, private.limpiar_texto(p->>'proveedor_rut', 20), v_num, v_fecha, v_tot, v_items, v_avisos, private.limpiar_texto(p->>'notas', 300))
  returning id into v_id;
  perform private.agente_log('Borrador de factura', 'proveedores', 'Borrador #' || v_id || ' · ' || v_prov || ' · N° ' || coalesce(v_num, '-'));
  return jsonb_build_object('borrador_id', v_id, 'proveedor', v_prov, 'numero', v_num, 'fecha', v_fecha, 'suma_lineas', v_suma,
                            'total_documento', v_tot, 'lineas_sin_producto', v_sin, 'items', v_items, 'avisos', v_avisos);
end $$;

-- Asigna (o corrige) el producto de una línea del borrador. p_linea parte en 1.
create or replace function public.agente_factura_asignar(p_borrador bigint, p_linea int, p_producto_id bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b record; prod record; v_items jsonb;
begin
  select * into b from facturas_borrador where id = p_borrador and estado = 'borrador' for update;
  if not found then raise exception 'Borrador % no existe o ya no está abierto', p_borrador; end if;
  if p_linea < 1 or p_linea > jsonb_array_length(b.items) then raise exception 'Línea % no existe', p_linea; end if;
  select id, nombre into prod from productos where id = p_producto_id;
  if not found then raise exception 'Producto % no existe', p_producto_id; end if;
  v_items := jsonb_set(jsonb_set(b.items, array[(p_linea - 1)::text, 'producto_id'], to_jsonb(prod.id)),
                       array[(p_linea - 1)::text, 'producto_nombre'], to_jsonb(prod.nombre));
  update facturas_borrador set items = v_items where id = p_borrador;
  return jsonb_build_object('borrador_id', p_borrador, 'linea', p_linea, 'producto', prod.nombre,
    'lineas_sin_producto', (select count(*) from jsonb_array_elements(v_items) e where e->>'producto_id' is null));
end $$;

create or replace function public.agente_factura_descartar(p_borrador bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  update facturas_borrador set estado = 'descartada' where id = p_borrador and estado = 'borrador';
  if not found then raise exception 'Borrador % no existe o ya no está abierto', p_borrador; end if;
  perform private.agente_log('Borrador descartado', 'proveedores', 'Borrador #' || p_borrador);
  return jsonb_build_object('borrador_id', p_borrador, 'estado', 'descartada');
end $$;

-- Confirma: crea la factura, suma stock con su costo y, si está pagada, el gasto. Todo o nada.
create or replace function public.agente_factura_confirmar(p_borrador bigint, p_pagada boolean default false, p_cuenta text default 'bancoestado')
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b record; it jsonb; v_prov bigint; v_fid bigint; v_gid bigint; v_total numeric; v_suma numeric := 0; v_n int := 0;
  v_cuenta text := coalesce(p_cuenta, 'bancoestado');
begin
  if v_cuenta not in ('efectivo','bancoestado','mercadopago') then raise exception 'Cuenta inválida'; end if;
  select * into b from facturas_borrador where id = p_borrador and estado = 'borrador' for update;
  if not found then raise exception 'Borrador % no existe o ya fue confirmado/descartado', p_borrador; end if;
  if exists (select 1 from jsonb_array_elements(b.items) e where e->>'producto_id' is null) then
    raise exception 'Hay líneas sin producto asignado';
  end if;
  if b.numero_factura is not null and exists (
       select 1 from facturas_compra where numero_factura = b.numero_factura
          and private.sin_tildes(proveedor_nombre) = private.sin_tildes(b.proveedor_nombre)) then
    raise exception 'Esta factura ya está registrada';
  end if;

  v_prov := b.proveedor_id;
  if v_prov is null then
    select id into v_prov from proveedores where activo and private.sin_tildes(nombre) = private.sin_tildes(b.proveedor_nombre) limit 1;
  end if;
  if v_prov is null then
    insert into proveedores (nombre, notas) values (b.proveedor_nombre, nullif('RUT ' || coalesce(b.proveedor_rut, ''), 'RUT ')) returning id into v_prov;
  end if;
  select coalesce(sum((e->>'subtotal')::numeric), 0) into v_suma from jsonb_array_elements(b.items) e;
  v_total := coalesce(b.total_documento, v_suma);

  insert into facturas_compra (proveedor_id, proveedor_nombre, numero_factura, fecha, total, estado_pago, notas)
  values (v_prov, b.proveedor_nombre, b.numero_factura, b.fecha, v_total, case when p_pagada then 'pagada' else 'pendiente' end,
          'Ingresada por agente (borrador #' || b.id || ')')
  returning id into v_fid;

  for it in select * from jsonb_array_elements(b.items) loop
    insert into factura_compra_items (factura_id, producto_id, producto_nombre, cantidad, costo_unitario, subtotal)
    values (v_fid, (it->>'producto_id')::bigint, it->>'producto_nombre', (it->>'cantidad')::numeric, (it->>'costo_unitario')::numeric, (it->>'subtotal')::numeric);
    perform public.mover_stock((it->>'producto_id')::bigint, (it->>'cantidad')::numeric, 'entrada',
      'Factura de compra ' || coalesce('N° ' || b.numero_factura, '#' || v_fid) || ' · ' || b.proveedor_nombre,
      'compra', v_fid, 'agente', nullif((it->>'costo_unitario')::numeric, 0));
    v_n := v_n + 1;
  end loop;

  if p_pagada then
    insert into gastos (fecha, descripcion, categoria, monto, cuenta, notas)
    values (b.fecha, 'Factura de compra ' || coalesce('#' || b.numero_factura, '#' || v_fid) || ' — ' || b.proveedor_nombre,
            'mercaderia', v_total, v_cuenta, 'Generado automáticamente al ingresar la factura de compra #' || v_fid)
    returning id into v_gid;
    update facturas_compra set gasto_id = v_gid where id = v_fid;
  end if;

  insert into producto_alias (alias_norm, producto_id, proveedor_id)
  select distinct on (private.agente_norm(e->>'descripcion')) private.agente_norm(e->>'descripcion'), (e->>'producto_id')::bigint, v_prov
    from jsonb_array_elements(b.items) e
   where length(private.agente_norm(e->>'descripcion')) between 3 and 150
     and private.agente_norm(e->>'descripcion') <> private.agente_norm(e->>'producto_nombre')
  on conflict (alias_norm, coalesce(proveedor_id, 0)) do update set producto_id = excluded.producto_id;

  update facturas_borrador set estado = 'confirmada', factura_id = v_fid, confirmada_at = now() where id = b.id;
  perform private.agente_log('Factura de compra registrada', 'proveedores', b.proveedor_nombre || ' — Factura ' || coalesce(b.numero_factura, '-') || ' — $' || v_total);
  return jsonb_build_object('factura_id', v_fid, 'proveedor', b.proveedor_nombre, 'lineas', v_n, 'total', v_total,
                            'estado_pago', case when p_pagada then 'pagada' else 'pendiente' end);
end $$;

create or replace function public.agente_factura_pagar(p_factura bigint, p_cuenta text default 'bancoestado')
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare f record; v_gid bigint; v_cuenta text := coalesce(p_cuenta, 'bancoestado');
begin
  if v_cuenta not in ('efectivo','bancoestado','mercadopago') then raise exception 'Cuenta inválida'; end if;
  select * into f from facturas_compra where id = p_factura for update;
  if not found then raise exception 'Factura % no existe', p_factura; end if;
  if f.estado_pago = 'pagada' then raise exception 'La factura ya está pagada'; end if;
  update facturas_compra set estado_pago = 'pagada' where id = f.id;
  if f.gasto_id is null then
    insert into gastos (fecha, descripcion, categoria, monto, cuenta, notas)
    values (current_date, 'Factura de compra ' || coalesce('#' || f.numero_factura, '#' || f.id) || ' — ' || coalesce(f.proveedor_nombre, ''),
            'mercaderia', f.total, v_cuenta, 'Generado automáticamente al pagar la factura de compra #' || f.id)
    returning id into v_gid;
    update facturas_compra set gasto_id = v_gid where id = f.id;
  end if;
  perform private.agente_log('Factura de compra marcada pagada', 'proveedores', 'Factura #' || f.id);
  return jsonb_build_object('factura_id', f.id, 'estado_pago', 'pagada', 'cuenta', v_cuenta);
end $$;

-- ── permisos: solo pq_agente ejecuta agente_* ──────────────────────
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'agente\_%' loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('grant execute on function %s to pq_agente', f.sig);
  end loop;
end $$;

notify pgrst, 'reload schema';
commit;
