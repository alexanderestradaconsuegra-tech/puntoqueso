-- 025: Pedidos — cobrar = registrar la venta en un solo paso
--
--  * Nueva etapa 'listo' (pedido preparado: al cliente le llega el detalle
--    con el monto y el link de pago). Retiro: listo → entregado.
--    Delivery: listo → en_camino → entregado.
--  * cobrar_pedido(): cuando el cliente paga (en tienda, transferencia,
--    tarjeta o link de Mercado Pago) se crea la venta con sus productos,
--    el delivery como línea, se descuenta el stock y el pedido queda
--    pagado y facturado. Todo en una transacción y sin duplicar.
--  * Retiro en tienda nunca lleva delivery (se limpia lo que hubiera).

alter table pedidos add column if not exists pagado_at timestamptz;

-- retiro con un monto de delivery que quedó guardado por error: se corrige
update pedidos
   set total = total - coalesce(costo_delivery, 0), costo_delivery = null
 where tipo_entrega = 'retiro' and coalesce(costo_delivery, 0) > 0 and venta_id is null;

create or replace function public.cobrar_pedido(p_id bigint, p jsonb)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  ped pedidos; v ventas; it record; t record;
  v_metodo  text    := coalesce(nullif(p->>'metodo_pago', ''), 'efectivo');
  v_turno   bigint  := nullif(p->>'turno_id', '')::bigint;
  v_usuario text    := nullif(p->>'registrado_por', '');
  v_entregar boolean := coalesce((p->>'entregar')::boolean, false);
  v_recibido numeric := nullif(p->>'efectivo_recibido', '')::numeric;
  v_deliv numeric; v_sub numeric; v_total numeric; v_n int;
begin
  if v_metodo not in ('efectivo', 'transferencia', 'tarjeta', 'mercadopago') then
    raise exception 'Medio de pago inválido';
  end if;
  select * into ped from pedidos where id = p_id for update;
  if not found then raise exception 'El pedido #% no existe', p_id; end if;
  if ped.estado = 'anulado' then raise exception 'El pedido está anulado'; end if;

  -- el efectivo entra al cajón: tiene que haber turno abierto
  if v_turno is not null then
    select tc.estado as turno, c.estado as caja into t
      from turnos_caja tc join cierres_caja c on c.id = tc.cierre_id where tc.id = v_turno;
    if not found or t.turno <> 'abierto' or t.caja <> 'abierta' then v_turno := null; end if;
  end if;
  if v_metodo = 'efectivo' and v_turno is null then
    raise exception 'Para cobrar en efectivo abre la caja y tu turno';
  end if;

  -- ya tenía venta (facturado antes, por cobrar): solo se registra el pago
  if ped.venta_id is not null then
    update ventas
       set estado_pago = 'pagado', metodo_pago = v_metodo,
           monto_efectivo      = case when v_metodo = 'efectivo' then total else 0 end,
           monto_transferencia = case when v_metodo = 'transferencia' then total else 0 end,
           monto_tarjeta       = case when v_metodo = 'tarjeta' then total else 0 end,
           monto_mercadopago   = case when v_metodo = 'mercadopago' then total else 0 end,
           monto_otro          = case when v_metodo = 'efectivo' then 0 else total end,
           turno_id = coalesce(turno_id, v_turno)
     where id = ped.venta_id and estado_pago <> 'pagado';
    update pedidos set estado_pago = 'pagado', pagado_at = coalesce(pagado_at, now()),
           estado = case when v_entregar then 'entregado' else estado end
     where id = p_id;
    select * into v from ventas where id = ped.venta_id;
    return jsonb_build_object('venta', to_jsonb(v), 'pedido_id', p_id, 'ya_facturado', true, 'ya_pagado', ped.estado_pago = 'pagado');
  end if;

  -- venta creada antes pero sin quedar enlazada al pedido: se reutiliza
  select * into v from ventas where venta_uid = 'pedido-' || p_id;
  if found then
    update pedidos set venta_id = v.id, estado_pago = 'pagado', pagado_at = coalesce(pagado_at, now()),
           estado = case when v_entregar then 'entregado' else estado end
     where id = p_id;
    return jsonb_build_object('venta', to_jsonb(v), 'pedido_id', p_id, 'repetida', true);
  end if;

  select count(*), coalesce(sum(round(coalesce(subtotal, cantidad * precio_unitario))), 0)
    into v_n, v_sub from pedido_items where pedido_id = p_id;
  if v_n = 0 then raise exception 'El pedido no tiene productos'; end if;
  v_deliv := case when ped.tipo_entrega = 'retiro' then 0 else coalesce(ped.costo_delivery, 0) end;
  v_total := v_sub + v_deliv;

  insert into ventas (cliente_id, cliente_nombre, total, metodo_pago,
                      monto_efectivo, monto_otro, monto_transferencia, monto_tarjeta, monto_mercadopago,
                      delivery_monto, efectivo_recibido, vuelto,
                      estado_pago, origen, registrado_por, turno_id, venta_uid)
  values (ped.cliente_id, coalesce(nullif(ped.cliente_nombre, ''), 'Cliente pedido'), v_total, v_metodo,
          case when v_metodo = 'efectivo' then v_total else 0 end,
          case when v_metodo = 'efectivo' then 0 else v_total end,
          case when v_metodo = 'transferencia' then v_total else 0 end,
          case when v_metodo = 'tarjeta' then v_total else 0 end,
          case when v_metodo = 'mercadopago' then v_total else 0 end,
          v_deliv,
          case when v_metodo = 'efectivo' then v_recibido end,
          case when v_metodo = 'efectivo' and v_recibido is not null then greatest(v_recibido - v_total, 0) end,
          'pagado', 'whatsapp', v_usuario, v_turno, 'pedido-' || p_id)
  returning * into v;

  for it in select * from pedido_items where pedido_id = p_id order by id loop
    insert into venta_items (venta_id, producto_id, producto_nombre, cantidad, precio_unitario, subtotal, costo_unitario)
    values (v.id, it.producto_id, it.producto_nombre, it.cantidad, it.precio_unitario,
            round(coalesce(it.subtotal, it.cantidad * it.precio_unitario)),
            case when it.producto_id is null then 0 else coalesce((select costo from productos where id = it.producto_id), 0) end);
    if it.producto_id is not null then
      perform public.mover_stock(it.producto_id, -it.cantidad, 'salida',
        'Pedido #' || p_id || ' (boleta ' || coalesce(v.boleta_numero::text, v.id::text) || ')',
        'whatsapp', v.id, v_usuario, null);
    end if;
  end loop;
  if v_deliv > 0 then
    insert into venta_items (venta_id, producto_id, producto_nombre, cantidad, precio_unitario, subtotal, costo_unitario)
    values (v.id, null, 'Delivery', 1, v_deliv, v_deliv, 0);
  end if;

  update pedidos
     set venta_id = v.id, estado_pago = 'pagado', pagado_at = now(), total = v_total,
         costo_delivery = case when tipo_entrega = 'retiro' then null else costo_delivery end,
         estado = case when v_entregar then 'entregado' else estado end
   where id = p_id;
  return jsonb_build_object('venta', to_jsonb(v), 'pedido_id', p_id);
