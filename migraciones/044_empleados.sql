-- ══════════════════════════════════════════════════════════════════
--  044 — Beneficio para el personal: compras con descuento y vales
--
--  empleados          ficha con descuento (15 %), límite mensual de compras
--                     ($50.000) y límite mensual de vales ($50.000).
--  registrar_venta_empleado(p)
--                     venta al DETAL con el descuento del empleado. El precio
--                     lo calcula SIEMPRE el servidor desde el precio normal del
--                     producto (nadie puede mandar otro precio, ni precio mayor).
--                     Rechaza la compra si pasa el límite del mes. Descuenta
--                     stock y deja la venta con medio de pago "empleado": no
--                     entra a Efectivo ni a ninguna cuenta (se cobra con el
--                     descuento de sueldo).
--  empleado_vales     adelantos de plata; salen de la cuenta elegida
--                     (cuenta_movimientos) y se descuentan igual a fin de mes.
--  registrar_vale / anular_vale / descontar_empleado / reabrir_descuento
--                     solo el administrador.
--  Una venta a empleado no cambia de medio de pago, y una ya descontada del
--  sueldo no se anula sin reabrir el descuento.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

create table if not exists empleados (
  id             bigserial primary key,
  nombre         text not null,
  rut            text,
  activo         boolean not null default true,
  descuento_pct  numeric not null default 15 check (descuento_pct >= 0 and descuento_pct <= 100),
  limite_compras numeric not null default 50000 check (limite_compras >= 0),
  limite_vale    numeric not null default 50000 check (limite_vale >= 0),
  notas          text,
  created_at     timestamptz default now()
);

create table if not exists empleado_vales (
  id            bigserial primary key,
  empleado_id   bigint not null references empleados(id),
  fecha         date not null default (now() at time zone 'America/Santiago')::date,
  monto         numeric not null check (monto > 0),
  cuenta        text not null check (cuenta in ('efectivo','bancoestado','mercadopago')),
  nota          text,
  movimiento_id bigint references cuenta_movimientos(id) on delete set null,
  registrado_por text,
  descontado_at timestamptz,
  anulado       boolean not null default false,
  created_at    timestamptz default now()
);
create index if not exists empleado_vales_emp_idx on empleado_vales (empleado_id, fecha);

alter table ventas add column if not exists empleado_id bigint references empleados(id);
alter table ventas add column if not exists descontado_at timestamptz;
create index if not exists ventas_empleado_idx on ventas (empleado_id, created_at) where empleado_id is not null;

