-- ══════════════════════════════════════════════════════════════════
--  045 — Cobrar un pedido con pago mixto
--
--  cobrar_pedido acepta metodo_pago = 'mixto' con monto_efectivo,
--  monto_transferencia, monto_tarjeta y monto_mercadopago (al menos dos medios,
--  y la suma debe cuadrar con el total del pedido). Cada monto entra a su
--  cuenta (efectivo → caja; transferencia y link → Mercado Pago; tarjeta →
--  BancoEstado). La parte en efectivo sigue las mismas reglas: necesita turno
--  abierto y no se acepta en pedidos con delivery. El pago mixto no se
--  redondea (lo cuadra quien cobra).
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

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
  v_deliv numeric; v_sub numeric; v_total numeric; v_n int; v_red numeric := 0;
  -- pago mixto: cuánto entró por cada medio
  n_ef numeric := greatest(coalesce(nullif(p->>'monto_efectivo', '')::numeric, 0), 0);
  n_tr numeric := greatest(coalesce(nullif(p->>'monto_transferencia', '')::numeric, 0), 0);
  n_tj numeric := greatest(coalesce(nullif(p->>'monto_tarjeta', '')::numeric, 0), 0);
  n_mp numeric := greatest(coalesce(nullif(p->>'monto_mercadopago', '')::numeric, 0), 0);
  v_cash boolean; v_vt numeric; v_det text;
begin
  if v_metodo not in ('efectivo', 'transferencia', 'tarjeta', 'mercadopago', 'mixto') then
    raise exception 'Medio de pago inválido';
  end if;
  if v_metodo = 'mixto' then
    if (n_ef > 0)::int + (n_tr > 0)::int + (n_tj > 0)::int + (n_mp > 0)::int < 2 then
      raise exception 'Un pago mixto lleva al menos dos medios; si es uno solo, elige ese medio';
    end if;
    v_det := concat_ws(', ',
      case when n_ef > 0 then 'Efectivo: ' || n_ef end,
      case when n_tr > 0 then 'Transferencia: ' || n_tr end,
      case when n_tj > 0 then 'Tarjeta: ' || n_tj end,
      case when n_mp > 0 then 'Mercado Pago: ' || n_mp end);
  else
    n_ef := 0; n_tr := 0; n_tj := 0; n_mp := 0;
  end if;
  v_cash := v_metodo = 'efectivo' or (v_metodo = 'mixto' and n_ef > 0);
  select * into ped from pedidos where id = p_id for update;
  if not found then raise exception 'El pedido #% no existe', p_id; end if;
  if ped.estado = 'anulado' then raise exception 'El pedido está anulado'; end if;
  -- los pedidos con delivery no se pagan en efectivo
  if v_cash and (ped.tipo_entrega in ('delivery', 'coordinar')
                                or (ped.tipo_entrega is null and coalesce(ped.costo_delivery, 0) > 0)) then
    raise exception 'Los pedidos con delivery no se pagan en efectivo: usa transferencia, tarjeta o link de pago';
  end if;

  -- el efectivo entra al cajón: tiene que haber turno abierto
  if v_turno is not null then
    select tc.estado as turno, c.estado as caja into t
      from turnos_caja tc join cierres_caja c on c.id = tc.cierre_id where tc.id = v_turno;
    if not found or t.turno <> 'abierto' or t.caja <> 'abierta' then v_turno := null; end if;
  end if;
  if v_cash and v_turno is null and not private.es_dueno() then
    raise exception 'Para cobrar en efectivo abre la caja y tu turno';
  end if;

  -- ya tenía venta (facturado antes, por cobrar): solo se registra el pago
  if ped.venta_id is not null then
    if v_metodo = 'mixto' then
      select total into v_vt from ventas where id = ped.venta_id;
      if abs(n_ef + n_tr + n_tj + n_mp - coalesce(v_vt, 0)) >= 1 then
        raise exception 'Los montos (%) no suman el total (%)', n_ef + n_tr + n_tj + n_mp, v_vt;
      end if;
    end if;
    update ventas
       set estado_pago = 'pagado', metodo_pago = v_metodo,
           metodo_pago_detalle = case when v_metodo = 'mixto' then v_det else metodo_pago_detalle end,
           monto_efectivo      = case when v_metodo = 'efectivo' then total when v_metodo = 'mixto' then n_ef else 0 end,
           monto_transferencia = case when v_metodo = 'transferencia' then total when v_metodo = 'mixto' then n_tr else 0 end,
           monto_tarjeta       = case when v_metodo = 'tarjeta' then total when v_metodo = 'mixto' then n_tj else 0 end,
           monto_mercadopago   = case when v_metodo = 'mercadopago' then total when v_metodo = 'mixto' then n_mp else 0 end,
           monto_otro          = case when v_metodo = 'efectivo' then 0 when v_metodo = 'mixto' then total - n_ef else total end,
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
  -- efectivo: se cobra en múltiplos de $10 (no hay monedas de $1 ni $5); el ajuste queda como línea "Redondeo"
  if v_metodo = 'efectivo' then
    v_red := round(v_total / 10) * 10 - v_total;
    v_total := v_total + v_red;
  end if;
  if v_metodo = 'mixto' and abs(n_ef + n_tr + n_tj + n_mp - v_total) >= 1 then
    raise exception 'Los montos (%) no suman el total del pedido (%)', n_ef + n_tr + n_tj + n_mp, v_total;
  end if;

  insert into ventas (cliente_id, cliente_nombre, total, metodo_pago, metodo_pago_detalle,
                      monto_efectivo, monto_otro, monto_transferencia, monto_tarjeta, monto_mercadopago,
                      delivery_monto, efectivo_recibido, vuelto,
                      estado_pago, origen, registrado_por, turno_id, venta_uid, fuera_caja)
  values (ped.cliente_id, coalesce(nullif(ped.cliente_nombre, ''), 'Cliente pedido'), v_total, v_metodo, v_det,
          case when v_metodo = 'efectivo' then v_total when v_metodo = 'mixto' then n_ef else 0 end,
          case when v_metodo = 'efectivo' then 0 when v_metodo = 'mixto' then v_total - n_ef else v_total end,
          case when v_metodo = 'transferencia' then v_total when v_metodo = 'mixto' then n_tr else 0 end,
          case when v_metodo = 'tarjeta' then v_total when v_metodo = 'mixto' then n_tj else 0 end,
          case when v_metodo = 'mercadopago' then v_total when v_metodo = 'mixto' then n_mp else 0 end,
          v_deliv,
          case when v_metodo = 'efectivo' then v_recibido end,
          case when v_metodo = 'efectivo' and v_recibido is not null then greatest(v_recibido - v_total, 0) end,
          'pagado', 'whatsapp', v_usuario, v_turno, 'pedido-' || p_id, v_cash and v_turno is null)
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

  if v_red <> 0 then
    insert into venta_items (venta_id, producto_id, producto_nombre, cantidad, precio_unitario, subtotal, costo_unitario)
    values (v.id, null, 'Redondeo', 1, v_red, v_red, 0);
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

notify pgrst, 'reload schema';
commit;
