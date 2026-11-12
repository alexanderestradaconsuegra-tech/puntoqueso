-- Lista las ventas con descuento de un mes (quien, a quien, cuanto, que se llevo). Solo lee.
-- Uso: ... psql ... -v mes=2026-10 -f ventas_con_descuento.sql
\pset pager off
\pset null '-'
\if :{?mes}
\else
  select to_char((now() at time zone 'America/Santiago')::date,'YYYY-MM') as mes \gset
\endif
select :'mes' || '-01' as ini \gset
select (:'ini'::date + interval '1 month')::date as fin \gset

select v.id, to_char(v.created_at at time zone 'America/Santiago','DD-MM HH24:MI') as cuando, v.registrado_por as vendedor,
       coalesce(v.cliente_nombre,'-') as cliente, v.total::bigint as cobrado, v.descuento::bigint as descuento,
       round(100*v.descuento/nullif(v.total+v.descuento,0),1) as pct,
       (select string_agg(left(i.producto_nombre,28)||' x'||round(i.cantidad,1)||case when coalesce(i.es_mayor,false) then ' (mayor)' else '' end, ' | ' order by i.id)
          from venta_items i where i.venta_id=v.id) as detalle
from ventas v
where coalesce(v.anulada,false)=false and coalesce(v.descuento,0)>0
  and (v.created_at at time zone 'America/Santiago')::date >= :'ini'::date and (v.created_at at time zone 'America/Santiago')::date < :'fin'::date
order by v.descuento desc;
