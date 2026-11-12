-- Resumen completo de ventas y gastos de un mes. Solo lee, no modifica nada.
-- Uso: ... psql ... -v mes=2026-10 -f resumen_mes.sql      (si no pones mes, usa el mes actual)
\set ON_ERROR_STOP on
\pset pager off
\pset null '-'
\if :{?mes}
\else
  select to_char((now() at time zone 'America/Santiago')::date,'YYYY-MM') as mes \gset
\endif
select :'mes' || '-01' as ini \gset
select (:'ini'::date + interval '1 month')::date as fin \gset

-- ventas del mes (hora Chile), sin anuladas, con el reparto por medio de pago
create temp view vm as
select v.*, (v.created_at at time zone 'America/Santiago')::date as dia,
  case when v.monto_transferencia is not null then coalesce(v.monto_efectivo,0) when v.metodo_pago='efectivo' then v.total else 0 end as m_ef,
  case when v.monto_transferencia is not null then coalesce(v.monto_transferencia,0) when v.metodo_pago='transferencia' then v.total else 0 end as m_tr,
  case when v.monto_transferencia is not null then coalesce(v.monto_tarjeta,0) when v.metodo_pago='tarjeta' then v.total else 0 end as m_tj,
  case when v.monto_transferencia is not null then coalesce(v.monto_mercadopago,0) when v.metodo_pago='mercadopago' then v.total else 0 end as m_mp
from ventas v
where coalesce(v.anulada,false)=false
  and (v.created_at at time zone 'America/Santiago')::date >= :'ini'::date and (v.created_at at time zone 'America/Santiago')::date < :'fin'::date;

create temp view gm as
select g.*, coalesce(g.fecha_pago,g.fecha) as dia_pago from gastos g
where g.estado_pago is distinct from 'pendiente'
  and coalesce(g.fecha_pago,g.fecha) >= :'ini'::date and coalesce(g.fecha_pago,g.fecha) < :'fin'::date;

\echo
\echo '=== 1. VENTAS DEL MES ==='
select count(*) as ventas, sum(total)::bigint as total_vendido, round(avg(total))::bigint as ticket_promedio,
       sum(coalesce(descuento,0))::bigint as descuentos_dados,
       (select count(*) from ventas v where coalesce(anulada,false) and (v.created_at at time zone 'America/Santiago')::date >= :'ini'::date and (v.created_at at time zone 'America/Santiago')::date < :'fin'::date) as anuladas_no_cuentan,
       count(distinct dia) as dias_con_venta, round(sum(total)/nullif(count(distinct dia),0))::bigint as promedio_por_dia
from vm;

\echo '=== 2. POR MEDIO DE PAGO ==='
select medio, monto::bigint, round(100*monto/nullif(sum(monto) over(),0),1) as pct from (
  select 'Efectivo' medio, sum(m_ef) monto from vm union all
  select 'Transferencia', sum(m_tr) from vm union all
  select 'Tarjeta', sum(m_tj) from vm union all
  select 'Mercado Pago', sum(m_mp) from vm) x order by monto desc;

\echo '=== 3. POR ORIGEN (local, web/WhatsApp, etc.) ==='
select coalesce(origen,'(sin origen)') origen, count(*) ventas, sum(total)::bigint total from vm group by 1 order by 3 desc;

\echo '=== 4. POR SEMANA ==='
select to_char(date_trunc('week',dia),'DD-MM') as semana_desde, count(*) ventas, sum(total)::bigint total from vm group by date_trunc('week',dia) order by date_trunc('week',dia);

\echo '=== 5. POR DIA DE LA SEMANA ==='
select to_char(dia,'ID') n, (array['Lunes','Martes','Miercoles','Jueves','Viernes','Sabado','Domingo'])[extract(isodow from dia)::int] as dia_semana,
       count(*) ventas, sum(total)::bigint total, round(sum(total)/count(distinct dia))::bigint as promedio_por_dia
from vm group by 1,2 order by 1;

\echo '=== 6. MEJORES Y PEORES DIAS ==='
(select 'mejor' tipo, dia, count(*) ventas, sum(total)::bigint total from vm group by dia order by sum(total) desc limit 3)
union all
(select 'peor', dia, count(*), sum(total)::bigint from vm group by dia order by sum(total) asc limit 3);

