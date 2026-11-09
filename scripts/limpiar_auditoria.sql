-- Vacía la pantalla Auditoría. ANTES guarda una copia en la tabla auditlog_respaldo (por si algún día la necesitas).
-- Se puede correr varias veces: cada vez suma a la copia lo que se borra.
create table if not exists auditlog_respaldo (like auditlog including defaults);
insert into auditlog_respaldo select * from auditlog;
select count(*) as registros_respaldados from auditlog_respaldo;
delete from auditlog;
select count(*) as quedan_en_auditoria from auditlog;
