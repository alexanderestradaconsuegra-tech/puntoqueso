-- ══════════════════════════════════════════════════════════════════
--  023 — Venta en una sola operación
--
--  Antes la Terminal hacía un viaje al servidor por la venta y DOS por
--  cada producto (guardar la línea + descontar stock), uno tras otro:
--  con conexión normal eran 3-5 segundos por venta, y si algo fallaba a
--  la mitad la venta quedaba incompleta. registrar_venta() hace todo en
--  la base en una transacción: venta, líneas, costo de cada producto y
--  descuento de stock (queda en el kardex). O se guarda completa o nada.
--  Además valida en el servidor que el turno y la caja sigan abiertos y
--  que el total cuadre con las líneas.
--  Anti-duplicado: cada carrito trae un código único (venta_uid). Si la
--  misma venta llega dos veces (doble toque en Cobrar, reintento por mala
--  conexión), la segunda devuelve la primera y NO crea otra venta.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

alter table ventas add column if not exists venta_uid text;
create unique index if not exists ventas_venta_uid_uq on ventas (venta_uid) where venta_uid is not null;

create or replace function public.registrar_venta(p jsonb)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v ventas; it jsonb; t record; v_suma numeric;
  v_turno bigint := nullif(p->>'turno_id', '')::bigint;
  v_usuario text := nullif(p->>'registrado_por', '');
  v_pid bigint;
  v_uid text := nullif(p->>'venta_uid', '');
begin
  -- la misma venta ya se registró: se devuelve esa, sin duplicar
  if v_uid is not null then
    select * into v from ventas where venta_uid = v_uid;
    if found then return to_jsonb(v) || jsonb_build_object('repetida', true); end if;
  end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'La venta no tiene productos'; end if;
  if jsonb_array_length(p->'items') > 300 then raise exception 'Demasiadas líneas en una venta'; end if;
  if v_turno is null then raise exception 'Abre tu turno para vender'; end if;
  select tc.estado as turno, c.estado as caja into t
    from turnos_caja tc join cierres_caja c on c.id = tc.cierre_id where tc.id = v_turno;
  if not found or t.turno <> 'abierto' or t.caja <> 'abierta' then
    raise exception 'Tu turno o la caja ya se cerraron: recarga la página';
  end if;
  select coalesce(sum((e->>'subtotal')::numeric), 0) into v_suma from jsonb_array_elements(p->'items') e;
  if abs(v_suma - coalesce((p->>'total')::numeric, -1)) > 1 then raise exception 'El total no cuadra con los productos'; end if;

  insert into ventas (cliente_id, cliente_nombre, total, metodo_pago, metodo_pago_detalle,
                      monto_efectivo, monto_otro, monto_transferencia, monto_tarjeta, monto_mercadopago,
                      delivery_monto, descuento, efectivo_recibido, vuelto,
                      estado_pago, origen, registrado_por, turno_id, venta_uid)
  values (nullif(p->>'cliente_id', '')::bigint, coalesce(nullif(p->>'cliente_nombre', ''), 'Cliente mostrador'),
          (p->>'total')::numeric, coalesce(p->>'metodo_pago', 'efectivo'), nullif(p->>'metodo_pago_detalle', ''),
          coalesce((p->>'monto_efectivo')::numeric, 0), coalesce((p->>'monto_otro')::numeric, 0),
          coalesce((p->>'monto_transferencia')::numeric, 0), coalesce((p->>'monto_tarjeta')::numeric, 0),
          coalesce((p->>'monto_mercadopago')::numeric, 0),
          coalesce((p->>'delivery_monto')::numeric, 0), coalesce((p->>'descuento')::numeric, 0),
          nullif(p->>'efectivo_recibido', '')::numeric, nullif(p->>'vuelto', '')::numeric,
          'pagado', 'terminal', v_usuario, v_turno, v_uid)
  returning * into v;

  for it in select * from jsonb_array_elements(p->'items') loop
    v_pid := nullif(it->>'producto_id', '')::bigint;
    insert into venta_items (venta_id, producto_id, producto_nombre, cantidad, precio_unitario, subtotal,
                             costo_unitario, es_mayor, precio_original)
    values (v.id, v_pid, it->>'producto_nombre', (it->>'cantidad')::numeric, (it->>'precio_unitario')::numeric,
            (it->>'subtotal')::numeric,
            case when v_pid is null then 0 else coalesce((select costo from productos where id = v_pid), 0) end,
            coalesce((it->>'es_mayor')::boolean, false), nullif(it->>'precio_original', '')::numeric);
    if v_pid is not null then
      perform public.mover_stock(v_pid, -((it->>'cantidad')::numeric), 'salida',
        'Venta boleta ' || coalesce(v.boleta_numero::text, v.id::text), 'terminal', v.id, v_usuario, null);
    end if;
  end loop;
  return to_jsonb(v);
end $$;
revoke all on function public.registrar_venta(jsonb) from public;
grant execute on function public.registrar_venta(jsonb) to pq_admin;

notify pgrst, 'reload schema';
commit;
