-- 033: Devoluciones a proveedor dentro de la factura de compra
--
--  factura_compra_items.devuelto: kg (o unidades) devueltos al proveedor (queso malo, etc.).
--  La línea cobra (cantidad − devuelto) × costo; el stock baja lo devuelto
--  ("Devolución a proveedor" en el kardex) y el total de la factura se recalcula.
--  Si ya se había abonado más que el nuevo total, la factura queda pagada (saldo a favor).
begin;
alter table factura_compra_items add column if not exists devuelto numeric not null default 0;

create or replace function public.editar_factura_compra(p_id bigint, p jsonb, p_usuario text default null)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  f record; prov record; it jsonb; r record;
  v_fecha date; v_num text; v_total numeric; v_suma numeric := 0; v_ajustes int := 0;
  v_nom text; v_cant numeric; v_costo numeric; v_dev numeric;
  v_ultima boolean; v_estado text; v_cuenta text; v_gid bigint; v_abonado numeric;
begin
  select * into f from facturas_compra where id = p_id for update;
  if not found then raise exception 'La factura % no existe', p_id; end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'La factura no tiene productos'; end if;
  if jsonb_array_length(p->'items') > 200 then raise exception 'Demasiadas líneas'; end if;

  select id, nombre into prov from proveedores where id = nullif(p->>'proveedor_id', '')::bigint;
  if not found then raise exception 'Elige un proveedor'; end if;
  v_fecha := coalesce(nullif(p->>'fecha', '')::date, f.fecha);
  v_num   := nullif(btrim(coalesce(p->>'numero', '')), '');

  -- lo nuevo, validado
  for it in select * from jsonb_array_elements(p->'items') loop
    select nombre into v_nom from productos where id = (it->>'producto_id')::bigint;
    if not found then raise exception 'Producto % no existe', it->>'producto_id'; end if;
    v_cant  := (it->>'cantidad')::numeric;
    v_costo := (it->>'costo_unitario')::numeric;
    if v_cant is null or v_cant <= 0 then raise exception 'Cantidad inválida en "%"', v_nom; end if;
    if v_costo is null or v_costo < 0 then raise exception 'Costo inválido en "%"', v_nom; end if;
    v_dev := coalesce(nullif(it->>'devuelto', '')::numeric, 0);
    if v_dev < 0 or v_dev > v_cant then raise exception 'La devolución de "%" no puede ser mayor que lo comprado', v_nom; end if;
    v_suma := v_suma + round((v_cant - v_dev) * v_costo);
  end loop;
  v_total := coalesce(nullif(p->>'total', '')::numeric, v_suma);

  -- stock: diferencia por producto (viejo → nuevo), con lo DEVUELTO descontado
  for r in
    select coalesce(o.producto_id, n.producto_id) as producto_id, coalesce(n.cant, 0) - coalesce(o.cant, 0) as delta,
           coalesce(n.dev, 0) - coalesce(o.dev, 0) as delta_dev
      from (select producto_id, sum(cantidad - coalesce(devuelto, 0)) cant, sum(coalesce(devuelto, 0)) dev
              from factura_compra_items where factura_id = p_id and producto_id is not null group by 1) o
      full join (select producto_id, sum(cantidad - coalesce(devuelto, 0)) cant, sum(coalesce(devuelto, 0)) dev
                   from jsonb_to_recordset(p->'items') as x(producto_id bigint, cantidad numeric, devuelto numeric) group by 1) n
             on n.producto_id = o.producto_id
  loop
    if r.delta <> 0 then
      perform public.mover_stock(r.producto_id, r.delta, case when r.delta > 0 then 'entrada' else 'salida' end,
        case when r.delta < 0 and r.delta_dev > 0 then 'Devolución a proveedor (factura ' else 'Corrección factura de compra (' end
          || coalesce('N° ' || v_num, '#' || p_id) || ') · ' || prov.nombre,
        'compra', p_id, p_usuario, null);
      v_ajustes := v_ajustes + 1;
    end if;
  end loop;

  -- costo: solo si esta es la última factura que trae el producto
  for r in select distinct on ((e->>'producto_id')::bigint) (e->>'producto_id')::bigint as producto_id, (e->>'costo_unitario')::numeric as costo
             from jsonb_array_elements(p->'items') with ordinality as t(e, linea)
            order by (e->>'producto_id')::bigint, linea desc loop
    select not exists (select 1 from factura_compra_items i where i.producto_id = r.producto_id and i.factura_id > p_id) into v_ultima;
    if v_ultima then update productos set costo = r.costo, updated_at = now() where id = r.producto_id and costo is distinct from r.costo; end if;
  end loop;

  delete from factura_compra_items where factura_id = p_id;
  insert into factura_compra_items (factura_id, producto_id, producto_nombre, cantidad, devuelto, costo_unitario, subtotal)
  select p_id, (t.e->>'producto_id')::bigint, pr.nombre, (t.e->>'cantidad')::numeric,
         coalesce(nullif(t.e->>'devuelto', '')::numeric, 0), (t.e->>'costo_unitario')::numeric,
         round(((t.e->>'cantidad')::numeric - coalesce(nullif(t.e->>'devuelto', '')::numeric, 0)) * (t.e->>'costo_unitario')::numeric)
    from jsonb_array_elements(p->'items') with ordinality as t(e, linea)
    join productos pr on pr.id = (t.e->>'producto_id')::bigint
   order by t.linea;

  -- con abonos el estado lo deciden los abonos (no se crea ni borra un gasto por el total)
  select coalesce(sum(monto), 0) into v_abonado from abonos_factura where factura_id = p_id;
  if v_abonado > 0 then
    update facturas_compra set proveedor_id = prov.id, proveedor_nombre = prov.nombre, numero_factura = v_num, fecha = v_fecha, total = v_total,
           pagado = v_abonado, estado_pago = case when v_abonado >= v_total - 0.5 then 'pagada' else 'pendiente' end
     where id = p_id;
    return jsonb_build_object('factura_id', p_id, 'total', v_total, 'productos_con_stock_ajustado', v_ajustes,
                              'estado_pago', case when v_abonado >= v_total - 0.5 then 'pagada' else 'pendiente' end,
                              'abonado', v_abonado, 'saldo', greatest(v_total - v_abonado, 0));
  end if;

  -- pago: estado y cuenta
  v_estado := coalesce(nullif(p->>'estado_pago', ''), f.estado_pago);
  if v_estado not in ('pendiente','pagada') then raise exception 'Estado de pago inválido'; end if;
  v_gid := f.gasto_id;
  if v_estado = 'pagada' then
    v_cuenta := nullif(p->>'cuenta', '');
    if v_cuenta is null and v_gid is not null then select cuenta into v_cuenta from gastos where id = v_gid; end if;
    v_cuenta := coalesce(v_cuenta, 'bancoestado');
    if v_cuenta not in ('efectivo','bancoestado','mercadopago') then raise exception 'Cuenta inválida'; end if;
    if v_gid is null then
      insert into gastos (fecha, descripcion, categoria, monto, cuenta, notas)
      values (v_fecha, 'Factura de compra ' || coalesce('#' || v_num, '#' || p_id) || ' — ' || prov.nombre,
              'mercaderia', v_total, v_cuenta, 'Generado al marcar pagada la factura de compra #' || p_id)
      returning id into v_gid;
    else
      update gastos set monto = v_total, fecha = v_fecha, cuenta = v_cuenta,
             descripcion = 'Factura de compra ' || coalesce('#' || v_num, '#' || p_id) || ' — ' || prov.nombre
       where id = v_gid;
    end if;
  elsif v_gid is not null then
    if exists (select 1 from caja_movimientos where gasto_id = v_gid) then
      raise exception 'Este pago salió de la caja (retiro de efectivo). Anúlalo desde Caja antes de pasar la factura a pendiente';
    end if;
    delete from gastos where id = v_gid;   -- facturas_compra.gasto_id queda en null
    v_gid := null;
  end if;

  update facturas_compra set proveedor_id = prov.id, proveedor_nombre = prov.nombre, numero_factura = v_num, fecha = v_fecha, total = v_total,
         estado_pago = v_estado, gasto_id = v_gid, pagado = case when v_estado = 'pagada' then v_total else 0 end
   where id = p_id;
  return jsonb_build_object('factura_id', p_id, 'total', v_total, 'productos_con_stock_ajustado', v_ajustes,
                            'estado_pago', v_estado, 'cuenta', v_cuenta);
end $$;
revoke all on function public.editar_factura_compra(bigint, jsonb, text) from public;
grant execute on function public.editar_factura_compra(bigint, jsonb, text) to pq_admin;

notify pgrst, 'reload schema';
commit;