\echo '=== 7. POR VENDEDOR ==='
select coalesce(registrado_por,'(sin dato)') vendedor, count(*) ventas, sum(total)::bigint total from vm group by 1 order by 3 desc;

\echo '=== 8. TOP 20 PRODUCTOS (ingreso, cantidad y margen) ==='
select i.producto_nombre producto, round(sum(i.cantidad),2) cantidad, sum(i.subtotal)::bigint ingreso,
       sum(coalesce(i.costo_unitario,0)*i.cantidad)::bigint costo,
       (sum(i.subtotal)-sum(coalesce(i.costo_unitario,0)*i.cantidad))::bigint margen,
       round(100*(sum(i.subtotal)-sum(coalesce(i.costo_unitario,0)*i.cantidad))/nullif(sum(i.subtotal),0),1) margen_pct
from venta_items i join vm on vm.id=i.venta_id group by 1 order by 3 desc limit 20;

\echo '=== 9. POR CATEGORIA DE PRODUCTO ==='
select coalesce(p.categoria,'(sin categoria)') categoria, sum(i.subtotal)::bigint ingreso,
       (sum(i.subtotal)-sum(coalesce(i.costo_unitario,0)*i.cantidad))::bigint margen,
       round(100*sum(i.subtotal)/nullif(sum(sum(i.subtotal)) over(),0),1) pct_ventas
from venta_items i join vm on vm.id=i.venta_id left join productos p on p.id=i.producto_id group by 1 order by 2 desc;

\echo '=== 10. DETAL vs MAYOR ==='
select case when coalesce(i.es_mayor,false) then 'Mayor' else 'Detal' end tipo, sum(i.subtotal)::bigint ingreso,
       (sum(i.subtotal)-sum(coalesce(i.costo_unitario,0)*i.cantidad))::bigint margen
from venta_items i join vm on vm.id=i.venta_id group by 1 order by 2 desc;

\echo '=== 11. TOP 10 CLIENTES ==='
select coalesce(cliente_nombre,'(mostrador)') cliente, count(*) compras, sum(total)::bigint total from vm group by 1 order by 3 desc limit 10;

\echo '=== 12. GASTOS PAGADOS EN EL MES, POR CATEGORIA ==='
select categoria, count(*) n, sum(monto)::bigint total, round(100*sum(monto)/nullif(sum(sum(monto)) over(),0),1) pct from gm group by 1 order by 3 desc;

\echo '=== 13. GASTOS PAGADOS, DETALLE ==='
select dia_pago fecha, categoria, left(descripcion,60) descripcion, cuenta, monto::bigint from gm order by dia_pago, id;

\echo '=== 14. GASTOS POR PAGAR (pendientes hoy) ==='
select coalesce(sum(monto),0)::bigint por_pagar, count(*) n from gastos where estado_pago='pendiente';

\echo '=== 15. RESULTADO DEL MES ==='
with v as (select coalesce(sum(total),0) ventas from vm),
 c as (select coalesce(sum(coalesce(i.costo_unitario,0)*i.cantidad),0) costo from venta_items i join vm on vm.id=i.venta_id),
 g as (select coalesce(sum(monto) filter (where categoria='mercaderia'),0) compras, coalesce(sum(monto) filter (where categoria is distinct from 'mercaderia'),0) operativos from gm)
select v.ventas::bigint ventas,
       c.costo::bigint costo_de_lo_vendido,
       (v.ventas-c.costo)::bigint utilidad_bruta,
       round(100*(v.ventas-c.costo)/nullif(v.ventas,0),1) margen_bruto_pct,
       g.operativos::bigint gastos_operativos,
       (v.ventas-c.costo-g.operativos)::bigint resultado_del_mes,
       g.compras::bigint compras_mercaderia_pagadas,
       (v.ventas-g.compras-g.operativos)::bigint caja_aprox_ventas_menos_todo_lo_pagado
from v,c,g;
\echo '(resultado_del_mes = ventas - costo de lo vendido - gastos que no son mercaderia. La compra de mercaderia no se resta dos veces.)'
\echo '(Si los productos no tienen costo cargado, costo y margen salen bajos/altos: revisa el costo.)'
