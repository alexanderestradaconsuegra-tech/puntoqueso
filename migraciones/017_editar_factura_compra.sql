-- ══════════════════════════════════════════════════════════════════
--  017 — Editar una factura de compra ya ingresada
--
--  Cambia proveedor, N°, fecha y productos (cantidad y costo) de una
--  factura, y corrige TODO lo que había movido, en una transacción:
--   · stock: por cada producto se mueve solo la DIFERENCIA entre lo
--     que ingresó la factura y lo nuevo (queda en el kardex como
--     "Corrección factura #N").
--   · costo del producto: se actualiza solo si esta es la última
--     factura que lo trae (una factura vieja no pisa un costo más nuevo).
--   · gasto: si la factura estaba pagada, el gasto toma el nuevo total
--     y la nueva fecha.
--  p: {proveedor_id, numero, fecha, total, items:[{producto_id, cantidad, costo_unitario}]}
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

create or replace function public.editar_factura_compra(p_id bigint, p jsonb, p_usuario text default null)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  f record; prov record; it jsonb; r record;
  v_fecha date; v_num text; v_total numeric; v_suma numeric := 0; v_ajustes int := 0;
  v_nom text; v_cant numeric; v_costo numeric;
  v_ultima boolean;
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
    v_suma := v_suma + round(v_cant * v_costo);
  end loop;
  v_total := coalesce(nullif(p->>'total', '')::numeric, v_suma);

  -- stock: diferencia por producto (viejo → nuevo)
  for r in
    select coalesce(o.producto_id, n.producto_id) as producto_id, coalesce(n.cant, 0) - coalesce(o.cant, 0) as delta
      from (select producto_id, sum(cantidad) cant from factura_compra_items where factura_id = p_id and producto_id is not null group by 1) o
      full join (select producto_id, sum(cantidad) cant from jsonb_to_recordset(p->'items') as x(producto_id bigint, cantidad numeric) group by 1) n
             on n.producto_id = o.producto_id
  loop
    if r.delta <> 0 then
      perform public.mover_stock(r.producto_id, r.delta, case when r.delta > 0 then 'entrada' else 'salida' end,
        'Corrección factura de compra ' || coalesce('N° ' || v_num, '#' || p_id) || ' · ' || prov.nombre,
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
  insert into factura_compra_items (factura_id, producto_id, producto_nombre, cantidad, costo_unitario, subtotal)
  select p_id, (t.e->>'producto_id')::bigint, pr.nombre, (t.e->>'cantidad')::numeric, (t.e->>'costo_unitario')::numeric,
         round((t.e->>'cantidad')::numeric * (t.e->>'costo_unitario')::numeric)
    from jsonb_array_elements(p->'items') with ordinality as t(e, linea)
    join productos pr on pr.id = (t.e->>'producto_id')::bigint
   order by t.linea;

  update facturas_compra set proveedor_id = prov.id, proveedor_nombre = prov.nombre, numero_factura = v_num, fecha = v_fecha, total = v_total
   where id = p_id;
  if f.gasto_id is not null then
    update gastos set monto = v_total, fecha = v_fecha,
           descripcion = 'Factura de compra ' || coalesce('#' || v_num, '#' || p_id) || ' — ' || prov.nombre
     where id = f.gasto_id;
  end if;
  return jsonb_build_object('factura_id', p_id, 'total', v_total, 'productos_con_stock_ajustado', v_ajustes);
end $$;
revoke all on function public.editar_factura_compra(bigint, jsonb, text) from public;
grant execute on function public.editar_factura_compra(bigint, jsonb, text) to pq_admin;

notify pgrst, 'reload schema';
commit;
