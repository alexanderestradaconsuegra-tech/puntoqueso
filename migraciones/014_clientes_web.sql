-- ══════════════════════════════════════════════════════════════════
--  014 — Clientes web y promociones por WhatsApp
--
--  clientes_web: un registro por teléfono (el mismo que identifica los
--  pedidos y los referidos). Guarda el permiso para recibir promos con
--  fecha y origen (respaldo legal: Ley 19.628 / 21.719, el cliente debe
--  aceptar y poder darse de baja).
--  clientes_web_resumen(): pedidos, total, primera/última compra,
--  comuna y productos comprados por cliente, para la pantalla del panel.
--  promos_envios: registro de cada campaña enviada.
--  crear_pedido_web: si el cliente marca la casilla, queda con permiso.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

create table if not exists clientes_web (
  telefono       text primary key,          -- normalizado (últimos 9 dígitos)
  nombre         text,
  acepta_promos  boolean not null default false,
  promos_at      timestamptz,               -- cuándo aceptó
  origen_permiso text,                      -- dónde aceptó
  baja_at        timestamptz,               -- cuándo pidió no recibir más
  notas          text,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);

create table if not exists promos_envios (
  id           bigserial primary key,
  fecha        timestamptz default now(),
  mensaje      text not null,
  filtro       text,
  destinatarios int,
  enviados     int default 0,
  fallidos     int default 0,
  registrado_por text
);

