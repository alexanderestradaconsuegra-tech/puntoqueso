-- Diagnóstico del stock de un producto (SOLO LEE, no cambia nada).
-- Cambia 'paisa' por parte del nombre del producto que quieres revisar.
-- Uso: curl -fsSL <url de este archivo> | sed "s/PRODUCTO_AQUI/paisa/" | docker exec -i postgresql-tnhz-postgresql-1 psql -U <usuario> -d <base>
\pset format aligned
\echo '== 1) Producto(s) encontrados'
select id, nombre, unidad, vender_por_peso, stock, pieza_nombre, pieza_contenido kg_por_pieza, updated_at
  from productos where nombre ilike '%PRODUCTO_AQUI%' order by id;

\echo
\echo '== 2) Ultimos 40 movimientos (el mas nuevo arriba). "salto" = el stock registrado no es el anterior + el movimiento'
with m as (
  select sm.id, sm.producto_id, sm.created_at, sm.tipo, sm.cantidad, sm.motivo, sm.origen, sm.registrado_por, sm.stock_resultante,
         lag(sm.stock_resultante) over (partition by sm.producto_id order by sm.id) stock_antes
    from stock_movimientos sm join productos p on p.id = sm.producto_id
   where p.nombre ilike '%PRODUCTO_AQUI%')
select to_char(created_at at time zone 'America/Santiago','DD-MM HH24:MI') cuando, producto_id prod, tipo, cantidad, stock_antes, stock_resultante despues,
       case when stock_antes is null then ''
            when abs(stock_antes + case when tipo='salida' then -cantidad when tipo='entrada' then cantidad else cantidad end - stock_resultante) > 0.001 then 'SALTO' else '' end salto,
       origen, registrado_por usuario, left(motivo, 60) motivo
  from m order by id desc limit 40;

\echo
\echo '== 3) Stock actual vs ultimo movimiento registrado'
select p.id, p.nombre, p.stock stock_actual,
       (select stock_resultante from stock_movimientos where producto_id = p.id order by id desc limit 1) ultimo_registrado
  from productos p where p.nombre ilike '%PRODUCTO_AQUI%';

\echo
\echo '== 4) Ventas de ese producto en los ultimos 3 dias (cantidad por linea)'
select to_char(v.created_at at time zone 'America/Santiago','DD-MM HH24:MI') cuando, coalesce(v.boleta_numero::text, v.id::text) boleta,
       vi.producto_nombre, vi.cantidad, vi.precio_unitario, vi.subtotal, v.anulada
  from venta_items vi join ventas v on v.id = vi.venta_id join productos p on p.id = vi.producto_id
 where p.nombre ilike '%PRODUCTO_AQUI%' and v.created_at > now() - interval '3 days'
 order by v.created_at desc;
