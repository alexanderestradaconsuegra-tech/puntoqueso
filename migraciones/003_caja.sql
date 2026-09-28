-- ══════════════════════════════════════════════════════════════════
--  003 — Apertura y cierre de caja diario
--
--  Una caja por día (cierres_caja.fecha ya es única):
--    abrir  → fondo_inicial (el sencillo con que parte el cajón)
--    durante el día → retiros/ingresos de efectivo (caja_movimientos)
--    cerrar → el cajero cuenta a ciegas; se guarda lo contado, lo
--             esperado y la diferencia, más el total de cada medio de
--             pago para que el dueño lo verifique contra el banco.
--
--  Las ventas guardan cuánto de su total fue en efectivo
--  (monto_efectivo): así una venta mixta suma al cajón solo su parte
--  en billetes, no el total.
--
--  Idempotente: se puede correr más de una vez.
-- ══════════════════════════════════════════════════════════════════
begin;

alter table cierres_caja add column if not exists estado text not null default 'cerrada';
alter table cierres_caja add column if not exists abierta_at timestamptz;
alter table cierres_caja add column if not exists abierta_por text;
alter table cierres_caja add column if not exists fondo_inicial numeric not null default 0;
alter table cierres_caja add column if not exists cerrada_at timestamptz;
alter table cierres_caja add column if not exists cerrada_por text;
alter table cierres_caja add column if not exists ventas_efectivo numeric;
alter table cierres_caja add column if not exists ventas_transferencia numeric;
alter table cierres_caja add column if not exists ventas_tarjeta numeric;
alter table cierres_caja add column if not exists ventas_otro_mixto numeric;
alter table cierres_caja add column if not exists ventas_cantidad integer;
alter table cierres_caja add column if not exists retiros numeric;
alter table cierres_caja add column if not exists ingresos numeric;
alter table cierres_caja add column if not exists conteo jsonb;
alter table cierres_caja add column if not exists banco_verificado boolean not null default false;
alter table cierres_caja add column if not exists banco_verificado_por text;
alter table cierres_caja add column if not exists banco_verificado_at timestamptz;
alter table cierres_caja add column if not exists banco_notas text;

do $$ begin
  alter table cierres_caja add constraint cierres_caja_estado_chk check (estado in ('abierta','cerrada'));
exception when duplicate_object then null; end $$;

-- ventas: parte del total pagada en efectivo (efectivo = total, mixto = su
-- parte en billetes, transferencia/tarjeta = 0) y la parte por otro medio.
alter table ventas add column if not exists monto_efectivo numeric;
alter table ventas add column if not exists monto_otro numeric;

-- ventas ya registradas: se completa desde el método de pago; las mixtas
-- desde el texto "Efectivo: 5000, Transferencia/Tarjeta: 3000".
update ventas set monto_efectivo=total, monto_otro=0
  where monto_efectivo is null and coalesce(metodo_pago,'efectivo')='efectivo';
update ventas set monto_efectivo=0, monto_otro=total
  where monto_efectivo is null and metodo_pago in ('transferencia','tarjeta');
update ventas set
    monto_efectivo=coalesce(nullif(substring(metodo_pago_detalle from 'Efectivo:\s*([0-9.]+)'),'')::numeric,0),
    monto_otro=coalesce(nullif(substring(metodo_pago_detalle from 'Tarjeta:\s*([0-9.]+)'),'')::numeric,0)
  where monto_efectivo is null and metodo_pago='mixto';

-- retiros (sale plata del cajón: pagar al proveedor del pan, depositar)
-- e ingresos (entra plata que no es venta: cambio que trae el dueño)
create table if not exists caja_movimientos (
  id bigserial primary key,
  cierre_id bigint not null references cierres_caja(id) on delete cascade,
  tipo text not null check (tipo in ('retiro','ingreso')),
  monto numeric not null check (monto > 0),
  motivo text not null,
  gasto_id bigint references gastos(id) on delete set null,
  registrado_por text,
  created_at timestamptz default now()
);
create index if not exists caja_movimientos_cierre_idx on caja_movimientos(cierre_id);

alter table caja_movimientos enable row level security;
drop policy if exists "pq_admin acceso total" on caja_movimientos;
create policy "pq_admin acceso total" on caja_movimientos for all to pq_admin using (true) with check (true);
grant select, insert, update, delete on caja_movimientos to pq_admin;
grant usage, select on sequence caja_movimientos_id_seq to pq_admin;
revoke all on caja_movimientos from web_anon;

notify pgrst, 'reload schema';
commit;
