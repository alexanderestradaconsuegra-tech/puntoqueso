-- Deshace lo que hizo la ÚLTIMA toma de inventario con "dejar en 0 los no contados":
-- devuelve a cada producto no contado el stock que tenía antes. NO toca los productos que sí se contaron
-- (esos quedan como los escribiste). Cada devolución queda en el kardex como "Reversión de toma de inventario".
-- Es seguro correrlo una sola vez: si lo repites, no devuelve nada dos veces.
-- Primero mira la vista previa con scripts/revertir_toma_ver.sql
begin;
create temp table _rev on commit drop as
select sm.producto_id, -sm.cantidad as restaurar, sm.referencia_id toma
  from stock_movimientos sm
 where sm.referencia_id = (select max(id) from tomas_inventario where cero_resto)
   and sm.motivo like '%(no contado: queda en 0)%'
   and not exists (select 1 from stock_movimientos r where r.producto_id = sm.producto_id
                    and r.motivo like 'Reversión de toma de inventario #' || sm.referencia_id || '%');
select public.mover_stock(r.producto_id, r.restaurar, 'ajuste',
         'Reversión de toma de inventario #' || r.toma || ' (los no contados se pusieron en 0 sin querer)',
         'ajuste', r.toma, 'admin', null)
  from _rev r where r.restaurar <> 0;
select count(*) productos_restaurados from _rev;
commit;
