-- ══════════════════════════════════════════════════════════════════
--  008 — Delivery por distancia y programa de referidos
--
--  DELIVERY
--    El precio sale de la distancia en línea recta ("a la redonda") entre
--    el local (config local_lat/local_lng) y el punto del cliente, según
--    config delivery_tramos: [{"km":3,"precio":2500},{"km":5,"precio":3500},
--    {"km":7,"precio":5000}]. Más lejos, o sin ubicación: 'coordinar'
--    (se acuerda por WhatsApp y el local fija el monto en el panel).
--    El cálculo lo hace SIEMPRE el servidor: el navegador solo manda el punto.
--
--  REFERIDOS (identidad = teléfono, sin cuentas)
--    · Un cliente que ya compró tiene un código (referidos_codigos).
--    · Quien llega con ?ref=CODIGO y es NUEVO (su teléfono nunca pidió ni
--      está en clientes), con productos >= referidos_minimo, en una
--      dirección distinta a la de quien lo invitó: delivery gratis y queda
--      un registro en referidos (pendiente).
--    · Cuando ESE pedido queda entregado y pagado, quien invitó gana un
--      delivery gratis (referidos_premios), que vence a los referidos_dias
--      y no acumula más de referidos_tope.
--    · El premio se aplica solo en su próximo pedido con delivery y
--      productos >= mínimo. Si el pedido se anula, el premio vuelve.
--    Todo se valida aquí; el navegador no decide nada.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

-- ── Ayudas ──────────────────────────────────────────────────────────
-- Teléfono chileno normalizado: últimos 9 dígitos (+56 9 1234 5678 → 912345678)
create or replace function private.norm_tel(t text) returns text
language sql immutable as $$
  select case when length(regexp_replace(coalesce(t, ''), '\D', '', 'g')) >= 8
              then right(regexp_replace(t, '\D', '', 'g'), 9) end
$$;

-- Dirección comparable: sin tildes, mayúsculas, espacios ni signos
create or replace function private.norm_dir(calle text, comuna text) returns text
language sql immutable as $$
  select nullif(regexp_replace(lower(translate(coalesce(calle, '') || '|' || coalesce(comuna, ''),
         'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')), '[^a-z0-9|]', '', 'g'), '|')
$$;

-- Distancia en km, en línea recta (haversine)
create or replace function private.dist_km(lat1 float8, lng1 float8, lat2 float8, lng2 float8) returns numeric
language sql immutable as $$
  select round((2 * 6371 * asin(sqrt(
           power(sin(radians(lat2 - lat1) / 2), 2) +
           cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))))::numeric, 2)
$$;

