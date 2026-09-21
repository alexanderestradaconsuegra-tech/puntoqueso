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
  pin_hash text,                        -- hash bcrypt del PIN de cajero (opcional, login rápido)
  permisos jsonb default '{}'::jsonb,   -- claves: verCostos, editarInventario, eliminarVentas, verReportes, verGastos, gestionarUsuarios
  created_at timestamptz default now()
);
alter table usuarios add column if not exists pin_hash text;
alter table usuarios add column if not exists permisos jsonb default '{}'::jsonb;

-- ── productos ──
create table if not exists productos (
  id bigserial primary key,
  nombre text not null,
  categoria text default 'otros',       -- queso | fiambre | otros
  unidad text default 'kg',             -- kg | unid
  precio numeric not null default 0,
  stock numeric default 0,
  stock_minimo numeric default 0,
  sku text,                             -- código interno / SKU
  codigo_barras text,                   -- código de barras estándar (EAN-13, etc.)
  vender_por_peso boolean default false,-- true = se vende al peso (usa selector de peso / balanza)
  activo boolean default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
alter table productos add column if not exists sku text;
alter table productos add column if not exists codigo_barras text;
alter table productos add column if not exists vender_por_peso boolean default false;
alter table productos add column if not exists imagen_b64 text; -- foto del producto, comprimida en base64 (data URL JPEG), fuente única para POS y futuro catálogo WhatsApp
alter table productos add column if not exists costo numeric default 0; -- costo unitario (base de margen), se actualiza al ingresar facturas de compra

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
-- metodo_pago acepta: efectivo | transferencia | tarjeta | mixto
-- (sin CHECK constraint por simplicidad, igual criterio que el resto del esquema)
create table if not exists ventas (
  id bigserial primary key,
  boleta_numero bigint,
  cliente_id bigint references clientes(id) on delete set null,
  cliente_nombre text,
  total numeric not null default 0,
  metodo_pago text default 'efectivo',   -- efectivo | transferencia | tarjeta | mixto
  metodo_pago_detalle text,              -- solo cuando metodo_pago='mixto', ej: "Efectivo: 5000, Transferencia: 3000"
  estado_pago text default 'pagado',     -- pagado | pendiente
  origen text default 'terminal',        -- terminal | whatsapp
  registrado_por text,
  created_at timestamptz default now()
);
alter table ventas add column if not exists metodo_pago_detalle text;
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
  -- estado: etapa de entrega del pedido —
  -- pendiente (recién llegó) | preparando | en_camino | entregado | anulado
  estado text default 'pendiente',
  notas text,
  created_at timestamptz default now()
);
alter table pedidos add column if not exists direccion_calle text;   -- calle + número, ej: "Av. Siempre Viva 742"
alter table pedidos add column if not exists direccion_depto text;   -- depto/casa/unidad, opcional
alter table pedidos add column if not exists direccion_comuna text;
-- estado_pago: estado de pago, independiente de la etapa de entrega
-- (un pedido puede estar 'entregado' y a la vez 'pendiente' de pago == "por cobrar")
-- mismo patrón que ventas.estado_pago: pendiente | pagado
alter table pedidos add column if not exists estado_pago text default 'pendiente';
-- link de pago de Mercado Pago (Checkout Pro), generado desde el admin (puntoqueso-os.html)
alter table pedidos add column if not exists mp_preference_id text;
alter table pedidos add column if not exists mp_link text;

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
-- cantidad que pidió el cliente en el catálogo, ANTES de ajustar el peso real
-- en la balanza. Se escribe una sola vez (el primer ajuste) para que la
-- comparación "pediste X → preparamos Y" siga siendo verdadera.
alter table pedido_items add column if not exists cantidad_original numeric;

-- total del pedido tal como lo hizo el cliente (se fija en el primer ajuste de pesos)
alter table pedidos add column if not exists total_original numeric;
alter table pedidos add column if not exists pesos_ajustados boolean default false;
-- se llena al facturar; reemplaza el estado fantasma 'facturado' (que no era
-- una etapa válida de PEDIDO_ETAPAS y rompía el badge/botón de avance).
-- Además sirve de guarda contra doble facturación (doble descuento de stock).
alter table pedidos add column if not exists venta_id bigint references ventas(id) on delete set null;

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

