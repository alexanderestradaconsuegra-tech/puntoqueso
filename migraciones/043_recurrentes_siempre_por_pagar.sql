-- ══════════════════════════════════════════════════════════════════
--  043 — Gastos recurrentes: siempre "por pagar" y una sola vez por período
--
--  Un gasto cuya descripción empieza con "(Recurrente) " es el que genera
--  el sistema solo. Un panel desactualizado (otro computador con la versión
--  vieja abierta) lo creaba ya PAGADO en BancoEstado y sin dejar marca de
--  período, así que se duplicaba y movía plata sin que nadie pagara.
--  Ahora la base lo corrige al crearse, venga de donde venga:
--   · nace "por pagar", sin cuenta ni fecha de pago;
--   · se enlaza a su gasto recurrente y a su período (mes si es mensual),
--     y la regla "un recurrente por período" rechaza el duplicado.
--  Los gastos que ya existen no se tocan (corrige a mano el duplicado).
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

create or replace function private.gasto_recurrente_guard() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare r record;
begin
  if new.descripcion is null or new.descripcion not like '(Recurrente) %' then return new; end if;
  new.estado_pago := 'pendiente';
  new.cuenta := null;
  new.fecha_pago := null;
  if new.recurrente_id is null then
    select id, frecuencia into r from gastos_recurrentes
     where descripcion = substr(new.descripcion, length('(Recurrente) ') + 1)
     order by id limit 1;
    if found then new.recurrente_id := r.id; end if;
  else
    select id, frecuencia into r from gastos_recurrentes where id = new.recurrente_id;
  end if;
  if new.recurrente_id is not null and new.periodo is null then
    new.periodo := case when coalesce(r.frecuencia, 'mensual') = 'mensual'
                        then to_char(new.fecha, 'YYYY-MM') else new.fecha::text end;
  end if;
  return new;
end $$;

drop trigger if exists gasto_recurrente_guard on gastos;
create trigger gasto_recurrente_guard before insert on gastos
  for each row execute function private.gasto_recurrente_guard();

commit;
