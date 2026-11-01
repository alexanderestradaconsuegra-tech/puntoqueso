-- Vista previa (SOLO LEE): productos que la ÚLTIMA toma de inventario puso en 0 por no estar contados,
-- y el stock que tenían antes. Si la lista es correcta, aplica scripts/revertir_toma_aplicar.sql
\pset format aligned
\echo '== Ultima toma de inventario con "dejar en 0 los no contados"'
select id, to_char(fecha at time zone 'America/Santiago','DD-MM-YYYY HH24:MI') cuando, registrado_por, productos contados, puestos_en_cero
  from tomas_inventario where cero_resto order by id desc limit 1;

\echo
\echo '== Productos que se restauran (stock_ahora -> stock_que_tenia)'
select p.id, p.nombre, p.unidad, p.stock stock_ahora, -sm.cantidad stock_que_tenia
  from stock_movimientos sm join productos p on p.id = sm.producto_id
 where sm.referencia_id = (select max(id) from tomas_inventario where cero_resto)
   and sm.motivo like '%(no contado: queda en 0)%'
   and not exists (select 1 from stock_movimientos r where r.producto_id = sm.producto_id
                    and r.motivo like 'Reversión de toma de inventario #' || sm.referencia_id || '%')
 order by p.nombre;