end $$;
revoke all on function public.cobrar_pedido(bigint, jsonb) from public;
grant execute on function public.cobrar_pedido(bigint, jsonb) to pq_admin;

-- ── Agente (Hermes): conoce la etapa 'listo' ──
create or replace function public.agente_pedidos(p_estado text default null, p_limite int default 20)
returns jsonb language sql security definer set search_path = public, private, pg_temp as $$
  select coalesce(jsonb_agg(row_to_json(x) order by x.id desc), '[]'::jsonb) from (
    select p.id, p.cliente_nombre, p.cliente_tel, p.estado, p.estado_pago, p.total, p.tipo_entrega,
           concat_ws(', ', p.direccion_calle, p.direccion_depto, p.direccion_comuna) as direccion,
           p.costo_delivery, p.notas, p.created_at, (p.venta_id is not null) as facturado,
           (select jsonb_agg(jsonb_build_object('producto', i.producto_nombre, 'cantidad', i.cantidad, 'subtotal', i.subtotal))
              from pedido_items i where i.pedido_id = p.id) as items
      from pedidos p
     where case when p_estado is null then p.estado in ('pendiente','preparando','listo','en_camino') else p.estado = p_estado end
     order by p.id desc
     limit least(greatest(coalesce(p_limite, 20), 1), 100)
  ) x
$$;

create or replace function public.agente_pedido_estado(p_id bigint, p_estado text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare ped record;
begin
  if p_estado not in ('pendiente','preparando','listo','en_camino','entregado','anulado') then raise exception 'Estado inválido'; end if;
  select id, estado, venta_id into ped from pedidos where id = p_id for update;
  if not found then raise exception 'Pedido % no existe', p_id; end if;
  if p_estado = 'anulado' and ped.venta_id is not null then raise exception 'El pedido ya está facturado: se anula desde el panel'; end if;
  update pedidos set estado = p_estado where id = p_id;
  perform private.agente_log('Cambio de estado pedido', 'pedidos', 'Pedido #' || p_id || ' → ' || p_estado);
  return jsonb_build_object('pedido_id', p_id, 'antes', ped.estado, 'ahora', p_estado);
end $$;