do $$ declare t text; begin
  foreach t in array array['clientes_web','promos_envios'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "pq_admin acceso total" on %I', t);
    execute format('create policy "pq_admin acceso total" on %I for all to pq_admin using (true) with check (true)', t);
    execute format('grant select, insert, update, delete on %I to pq_admin', t);
  end loop;
end $$;
grant usage, select on all sequences in schema public to pq_admin;

-- Clientes que ya pidieron antes de este cambio (sin permiso de promos)
insert into clientes_web (telefono, nombre)
select distinct on (cliente_tel_norm) cliente_tel_norm, cliente_nombre
  from pedidos where cliente_tel_norm is not null
 order by cliente_tel_norm, created_at desc
on conflict (telefono) do nothing;

create or replace function public.clientes_web_resumen()
returns table (telefono text, tel_contacto text, nombre text, pedidos bigint, total numeric,
               primer_pedido timestamptz, ultimo_pedido timestamptz, comuna text, productos bigint[],
               acepta_promos boolean, promos_at timestamptz, baja_at timestamptz, origen_permiso text)
language sql stable security invoker set search_path = public as $$
  select c.telefono,
         coalesce(s.tel_contacto, c.telefono),
         coalesce(c.nombre, s.nombre),
         coalesce(s.pedidos, 0), coalesce(s.total, 0),
         s.primer, s.ultimo, s.comuna, coalesce(s.productos, '{}'),
         c.acepta_promos, c.promos_at, c.baja_at, c.origen_permiso
    from (select cw.telefono, cw.nombre, cw.acepta_promos, cw.promos_at, cw.baja_at, cw.origen_permiso
            from clientes_web cw
          union all
          select distinct pp.cliente_tel_norm, null::text, false, null::timestamptz, null::timestamptz, null::text
            from pedidos pp
           where pp.cliente_tel_norm is not null
             and not exists (select 1 from clientes_web x where x.telefono = pp.cliente_tel_norm)) c
    left join lateral (
      select (array_agg(p.cliente_tel order by p.created_at desc))[1] as tel_contacto,
             (array_agg(p.cliente_nombre order by p.created_at desc))[1] as nombre,
             count(*) as pedidos, sum(p.total) as total,
             min(p.created_at) as primer, max(p.created_at) as ultimo,
             (array_agg(p.direccion_comuna order by p.created_at desc) filter (where p.direccion_comuna is not null))[1] as comuna,
             (select array_agg(distinct pi.producto_id) from pedido_items pi
                join pedidos q on q.id = pi.pedido_id
               where q.cliente_tel_norm = c.telefono and q.estado <> 'anulado' and pi.producto_id is not null) as productos
        from pedidos p
       where p.cliente_tel_norm = c.telefono and p.estado <> 'anulado'
    ) s on true
$$;
revoke all on function public.clientes_web_resumen() from public;
grant execute on function public.clientes_web_resumen() to pq_admin;

create or replace function public.crear_pedido_web(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare
  v_nombre  text := private.limpiar_texto(p->>'nombre', 80);
  v_tel     text := private.limpiar_texto(p->>'telefono', 30);
  v_tn      text := private.norm_tel(p->>'telefono');
  v_calle   text := private.limpiar_texto(p->>'calle', 150);
  v_depto   text := private.limpiar_texto(p->>'depto', 60);
  v_comuna  text := private.limpiar_texto(p->>'comuna', 80);
  v_notas   text := private.limpiar_texto(p->>'notas', 500);
  v_entrega text := coalesce(p->>'entrega', 'delivery');
  v_ref     text := upper(private.limpiar_texto(p->>'ref', 20));
  v_items   jsonb := p->'items';
  v_lat float8; v_lng float8;
  v_min    numeric := private.cfg_num('referidos_minimo', 20000);
  v_activo boolean := coalesce(lower(private.cfg_txt('referidos_activo')), 'true') not in ('false','0','no');
  v_id bigint; v_sub numeric := 0; v_cant numeric; it jsonb; prod record;
  v_cot jsonb; v_tipo text; v_km numeric; v_costo numeric;
  v_benef text; v_msg text; v_refe text; v_nuevo boolean; v_premio bigint; v_ref_ok boolean := false;
  v_ctrl boolean := coalesce(lower(private.cfg_txt('web_control_stock')), 'true') not in ('false','0','no');
  v_pedido jsonb := '{}'::jsonb; v_disp numeric; v_ya numeric;
begin
  if v_nombre is null then raise exception 'Ingresa tu nombre'; end if;
  if v_tel is null or v_tn is null then raise exception 'Revisa tu número de WhatsApp'; end if;
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'El pedido no tiene productos';
  end if;
  if jsonb_array_length(v_items) > 50 then raise exception 'Demasiados productos en un solo pedido'; end if;
  if v_entrega not in ('delivery','retiro') then v_entrega := 'delivery'; end if;
  begin
    v_lat := (p->>'lat')::float8; v_lng := (p->>'lng')::float8;
  exception when others then v_lat := null; v_lng := null;
  end;
  if v_lat is null or v_lng is null then v_lat := null; v_lng := null; end if;
  if v_entrega = 'delivery' and v_calle is null and v_lat is null then
    raise exception 'Escribe tu dirección o usa tu ubicación actual';
  end if;

  insert into pedidos (cliente_nombre, cliente_tel, direccion_calle, direccion_depto,
                       direccion_comuna, notas, total, estado)
  values (v_nombre, v_tel,
          case when v_entrega = 'delivery' then v_calle end,
          case when v_entrega = 'delivery' then v_depto end,
          case when v_entrega = 'delivery' then v_comuna end,
          v_notas, 0, 'pendiente')
  returning id into v_id;

  for it in select * from jsonb_array_elements(v_items) loop
    v_cant := (it->>'cantidad')::numeric;
    if v_cant is null or v_cant <= 0 or v_cant > 1000 then raise exception 'Cantidad inválida'; end if;
    -- se bloquea la fila: dos pedidos al mismo tiempo no pueden llevarse el mismo stock
    select id, nombre, precio, stock, vender_por_peso into prod
      from productos where id = (it->>'producto_id')::bigint and activo = true and en_catalogo = true
      for update;
    if not found then raise exception 'Un producto de tu pedido ya no está disponible'; end if;
    if v_ctrl then
      v_ya := coalesce((v_pedido->>prod.id::text)::numeric, 0);
      v_disp := coalesce(prod.stock, 0) - private.reservado(prod.id, v_id) - v_ya;
      if v_disp < (case when prod.vender_por_peso then 0.1 else 1 end) then
        raise exception '% está agotado. Quítalo del carrito para continuar.', prod.nombre;
      end if;
      if v_cant > v_disp then
        raise exception 'De % solo quedan %. Ajusta la cantidad en tu carrito.', prod.nombre,
          case when prod.vender_por_peso then trim(to_char(floor(v_disp * 10) / 10, 'FM990.0')) || ' kg'
               else floor(v_disp)::text || ' unidades' end;
      end if;
      v_pedido := jsonb_set(v_pedido, array[prod.id::text], to_jsonb(v_ya + v_cant));
    end if;
    insert into pedido_items (pedido_id, producto_id, producto_nombre, cantidad, precio_unitario, subtotal)
    values (v_id, prod.id, prod.nombre, v_cant, prod.precio, prod.precio * v_cant);
    v_sub := v_sub + prod.precio * v_cant;
  end loop;

  -- Entrega
  if v_entrega = 'retiro' then
    v_tipo := 'retiro'; v_costo := 0; v_lat := null; v_lng := null;
  else
    v_cot := private.cotizar(v_lat, v_lng);
    v_tipo := v_cot->>'zona';
    v_km := (v_cot->>'km')::numeric;
    v_costo := (v_cot->>'precio')::numeric;
  end if;

  -- Referidos
  if v_activo then
    v_nuevo := not exists (select 1 from pedidos where cliente_tel_norm = v_tn and id <> v_id and estado <> 'anulado')
           and not exists (select 1 from clientes where private.norm_tel(telefono) = v_tn);
    if v_ref is not null then
      select telefono into v_refe from referidos_codigos where codigo = v_ref;
      if v_refe is null then
        v_msg := 'El código de invitación no es válido.';
      elsif v_refe = v_tn then
        v_msg := 'No puedes usar tu propio código de invitación.';
      elsif not v_nuevo or exists (select 1 from referidos where referido_tel = v_tn and estado <> 'anulado') then
        v_msg := 'La invitación es solo para la primera compra.';
      elsif v_sub < v_min then
        v_msg := 'La invitación aplica con productos desde ' || private.clp(v_min) || '.';
      elsif exists (select 1 from pedidos q where q.cliente_tel_norm = v_refe and q.estado <> 'anulado' and (
                     (v_calle is not null and v_entrega = 'delivery'
                      and private.norm_dir(q.direccion_calle, q.direccion_comuna) = private.norm_dir(v_calle, v_comuna))
                  or (v_lat is not null and q.lat is not null and private.dist_km(q.lat, q.lng, v_lat, v_lng) < 0.05))) then
        v_msg := 'La invitación no aplica a la misma dirección de quien te invitó.';
      else
        insert into referidos (codigo, referente_tel, referido_tel, referido_nombre, pedido_id)
        values (v_ref, v_refe, v_tn, v_nombre, v_id);
        v_ref_ok := true;
        if (v_tipo = 'delivery' and v_costo > 0) or (v_entrega = 'delivery' and v_km is null) then
          -- (si la tienda no pudo ubicar la dirección, el local calcula la
          --  distancia en el panel, pero el delivery ya queda gratis)
          v_costo := 0; v_benef := 'referido';
          v_msg := '¡Delivery gratis por invitación!';
        else
          v_msg := 'Invitación registrada: quien te invitó gana un delivery gratis.';
        end if;
      end if;
    end if;
    -- Premio ganado por invitar
    if v_benef is null and v_tipo = 'delivery' and v_costo > 0 and v_sub >= v_min then
      select id into v_premio from referidos_premios
       where telefono = v_tn and estado = 'disponible' and vence_at > now()
       order by vence_at limit 1 for update;
      if v_premio is not null then
        update referidos_premios set estado = 'usado', pedido_uso_id = v_id, usado_at = now() where id = v_premio;
        v_costo := 0; v_benef := 'premio';
        v_msg := '¡Usaste tu delivery gratis ganado por invitar!';
      end if;
    end if;
  end if;

  -- Cliente web: nombre al día y, si lo pidió, permiso para promos (con fecha)
  insert into clientes_web (telefono, nombre, acepta_promos, promos_at, origen_permiso)
  values (v_tn, v_nombre, coalesce((p->>'promos')::boolean, false),
          case when coalesce((p->>'promos')::boolean, false) then now() end,
          case when coalesce((p->>'promos')::boolean, false) then 'Casilla en la tienda web, pedido #' || v_id end)
  on conflict (telefono) do update set
      nombre         = excluded.nombre,
      acepta_promos  = clientes_web.acepta_promos or excluded.acepta_promos,
      promos_at      = case when excluded.acepta_promos and not clientes_web.acepta_promos then now() else clientes_web.promos_at end,
      baja_at        = case when excluded.acepta_promos and not clientes_web.acepta_promos then null else clientes_web.baja_at end,
      origen_permiso = case when excluded.acepta_promos and not clientes_web.acepta_promos then excluded.origen_permiso else clientes_web.origen_permiso end,
      updated_at     = now();

  update pedidos set
      subtotal_productos = v_sub,
      costo_delivery     = v_costo,
      total              = v_sub + coalesce(v_costo, 0),
      tipo_entrega       = v_tipo,
      distancia_km       = v_km,
      lat                = v_lat,
      lng                = v_lng,
      beneficio_delivery = v_benef,
      referido_codigo    = case when v_ref_ok then v_ref end
    where id = v_id;

  return jsonb_build_object('id', v_id, 'subtotal', v_sub, 'delivery', v_costo,
                            'total', v_sub + coalesce(v_costo, 0), 'tipo', v_tipo, 'km', v_km,
                            'beneficio', v_benef, 'mensaje', v_msg);
end $$;
revoke all on function public.crear_pedido_web(jsonb) from public;
grant execute on function public.crear_pedido_web(jsonb) to web_anon, pq_admin;

notify pgrst, 'reload schema';
commit;
