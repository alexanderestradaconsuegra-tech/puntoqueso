-- ══════════════════════════════════════════════════════════════════
--  048 — Ingresar una factura de compra: todo o nada
--
--  Antes el panel guardaba la factura, luego cada línea y luego sumaba el
--  stock línea por línea, en pasos separados: si se cortaba internet a la
--  mitad, quedaba una factura a medias. Ahora es UNA sola operación en el
--  servidor (factura + líneas + stock + gasto si está pagada): o queda
--  todo guardado, o no queda nada y el panel lo dice.
--   · uid: identificador único por factura que llega del panel; si el mismo envío
--     se repite (reintento por mala conexión) NO se duplica ni suma el stock dos veces.
--   · Si ya existe una factura con el mismo número de ese proveedor, avisa
--     (se puede guardar igual si de verdad es otra).
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

alter table facturas_compra add column if not exists uid text;
create unique index if not exists facturas_compra_uid_uq on facturas_compra(uid) where uid is not null;

create or replace function public.crear_factura_compra(p jsonb, p_usuario text default null)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v_uid text := nullif(p->>'uid', '');
  v_prov record; v_prod record; it jsonb;
  v_num text := nullif(btrim(coalesce(p->>'numero', '')), '');
  v_fecha date := coalesce(nullif(p->>'fecha', '')::date, (now() at time zone 'America/Santiago')::date);
  v_estado text := coalesce(nullif(p->>'estado_pago', ''), 'pendiente');
  v_cuenta text := coalesce(nullif(p->>'cuenta', ''), 'bancoestado');
  v_fid bigint; v_gid bigint; v_total numeric := 0; v_cant numeric; v_costo numeric; v_sub numeric; v_n int := 0;
  v_ex record;
begin
  if v_uid is not null then
    perform pg_advisory_xact_lock(hashtext('crear_factura_compra:' || v_uid));
    select id, total into v_ex from facturas_compra where uid = v_uid;
    if found then   -- el mismo envío ya se guardó: no se repite nada
      return jsonb_build_object('factura_id', v_ex.id, 'total', v_ex.total, 'repetida', true,
                                'lineas', (select count(*) from factura_compra_items where factura_id = v_ex.id));
    end if;
  end if;
  if v_estado not in ('pendiente','pagada') then raise exception 'Estado de pago inválido'; end if;
  if v_estado = 'pagada' and v_cuenta not in ('efectivo','bancoestado','mercadopago') then raise exception 'Cuenta de pago inválida'; end if;
  select * into v_prov from proveedores where id = nullif(p->>'proveedor_id', '')::bigint;
  if not found then raise exception 'Elige un proveedor'; end if;
  if jsonb_typeof(p->'items') is distinct from 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'La factura no tiene productos'; end if;

  if v_num is not null and not coalesce((p->>'permitir_duplicada')::boolean, false)
     and exists (select 1 from facturas_compra where proveedor_id = v_prov.id and lower(numero_factura) = lower(v_num)) then
    raise exception 'DUPLICADA: ya existe la factura N° % de %', v_num, v_prov.nombre;
  end if;

  -- valida todas las líneas antes de tocar nada
  for it in select * from jsonb_array_elements(p->'items') loop
    v_cant := (it->>'cantidad')::numeric; v_costo := coalesce(nullif(it->>'costo_unitario', '')::numeric, 0);
    if v_cant is null or v_cant <= 0 then raise exception 'Hay una cantidad en 0 o vacía: corrígela'; end if;
    if v_costo < 0 then raise exception 'Hay un precio negativo'; end if;
    select id into v_prod from productos where id = nullif(it->>'producto_id', '')::bigint;
    if not found then raise exception 'Un producto de la factura ya no existe: vuelve a elegirlo'; end if;
    v_total := v_total + round(v_cant * v_costo);
  end loop;

  insert into facturas_compra (proveedor_id, proveedor_nombre, numero_factura, fecha, total, estado_pago, pagado, uid)
  values (v_prov.id, v_prov.nombre, v_num, v_fecha, v_total, v_estado, case when v_estado = 'pagada' then v_total else 0 end, v_uid)
  returning id into v_fid;

  for it in select * from jsonb_array_elements(p->'items') loop
    v_cant := (it->>'cantidad')::numeric; v_costo := coalesce(nullif(it->>'costo_unitario', '')::numeric, 0); v_sub := round(v_cant * v_costo);
    select id, nombre into v_prod from productos where id = (it->>'producto_id')::bigint;
    insert into factura_compra_items (factura_id, producto_id, producto_nombre, cantidad, costo_unitario, subtotal)
    values (v_fid, v_prod.id, v_prod.nombre, v_cant, v_costo, v_sub);
    perform public.mover_stock(v_prod.id, v_cant, 'entrada',
      'Factura de compra ' || coalesce('N° ' || v_num, '#' || v_fid) || ' · ' || v_prov.nombre, 'compra', v_fid, p_usuario, nullif(v_costo, 0));
    v_n := v_n + 1;
  end loop;

  if v_estado = 'pagada' then
    insert into gastos (fecha, descripcion, categoria, monto, cuenta, notas)
    values (v_fecha, 'Factura de compra ' || coalesce('#' || v_num, '#' || v_fid) || ' — ' || v_prov.nombre, 'mercaderia', v_total, v_cuenta,
            'Generado automáticamente al pagar la factura de compra #' || v_fid)
    returning id into v_gid;
    update facturas_compra set gasto_id = v_gid where id = v_fid;
  end if;

  return jsonb_build_object('factura_id', v_fid, 'total', v_total, 'lineas', v_n, 'repetida', false, 'gasto_id', v_gid);
end $$;
revoke all on function public.crear_factura_compra(jsonb, text) from public;
grant execute on function public.crear_factura_compra(jsonb, text) to pq_admin;

notify pgrst, 'reload schema';
commit;
