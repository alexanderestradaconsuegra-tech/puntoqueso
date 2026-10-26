-- Diagnóstico del faltante de caja (SOLO LEE, no cambia nada). Analiza el ÚLTIMO cierre de caja cerrado.
-- Uso: curl -fsSL <url de este archivo> | docker exec -i postgresql-tnhz-postgresql-1 psql -U <usuario> -d <base>
\pset format aligned
\echo '== 1) Ultimo cierre de caja: como se llego al "debia haber"'
select c.fecha, c.fondo_inicial fondo, c.ventas_efectivo ventas_efectivo, c.ingresos, c.retiros,
       c.total_esperado debia_haber, c.total_contado contado, c.diferencia, c.deja_en_caja
  from cierres_caja c where c.estado='cerrada' order by c.fecha desc, c.id desc limit 1;

\echo
\echo '== 2) Por turno'
select t.numero turno, coalesce(t.cajero_nombre,t.cajero) cajero, t.fondo_inicial fondo, t.ventas_efectivo, t.retiros, t.ingresos,
       t.total_esperado debia_haber, t.total_contado contado, t.diferencia
  from turnos_caja t where t.cierre_id=(select id from cierres_caja where estado='cerrada' order by fecha desc, id desc limit 1)
 order by t.numero;

\echo
\echo '== 3) Ventas con efectivo de ese dia (revisa las que no recuerdas cobrar en billetes)'
select to_char(v.created_at at time zone 'America/Santiago','HH24:MI') hora, coalesce(v.boleta_numero::text,v.id::text) boleta,
       v.total, v.metodo_pago, v.monto_efectivo efectivo, v.efectivo_recibido recibido, v.vuelto, v.registrado_por usuario,
       v.turno_id turno, v.fuera_caja, v.origen
  from ventas v
 where not v.anulada and coalesce(v.estado_pago,'pagado')<>'pendiente'
   and (v.created_at at time zone 'America/Santiago')::date=(select fecha from cierres_caja where estado='cerrada' order by fecha desc, id desc limit 1)
   and (v.metodo_pago in ('efectivo','mixto') or coalesce(v.monto_efectivo,0)>0)
 order by v.created_at;

\echo
\echo '== 4) Ventas en efectivo con numeros raros (total no redondo, o recibido - vuelto distinto del total)'
select to_char(v.created_at at time zone 'America/Santiago','HH24:MI') hora, coalesce(v.boleta_numero::text,v.id::text) boleta,
       v.total, v.efectivo_recibido recibido, v.vuelto, (v.efectivo_recibido-coalesce(v.vuelto,0))-coalesce(v.monto_efectivo,v.total) diferencia_cobrado
  from ventas v
 where not v.anulada and coalesce(v.estado_pago,'pagado')<>'pendiente'
   and (v.created_at at time zone 'America/Santiago')::date=(select fecha from cierres_caja where estado='cerrada' order by fecha desc, id desc limit 1)
   and (v.metodo_pago in ('efectivo','mixto') or coalesce(v.monto_efectivo,0)>0)
   and (mod(coalesce(v.monto_efectivo,v.total),10)<>0
        or (v.efectivo_recibido is not null and abs((v.efectivo_recibido-coalesce(v.vuelto,0))-coalesce(v.monto_efectivo,v.total))>=1))
 order by v.created_at;

\echo
\echo '== 5) Ese dia: ventas anuladas y medios de pago cambiados'
select to_char(v.created_at at time zone 'America/Santiago','HH24:MI') hora, coalesce(v.boleta_numero::text,v.id::text) boleta,
       v.total, v.metodo_pago, 'ANULADA: '||coalesce(v.motivo_anulacion,'') detalle
  from ventas v
 where v.anulada and (v.created_at at time zone 'America/Santiago')::date=(select fecha from cierres_caja where estado='cerrada' order by fecha desc, id desc limit 1)
union all
select to_char(a.created_at at time zone 'America/Santiago','HH24:MI'), null, null, null, a.detalle
  from auditlog a
 where a.accion='Medio de pago cambiado'
   and (a.created_at at time zone 'America/Santiago')::date>=(select fecha from cierres_caja where estado='cerrada' order by fecha desc, id desc limit 1)
 order by 1;

\echo
\echo '== 6) Retiros e ingresos de la caja de ese dia'
select to_char(m.created_at at time zone 'America/Santiago','HH24:MI') hora, m.tipo, m.monto, m.motivo, m.destino, m.gasto_id is not null es_gasto
  from caja_movimientos m where m.cierre_id=(select id from cierres_caja where estado='cerrada' order by fecha desc, id desc limit 1)
 order by m.created_at;

\echo
\echo '== 7) Gastos en efectivo de ese dia que NO salieron por Retiro de caja (el cierre no los conoce)'
select g.monto, g.descripcion, g.fecha_pago
  from gastos g
 where g.cuenta='efectivo' and coalesce(g.estado_pago,'pagado')<>'pendiente'
   and coalesce(g.fecha_pago,g.fecha)=(select fecha from cierres_caja where estado='cerrada' order by fecha desc, id desc limit 1)
   and not exists (select 1 from caja_movimientos m where m.gasto_id=g.id);

\echo
\echo '== 8) Diferencia de los ultimos 15 cierres (para ver si es un patron)'
select fecha, total_esperado debia_haber, total_contado contado, diferencia, notas is not null tiene_nota
  from cierres_caja where estado='cerrada' order by fecha desc, id desc limit 15;