-- ── gastos recurrentes: costos fijos que se generan solos cada
--    período (arriendo, servicios, empleados, etc.) — ver lógica
--    de generación en el front (generarGastosRecurrentesPendientes) ──
create table if not exists gastos_recurrentes (
  id bigserial primary key,
  descripcion text not null,
  categoria text default 'otros',
  monto numeric not null,
  frecuencia text not null default 'mensual',  -- mensual | semanal | quincenal
  dia_mes integer,          -- for mensual/quincenal: day of month to generate on (1-28, avoid month-length edge cases)
  dia_semana integer,       -- for semanal: 0=domingo..6=sábado
  activo boolean default true,
  ultima_generacion date,   -- last date a gasto was auto-created from this recurrente, to avoid duplicates
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

-- ── proveedores + facturas de compra (ingreso de stock por factura) ──
create table if not exists proveedores (
  id bigserial primary key,
  nombre text not null,
  contacto text,
  telefono text,
  email text,
  notas text,
  activo boolean default true,
  created_at timestamptz default now()
);

create table if not exists facturas_compra (
  id bigserial primary key,
  proveedor_id bigint references proveedores(id) on delete set null,
  proveedor_nombre text,
  numero_factura text,
  fecha date not null default current_date,
  total numeric not null default 0,
  estado_pago text default 'pendiente',  -- pendiente | pagada
  notas text,
  created_at timestamptz default now()
);

create table if not exists factura_compra_items (
  id bigserial primary key,
  factura_id bigint references facturas_compra(id) on delete cascade,
  producto_id bigint references productos(id) on delete set null,
  producto_nombre text,
  cantidad numeric not null,
  costo_unitario numeric not null,
  subtotal numeric not null,
  created_at timestamptz default now()
);

-- ── cierres de caja diarios ──
create table if not exists cierres_caja (
  id bigserial primary key,
  fecha date not null unique,
  total_esperado numeric not null default 0,
  total_contado numeric,
  diferencia numeric,
  notas text,
  registrado_por text,
  created_at timestamptz default now()
);

-- ── configuración general (clave/valor) ──
-- claves usadas por la app (todas opcionales, se guardan/leen desde
-- Configuración → puntoqueso-os.html, admin-only):
--   nombre_negocio            -- nombre del negocio
--   whatsapp                  -- teléfono de WhatsApp del catálogo público
--   evolution_api_url         -- URL base de tu instancia de Evolution API (WhatsApp)
--   evolution_api_key         -- API key de Evolution API
--   evolution_instance        -- nombre de la instancia/número de WhatsApp en Evolution API
--   mercadopago_access_token  -- Access Token de Mercado Pago Chile (solo se usa desde
--                                 el admin autenticado, para generar links de pago —
--                                 nunca se expone en catalogo.html, que es pública)
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
    'gastos','stock_movimientos','config',
    'proveedores','facturas_compra','factura_compra_items','cierres_caja',
    'gastos_recurrentes'
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

-- ══════════════════════════════════════════════════════════
--  AUDITORÍA — bitácora de acciones (venta, producto, config, etc.)
-- ══════════════════════════════════════════════════════════
create table if not exists auditlog (
  id bigserial primary key,
  usuario text,
  accion text not null,
  modulo text,
  detalle text,
  created_at timestamptz default now()
);
alter table auditlog enable row level security;
grant select, insert on auditlog to web_anon;
grant usage, select on sequence auditlog_id_seq to web_anon;
drop policy if exists "web_anon acceso total" on auditlog;
create policy "web_anon acceso total" on auditlog for all to web_anon using (true) with check (true);

-- ══════════════════════════════════════════════════════════
--  PIN de cajero — login rápido sin contraseña completa
--  (mismo modelo de confianza que el resto de este esquema: no
--  hay capa JWT/app-level auth sobre estas funciones, así que su
--  única protección es que no se exponen fuera de la UI de admin
--  de Usuarios / del selector de cajero — "seguridad por
--  obscuridad + acceso de red", igual que el resto de este archivo)
-- ══════════════════════════════════════════════════════════
create or replace function verificar_pin(p_usuario_id bigint, p_pin text)
returns boolean
language sql security definer
as $$
  select exists(
    select 1 from usuarios
    where id = p_usuario_id
      and activo = true
      and pin_hash is not null
      and pin_hash = crypt(p_pin, pin_hash)
  );
$$;
revoke all on function verificar_pin from public;
grant execute on function verificar_pin to web_anon;

-- Solo debe invocarse desde la UI de administración de Usuarios (admin-only en la app).
create or replace function set_pin_hash(p_usuario_id bigint, p_pin text)
returns void
language plpgsql security definer
as $$
begin
  update usuarios set pin_hash = crypt(p_pin, gen_salt('bf')) where id = p_usuario_id;
end;
$$;
revoke all on function set_pin_hash from public;
grant execute on function set_pin_hash to web_anon;

-- Fija la contraseña de un usuario (creación desde la UI de Usuarios, admin-only).
-- Mismo patrón/criterio de confianza que set_pin_hash: sin capa JWT, la única
-- protección es que no se expone fuera de la UI de administración de Usuarios.
create or replace function set_password_hash(p_usuario_id bigint, p_password text)
returns void
language plpgsql security definer
as $$
begin
  update usuarios set password_hash = crypt(p_password, gen_salt('bf')) where id = p_usuario_id;
end;
$$;
revoke all on function set_password_hash from public;
grant execute on function set_password_hash to web_anon;

-- usuarios: permitir lectura de id/permisos para el switch de cajero y roles
-- (nunca password_hash ni pin_hash)
grant select (id, usuario, nombre, rol, activo, permisos) on usuarios to web_anon;
-- permitir a la UI de administración (admin-only en la app) editar rol/activo/permisos
-- y crear nuevos usuarios; el PIN y la contraseña siempre se fijan vía RPC (crypt), nunca en texto plano
grant update (nombre, rol, activo, permisos) on usuarios to web_anon;
grant insert (usuario, nombre, rol, activo, permisos, password_hash) on usuarios to web_anon;
drop policy if exists "web_anon editar permisos" on usuarios;
create policy "web_anon editar permisos" on usuarios for update to web_anon using (true) with check (true);
drop policy if exists "web_anon crear usuarios" on usuarios;
create policy "web_anon crear usuarios" on usuarios for insert to web_anon with check (true);

-- listo. Revisa el README.md para configurar PostgREST.
