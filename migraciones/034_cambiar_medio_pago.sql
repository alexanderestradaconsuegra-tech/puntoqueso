-- ══════════════════════════════════════════════════════════════════
--  034 — Corregir el medio de pago de una venta (solo el administrador)
--
--  cambiar_medio_pago(p_id, p): cambia efectivo / transferencia / tarjeta /
--  link Mercado Pago / mixto de una venta ya registrada, en una transacción:
--   · la venta queda con sus montos por medio (lo que usan Cuentas,
--     Dashboard y cierres); el total y los productos NO cambian.
--   · si la venta está en un turno ya cerrado, el cierre de ese turno y el
--     de la caja del día se corrigen: ventas por medio, "debía haber" y la
--     diferencia contra lo contado (el conteo no se toca).
--   · si el turno sigue abierto no hay nada más que hacer: se calcula al cerrar.
--   · deja el cambio en la auditoría con el medio anterior y el nuevo.
--  No se puede: venta anulada, venta sin pagar (pedido por cobrar) o de más
--  de 90 días. Solo el usuario con rol admin (private.es_dueno, migración 032).
--  p: {metodo_pago, efectivo, transferencia, tarjeta, mercadopago}
--     (los montos solo se usan con metodo_pago = 'mixto' y deben sumar el total)
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

create or replace function public.cambiar_medio_pago(p_id bigint, p jsonb)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v ventas; tu record;
  v_metodo text := nullif(p->>'metodo_pago', '');
  v_hoy date := (now() at time zone 'America/Santiago')::date;
  n_ef numeric := 0; n_tr numeric := 0; n_tj numeric := 0; n_mp numeric := 0;
  o_ef numeric; o_tr numeric; o_tj numeric; o_mp numeric;
  d_ef numeric; d_tr numeric; d_tj numeric; d_mp numeric;
  v_det text; v_antes text; v_ajuste text := '';
  v_usuario text := nullif(current_setting('request.jwt.claims', true), '')::json->>'usuario';
