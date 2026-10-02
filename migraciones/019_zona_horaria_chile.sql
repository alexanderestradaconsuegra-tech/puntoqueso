-- ══════════════════════════════════════════════════════════════════
--  019 — Zona horaria de la base de datos: Chile
--
--  La base trabajaba en UTC, así que current_date (la fecha por defecto
--  de gastos, facturas de compra y pagos) cambiaba de día a las ~21:00
--  de Chile. Los datos ya guardados no cambian (los timestamps siguen
--  siendo los mismos instantes); solo cambia cómo se calcula "hoy" y
--  cómo se muestran las horas. Después de correrla hay que reiniciar
--  PostgREST para que tome la zona nueva.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
do $$
begin
  execute format('alter database %I set timezone to %L', current_database(), 'America/Santiago');
  raise notice 'Zona horaria de % fijada en America/Santiago (aplica a las conexiones nuevas)', current_database();
exception when insufficient_privilege then
  raise notice 'No hay permiso para cambiar la zona horaria de la base. Ejecuta como superusuario: alter database "%" set timezone to ''America/Santiago'';', current_database();
end $$;