do $$ declare t text; begin
  foreach t in array array['empleados','empleado_vales'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "pq_admin acceso total" on %I', t);
    execute format('create policy "pq_admin acceso total" on %I for all to pq_admin using (true) with check (true)', t);
    execute format('grant select, insert, update, delete on %I to pq_admin', t);
  end loop;
end $$;
grant usage, select on all sequences in schema public to pq_admin;

-- ── Compra de un empleado (solo detal, con su descuento) ──────────────
create or replace function public.registrar_venta_empleado(p jsonb)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  e empleados; v ventas; it jsonb; prod record; v_res jsonb;
  v_items jsonb := '[]'::jsonb; v_total numeric := 0; v_desc numeric := 0;
  v_unit numeric; v_sub numeric; v_cant numeric; v_usado numeric; v_ini timestamptz;
  v_uid text := nullif(p->>'venta_uid', '');
begin
  -- la misma compra ya se registró: se devuelve esa, sin volver a contar el límite
  if v_uid is not null then
    select * into v from ventas where venta_uid = v_uid;
    if found then return to_jsonb(v) || jsonb_build_object('repetida', true); end if;
  end if;
  select * into e from empleados where id = nullif(p->>'empleado_id', '')::bigint for update;
  if not found or not e.activo then raise exception 'La persona del personal no existe o está inactiva'; end if;
  if p->'items' is null or jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then
    raise exception 'La compra no tiene productos';
  end if;
  if jsonb_array_length(p->'items') > 100 then raise exception 'Demasiadas líneas en una compra'; end if;

  for it in select * from jsonb_array_elements(p->'items') loop
    if coalesce((it->>'es_mayor')::boolean, false) then
      raise exception 'Las compras del personal son solo al detal: quita el precio por mayor o por pieza';
    end if;
    select id, nombre, precio into prod from productos
     where id = nullif(it->>'producto_id', '')::bigint and activo = true;
    if not found then raise exception 'Un producto de la compra ya no está disponible'; end if;
    v_cant := (it->>'cantidad')::numeric;
    if v_cant is null or v_cant <= 0 or v_cant > 1000 then raise exception 'Cantidad inválida'; end if;
    v_unit := round(prod.precio * (1 - e.descuento_pct / 100));
    v_sub  := round(v_unit * v_cant);
    v_total := v_total + v_sub;
    v_desc  := v_desc + (prod.precio * v_cant - v_sub);
    v_items := v_items || jsonb_build_object(
      'producto_id', prod.id, 'producto_nombre', coalesce(nullif(it->>'producto_nombre', ''), prod.nombre),
      'cantidad', v_cant, 'precio_unitario', v_unit, 'subtotal', v_sub,
      'precio_original', prod.precio, 'es_mayor', false);
  end loop;

  -- límite del mes calendario (hora de Chile)
  v_ini := date_trunc('month', now() at time zone 'America/Santiago') at time zone 'America/Santiago';
  select coalesce(sum(total), 0) into v_usado from ventas
   where empleado_id = e.id and not coalesce(anulada, false) and created_at >= v_ini;
  if v_usado + v_total > e.limite_compras then
    raise exception 'Supera el límite mensual de % (lleva $%, esta compra es $% y el límite es $%). Disponible: $%',
      e.nombre, replace(to_char(v_usado, 'FM999,999,999'), ',', '.'), replace(to_char(v_total, 'FM999,999,999'), ',', '.'),
      replace(to_char(e.limite_compras, 'FM999,999,999'), ',', '.'),
      replace(to_char(greatest(e.limite_compras - v_usado, 0), 'FM999,999,999'), ',', '.');
  end if;

  v_res := public.registrar_venta(jsonb_build_object(
    'cliente_nombre', 'Personal: ' || e.nombre, 'total', v_total,
    'metodo_pago', 'empleado', 'metodo_pago_detalle', 'Descuento de sueldo',
    'monto_efectivo', 0, 'monto_otro', 0, 'monto_transferencia', 0, 'monto_tarjeta', 0, 'monto_mercadopago', 0,
    'delivery_monto', 0, 'descuento', round(v_desc),
    'registrado_por', p->>'registrado_por', 'turno_id', p->>'turno_id', 'fuera_caja', p->>'fuera_caja',
    'venta_uid', v_uid, 'items', v_items));
  update ventas set empleado_id = e.id where id = (v_res->>'id')::bigint and empleado_id is null;
  return v_res || jsonb_build_object('empleado_id', e.id, 'usado_mes', v_usado + v_total, 'limite', e.limite_compras);
end $$;
revoke all on function public.registrar_venta_empleado(jsonb) from public;
grant execute on function public.registrar_venta_empleado(jsonb) to pq_admin;

-- ── Vale (adelanto de plata) ───────────────────────────────────────────
create or replace function public.registrar_vale(p jsonb)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  e empleados; v_monto numeric := (p->>'monto')::numeric; v_cuenta text := p->>'cuenta';
  v_hoy date := (now() at time zone 'America/Santiago')::date; v_usado numeric; v_mov bigint; v_id bigint;
begin
  if not private.es_dueno() then raise exception 'Solo el administrador registra vales'; end if;
  select * into e from empleados where id = nullif(p->>'empleado_id', '')::bigint for update;
  if not found or not e.activo then raise exception 'La persona del personal no existe o está inactiva'; end if;
  if v_monto is null or v_monto <= 0 then raise exception 'Escribe el monto del vale'; end if;
  if v_cuenta is null or v_cuenta not in ('efectivo','bancoestado','mercadopago') then raise exception 'Elige de qué cuenta sale la plata'; end if;
  select coalesce(sum(monto), 0) into v_usado from empleado_vales
   where empleado_id = e.id and not anulado and fecha >= date_trunc('month', v_hoy)::date;
  if v_usado + v_monto > e.limite_vale then
    raise exception 'Supera el límite mensual de vales de % (lleva $%, límite $%)', e.nombre,
      replace(to_char(v_usado, 'FM999,999,999'), ',', '.'), replace(to_char(e.limite_vale, 'FM999,999,999'), ',', '.');
  end if;
  insert into cuenta_movimientos (fecha, tipo, cuenta_origen, monto, descripcion, registrado_por)
  values (v_hoy, 'egreso', v_cuenta, v_monto, 'Vale personal: ' || e.nombre, nullif(p->>'registrado_por', ''))
  returning id into v_mov;
  insert into empleado_vales (empleado_id, fecha, monto, cuenta, nota, movimiento_id, registrado_por)
  values (e.id, v_hoy, v_monto, v_cuenta, nullif(p->>'nota', ''), v_mov, nullif(p->>'registrado_por', ''))
  returning id into v_id;
  return jsonb_build_object('vale_id', v_id, 'usado_mes', v_usado + v_monto, 'limite', e.limite_vale);
end $$;
revoke all on function public.registrar_vale(jsonb) from public;
grant execute on function public.registrar_vale(jsonb) to pq_admin;

create or replace function public.anular_vale(p_id bigint)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare v empleado_vales;
begin
  if not private.es_dueno() then raise exception 'Solo el administrador anula vales'; end if;
  select * into v from empleado_vales where id = p_id for update;
  if not found then raise exception 'El vale no existe'; end if;
  if v.anulado then raise exception 'El vale ya está anulado'; end if;
  if v.descontado_at is not null then raise exception 'Este vale ya se descontó del sueldo: reabre el descuento antes de anularlo'; end if;
  update empleado_vales set anulado = true, movimiento_id = null where id = p_id;
  if v.movimiento_id is not null then delete from cuenta_movimientos where id = v.movimiento_id; end if;
  return jsonb_build_object('vale_id', p_id, 'anulado', true);
end $$;
revoke all on function public.anular_vale(bigint) from public;
grant execute on function public.anular_vale(bigint) to pq_admin;

-- ── Descuento de sueldo del mes ───────────────────────────────────────
create or replace function public.descontar_empleado(p_empleado bigint, p_mes text)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v_ini date := to_date(p_mes || '-01', 'YYYY-MM-DD'); v_fin date; v_c numeric; v_v numeric;
begin
  if not private.es_dueno() then raise exception 'Solo el administrador marca descuentos'; end if;
  v_fin := (v_ini + interval '1 month')::date;
  with u as (
    update ventas set descontado_at = now()
     where empleado_id = p_empleado and not coalesce(anulada, false) and descontado_at is null
       and (created_at at time zone 'America/Santiago')::date >= v_ini and (created_at at time zone 'America/Santiago')::date < v_fin
     returning total)
  select coalesce(sum(total), 0) into v_c from u;
  with u as (
    update empleado_vales set descontado_at = now()
     where empleado_id = p_empleado and not anulado and descontado_at is null and fecha >= v_ini and fecha < v_fin
     returning monto)
  select coalesce(sum(monto), 0) into v_v from u;
  return jsonb_build_object('compras', v_c, 'vales', v_v, 'total', v_c + v_v);
end $$;
revoke all on function public.descontar_empleado(bigint, text) from public;
grant execute on function public.descontar_empleado(bigint, text) to pq_admin;

create or replace function public.reabrir_descuento(p_empleado bigint, p_mes text)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare v_ini date := to_date(p_mes || '-01', 'YYYY-MM-DD'); v_fin date; n1 int; n2 int;
begin
  if not private.es_dueno() then raise exception 'Solo el administrador reabre descuentos'; end if;
  v_fin := (v_ini + interval '1 month')::date;
  update ventas set descontado_at = null
   where empleado_id = p_empleado and descontado_at is not null
     and (created_at at time zone 'America/Santiago')::date >= v_ini and (created_at at time zone 'America/Santiago')::date < v_fin;
  get diagnostics n1 = row_count;
  update empleado_vales set descontado_at = null
   where empleado_id = p_empleado and descontado_at is not null and fecha >= v_ini and fecha < v_fin;
  get diagnostics n2 = row_count;
  return jsonb_build_object('compras', n1, 'vales', n2);
end $$;
revoke all on function public.reabrir_descuento(bigint, text) from public;
grant execute on function public.reabrir_descuento(bigint, text) to pq_admin;

-- ── Candados sobre las ventas de empleados ─────────────────────────────
create or replace function private.venta_empleado_guard() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if old.empleado_id is not null then
    if new.metodo_pago is distinct from old.metodo_pago then
      raise exception 'Una compra del personal no cambia de medio de pago';
    end if;
    if coalesce(new.anulada, false) and not coalesce(old.anulada, false) and old.descontado_at is not null then
      raise exception 'Esta compra ya se descontó del sueldo: reabre el descuento del mes antes de anularla';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists venta_empleado_guard on ventas;
create trigger venta_empleado_guard before update on ventas
  for each row execute function private.venta_empleado_guard();

notify pgrst, 'reload schema';
commit;
