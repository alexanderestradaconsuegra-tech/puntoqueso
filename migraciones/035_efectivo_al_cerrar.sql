-- ══════════════════════════════════════════════════════════════════
--  035 — Efectivo que se saca del cajón al cerrar el día
--
--  Al cerrar el día se cuenta todo el cajón, se deja el sencillo para
--  mañana (ej. $30.000) y el resto se retira. Ese retiro ahora se
--  registra solo, para que la cuenta Efectivo no quede inflada.
--   · cierres_caja.deja_en_caja: lo que quedó en el cajón para mañana
--     (es lo que sugiere el mensaje de "Abrir caja" del día siguiente).
--   · caja_movimientos.al_cerrar: marca el retiro hecho al cerrar; no
--     entra en el "debía haber" del cierre (ya se contó antes de sacarlo)
--     pero sí mueve la cuenta Efectivo.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;
alter table cierres_caja add column if not exists deja_en_caja numeric;
alter table caja_movimientos add column if not exists al_cerrar boolean not null default false;
notify pgrst, 'reload schema';
commit;
