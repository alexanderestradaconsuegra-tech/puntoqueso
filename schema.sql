-- ══════════════════════════════════════════════════════════
--  Punto Queso — esquema de base de datos (Postgres + PostgREST)
--  Corre esto completo en tu Postgres (una sola vez).
-- ══════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- ── usuarios (login) ──
create table if not exists usuarios (
  id bigserial primary key,
  usuario text unique not null,
  nombre text not null,
  rol text not null default 'admin',   -- admin | vendedor
  activo boolean default true,
  password_hash text not null,
  created_at timestamptz default now()
);

-- ── productos ──
create table if not exists productos (
  id bigserial primary key,
  nombre text not null,
  categoria text default 'otros',       -- queso | fiambre | otros
  unidad text default 'kg',             -- kg | unid
  precio numeric not null default 0,
  stock numeric default 0,
  stock_minimo numeric default 0,
  activo boolean default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- ── clientes ──
create table if not exists clientes (
  id bigserial primary key,
  nombre text not null,
  telefono text,
  direccion text,
  notas text,
  activo boolean default true,
  created_at timestamptz default now()
);

-- ── ventas (terminal de ventas / caja) ──
create table if not exists ventas (
  id bigserial primary key,
  boleta_numero bigint,
  cliente_id bigint references clientes(id) on delete set null,
  cliente_nombre text,
  total numeric not null default 0,
  metodo_pago text default 'efectivo',   -- efectivo | debito | credito | transferencia
  estado_pago text default 'pagado',     -- pagado | pendiente
  origen text default 'terminal',        -- terminal | whatsapp
  registrado_por text,
  created_at timestamptz default now()
);
create sequence if not exists boleta_seq start 1;
alter table ventas alter column boleta_numero set default nextval('boleta_seq');

create table if not exists venta_items (
  id bigserial primary key,
  venta_id bigint references ventas(id) on delete cascade,
  producto_id bigint references productos(id) on delete set null,
  producto_nombre text,
  cantidad numeric not null,
  precio_unitario numeric not null,
  subtotal numeric not null,
  created_at timestamptz default now()
);

-- ── pedidos (catálogo por WhatsApp → llegan aquí antes de facturarse) ──
create table if not exists pedidos (
  id bigserial primary key,
  cliente_id bigint references clientes(id) on delete set null,
  cliente_nombre text,
  cliente_tel text,
  total numeric default 0,
  estado text default 'pendiente',   -- pendiente | confirmado | facturado | anulado
  notas text,
  created_at timestamptz default now()
);

create table if not exists pedido_items (
  id bigserial primary key,
  pedido_id bigint references pedidos(id) on delete cascade,
  producto_id bigint references productos(id) on delete set null,
  producto_nombre text,
  cantidad numeric not null,
  precio_unitario numeric,
  subtotal numeric,
  created_at timestamptz default now()
);

-- ── gastos ──
create table if not exists gastos (
  id bigserial primary key,
  fecha date not null default current_date,
  descripcion text not null,
  categoria text default 'otros',
  monto numeric not null,
  notas text,
  created_at timestamptz default now()
);

-- ── kardex de stock (igual patrón que Campolac — ¡ojo con el nombre!) ──
create table if not exists stock_movimientos (
  id bigserial primary key,
  producto_id bigint references productos(id) on delete set null,
  tipo text not null,               -- entrada | salida | ajuste
  cantidad numeric not null,
  motivo text,
  origen text,                      -- terminal | ajuste | compra | whatsapp
  referencia_id bigint,
  registrado_por text,
  created_at timestamptz default now()
);

-- ── configuración general (clave/valor) ──
create table if not exists config (
  clave text primary key,
  valor jsonb,
  updated_at timestamptz default now()
);

-- ══════════════════════════════════════════════════════════
--  LOGIN seguro — contraseña hasheada + función de verificación
--  (mismo patrón ya aplicado en Campolac)
-- ══════════════════════════════════════════════════════════

-- Crea el primer usuario admin. CAMBIA 'TU_CLAVE_AQUI' antes de correr esto.
insert into usuarios (usuario, nombre, rol, activo, password_hash)
values ('admin', 'Administrador', 'admin', true, crypt('TU_CLAVE_AQUI', gen_salt('bf')))
on conflict (usuario) do nothing;

create or replace function verificar_login(p_usuario text, p_password text)
returns boolean
language sql security definer
as $$
  select exists(
    select 1 from usuarios
    where usuario = p_usuario
      and activo = true
      and password_hash = crypt(p_password, password_hash)
  );
$$;
revoke all on function verificar_login from public;
grant execute on function verificar_login to web_anon;

-- ══════════════════════════════════════════════════════════
--  ROL PARA POSTGREST (equivalente al "anon" de Supabase)
-- ══════════════════════════════════════════════════════════
-- Crea el rol que PostgREST usa para peticiones sin JWT.
-- CAMBIA 'clave_segura_aqui' por una contraseña real.
do $$
begin
  if not exists (select from pg_roles where rolname = 'web_anon') then
    create role web_anon nologin;
  end if;
  if not exists (select from pg_roles where rolname = 'authenticator') then
    create role authenticator noinherit login password 'clave_segura_aqui';
  end if;
end $$;
grant web_anon to authenticator;
grant usage on schema public to web_anon;

-- ══════════════════════════════════════════════════════════
--  RLS — activado en todo, con política de acceso total para
--  web_anon (igual criterio que usamos en Campolac: la seguridad
--  real la da no exponer nunca la password en las consultas, no
--  el RLS en sí — RLS aquí es la barrera contra acceso externo
--  directo a la base, no el control de permisos de la app).
-- ══════════════════════════════════════════════════════════
do $$
declare t text;
begin
  for t in select unnest(array[
    'productos','clientes','ventas','venta_items','pedidos','pedido_items',
    'gastos','stock_movimientos','config'
  ]) loop
    execute format('alter table %I enable row level security', t);
    execute format('grant select, insert, update, delete on %I to web_anon', t);
    execute format('grant usage, select on sequence %I_id_seq to web_anon', t);
    execute format(
      'drop policy if exists "web_anon acceso total" on %I; create policy "web_anon acceso total" on %I for all to web_anon using (true) with check (true)',
      t, t
    );
  end loop;
end $$;
grant usage, select on sequence boleta_seq to web_anon;

-- usuarios: RLS estricto — nunca exponer password_hash
alter table usuarios enable row level security;
grant select (usuario, nombre, rol, activo) on usuarios to web_anon;
drop policy if exists "web_anon lectura basica" on usuarios;
create policy "web_anon lectura basica" on usuarios for select to web_anon using (true);

-- listo. Revisa el README.md para configurar PostgREST.
