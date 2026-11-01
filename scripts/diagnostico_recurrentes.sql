-- Diagnóstico de gastos recurrentes duplicados (SOLO LEE, no cambia nada).
\pset format aligned
\echo '== 1) Gastos "(Recurrente)" de los ultimos 3 meses (cada uno con como se creo y su estado)'
select g.id, g.fecha, g.descripcion, g.monto, g.estado_pago, g.cuenta, g.fecha_pago, g.recurrente_id, g.periodo,
       to_char(g.created_at at time zone 'America/Santiago','DD-MM HH24:MI:SS') creado, left(g.notas, 50) notas
  from gastos g
 where g.descripcion like '(Recurrente)%' and g.fecha >= (current_date - interval '90 days')
 order by g.fecha desc, g.id desc;

\echo
\echo '== 2) Configuracion de los recurrentes (ultima_generacion, frecuencia)'
select id, descripcion, monto, frecuencia, dia_mes, dia_semana, activo, ultima_generacion, to_char(created_at,'DD-MM-YYYY') creado
  from gastos_recurrentes order by id;

\echo
\echo '== 3) Auditoria de esos gastos (quien los creo / pago)'
select to_char(created_at at time zone 'America/Santiago','DD-MM HH24:MI:SS') cuando, usuario, accion, left(detalle, 70) detalle
  from auditlog
 where (accion ilike '%recurrente%' or detalle ilike '%contador%') and created_at > now() - interval '10 days'
 order by id desc limit 20;