create or replace function private.cfg_txt(k text) returns text
language sql stable as $$
  select nullif(btrim(valor #>> '{}'), '') from public.config where clave = k
$$;

create or replace function private.cfg_num(k text, def numeric) returns numeric
language plpgsql stable as $$
declare v text := private.cfg_txt(k);
begin
  if v is null then return def; end if;
  return replace(v, ',', '.')::numeric;
exception when others then return def;
end $$;

create or replace function private.clp(n numeric) returns text
language sql immutable as $$
  select '$' || replace(to_char(round(coalesce(n, 0)), 'FM999,999,999'), ',', '.')
$$;

-- Precio del delivery para un punto. zona: 'delivery' | 'coordinar'
create or replace function private.cotizar(p_lat float8, p_lng float8) returns jsonb
language plpgsql stable as $$
declare
  llat float8 := private.cfg_num('local_lat', null);
  llng float8 := private.cfg_num('local_lng', null);
  km numeric;
  tramos jsonb;
  t jsonb;
begin
  if p_lat is null or p_lng is null or llat is null or llng is null
     or p_lat not between -56 and -17 or p_lng not between -76 and -66 then
    return jsonb_build_object('zona', 'coordinar', 'km', null, 'precio', null);
  end if;
  km := private.dist_km(llat, llng, p_lat, p_lng);
  select valor into tramos from public.config where clave = 'delivery_tramos';
  if jsonb_typeof(tramos) = 'string' then tramos := (tramos #>> '{}')::jsonb; end if;
  if jsonb_typeof(tramos) = 'array' then
    for t in select value from jsonb_array_elements(tramos) order by (value->>'km')::numeric loop
      if km <= (t->>'km')::numeric then
        return jsonb_build_object('zona', 'delivery', 'km', km, 'precio', (t->>'precio')::numeric);
      end if;
    end loop;
  end if;
  return jsonb_build_object('zona', 'coordinar', 'km', km, 'precio', null);
exception when others then
  return jsonb_build_object('zona', 'coordinar', 'km', km, 'precio', null);
end $$;

-- ── Configuración inicial (no pisa lo que ya exista) ───────────────
insert into config (clave, valor) values
  ('delivery_tramos',   '[{"km":3,"precio":2500},{"km":5,"precio":3500},{"km":7,"precio":5000}]'::jsonb),
  ('referidos_activo',  '"true"'::jsonb),
  ('referidos_minimo',  '"20000"'::jsonb),
  ('referidos_tope',    '"3"'::jsonb),
  ('referidos_dias',    '"90"'::jsonb),
  ('tienda_url',        '"https://quesosvenezolanos.cl"'::jsonb)
on conflict (clave) do nothing;

-- ── Pedidos: entrega y beneficios ──────────────────────────────────
alter table pedidos add column if not exists tipo_entrega text;         -- delivery | retiro | coordinar (null = pedido antiguo o manual)
alter table pedidos add column if not exists lat double precision;
alter table pedidos add column if not exists lng double precision;
alter table pedidos add column if not exists distancia_km numeric;
alter table pedidos add column if not exists costo_delivery numeric;    -- null = por definir; ya incluido en total
alter table pedidos add column if not exists subtotal_productos numeric;
alter table pedidos add column if not exists beneficio_delivery text;   -- referido | premio
alter table pedidos add column if not exists referido_codigo text;
alter table pedidos add column if not exists cliente_tel_norm text;
update pedidos set cliente_tel_norm = private.norm_tel(cliente_tel)
  where cliente_tel_norm is distinct from private.norm_tel(cliente_tel);
create index if not exists pedidos_tel_norm_idx on pedidos (cliente_tel_norm);

-- ── Referidos ──────────────────────────────────────────────────────
create table if not exists referidos_codigos (
  telefono   text primary key,          -- normalizado
  codigo     text not null unique,
  nombre     text,
  created_at timestamptz default now()
);

create table if not exists referidos (
  id              bigserial primary key,
  codigo          text not null,
  referente_tel   text not null,
  referido_tel    text not null,
  referido_nombre text,
  pedido_id       bigint references pedidos(id) on delete set null,
  estado          text not null default 'pendiente'
                  check (estado in ('pendiente','ganado','sin_premio','anulado')),
  nota            text,
  created_at      timestamptz default now(),
  ganado_at       timestamptz
);
-- Un teléfono se refiere una sola vez (salvo que esa vez se haya anulado)
create unique index if not exists referidos_referido_unico on referidos (referido_tel) where estado <> 'anulado';
create index if not exists referidos_pedido_idx on referidos (pedido_id);

create table if not exists referidos_premios (
  id            bigserial primary key,
  telefono      text not null,            -- quien invitó (normalizado)
  referido_id   bigint references referidos(id) on delete set null,
  estado        text not null default 'disponible' check (estado in ('disponible','usado','anulado')),
  vence_at      timestamptz not null,
  pedido_uso_id bigint references pedidos(id) on delete set null,
  notificado    boolean not null default false,
  created_at    timestamptz default now(),
  usado_at      timestamptz
);
create index if not exists referidos_premios_tel_idx on referidos_premios (telefono, estado);

do $$ declare t text; begin
  foreach t in array array['referidos_codigos','referidos','referidos_premios'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "pq_admin acceso total" on %I', t);
    execute format('create policy "pq_admin acceso total" on %I for all to pq_admin using (true) with check (true)', t);
    execute format('grant select, insert, update, delete on %I to pq_admin', t);
  end loop;
end $$;
grant usage, select on all sequences in schema public to pq_admin;

-- ── Código de un cliente (solo si ya compró de verdad) ─────────────
create or replace function private.nuevo_codigo() returns text
language plpgsql volatile as $$
declare abc text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  loop
    c := '';
    for i in 1..6 loop c := c || substr(abc, 1 + floor(random() * length(abc))::int, 1); end loop;
    exit when not exists (select 1 from public.referidos_codigos where codigo = c);
  end loop;
  return c;
end $$;

create or replace function public.codigo_referido(p_tel text, p_nombre text default null) returns text
language plpgsql security definer set search_path = public, private as $$
declare t text := private.norm_tel(p_tel); c text;
begin
  if t is null then raise exception 'Teléfono inválido'; end if;
  select codigo into c from referidos_codigos where telefono = t;
  if c is not null then return c; end if;
  -- Ya compró: un pedido entregado, o una venta del local a un cliente con ese teléfono
  if not exists (select 1 from pedidos where cliente_tel_norm = t and estado in ('entregado','facturado'))
     and not exists (select 1 from ventas v join clientes cl on cl.id = v.cliente_id
                      where private.norm_tel(cl.telefono) = t and not coalesce(v.anulada, false)) then
    return null;
  end if;
  insert into referidos_codigos (telefono, codigo, nombre)
  values (t, private.nuevo_codigo(), private.limpiar_texto(p_nombre, 80))
  on conflict (telefono) do nothing;
  select codigo into c from referidos_codigos where telefono = t;
  return c;
end $$;
revoke all on function public.codigo_referido(text, text) from public;
grant execute on function public.codigo_referido(text, text) to pq_admin;

-- ── Cotizar delivery (lo usa la tienda para mostrar el precio) ─────
create or replace function public.cotizar_delivery(p_lat float8, p_lng float8) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select private.cotizar(p_lat, p_lng)
$$;
revoke all on function public.cotizar_delivery(float8, float8) from public;
grant execute on function public.cotizar_delivery(float8, float8) to web_anon, pq_admin;

-- ── Pedido desde la tienda web (reemplaza a crear_pedido_publico) ──
-- p: {nombre, telefono, calle, depto, comuna, notas, entrega:'delivery'|'retiro',
--     lat, lng, ref, items:[{producto_id, cantidad}]}
create or replace function public.crear_pedido_web(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare
  v_nombre  text := private.limpiar_texto(p->>'nombre', 80);
  v_tel     text := private.limpiar_texto(p->>'telefono', 30);
  v_tn      text := private.norm_tel(p->>'telefono');
  v_calle   text := private.limpiar_texto(p->>'calle', 150);
  v_depto   text := private.limpiar_texto(p->>'depto', 60);
  v_comuna  text := private.limpiar_texto(p->>'comuna', 80);
  v_notas   text := private.limpiar_texto(p->>'notas', 500);
  v_entrega text := coalesce(p->>'entrega', 'delivery');
  v_ref     text := upper(private.limpiar_texto(p->>'ref', 20));
  v_items   jsonb := p->'items';
  v_lat float8; v_lng float8;
  v_min    numeric := private.cfg_num('referidos_minimo', 20000);
  v_activo boolean := coalesce(lower(private.cfg_txt('referidos_activo')), 'true') not in ('false','0','no');
  v_id bigint; v_sub numeric := 0; v_cant numeric; it jsonb; prod record;
  v_cot jsonb; v_tipo text; v_km numeric; v_costo numeric;
  v_benef text; v_msg text; v_refe text; v_nuevo boolean; v_premio bigint; v_ref_ok boolean := false;
begin
  if v_nombre is null then raise exception 'Ingresa tu nombre'; end if;
  if v_tel is null or v_tn is null then raise exception 'Revisa tu número de WhatsApp'; end if;
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'El pedido no tiene productos';
  end if;
  if jsonb_array_length(v_items) > 50 then raise exception 'Demasiados productos en un solo pedido'; end if;
  if v_entrega not in ('delivery','retiro') then v_entrega := 'delivery'; end if;
  begin
    v_lat := (p->>'lat')::float8; v_lng := (p->>'lng')::float8;
  exception when others then v_lat := null; v_lng := null;
  end;
  if v_lat is null or v_lng is null then v_lat := null; v_lng := null; end if;
  if v_entrega = 'delivery' and v_calle is null and v_lat is null then
    raise exception 'Escribe tu dirección o usa tu ubicación actual';
  end if;

  insert into pedidos (cliente_nombre, cliente_tel, direccion_calle, direccion_depto,
                       direccion_comuna, notas, total, estado)
  values (v_nombre, v_tel,
          case when v_entrega = 'delivery' then v_calle end,
          case when v_entrega = 'delivery' then v_depto end,
          case when v_entrega = 'delivery' then v_comuna end,
          v_notas, 0, 'pendiente')
  returning id into v_id;

  for it in select * from jsonb_array_elements(v_items) loop
    v_cant := (it->>'cantidad')::numeric;
    if v_cant is null or v_cant <= 0 or v_cant > 1000 then raise exception 'Cantidad inválida'; end if;
    select id, nombre, precio into prod
      from productos where id = (it->>'producto_id')::bigint and activo = true and en_catalogo = true;
    if not found then raise exception 'Un producto de tu pedido ya no está disponible'; end if;
    insert into pedido_items (pedido_id, producto_id, producto_nombre, cantidad, precio_unitario, subtotal)
    values (v_id, prod.id, prod.nombre, v_cant, prod.precio, prod.precio * v_cant);
    v_sub := v_sub + prod.precio * v_cant;
  end loop;

  -- Entrega
  if v_entrega = 'retiro' then
    v_tipo := 'retiro'; v_costo := 0; v_lat := null; v_lng := null;
  else
    v_cot := private.cotizar(v_lat, v_lng);
    v_tipo := v_cot->>'zona';
    v_km := (v_cot->>'km')::numeric;
    v_costo := (v_cot->>'precio')::numeric;
  end if;

  -- Referidos
  if v_activo then
    v_nuevo := not exists (select 1 from pedidos where cliente_tel_norm = v_tn and id <> v_id and estado <> 'anulado')
           and not exists (select 1 from clientes where private.norm_tel(telefono) = v_tn);
    if v_ref is not null then
      select telefono into v_refe from referidos_codigos where codigo = v_ref;
      if v_refe is null then
        v_msg := 'El código de invitación no es válido.';
      elsif v_refe = v_tn then
        v_msg := 'No puedes usar tu propio código de invitación.';
      elsif not v_nuevo or exists (select 1 from referidos where referido_tel = v_tn and estado <> 'anulado') then
        v_msg := 'La invitación es solo para la primera compra.';
      elsif v_sub < v_min then
        v_msg := 'La invitación aplica con productos desde ' || private.clp(v_min) || '.';
      elsif exists (select 1 from pedidos q where q.cliente_tel_norm = v_refe and q.estado <> 'anulado' and (
                     (v_calle is not null and v_entrega = 'delivery'
                      and private.norm_dir(q.direccion_calle, q.direccion_comuna) = private.norm_dir(v_calle, v_comuna))
                  or (v_lat is not null and q.lat is not null and private.dist_km(q.lat, q.lng, v_lat, v_lng) < 0.05))) then
        v_msg := 'La invitación no aplica a la misma dirección de quien te invitó.';
      else
        insert into referidos (codigo, referente_tel, referido_tel, referido_nombre, pedido_id)
        values (v_ref, v_refe, v_tn, v_nombre, v_id);
        v_ref_ok := true;
        if v_tipo = 'delivery' and v_costo > 0 then
          v_costo := 0; v_benef := 'referido';
          v_msg := '¡Delivery gratis por invitación!';
        else
          v_msg := 'Invitación registrada: quien te invitó gana un delivery gratis.';
        end if;
      end if;
    end if;
    -- Premio ganado por invitar
    if v_benef is null and v_tipo = 'delivery' and v_costo > 0 and v_sub >= v_min then
      select id into v_premio from referidos_premios
       where telefono = v_tn and estado = 'disponible' and vence_at > now()
       order by vence_at limit 1 for update;
      if v_premio is not null then
        update referidos_premios set estado = 'usado', pedido_uso_id = v_id, usado_at = now() where id = v_premio;
        v_costo := 0; v_benef := 'premio';
        v_msg := '¡Usaste tu delivery gratis ganado por invitar!';
      end if;
    end if;
  end if;

  update pedidos set
      subtotal_productos = v_sub,
      costo_delivery     = v_costo,
      total              = v_sub + coalesce(v_costo, 0),
      tipo_entrega       = v_tipo,
      distancia_km       = v_km,
      lat                = v_lat,
      lng                = v_lng,
      beneficio_delivery = v_benef,
      referido_codigo    = case when v_ref_ok then v_ref end
    where id = v_id;

  return jsonb_build_object('id', v_id, 'subtotal', v_sub, 'delivery', v_costo,
                            'total', v_sub + coalesce(v_costo, 0), 'tipo', v_tipo, 'km', v_km,
                            'beneficio', v_benef, 'mensaje', v_msg);
end $$;
revoke all on function public.crear_pedido_web(jsonb) from public;
grant execute on function public.crear_pedido_web(jsonb) to web_anon, pq_admin;

-- ── Ciclo de vida: ganar, devolver y anular premios ────────────────
create or replace function private.pedidos_referidos_trg() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare
  r record; n int;
  v_tope int := private.cfg_num('referidos_tope', 3);
  v_dias int := private.cfg_num('referidos_dias', 90);
begin
  if tg_op = 'DELETE' then
    update referidos set estado = 'anulado', nota = 'Pedido eliminado' where pedido_id = old.id and estado = 'pendiente';
    update referidos_premios set estado = 'disponible', pedido_uso_id = null, usado_at = null
     where pedido_uso_id = old.id and estado = 'usado';
    return old;
  end if;

  new.cliente_tel_norm := private.norm_tel(new.cliente_tel);

  if tg_op = 'UPDATE' then
    if new.estado = 'anulado' and old.estado is distinct from 'anulado' then
      -- el premio que usó este pedido vuelve a estar disponible
      update referidos_premios set estado = 'disponible', pedido_uso_id = null, usado_at = null
       where pedido_uso_id = new.id and estado = 'usado';
      -- lo que ganó quien invitó con este pedido se anula (si aún no lo usó)
      update referidos_premios set estado = 'anulado'
       where estado = 'disponible' and referido_id in (select id from referidos where pedido_id = new.id);
      update referidos set estado = 'anulado', nota = 'Pedido anulado'
       where pedido_id = new.id and estado in ('pendiente','ganado','sin_premio');
    elsif new.estado in ('entregado','facturado') and new.estado_pago = 'pagado'
          and not (old.estado in ('entregado','facturado') and old.estado_pago = 'pagado') then
      for r in select * from referidos where pedido_id = new.id and estado = 'pendiente' loop
        select count(*) into n from referidos_premios
         where telefono = r.referente_tel and estado = 'disponible' and vence_at > now();
        if n < v_tope then
          insert into referidos_premios (telefono, referido_id, vence_at)
          values (r.referente_tel, r.id, now() + make_interval(days => v_dias));
          update referidos set estado = 'ganado', ganado_at = now() where id = r.id;
        else
          update referidos set estado = 'sin_premio', ganado_at = now(),
                 nota = 'Ya tenía ' || v_tope || ' deliveries gratis sin usar' where id = r.id;
        end if;
      end loop;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists pedidos_referidos on pedidos;
create trigger pedidos_referidos before insert or update or delete on pedidos
  for each row execute function private.pedidos_referidos_trg();

-- ── Lo que el público puede leer de config ─────────────────────────
drop policy if exists "web_anon config publica" on config;
create policy "web_anon config publica" on config for select to web_anon
  using (clave in ('nombre_negocio','whatsapp','negocio_nombre','negocio_razon_social','negocio_rut',
                   'negocio_direccion','negocio_telefono','negocio_instagram','negocio_tiktok',
                   'catalogo_url','google_review_url',
                   'google_maps_key','delivery_tramos','local_lat','local_lng',
                   'referidos_activo','referidos_minimo','tienda_url'));

notify pgrst, 'reload schema';
commit;
