-- ══════════════════════════════════════════════════════════════════
--  018 — Delivery que se traspasa al motorizado
--
--  El cliente paga el delivery junto con la compra y el dueño le paga
--  ese mismo monto al motorizado después. Ese dinero no es ingreso del
--  negocio: se lleva como "por pagar al motorizado".
--   · ventas.delivery_monto: la parte de la venta que es delivery
--     (la línea "Delivery" de la boleta sigue siendo parte del total).
--   · ventas.delivery_pago_id: a qué pago al motorizado se incluyó
--     (null = todavía por pagar).
--   · pagos_motorizado: cada pago (fecha, monto, cuenta, quién).
--   · pagar_motorizado(): paga varias entregas juntas, en una sola
--     transacción: registra el pago, el gasto "delivery" y, si sale del
--     cajón, el retiro de caja. Todo o nada.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

create table if not exists pagos_motorizado (
  id             bigserial primary key,
  fecha          date not null default current_date,
  monto          numeric not null check (monto > 0),
  cuenta         text not null check (cuenta in ('efectivo','bancoestado','mercadopago')),
  motorizado     text,
  entregas       int not null default 0,
  notas          text,
  gasto_id       bigint references gastos(id) on delete set null,
  registrado_por text,
  created_at     timestamptz default now()
);
alter table pagos_motorizado enable row level security;
drop policy if exists "pq_admin acceso total" on pagos_motorizado;
create policy "pq_admin acceso total" on pagos_motorizado for all to pq_admin using (true) with check (true);
grant select, insert, update, delete on pagos_motorizado to pq_admin;
grant usage, select on all sequences in schema public to pq_admin;

alter table ventas add column if not exists delivery_monto numeric not null default 0;
alter table ventas add column if not exists delivery_pago_id bigint;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'ventas_delivery_pago_fk') then
    alter table ventas add constraint ventas_delivery_pago_fk foreign key (delivery_pago_id) references pagos_motorizado(id) on delete set null;
  end if;
end $$;
create index if not exists ventas_delivery_pendiente_idx on ventas (created_at) where delivery_monto > 0 and delivery_pago_id is null;

-- Ventas anteriores: el delivery ya estaba como línea "Delivery" en la boleta
update ventas v set delivery_monto = x.m
  from (select venta_id, sum(subtotal) m from venta_items where producto_id is null and producto_nombre = 'Delivery' group by 1) x
 where x.venta_id = v.id and v.delivery_monto = 0;

-- p_ventas: ids de las ventas cuyo delivery se paga ahora. Paga solo las que siguen pendientes y no anuladas.
create or replace function public.pagar_motorizado(p_ventas bigint[], p_cuenta text, p_motorizado text default null, p_usuario text default null, p_notas text default null)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v_monto numeric; v_n int; v_pago bigint; v_gasto bigint;
  v_hoy date := (now() at time zone 'America/Santiago')::date;
  v_cierre bigint; v_turno bigint; v_mot text := nullif(btrim(coalesce(p_motorizado, '')), '');
begin
  if p_cuenta not in ('efectivo','bancoestado','mercadopago') then raise exception 'Elige desde qué cuenta pagas'; end if;
  if p_ventas is null or cardinality(p_ventas) = 0 then raise exception 'Elige al menos una entrega'; end if;

  select coalesce(sum(delivery_monto), 0), count(*) into v_monto, v_n
    from (select delivery_monto from ventas
           where id = any(p_ventas) and delivery_monto > 0 and delivery_pago_id is null and not anulada for update) x;
  if v_n = 0 or v_monto <= 0 then raise exception 'No hay entregas pendientes de pago en la selección'; end if;

  if p_cuenta = 'efectivo' then
    select id into v_cierre from cierres_caja where estado = 'abierta' order by fecha desc, id desc limit 1;
    if v_cierre is null then raise exception 'Para pagar en efectivo desde el cajón, la caja del día debe estar abierta'; end if;
    select id into v_turno from turnos_caja where cierre_id = v_cierre and estado = 'abierto' limit 1;
  end if;

  insert into gastos (fecha, descripcion, categoria, monto, cuenta, notas)
  values (v_hoy, 'Pago motorizado' || coalesce(' — ' || v_mot, '') || ' (' || v_n || ' entrega' || case when v_n = 1 then '' else 's' end || ')',
          'delivery', v_monto, p_cuenta, coalesce(p_notas, 'Delivery cobrado a los clientes y traspasado al motorizado'))
  returning id into v_gasto;

  insert into pagos_motorizado (fecha, monto, cuenta, motorizado, entregas, notas, gasto_id, registrado_por)
  values (v_hoy, v_monto, p_cuenta, v_mot, v_n, p_notas, v_gasto, p_usuario)
  returning id into v_pago;

  update ventas set delivery_pago_id = v_pago
   where id = any(p_ventas) and delivery_monto > 0 and delivery_pago_id is null and not anulada;

  if p_cuenta = 'efectivo' then
    insert into caja_movimientos (cierre_id, turno_id, tipo, monto, motivo, gasto_id, registrado_por)
    values (v_cierre, v_turno, 'retiro', v_monto, 'Pago motorizado' || coalesce(' — ' || v_mot, ''), v_gasto, p_usuario);
  end if;
  return jsonb_build_object('pago_id', v_pago, 'monto', v_monto, 'entregas', v_n, 'gasto_id', v_gasto);
end $$;
revoke all on function public.pagar_motorizado(bigint[], text, text, text, text) from public;
grant execute on function public.pagar_motorizado(bigint[], text, text, text, text) to pq_admin;

notify pgrst, 'reload schema';
commit;
