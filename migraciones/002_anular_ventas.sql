-- ══════════════════════════════════════════════════════════════════
--  Migración 002 — Anular ventas (en vez de borrarlas)
-- ══════════════════════════════════════════════════════════════════
--  ANTES: "Eliminar venta" borraba ventas + venta_items y NO devolvía
--  el stock, así que cada venta borrada dejaba el inventario más bajo
--  que la realidad.
--
--  AHORA la venta se ANULA: queda en la base (trazabilidad), el panel
--  devuelve el stock con un movimiento 'entrada' origen 'anulacion' y
--  todos los totales (Dashboard, Contabilidad, cierre de caja) excluyen
--  las ventas con anulada = true.
--
--  Solo agrega columnas a una tabla existente: pq_admin ya tiene
--  select/insert/update/delete sobre ventas, no hacen falta permisos
--  nuevos, y web_anon no recibe nada.
--
--  Se corre con:
--    psql -v ON_ERROR_STOP=1 -f 002_anular_ventas.sql
--  Es idempotente y va en UNA transacción.
-- ══════════════════════════════════════════════════════════════════
begin;

alter table ventas add column if not exists anulada boolean not null default false;
alter table ventas add column if not exists anulada_at timestamptz;
alter table ventas add column if not exists anulada_por text;
alter table ventas add column if not exists motivo_anulacion text;

-- Los reportes filtran por fecha: índice para que no escaneen la tabla completa.
create index if not exists ventas_created_at_idx on ventas (created_at);

commit;

notify pgrst, 'reload schema';
