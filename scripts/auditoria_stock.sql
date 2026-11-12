-- AUDITORIA DE STOCK (solo lee, no cambia nada).
-- Uso:  ... psql ... -v prod=cheddar -f auditoria_stock.sql     (prod = parte del nombre del producto)
\set ON_ERROR_STOP on
\pset pager off
\pset null '-'
\if :{?prod}
\else
  \set prod ''
\endif

\echo
\echo '=== A. PRODUCTO(S) QUE COINCIDEN (si salen dos parecidos, puede que facturas y ventas vayan a productos distintos) ==='
select id, nombre, stock, unidad, vender_por_peso kg, activo, to_char(updated_at at time zone 'America/Santiago','DD-MM HH24:MI') actualizado
  from productos where nombre ilike '%'||:'prod'||'%' order by id;

\echo
\echo '=== B. HISTORIAL COMPLETO DEL PRODUCTO (kardex): cada entrada/salida, quien y cuando. SALTO = el stock no es el anterior mas el movimiento ==='
with m as (
  select sm.*, lag(sm.stock_resultante) over (partition by sm.producto_id order by sm.id) stock_antes
    from stock_movimientos sm join productos p on p.id=sm.producto_id where p.nombre ilike '%'||:'prod'||'%')
select to_char(created_at at time zone 'America/Santiago','DD-MM HH24:MI') cuando, producto_id prod, tipo, cantidad, stock_antes antes, stock_resultante despues,
       case when stock_antes is not null and abs(stock_antes + case when tipo='salida' then -cantidad else cantidad end - stock_resultante) > 0.001 then 'SALTO' else '' end salto,
       origen, registrado_por usuario, left(motivo,55) motivo
  from m where created_at >= now() - interval '45 days' order by id;

\echo
\echo '=== C. RESUMEN POR ORIGEN (45 dias): cuanto entro y cuanto salio por cada camino ==='
select p.id prod, sm.origen, sm.tipo, count(*) movimientos, round(sum(case when sm.tipo='salida' then -sm.cantidad else sm.cantidad end),2) neto
  from stock_movimientos sm join productos p on p.id=sm.producto_id
 where p.nombre ilike '%'||:'prod'||'%' and sm.created_at >= now() - interval '45 days'
 group by 1,2,3 order by 1,2,3;

\echo
\echo '=== D. FACTURAS DE COMPRA CON ESTE PRODUCTO y si su ENTRADA quedo en el kardex (OK / FALTA) ==='
select f.id factura, f.numero_factura n_factura, f.fecha, f.proveedor_nombre proveedor, i.producto_nombre, i.cantidad, i.devuelto,
       coalesce((select sum(sm.cantidad) from stock_movimientos sm where sm.producto_id=i.producto_id and sm.origen='compra' and sm.referencia_id=f.id and sm.tipo='entrada'),0) entrada_en_kardex,
       case when exists (select 1 from stock_movimientos sm where sm.producto_id=i.producto_id and sm.origen='compra' and sm.referencia_id=f.id and sm.tipo='entrada') then 'OK' else 'FALTA ENTRADA' end estado
  from factura_compra_items i join facturas_compra f on f.id=i.factura_id join productos p on p.id=i.producto_id
 where p.nombre ilike '%'||:'prod'||'%' order by f.fecha desc, f.id desc limit 30;

\echo
\echo '=== E. VENTAS vs KARDEX (45 dias): lo vendido segun ventas (descontando anuladas) debe ser igual a lo que salio del stock por ventas ==='
select p.id prod, p.nombre,
       (select coalesce(sum(vi.cantidad),0) from venta_items vi join ventas v on v.id=vi.venta_id where vi.producto_id=p.id and not coalesce(v.anulada,false) and v.created_at >= now() - interval '45 days') vendido_segun_ventas,
       (select coalesce(sum(case when sm.tipo='salida' then sm.cantidad else -sm.cantidad end),0) from stock_movimientos sm
         where sm.producto_id=p.id and sm.created_at >= now() - interval '45 days' and sm.origen not in ('compra','manual','ajuste','toma')) salio_por_ventas_en_kardex
  from productos p where p.nombre ilike '%'||:'prod'||'%';

\echo '=== F. AJUSTES MANUALES, TOMAS DE INVENTARIO y EDICIONES DE STOCK (ultimos 45 dias, todos los productos) = lo que mas altera el stock sin que haya venta ni compra ==='
select to_char(sm.created_at at time zone 'America/Santiago','DD-MM HH24:MI') cuando, p.nombre, sm.tipo, sm.cantidad, sm.stock_resultante despues, sm.origen, sm.registrado_por usuario, left(sm.motivo,50) motivo
  from stock_movimientos sm join productos p on p.id=sm.producto_id
 where sm.created_at >= now() - interval '45 days' and (sm.origen in ('manual','ajuste','toma') or sm.tipo='ajuste')
 order by sm.id desc limit 60;

\echo
\echo '=== G. CONSISTENCIA GLOBAL: productos cuyo stock actual NO es el ultimo valor del kardex (algo cambio el stock sin dejar rastro) ==='
select p.id, p.nombre, p.stock stock_actual, u.stock_resultante ultimo_en_kardex, round(p.stock-u.stock_resultante,3) diferencia, to_char(p.updated_at at time zone 'America/Santiago','DD-MM HH24:MI') producto_actualizado
  from productos p join lateral (select stock_resultante from stock_movimientos where producto_id=p.id order by id desc limit 1) u on true
 where abs(p.stock-u.stock_resultante) > 0.001 order by abs(p.stock-u.stock_resultante) desc limit 40;

\echo
\echo '=== H. FACTURAS (ultimos 60 dias) CUYAS LINEAS NO TIENEN ENTRADA EN EL KARDEX: stock que nunca se sumo ==='
select f.id factura, f.numero_factura, f.fecha, f.proveedor_nombre, i.producto_nombre, i.cantidad
  from factura_compra_items i join facturas_compra f on f.id=i.factura_id
 where f.fecha >= current_date - 60 and i.producto_id is not null
   and not exists (select 1 from stock_movimientos sm where sm.producto_id=i.producto_id and sm.origen='compra' and sm.referencia_id=f.id and sm.tipo='entrada')
 order by f.fecha desc, f.id desc limit 40;

\echo
\echo '=== I. ENTRADAS DE COMPRA CUYA FACTURA YA NO EXISTE (factura eliminada: el stock queda, la factura no) ==='
select to_char(sm.created_at at time zone 'America/Santiago','DD-MM HH24:MI') cuando, p.nombre, sm.cantidad, sm.referencia_id factura_id, left(sm.motivo,60) motivo
  from stock_movimientos sm join productos p on p.id=sm.producto_id
 where sm.origen='compra' and sm.tipo='entrada' and sm.created_at >= now() - interval '60 days'
   and not exists (select 1 from facturas_compra f where f.id=sm.referencia_id)
 order by sm.id desc limit 30;
