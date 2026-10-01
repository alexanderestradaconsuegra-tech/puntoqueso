-- ══════════════════════════════════════════════════════════════════
--  011 — Turnos de caja por cajero
--
--  Dentro de la caja del día (cierres_caja) hay turnos: cada cajero
--  recibe el cajón (fondo), vende y al terminar cuenta a ciegas. El
--  turno guarda lo esperado, lo contado y la diferencia, así cada uno
--  responde por su parte. Solo puede haber UN turno abierto por día
--  (hay un solo cajón). El cierre del día junta todos los turnos.
--
--  ventas.turno_id y caja_movimientos.turno_id dicen a qué turno
--  pertenece cada venta y cada retiro/ingreso.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

create table if not exists turnos_caja (
  id                   bigserial primary key,
  cierre_id            bigint not null references cierres_caja(id) on delete cascade,
  numero               int not null,
  cajero               text not null,
  cajero_nombre        text,
  estado               text not null default 'abierto' check (estado in ('abierto','cerrado')),
  inicio_at            timestamptz not null default now(),
  fin_at               timestamptz,
  fondo_inicial        numeric not null default 0,
  ventas_efectivo      numeric,
  ventas_transferencia numeric,
  ventas_tarjeta       numeric,
  ventas_mercadopago   numeric,
  ventas_cantidad      int,
  total_vendido        numeric,
  retiros              numeric,
  ingresos             numeric,
  total_esperado       numeric,
  total_contado        numeric,
  diferencia           numeric,
  conteo               jsonb,
  notas                text,
  cerrado_por          text,
  created_at           timestamptz default now()
);
create unique index if not exists turnos_un_abierto on turnos_caja (cierre_id) where estado = 'abierto';
create unique index if not exists turnos_numero on turnos_caja (cierre_id, numero);

alter table caja_movimientos add column if not exists turno_id bigint references turnos_caja(id) on delete set null;
alter table ventas           add column if not exists turno_id bigint references turnos_caja(id) on delete set null;
create index if not exists ventas_turno_idx on ventas (turno_id);

alter table turnos_caja enable row level security;
drop policy if exists "pq_admin acceso total" on turnos_caja;
create policy "pq_admin acceso total" on turnos_caja for all to pq_admin using (true) with check (true);
grant select, insert, update, delete on turnos_caja to pq_admin;
grant usage, select on all sequences in schema public to pq_admin;

-- Caja abierta hoy, de antes de este cambio: se le crea su primer turno
-- con lo que ya traía (quien abrió, a qué hora y el fondo).
insert into turnos_caja (cierre_id, numero, cajero, cajero_nombre, inicio_at, fondo_inicial)
select c.id, 1, coalesce(c.abierta_por, 'admin'), c.abierta_por, c.abierta_at, coalesce(c.fondo_inicial, 0)
  from cierres_caja c
 where c.estado = 'abierta' and c.abierta_at is not null
   and not exists (select 1 from turnos_caja t where t.cierre_id = c.id);

update ventas v set turno_id = t.id
  from turnos_caja t
 where v.turno_id is null and t.estado = 'abierto' and v.created_at >= t.inicio_at;
update caja_movimientos m set turno_id = t.id
  from turnos_caja t
 where m.turno_id is null and t.estado = 'abierto' and m.cierre_id = t.cierre_id;

notify pgrst, 'reload schema';
commit;