begin
  if not private.es_dueno() then raise exception 'Solo el administrador puede cambiar el medio de pago'; end if;
  if v_metodo is null or v_metodo not in ('efectivo','transferencia','tarjeta','mercadopago','mixto') then
    raise exception 'Medio de pago inválido';
  end if;
  select * into v from ventas where id = p_id for update;
  if not found then raise exception 'La venta no existe'; end if;
  if v.anulada then raise exception 'La venta está anulada'; end if;
  if v.estado_pago = 'pendiente' then raise exception 'Esta venta aún no está pagada: cóbrala desde Pedidos'; end if;
  if (v.created_at at time zone 'America/Santiago')::date < v_hoy - 90 then
    raise exception 'Solo se pueden corregir ventas de los últimos 90 días';
  end if;

  -- montos actuales por medio (ventas viejas sin desglose: se reparten por método)
  if v.monto_transferencia is not null then
    o_ef := coalesce(v.monto_efectivo, 0); o_tr := coalesce(v.monto_transferencia, 0);
    o_tj := coalesce(v.monto_tarjeta, 0);  o_mp := coalesce(v.monto_mercadopago, 0);
  else
    o_ef := case when v.metodo_pago = 'mixto' then coalesce(v.monto_efectivo, 0) when coalesce(v.metodo_pago, 'efectivo') = 'efectivo' then v.total else 0 end;
    o_tr := case when v.metodo_pago = 'mixto' then coalesce(v.monto_otro, 0) when v.metodo_pago = 'transferencia' then v.total else 0 end;
    o_tj := case when v.metodo_pago = 'tarjeta' then v.total else 0 end;
    o_mp := case when v.metodo_pago = 'mercadopago' then v.total else 0 end;
  end if;

  -- montos nuevos
  if v_metodo = 'mixto' then
    n_ef := greatest(coalesce(nullif(p->>'efectivo', '')::numeric, 0), 0);
    n_tr := greatest(coalesce(nullif(p->>'transferencia', '')::numeric, 0), 0);
    n_tj := greatest(coalesce(nullif(p->>'tarjeta', '')::numeric, 0), 0);
    n_mp := greatest(coalesce(nullif(p->>'mercadopago', '')::numeric, 0), 0);
    if abs(n_ef + n_tr + n_tj + n_mp - v.total) >= 1 then
      raise exception 'Los montos (%) no suman el total de la venta (%)', n_ef + n_tr + n_tj + n_mp, v.total;
    end if;
    if (n_ef > 0)::int + (n_tr > 0)::int + (n_tj > 0)::int + (n_mp > 0)::int < 2 then
      raise exception 'Un pago mixto lleva al menos dos medios; si es uno solo, elige ese medio';
    end if;
    v_det := concat_ws(', ',
      case when n_ef > 0 then 'Efectivo: ' || n_ef end,
      case when n_tr > 0 then 'Transferencia: ' || n_tr end,
      case when n_tj > 0 then 'Tarjeta: ' || n_tj end,
      case when n_mp > 0 then 'Mercado Pago: ' || n_mp end);
  elsif v_metodo = 'efectivo'      then n_ef := v.total;
  elsif v_metodo = 'transferencia' then n_tr := v.total;
  elsif v_metodo = 'tarjeta'       then n_tj := v.total;
  else                                  n_mp := v.total;
  end if;

  d_ef := n_ef - o_ef; d_tr := n_tr - o_tr; d_tj := n_tj - o_tj; d_mp := n_mp - o_mp;
  if d_ef = 0 and d_tr = 0 and d_tj = 0 and d_mp = 0 and v.metodo_pago = v_metodo then
    return jsonb_build_object('venta_id', p_id, 'sin_cambios', true);
  end if;
  v_antes := v.metodo_pago || coalesce(' (' || v.metodo_pago_detalle || ')', '');

  update ventas
     set metodo_pago = v_metodo, metodo_pago_detalle = v_det,
         monto_efectivo = n_ef, monto_transferencia = n_tr, monto_tarjeta = n_tj, monto_mercadopago = n_mp,
         monto_otro = v.total - n_ef,
         -- con cuánto pagó y el vuelto solo tienen sentido en efectivo
         efectivo_recibido = case when v_metodo = 'efectivo' and v.metodo_pago = 'efectivo' then efectivo_recibido end,
         vuelto            = case when v_metodo = 'efectivo' and v.metodo_pago = 'efectivo' then vuelto end
   where id = p_id;

  -- turno ya cerrado: se corrige su cierre y el de la caja (el conteo queda igual)
  if v.turno_id is not null and not coalesce(v.fuera_caja, false) then
    select * into tu from turnos_caja where id = v.turno_id for update;
    if found and tu.estado = 'cerrado' then
      update turnos_caja
         set ventas_efectivo      = coalesce(ventas_efectivo, 0) + d_ef,
             ventas_transferencia = coalesce(ventas_transferencia, 0) + d_tr,
             ventas_tarjeta       = coalesce(ventas_tarjeta, 0) + d_tj,
             ventas_mercadopago   = coalesce(ventas_mercadopago, 0) + d_mp,
             total_esperado       = coalesce(total_esperado, 0) + d_ef,
             diferencia           = case when total_contado is null then diferencia
                                         else total_contado - (coalesce(total_esperado, 0) + d_ef) end
       where id = tu.id;
      v_ajuste := ' · se corrigió el cierre del turno ' || tu.numero;
    end if;
    if found then
      update cierres_caja
         set ventas_efectivo      = coalesce(ventas_efectivo, 0) + d_ef,
             ventas_transferencia = coalesce(ventas_transferencia, 0) + d_tr,
             ventas_tarjeta       = coalesce(ventas_tarjeta, 0) + d_tj,
             ventas_mercadopago   = coalesce(ventas_mercadopago, 0) + d_mp,
             total_esperado       = coalesce(total_esperado, 0) + d_ef,
             diferencia           = case when total_contado is null then diferencia
                                         else total_contado - (coalesce(total_esperado, 0) + d_ef) end
       where id = tu.cierre_id and estado = 'cerrada';
      if found then v_ajuste := v_ajuste || ' y de la caja del ' || to_char((v.created_at at time zone 'America/Santiago')::date, 'DD-MM-YYYY'); end if;
    end if;
  end if;

  insert into auditlog (usuario, accion, modulo, detalle)
  values (coalesce((select nombre from usuarios where usuario = v_usuario), v_usuario), 'Medio de pago cambiado', 'ventas',
          'Boleta ' || coalesce(v.boleta_numero::text, v.id::text) || ' ($' || replace(to_char(v.total, 'FM999,999,999'), ',', '.') || '): '
          || v_antes || ' → ' || v_metodo || coalesce(' (' || v_det || ')', '') || v_ajuste);

  return jsonb_build_object('venta_id', p_id, 'antes', v.metodo_pago, 'ahora', v_metodo,
                            'delta_efectivo', d_ef, 'ajuste', nullif(v_ajuste, ''));
end $$;
revoke all on function public.cambiar_medio_pago(bigint, jsonb) from public;
grant execute on function public.cambiar_medio_pago(bigint, jsonb) to pq_admin;

notify pgrst, 'reload schema';
commit;
