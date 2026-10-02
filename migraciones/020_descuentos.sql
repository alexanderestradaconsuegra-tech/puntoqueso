-- ══════════════════════════════════════════════════════════════════
--  020 — Descuentos en la venta
--
--  En la Terminal el dueño (o quien tenga el permiso) puede bajar el
--  precio de un producto en una venta o aplicar un descuento a toda la
--  venta. El producto conserva su precio normal; lo que cambia es lo
--  cobrado en esa boleta.
--   · venta_items.precio_original: precio de lista de esa línea al vender
--     (si es mayor que precio_unitario, hubo descuento).
--   · ventas.descuento: total descontado en la venta (líneas + descuento
--     general), para poder reportarlo.
--  El descuento general queda como una línea "Descuento" con monto negativo.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;
alter table venta_items add column if not exists precio_original numeric;
alter table ventas      add column if not exists descuento numeric not null default 0;
notify pgrst, 'reload schema';
commit;
