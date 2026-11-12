-- Revision de los hallazgos de la auditoria de stock (SOLO LEE).
\pset pager off
\pset null '-'

\echo '=== 1. VENTA boleta 872 (salida de 18,53 kg de cheddar el 09-11): que se vendio, a quien, quien y cuanto cobro ==='
select v.id, v.boleta_numero boleta, to_char(v.created_at at time zone 'America/Santiago','DD-MM HH24:MI') cuando, v.registrado_por vendedor,
       coalesce(v.cliente_nombre,'-') cliente, v.metodo_pago, v.total::bigint total, coalesce(v.descuento,0)::bigint descuento, v.anulada
  from ventas v where v.boleta_numero = 872;
select i.producto_nombre, i.cantidad, i.precio_unitario::bigint, i.subtotal::bigint, coalesce(i.costo_unitario,0)::bigint costo_unit, coalesce(i.es_mayor,false) mayor
  from venta_items i join ventas v on v.id=i.venta_id where v.boleta_numero = 872 order by i.id;

\echo
\echo '=== 2. FACTURAS ELIMINADAS que dejaron stock: ¿hay otra factura con el mismo numero (se volvio a cargar)? ==='
select n.numero, n.proveedor, (select count(*) from facturas_compra f where f.numero_factura = n.numero) facturas_actuales_con_ese_numero,
       (select string_agg(f.id::text, ',') from facturas_compra f where f.numero_factura = n.numero) ids_actuales
  from (values ('54472','La Chacineria'),('55439','COTECA SPA'),('0425','Fruna')) n(numero, proveedor);

\echo
\echo '=== 3. QUIEN ELIMINO FACTURAS (si limpiaste la Auditoria, esta en el respaldo auditlog_respaldo) ==='
select to_char(created_at at time zone 'America/Santiago','DD-MM HH24:MI') cuando, usuario, accion, detalle from auditlog where accion ilike '%factura de compra eliminada%' order by created_at desc limit 20;
select to_char(created_at at time zone 'America/Santiago','DD-MM HH24:MI') cuando, usuario, accion, detalle from auditlog_respaldo where accion ilike '%factura de compra eliminada%' order by created_at desc limit 20;

\echo
\echo '=== 4. KARDEX de los ajustes manuales grandes (Mantecoso Valdivia, Tocino ahumado, Gauda Soprole), ultimos 20 dias ==='
select to_char(sm.created_at at time zone 'America/Santiago','DD-MM HH24:MI') cuando, p.nombre, sm.tipo, sm.cantidad, sm.stock_resultante despues, sm.origen, sm.registrado_por usuario, left(sm.motivo,45) motivo
  from stock_movimientos sm join productos p on p.id=sm.producto_id
 where (p.nombre ilike '%valdivia%mantecoso%' or p.nombre ilike '%mantecoso%valdivia%' or p.nombre ilike 'tocino ahumado%' or p.nombre ilike '%gauda soprole%')
   and sm.created_at >= now() - interval '20 days'
 order by p.nombre, sm.id;
