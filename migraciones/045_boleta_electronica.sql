-- ═══════════════════════════════════════════════════════════════════
--  045 — Boleta electrónica (SII) por API de documentos electrónicos
--
--  documentos_tributarios  un registro por documento emitido o por emitir:
--                          tipo 39 = boleta electrónica, 61 = nota de crédito
--                          (se emite al anular una venta que ya tenía boleta).
--  config                  dte_activo (interruptor general, viene APAGADO) y
--                          dte_medios (qué medios de pago llevan boleta).
--  Al registrar una venta, un trigger la deja "pendiente" si corresponde.
--  Quien la emite de verdad es el flujo de n8n (pq_boleta_electronica), que
--  habla con la API; la clave de la API vive en n8n, nunca en esta base.
--
--  Una venta con boleta emitida NO puede cambiar de monto, de fecha ni de
--  medio de pago: un documento tributario no se edita. Se anula (y eso emite
--  la nota de crédito).
--  Idempotente.
-- ═══════════════════════════════════════════════════════════════════
begin;

insert into config (clave, valor) values
  ('dte_activo', 'false'::jsonb),
  ('dte_medios', '{"efectivo": true, "tarjeta": true, "mixto": true, "transferencia": false}'::jsonb)
on conflict (clave) do nothing;

create table if not exists documentos_tributarios (
  id               bigserial primary key,
  venta_id         bigint not null references ventas(id) on delete cascade,
  tipo             smallint not null default 39 check (tipo in (39, 61)),
  estado           text not null default 'pendiente'
                     check (estado in ('pendiente', 'emitida', 'error', 'omitida')),
  folio            bigint,
  token            text,                 -- identificador del documento en el proveedor
  resolucion       jsonb,                -- {fecha, numero} que devuelve el proveedor
  ref_documento_id bigint references documentos_tributarios(id),   -- la nota de crédito apunta a su boleta
  intentos         int not null default 0,
  error            text,
  emitido_at       timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index if not exists documentos_tributarios_venta_tipo_uq
  on documentos_tributarios (venta_id, tipo);
create index if not exists documentos_tributarios_estado_idx
  on documentos_tributarios (estado) where estado in ('pendiente', 'error');

do $$ begin
  execute 'alter table documentos_tributarios enable row level security';
  execute 'drop policy if exists "pq_admin acceso total" on documentos_tributarios';
  execute 'create policy "pq_admin acceso total" on documentos_tributarios for all to pq_admin using (true) with check (true)';
  execute 'grant select, insert, update on documentos_tributarios to pq_admin';
end $$;
grant usage, select on all sequences in schema public to pq_admin;

-- ── Venta nueva → boleta pendiente (si está activo y el medio de pago aplica) ──
create or replace function public.dte_encolar_venta()
returns trigger
language plpgsql security invoker set search_path = public as $$
declare
  v_activo boolean;
  v_medios jsonb;
  v_aplica boolean := false;
  v_estado text := 'pendiente';
  v_error  text;
begin
  select coalesce((valor)::text = 'true', false) into v_activo from config where clave = 'dte_activo';
  if not coalesce(v_activo, false) then return new; end if;
  if new.anulada then return new; end if;

  select valor into v_medios from config where clave = 'dte_medios';
  v_medios := coalesce(v_medios, '{"efectivo": true, "tarjeta": true, "mixto": true, "transferencia": false}'::jsonb);

  if new.metodo_pago = 'mixto' then
    -- mixto lleva boleta si una parte se pagó en efectivo o tarjeta y el medio "mixto" está activo
    v_aplica := coalesce((v_medios->>'mixto')::boolean, false)
                and (coalesce(new.monto_efectivo, 0) + coalesce(new.monto_tarjeta, 0)) > 0;
  else
    v_aplica := coalesce((v_medios->>new.metodo_pago)::boolean, false);   -- empleado, mercadopago, etc. no están: no aplican
  end if;
  if not v_aplica or coalesce(new.total, 0) <= 0 then return new; end if;

  -- una venta registrada con otra fecha no puede llevar boleta de hoy
  if new.created_at < now() - interval '1 day' or new.created_at > now() + interval '1 hour' then
    v_estado := 'omitida';
    v_error  := 'Venta con fecha distinta a hoy: no se emite boleta';
  end if;

  insert into documentos_tributarios (venta_id, tipo, estado, error)
  values (new.id, 39, v_estado, v_error)
  on conflict (venta_id, tipo) do nothing;
  return new;
end $$;

drop trigger if exists ventas_dte_encolar on ventas;
create trigger ventas_dte_encolar
  after insert on ventas
  for each row execute function public.dte_encolar_venta();

-- ── Anular una venta con boleta emitida → nota de crédito pendiente ──
create or replace function public.dte_anulacion_venta()
returns trigger
language plpgsql security invoker set search_path = public as $$
declare v_boleta documentos_tributarios;
begin
  if new.anulada and not coalesce(old.anulada, false) then
    select * into v_boleta from documentos_tributarios
     where venta_id = new.id and tipo = 39 and estado = 'emitida';
    if found then
      insert into documentos_tributarios (venta_id, tipo, estado, ref_documento_id)
      values (new.id, 61, 'pendiente', v_boleta.id)
      on conflict (venta_id, tipo) do nothing;
    else
      -- boleta que nunca se emitió: ya no hay nada que emitir
      update documentos_tributarios
         set estado = 'omitida', error = 'Venta anulada antes de emitir la boleta', updated_at = now()
       where venta_id = new.id and tipo = 39 and estado in ('pendiente', 'error');
    end if;
  end if;
  return new;
end $$;

drop trigger if exists ventas_dte_anulacion on ventas;
create trigger ventas_dte_anulacion
  after update of anulada on ventas
  for each row execute function public.dte_anulacion_venta();

-- ── Una venta con boleta emitida no cambia de monto, fecha ni medio de pago ──
create or replace function public.dte_proteger_venta()
returns trigger
language plpgsql security invoker set search_path = public as $$
begin
  if (new.total is distinct from old.total
      or new.created_at is distinct from old.created_at
      or new.metodo_pago is distinct from old.metodo_pago)
     and exists (select 1 from documentos_tributarios
                  where venta_id = old.id and tipo = 39 and estado = 'emitida') then
    raise exception 'La venta % tiene boleta electrónica emitida: no se puede cambiar el monto, la fecha ni el medio de pago. Anúlala y vuelve a venderla.', old.id
      using errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists ventas_dte_proteger on ventas;
create trigger ventas_dte_proteger
  before update on ventas
  for each row execute function public.dte_proteger_venta();

commit;
