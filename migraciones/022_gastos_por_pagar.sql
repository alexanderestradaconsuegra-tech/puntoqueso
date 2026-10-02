-- ══════════════════════════════════════════════════════════════════
--  022 — Gastos por pagar
--
--  Un gasto puede estar "pendiente" (por pagar) o "pagado". Solo los
--  pagados mueven el saldo de una cuenta, y en la fecha en que se
--  pagaron (fecha_pago). Los gastos recurrentes ahora se generan como
--  pendientes: al pagarlos se elige la cuenta y la fecha.
--   · pagar_gasto(): marca pagado; si sale del cajón, registra además el
--     retiro en la caja abierta (así el cierre cuadra). Todo o nada.
--   · desmarcar_pago_gasto(): vuelve a "por pagar" un gasto marcado
--     pagado por error (no si viene de una factura, del motorizado o de
--     un retiro de caja: eso se corrige en su lugar).
--   · recurrente_id + periodo: un gasto recurrente se genera UNA vez por
--     período aunque el panel esté abierto en dos equipos a la vez.
--  Los gastos existentes quedan como pagados (como estaban).
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

alter table gastos add column if not exists estado_pago text not null default 'pagado';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'gastos_estado_pago_chk') then
    alter table gastos add constraint gastos_estado_pago_chk check (estado_pago in ('pagado','pendiente'));
  end if;
end $$;
alter table gastos add column if not exists fecha_pago date;
alter table gastos add column if not exists recurrente_id bigint references gastos_recurrentes(id) on delete set null;
alter table gastos add column if not exists periodo text;
create unique index if not exists gastos_recurrente_periodo_uq on gastos (recurrente_id, periodo)
  where recurrente_id is not null and periodo is not null;
create index if not exists gastos_pendientes_idx on gastos (fecha) where estado_pago = 'pendiente';
update gastos set fecha_pago = fecha where estado_pago = 'pagado' and fecha_pago is null;

create or replace function public.pagar_gasto(p_id bigint, p_cuenta text, p_fecha date default null, p_desde_caja boolean default false, p_usuario text default null)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare g record; v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Santiago')::date); v_cierre bigint; v_turno bigint;
begin
  if p_cuenta not in ('efectivo','bancoestado','mercadopago') then raise exception 'Elige desde qué cuenta pagas'; end if;
  select * into g from gastos where id = p_id for update;
  if not found then raise exception 'El gasto no existe'; end if;
  if g.estado_pago = 'pagado' then raise exception 'Este gasto ya está pagado'; end if;
  if p_cuenta = 'efectivo' and coalesce(p_desde_caja, false) then
    select id into v_cierre from cierres_caja where estado = 'abierta' order by fecha desc, id desc limit 1;
    if v_cierre is null then raise exception 'Para pagar con plata del cajón, la caja del día debe estar abierta'; end if;
    select id into v_turno from turnos_caja where cierre_id = v_cierre and estado = 'abierto' limit 1;
    insert into caja_movimientos (cierre_id, turno_id, tipo, monto, motivo, gasto_id, registrado_por)
    values (v_cierre, v_turno, 'retiro', g.monto, 'Pago: ' || g.descripcion, g.id, p_usuario);
  end if;
  update gastos set estado_pago = 'pagado', cuenta = p_cuenta, fecha_pago = v_fecha where id = p_id;
  return jsonb_build_object('gasto_id', p_id, 'cuenta', p_cuenta, 'fecha_pago', v_fecha, 'monto', g.monto);
end $$;
revoke all on function public.pagar_gasto(bigint, text, date, boolean, text) from public;
grant execute on function public.pagar_gasto(bigint, text, date, boolean, text) to pq_admin;

create or replace function public.desmarcar_pago_gasto(p_id bigint)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare g record;
begin
  select * into g from gastos where id = p_id for update;
  if not found then raise exception 'El gasto no existe'; end if;
  if g.estado_pago <> 'pagado' then raise exception 'Este gasto no está pagado'; end if;
  if exists (select 1 from facturas_compra where gasto_id = p_id) then
    raise exception 'Este gasto viene de una factura de compra: cámbiala a "Pendiente" editando la factura en Proveedores';
  end if;
  if exists (select 1 from pagos_motorizado where gasto_id = p_id) then
    raise exception 'Este gasto es un pago al motorizado: no se puede desmarcar desde aquí';
  end if;
  if exists (select 1 from caja_movimientos where gasto_id = p_id) then
    raise exception 'Este pago salió del cajón (retiro de caja): no se puede desmarcar desde aquí';
  end if;
  update gastos set estado_pago = 'pendiente', cuenta = null, fecha_pago = null where id = p_id;
  return jsonb_build_object('gasto_id', p_id, 'estado_pago', 'pendiente');
end $$;
revoke all on function public.desmarcar_pago_gasto(bigint) from public;
grant execute on function public.desmarcar_pago_gasto(bigint) to pq_admin;

notify pgrst, 'reload schema';
commit;
