-- ══════════════════════════════════════════════════════════════════
--  009 — Referido sin ubicación exacta
--
--  Si quien llega invitado pide delivery y la tienda no alcanzó a ubicar
--  su dirección (Google no disponible), antes quedaba "por coordinar" y
--  el local podía terminar cobrándole el delivery. Ahora el beneficio se
--  aplica igual (delivery $0) y el panel ya no lo recalcula.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

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
    select id, nombre, precio into prod
      from productos where id = (it->>'producto_id')::bigint and activo = true and en_catalogo = true;
    if not found then raise exception 'Un producto de tu pedido ya no está disponible'; end if;
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
