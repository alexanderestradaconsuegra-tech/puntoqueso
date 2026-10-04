-- ══════════════════════════════════════════════════════════════════
--  024 — Ventas de otro día
--
--  · registrar_venta() acepta "fecha": una venta de un día anterior
--    (p. ej. lo vendido en otro sistema) queda con esa fecha en ventas,
--    reportes y cuentas, descuenta stock, y NO entra a la caja ni al
--    turno de hoy (esa plata no está en el cajón de hoy).
--  · cambiar_fecha_venta(): corrige la fecha de una venta ya registrada.
--    Si la venta estaba en un turno abierto, sale de él; si su turno ya
--    se cerró, no se permite (el cierre ya la contó).
--  Reemplaza la función de 023. Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

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
                      estado_pago, origen, registrado_por, turno_id, venta_uid, created_at)
  values (nullif(p->>'cliente_id', '')::bigint, coalesce(nullif(p->>'cliente_nombre', ''), 'Cliente mostrador'),
          (p->>'total')::numeric, coalesce(p->>'metodo_pago', 'efectivo'), nullif(p->>'metodo_pago_detalle', ''),
          coalesce((p->>'monto_efectivo')::numeric, 0), coalesce((p->>'monto_otro')::numeric, 0),
          coalesce((p->>'monto_transferencia')::numeric, 0), coalesce((p->>'monto_tarjeta')::numeric, 0),
          coalesce((p->>'monto_mercadopago')::numeric, 0),
          coalesce((p->>'delivery_monto')::numeric, 0), coalesce((p->>'descuento')::numeric, 0),
          nullif(p->>'efectivo_recibido', '')::numeric, nullif(p->>'vuelto', '')::numeric,
          'pagado', 'terminal', v_usuario, v_turno, v_uid, v_ts)
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

create or replace function public.cambiar_fecha_venta(p_id bigint, p_fecha date, p_usuario text default null)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v record; v_hoy date := (now() at time zone 'America/Santiago')::date; v_ts timestamptz; v_turno_estado text;
begin
  select * into v from ventas where id = p_id for update;
  if not found then raise exception 'La venta no existe'; end if;
  if v.anulada then raise exception 'La venta está anulada'; end if;
  if p_fecha is null or p_fecha > v_hoy then raise exception 'La fecha no puede ser futura'; end if;
  if p_fecha < v_hoy - 90 then raise exception 'Solo se puede mover a los últimos 90 días'; end if;
  if v.turno_id is not null then
    select estado into v_turno_estado from turnos_caja where id = v.turno_id;
    if v_turno_estado = 'cerrado' then
      raise exception 'Esta venta ya está en un cierre de turno: no se puede cambiar la fecha';
    end if;
  end if;
  -- se mantiene la hora; si pasa a otro día, sale del turno de hoy
  v_ts := (p_fecha + (v.created_at at time zone 'America/Santiago')::time) at time zone 'America/Santiago';
  update ventas set created_at = v_ts, turno_id = case when p_fecha = v_hoy then turno_id else null end where id = p_id;
  update venta_items set created_at = v_ts where venta_id = p_id;
  return jsonb_build_object('venta_id', p_id, 'fecha', p_fecha);
end $$;
revoke all on function public.cambiar_fecha_venta(bigint, date, text) from public;
grant execute on function public.cambiar_fecha_venta(bigint, date, text) to pq_admin;

notify pgrst, 'reload schema';
commit;
