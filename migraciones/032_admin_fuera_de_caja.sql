-- 032: El dueño puede vender desde otro equipo sin interrumpir la caja
--
--  Si un cajero tiene el turno abierto, el administrador (solo rol 'admin')
--  vende "fuera de la caja": la venta cuenta en ventas, stock y cuentas,
--  pero NO en el cuadre del cajón del cajero (esa plata la recibe el dueño).
--  ventas.fuera_caja marca esas ventas.
begin;
alter table ventas add column if not exists fuera_caja boolean not null default false;

-- ¿quien llama es el dueño? (rol 'admin' del usuario del token)
create or replace function private.es_dueno() returns boolean
language sql stable security definer set search_path = public, private, pg_temp as $$
  select coalesce((select u.rol = 'admin' and u.activo from usuarios u
                    where u.usuario = nullif(current_setting('request.jwt.claims', true), '')::json->>'usuario'), false)
$$;
revoke all on function private.es_dueno() from public;
grant execute on function private.es_dueno() to pq_admin;
grant usage on schema private to pq_admin;

create or replace function public.registrar_venta(p jsonb)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v ventas; it jsonb; t record; v_suma numeric;
  v_turno bigint := nullif(p->>'turno_id', '')::bigint;
  v_usuario text := nullif(p->>'registrado_por', '');
  v_pid bigint;
  v_uid text := nullif(p->>'venta_uid', '');
  v_hoy date := (now() at time zone 'America/Santiago')::date;
  v_fecha date := nullif(p->>'fecha', '')::date;   -- venta de un día anterior (otro sistema, cuaderno)
  v_ts timestamptz := now();
  v_fuera boolean := coalesce((p->>'fuera_caja')::boolean, false);
begin
  -- la misma venta ya se registró: se devuelve esa, sin duplicar
  if v_uid is not null then
    select * into v from ventas where venta_uid = v_uid;
    if found then return to_jsonb(v) || jsonb_build_object('repetida', true); end if;
  end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'La venta no tiene productos'; end if;
  if jsonb_array_length(p->'items') > 300 then raise exception 'Demasiadas líneas en una venta'; end if;
  if v_fecha is not null and v_fecha >= v_hoy then v_fecha := null; end if;
  if v_fecha is not null then
    -- venta de otro día: queda con esa fecha y NO entra a la caja de hoy (esa plata no está en el cajón)
    if v_fecha < v_hoy - 90 then raise exception 'Solo se pueden registrar ventas de los últimos 90 días'; end if;
    v_turno := null;
    v_ts := (v_fecha + time '12:00') at time zone 'America/Santiago';
  elsif v_fuera then
    -- venta del dueño desde otro equipo mientras un cajero tiene el turno: no entra al cajón
    if not private.es_dueno() then raise exception 'Solo el administrador puede vender fuera de la caja'; end if;
    v_turno := null;
  else
    if v_turno is null then raise exception 'Abre tu turno para vender'; end if;
    select tc.estado as turno, c.estado as caja into t
      from turnos_caja tc join cierres_caja c on c.id = tc.cierre_id where tc.id = v_turno;
    if not found or t.turno <> 'abierto' or t.caja <> 'abierta' then
      raise exception 'Tu turno o la caja ya se cerraron: recarga la página';
    end if;
  end if;
  select coalesce(sum((e->>'subtotal')::numeric), 0) into v_suma from jsonb_array_elements(p->'items') e;
  if abs(v_suma - coalesce((p->>'total')::numeric, -1)) > 1 then raise exception 'El total no cuadra con los productos'; end if;

  insert into ventas (cliente_id, cliente_nombre, total, metodo_pago, metodo_pago_detalle,
                      monto_efectivo, monto_otro, monto_transferencia, monto_tarjeta, monto_mercadopago,
                      delivery_monto, descuento, efectivo_recibido, vuelto,
                      estado_pago, origen, registrado_por, turno_id, venta_uid, created_at, fuera_caja)
  values (nullif(p->>'cliente_id', '')::bigint, coalesce(nullif(p->>'cliente_nombre', ''), 'Cliente mostrador'),
          (p->>'total')::numeric, coalesce(p->>'metodo_pago', 'efectivo'), nullif(p->>'metodo_pago_detalle', ''),
          coalesce((p->>'monto_efectivo')::numeric, 0), coalesce((p->>'monto_otro')::numeric, 0),
          coalesce((p->>'monto_transferencia')::numeric, 0), coalesce((p->>'monto_tarjeta')::numeric, 0),
          coalesce((p->>'monto_mercadopago')::numeric, 0),
          coalesce((p->>'delivery_monto')::numeric, 0), coalesce((p->>'descuento')::numeric, 0),
          nullif(p->>'efectivo_recibido', '')::numeric, nullif(p->>'vuelto', '')::numeric,
          'pagado', 'terminal', v_usuario, v_turno, v_uid, v_ts, v_fuera)
  returning * into v;

  for it in select * from jsonb_array_elements(p->'items') loop
    v_pid := nullif(it->>'producto_id', '')::bigint;
    insert into venta_items (venta_id, producto_id, producto_nombre, cantidad, precio_unitario, subtotal,
                             costo_unitario, es_mayor, precio_original, created_at)
    values (v.id, v_pid, it->>'producto_nombre', (it->>'cantidad')::numeric, (it->>'precio_unitario')::numeric,
            (it->>'subtotal')::numeric,
            case when v_pid is null then 0 else coalesce((select costo from productos where id = v_pid), 0) end,
            coalesce((it->>'es_mayor')::boolean, false), nullif(it->>'precio_original', '')::numeric, v_ts);
    if v_pid is not null then
      perform public.mover_stock(v_pid, -((it->>'cantidad')::numeric), 'salida',
        'Venta boleta ' || coalesce(v.boleta_numero::text, v.id::text)
          || case when v_fecha is not null then ' (del ' || to_char(v_fecha, 'DD-MM-YYYY') || ')' else '' end,
        'terminal', v.id, v_usuario, null);
    end if;
  end loop;
  return to_jsonb(v);
end $$;
revoke all on function public.registrar_venta(jsonb) from public;
grant execute on function public.registrar_venta(jsonb) to pq_admin;

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
  if v_metodo = 'efectivo' and v_turno is null and not private.es_dueno() then
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
                      estado_pago, origen, registrado_por, turno_id, venta_uid, fuera_caja)
  values (ped.cliente_id, coalesce(nullif(ped.cliente_nombre, ''), 'Cliente pedido'), v_total, v_metodo,
          case when v_metodo = 'efectivo' then v_total else 0 end,
          case when v_metodo = 'efectivo' then 0 else v_total end,
          case when v_metodo = 'transferencia' then v_total else 0 end,
          case when v_metodo = 'tarjeta' then v_total else 0 end,
          case when v_metodo = 'mercadopago' then v_total else 0 end,
          v_deliv,
          case when v_metodo = 'efectivo' then v_recibido end,
          case when v_metodo = 'efectivo' and v_recibido is not null then greatest(v_recibido - v_total, 0) end,
          'pagado', 'whatsapp', v_usuario, v_turno, 'pedido-' || p_id, v_metodo = 'efectivo' and v_turno is null)
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

notify pgrst, 'reload schema';
commit;
