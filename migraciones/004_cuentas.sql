-- ══════════════════════════════════════════════════════════════════
--  004 — Cuentas y conciliación (Efectivo, BancoEstado, Mercado Pago)
--
--  Dónde llega cada forma de pago:
--    efectivo       → cuenta 'efectivo'   (el cajón)
--    transferencia  → cuenta 'mercadopago'
--    tarjeta        → cuenta 'bancoestado'
--    mercadopago    → cuenta 'mercadopago' (link de pago de los pedidos)
--  Una venta guarda cuánto fue por cada medio (monto_efectivo,
--  monto_transferencia, monto_tarjeta, monto_mercadopago): así una venta
--  mixta reparte su total entre las cuentas que corresponde.
--
--  Los gastos dicen de qué cuenta salieron (gastos.cuenta). Los
--  traspasos (depositar efectivo en el banco), comisiones y aportes van
--  en cuenta_movimientos. conciliaciones guarda cada vez que el dueño
--  compara el saldo real (app del banco) con el del sistema.
--
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

-- ── ventas: monto por medio de pago ──
alter table ventas add column if not exists monto_transferencia numeric;
alter table ventas add column if not exists monto_tarjeta numeric;
alter table ventas add column if not exists monto_mercadopago numeric;

update ventas set monto_efectivo=coalesce(monto_efectivo, case when coalesce(metodo_pago,'efectivo')='efectivo' then total else 0 end)
  where monto_transferencia is null;
update ventas set
    monto_transferencia=case when metodo_pago='transferencia' then total
                             when metodo_pago='mixto' then coalesce(monto_otro,0) else 0 end,
    monto_tarjeta=case when metodo_pago='tarjeta' then total else 0 end,
    monto_mercadopago=case when metodo_pago='mercadopago' then total else 0 end
  where monto_transferencia is null;

-- ── gastos: de qué cuenta se pagaron ──
alter table gastos add column if not exists cuenta text;
do $$ begin
  alter table gastos add constraint gastos_cuenta_chk check (cuenta is null or cuenta in ('efectivo','bancoestado','mercadopago'));
exception when duplicate_object then null; end $$;
update gastos set cuenta='efectivo' where cuenta is null and notas='Pagado en efectivo desde la caja';

alter table gastos_recurrentes add column if not exists cuenta text default 'bancoestado';

-- ── caja: a dónde va un retiro que no es gasto (o de dónde viene un ingreso) ──
alter table caja_movimientos add column if not exists destino text;
do $$ begin
  alter table caja_movimientos add constraint caja_mov_destino_chk check (destino is null or destino in ('bancoestado','mercadopago','dueno'));
exception when duplicate_object then null; end $$;

-- ── cierre: total del día que entró por link de Mercado Pago ──
alter table cierres_caja add column if not exists ventas_mercadopago numeric;

-- ── cuentas ──
create table if not exists cuentas (
  codigo text primary key check (codigo in ('efectivo','bancoestado','mercadopago')),
  nombre text not null,
  saldo_inicial numeric not null default 0,
  fecha_inicio date,                 -- desde cuándo lleva la cuenta el sistema
  orden integer not null default 0
);
insert into cuentas(codigo,nombre,orden) values
  ('efectivo','Efectivo',1),('bancoestado','BancoEstado',2),('mercadopago','Mercado Pago',3)
on conflict (codigo) do nothing;

-- traspasos (origen y destino), ingresos (solo destino) y egresos (solo origen)
create table if not exists cuenta_movimientos (
  id bigserial primary key,
  fecha date not null default current_date,
  tipo text not null check (tipo in ('traspaso','ingreso','egreso')),
  cuenta_origen text references cuentas(codigo),
  cuenta_destino text references cuentas(codigo),
  monto numeric not null check (monto > 0),
  descripcion text not null,
  registrado_por text,
  created_at timestamptz default now(),
  check ((tipo='traspaso' and cuenta_origen is not null and cuenta_destino is not null and cuenta_origen<>cuenta_destino)
      or (tipo='ingreso' and cuenta_destino is not null and cuenta_origen is null)
      or (tipo='egreso' and cuenta_origen is not null and cuenta_destino is null))
);

create table if not exists conciliaciones (
  id bigserial primary key,
  cuenta text not null references cuentas(codigo),
  fecha date not null default current_date,
  saldo_sistema numeric not null,
  saldo_real numeric not null,
  diferencia numeric not null,
  ajustado boolean not null default false,
  notas text,
  registrado_por text,
  created_at timestamptz default now()
);

do $$
declare t text;
begin
  foreach t in array array['cuentas','cuenta_movimientos','conciliaciones'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "pq_admin acceso total" on %I', t);
    execute format('create policy "pq_admin acceso total" on %I for all to pq_admin using (true) with check (true)', t);
    execute format('grant select, insert, update, delete on %I to pq_admin', t);
    execute format('revoke all on %I from web_anon', t);
  end loop;
end $$;
grant usage, select on sequence cuenta_movimientos_id_seq to pq_admin;
grant usage, select on sequence conciliaciones_id_seq to pq_admin;

notify pgrst, 'reload schema';
commit;
