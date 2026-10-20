-- ══════════════════════════════════════════════════════════════════
--  040 — Tickets en espera (Terminal de ventas)
--
--  Permite guardar el carrito con un nombre mientras el cliente decide si
--  quiere algo más, atender a otra persona, y retomarlo después.
--   · NO toca ventas, stock, caja ni cuentas: solo guarda la lista de lo que
--     se iba a vender. El stock se descuenta recién al cobrar (como siempre)
--     y no se aparta mientras el ticket espera.
--   · Es compartido entre equipos (caja y administrador ven los mismos
--     tickets). abrir_ticket_espera() lo "toma" para un solo equipo: otro
--     equipo no puede abrirlo mientras se está atendiendo (el bloqueo vence a
--     los 30 minutos por si el equipo se apagó).
--   · Los tickets de más de 3 días los borra el panel solo.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

create table if not exists tickets_espera (
  id          bigserial primary key,
  nombre      text not null,
  items       jsonb not null,
  cliente_id  bigint,
  descuento   jsonb,
  total       numeric not null default 0,
  creado_por  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  en_uso_por  text,
  en_uso_at   timestamptz
);
alter table tickets_espera enable row level security;
drop policy if exists "pq_admin tickets_espera" on tickets_espera;
create policy "pq_admin tickets_espera" on tickets_espera for all to pq_admin using (true) with check (true);
grant select, insert, update, delete on tickets_espera to pq_admin;
grant usage, select on sequence tickets_espera_id_seq to pq_admin;
revoke all on tickets_espera from web_anon;

-- Toma el ticket para un equipo. p_quien = 'usuario#equipo'
create or replace function public.abrir_ticket_espera(p_id bigint, p_quien text)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare t tickets_espera;
begin
  select * into t from tickets_espera where id = p_id for update;
  if not found then raise exception 'Ese ticket ya no existe (lo cobraron o lo borraron)'; end if;
  if t.en_uso_por is not null and t.en_uso_por <> p_quien and t.en_uso_at > now() - interval '30 minutes' then
    raise exception 'Ese ticket lo está atendiendo %', split_part(t.en_uso_por, '#', 1);
  end if;
  update tickets_espera set en_uso_por = p_quien, en_uso_at = now() where id = p_id returning * into t;
  return to_jsonb(t);
end $$;
revoke all on function public.abrir_ticket_espera(bigint, text) from public;
grant execute on function public.abrir_ticket_espera(bigint, text) to pq_admin;

notify pgrst, 'reload schema';
commit;
