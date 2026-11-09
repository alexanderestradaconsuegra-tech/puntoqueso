-- Corrige los gastos de facturas de compra que se marcaron pagadas HOY pero quedaron con la fecha vieja de la factura.
-- Solo toca gastos creados hoy (hora Chile) por "marcar pagada" y con fecha distinta de hoy.
-- 1) Ver qué cambiaría (no modifica nada):
select g.id, g.fecha as fecha_actual, (now() at time zone 'America/Santiago')::date as fecha_nueva, g.descripcion, g.monto
  from gastos g
 where (g.notas like 'Generado % pagada la factura de compra%' or g.notas like 'Generado automáticamente al pagar la factura%')
   and (g.created_at at time zone 'America/Santiago')::date = (now() at time zone 'America/Santiago')::date
   and g.fecha <> (now() at time zone 'America/Santiago')::date;
-- 2) Aplicar:
update gastos g set fecha = (now() at time zone 'America/Santiago')::date
 where (g.notas like 'Generado % pagada la factura de compra%' or g.notas like 'Generado automáticamente al pagar la factura%')
   and (g.created_at at time zone 'America/Santiago')::date = (now() at time zone 'America/Santiago')::date
   and g.fecha <> (now() at time zone 'America/Santiago')::date;
