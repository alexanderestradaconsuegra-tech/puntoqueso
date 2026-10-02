-- ══════════════════════════════════════════════════════════════════
--  021 — Efectivo recibido y vuelto
--
--  Cuando se paga en efectivo el cajero escribe con cuánto paga el
--  cliente y el sistema calcula el vuelto. Se guarda en la venta para
--  que la boleta (y su reimpresión) muestre "Efectivo recibido" y
--  "Vuelto". No cambia lo que entra a caja: eso sigue siendo el total.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;
alter table ventas add column if not exists efectivo_recibido numeric;
alter table ventas add column if not exists vuelto numeric;
notify pgrst, 'reload schema';
commit;
