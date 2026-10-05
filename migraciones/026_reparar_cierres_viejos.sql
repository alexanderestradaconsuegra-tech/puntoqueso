-- 026: repara las cajas de días anteriores que se cerraron hoy (5-oct-2026)
-- con el aviso "Falta cerrar la caja del ...". Ese cierre sumó como "esperado"
-- todas las ventas en efectivo desde ese día hasta hoy y dejó un faltante
-- falso que bajó el saldo de Efectivo. Se recalcula con las ventas de SU día
-- y se deja sin diferencia.
with c as (
  select id, fecha, abierta_at from cierres_caja
   where estado = 'cerrada' and fecha < date '2026-10-05' and cerrada_at >= timestamptz '2026-10-05 00:00:00-03'
), v as (
  select c.id,
         coalesce(sum(case when ve.monto_transferencia is null and coalesce(ve.metodo_pago,'efectivo') = 'efectivo' then ve.total else coalesce(ve.monto_efectivo,0) end), 0) as ef,
         coalesce(sum(coalesce(ve.monto_transferencia, case when ve.metodo_pago = 'transferencia' then ve.total else 0 end)), 0) as tr,
         coalesce(sum(coalesce(ve.monto_tarjeta,       case when ve.metodo_pago = 'tarjeta' then ve.total else 0 end)), 0) as tj,
         coalesce(sum(coalesce(ve.monto_mercadopago,   case when ve.metodo_pago = 'mercadopago' then ve.total else 0 end)), 0) as mp,
         count(ve.id) as n
    from c left join ventas ve
      on not ve.anulada and coalesce(ve.estado_pago,'pagado') <> 'pendiente'
     and ve.created_at >= c.abierta_at
     and (ve.created_at at time zone 'America/Santiago')::date = c.fecha
   group by c.id
), m as (
  select c.id,
         coalesce(sum(case when cm.tipo = 'retiro' then cm.monto else 0 end), 0) as ret,
         coalesce(sum(case when cm.tipo <> 'retiro' then cm.monto else 0 end), 0) as ing
    from c left join caja_movimientos cm on cm.cierre_id = c.id
   group by c.id
)
update cierres_caja k
   set ventas_efectivo = v.ef, ventas_transferencia = v.tr, ventas_tarjeta = v.tj, ventas_mercadopago = v.mp,
       ventas_cantidad = v.n, retiros = m.ret, ingresos = m.ing,
       total_esperado = coalesce(k.fondo_inicial, 0) + v.ef + m.ing - m.ret,
       total_contado  = coalesce(k.fondo_inicial, 0) + v.ef + m.ing - m.ret,
       diferencia = 0,
       notas = 'Cerrada sin conteo: quedó abierta de un día anterior (reparada)'
  from v, m
 where k.id = v.id and k.id = m.id;

update turnos_caja t
   set diferencia = 0, total_contado = t.total_esperado,
       notas = 'Cerrado sin conteo: quedó abierto de un día anterior (reparado)'
 where t.cierre_id in (select id from cierres_caja where notas = 'Cerrada sin conteo: quedó abierta de un día anterior (reparada)');

select fecha, total_esperado, diferencia, ventas_cantidad from cierres_caja
 where notas = 'Cerrada sin conteo: quedó abierta de un día anterior (reparada)' order by fecha;
