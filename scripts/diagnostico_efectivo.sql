-- Diagnóstico del Efectivo (SOLO LEE, no cambia nada). Reproduce día por día lo que calcula la pantalla Cuentas.
-- Uso: curl -fsSL <url de este archivo> | docker exec -i postgresql-tnhz-postgresql-1 psql -U <usuario> -d <base>
\pset format aligned
\echo '== 1) Efectivo dia por dia (lo mismo que calcula la pantalla Cuentas)'
with ini as (select coalesce(saldo_inicial,0) s, fecha_inicio f from cuentas where codigo='efectivo'),
v as (select (created_at at time zone 'America/Santiago')::date d,
             sum(case when monto_transferencia is not null then coalesce(monto_efectivo,0)
                      when metodo_pago='mixto' then coalesce(monto_efectivo,0)
                      when coalesce(metodo_pago,'efectivo')='efectivo' then total else 0 end) x
        from ventas where not anulada and coalesce(estado_pago,'pagado')<>'pendiente' group by 1),
g as (select coalesce(fecha_pago,fecha) d, sum(monto) x from gastos
       where cuenta='efectivo' and coalesce(estado_pago,'pagado')<>'pendiente' group by 1),
r as (select (created_at at time zone 'America/Santiago')::date d,
             sum(case when tipo='ingreso' then monto else -monto end) x
        from caja_movimientos where tipo='ingreso' or gasto_id is null group by 1),
c as (select fecha d, sum(diferencia) x from cierres_caja where estado='cerrada' and diferencia is not null group by 1),
t as (select fecha d, sum(case when cuenta_destino='efectivo' then monto else 0 end - case when cuenta_origen='efectivo' then monto else 0 end) x
        from cuenta_movimientos group by 1),
dias as (select d from v union select d from g union select d from r union select d from c union select d from t),
tabla as (
  select dias.d,
         coalesce(v.x,0) ventas_efectivo, -coalesce(g.x,0) gastos_efectivo, coalesce(r.x,0) retiros_caja,
         coalesce(c.x,0) dif_cierre, coalesce(t.x,0) traspasos_ajustes
    from dias left join v using(d) left join g using(d) left join r using(d) left join c using(d) left join t using(d), ini
   where dias.d >= ini.f)
select d fecha, ventas_efectivo, gastos_efectivo, retiros_caja, dif_cierre, traspasos_ajustes,
       (ventas_efectivo+gastos_efectivo+retiros_caja+dif_cierre+traspasos_ajustes) total_dia,
       (select s from ini)+sum(ventas_efectivo+gastos_efectivo+retiros_caja+dif_cierre+traspasos_ajustes) over (order by d) saldo
  from tabla order by d;

\echo
\echo '== 2) Dias donde un gasto en efectivo coincide con un faltante del cierre (posible doble descuento)'
select c.fecha, c.diferencia faltante_cierre, g.monto gasto_efectivo, g.descripcion
  from cierres_caja c join gastos g on g.cuenta='efectivo' and coalesce(g.fecha_pago,g.fecha)=c.fecha
 where c.estado='cerrada' and c.diferencia<0 and abs(c.diferencia+g.monto)<=1000
   and not exists (select 1 from caja_movimientos m where m.gasto_id=g.id)
 order by c.fecha;

\echo
\echo '== 3) Gastos en efectivo que NO pasaron por Retiro de caja (el cierre no los conoce)'
select coalesce(g.fecha_pago,g.fecha) fecha, g.monto, g.descripcion
  from gastos g
 where g.cuenta='efectivo' and coalesce(g.estado_pago,'pagado')<>'pendiente'
   and not exists (select 1 from caja_movimientos m where m.gasto_id=g.id)
   and coalesce(g.fecha_pago,g.fecha) >= (select fecha_inicio from cuentas where codigo='efectivo')
 order by 1;

\echo
\echo '== 4) Cierres de caja (esperado, contado, diferencia, lo que se dejo)'
select fecha, total_esperado esperado, total_contado contado, diferencia, deja_en_caja, notas is not null tiene_nota
  from cierres_caja where estado='cerrada' order by fecha;

\echo
\echo '== 5) Conciliaciones del efectivo'
select fecha, saldo_sistema, saldo_real, diferencia, ajustado, notas from conciliaciones where cuenta='efectivo' order by id;
