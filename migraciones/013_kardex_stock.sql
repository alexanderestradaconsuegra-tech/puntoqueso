-- ══════════════════════════════════════════════════════════════════
--  013 — Control total del stock (kardex)
--
--  · mover_stock(): TODO cambio de stock del panel pasa por aquí. Suma o
--    resta sobre el valor REAL de la base (no sobre la copia de la
--    pantalla), así dos cajas o dos líneas del mismo producto nunca se
--    pisan, y registra el movimiento en la misma operación.
--  · Trigger en productos: si el stock cambia por cualquier otro camino
--    (editar producto, importar Excel, un comando), igual queda registrado
--    como "cambio manual", con el usuario que lo hizo.
--  · stock_movimientos guarda además el stock resultante y el costo.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

alter table stock_movimientos add column if not exists stock_resultante numeric;
alter table stock_movimientos add column if not exists costo_unitario numeric;
create index if not exists stock_movimientos_producto_idx on stock_movimientos (producto_id, created_at desc);

create or replace function public.mover_stock(
  p_producto bigint, p_delta numeric, p_tipo text, p_motivo text, p_origen text,
  p_ref bigint default null, p_usuario text default null, p_costo numeric default null
) returns numeric
language plpgsql security invoker set search_path = public as $$
declare v_stock numeric;
begin
  if p_delta is null or p_delta = 0 then
    select stock into v_stock from productos where id = p_producto;
    return v_stock;
  end if;
  if p_tipo not in ('entrada','salida','ajuste') then raise exception 'Tipo de movimiento inválido'; end if;
  perform set_config('pq.mov', '1', true);
  update productos
     set stock = coalesce(stock, 0) + p_delta,
         costo = coalesce(p_costo, costo),
         updated_at = now()
   where id = p_producto
   returning stock into v_stock;
  if not found then raise exception 'Producto % no existe', p_producto; end if;
  insert into stock_movimientos (producto_id, tipo, cantidad, motivo, origen, referencia_id, registrado_por, stock_resultante, costo_unitario)
  values (p_producto, p_tipo, case when p_tipo = 'ajuste' then p_delta else abs(p_delta) end,
          p_motivo, p_origen, p_ref, p_usuario, v_stock, p_costo);
  perform set_config('pq.mov', '', true);
  return v_stock;
end $$;
revoke all on function public.mover_stock(bigint, numeric, text, text, text, bigint, text, numeric) from public;
grant execute on function public.mover_stock(bigint, numeric, text, text, text, bigint, text, numeric) to pq_admin;

-- Cualquier otro cambio de stock queda registrado igual
create or replace function private.log_stock_manual() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_user text;
begin
  if coalesce(current_setting('pq.mov', true), '') = '1' then return new; end if;
  if tg_op = 'UPDATE' and coalesce(new.stock, 0) = coalesce(old.stock, 0) then return new; end if;
  if tg_op = 'INSERT' and coalesce(new.stock, 0) = 0 then return new; end if;
  begin
    v_user := current_setting('request.jwt.claims', true)::json->>'usuario';
  exception when others then v_user := null; end;
  insert into stock_movimientos (producto_id, tipo, cantidad, motivo, origen, registrado_por, stock_resultante, costo_unitario)
  values (new.id, 'ajuste',
          coalesce(new.stock, 0) - (case when tg_op = 'UPDATE' then coalesce(old.stock, 0) else 0 end),
          case when tg_op = 'INSERT' then 'Stock inicial (producto creado)' else 'Cambio manual de stock (editar / importar)' end,
          'manual', coalesce(v_user, current_user), new.stock, new.costo);
  return new;
end $$;
drop trigger if exists productos_log_stock on productos;
create trigger productos_log_stock after insert or update of stock on productos
  for each row execute function private.log_stock_manual();

-- La toma de inventario registra sus propios movimientos (con saldo y costo)
create or replace function public.aplicar_toma_inventario(p_items jsonb, p_cero_resto boolean, p_usuario text, p_notas text default null)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  it jsonb; prod record; v_id bigint;
  v_cant numeric; v_costo numeric; v_antes numeric;
  v_n int := 0; v_cero int := 0; v_vc numeric := 0; v_vv numeric := 0;
  v_det jsonb := '[]'::jsonb; v_ids bigint[] := '{}';
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then raise exception 'Lista de productos inválida'; end if;
  -- los movimientos de esta toma se registran aquí mismo (el trigger no duplica)
  perform set_config('pq.mov', '1', true);
  insert into tomas_inventario (registrado_por, cero_resto, notas) values (p_usuario, coalesce(p_cero_resto, false), p_notas)
  returning id into v_id;

  for it in select * from jsonb_array_elements(p_items) loop
    select id, nombre, stock, costo, precio, unidad into prod
      from productos where id = (it->>'producto_id')::bigint and activo = true for update;
    if not found or (prod.id = any(v_ids)) then continue; end if;
    v_cant  := greatest(0, coalesce(nullif(it->>'cantidad', '')::numeric, 0));
    v_costo := greatest(0, coalesce(nullif(it->>'costo', '')::numeric, prod.costo, 0));
    v_antes := coalesce(prod.stock, 0);
    update productos set stock = v_cant, costo = v_costo, updated_at = now() where id = prod.id;
    if v_cant <> v_antes then
      insert into stock_movimientos (producto_id, tipo, cantidad, motivo, origen, referencia_id, registrado_por, stock_resultante, costo_unitario)
      values (prod.id, 'ajuste', v_cant - v_antes, 'Toma de inventario #' || v_id, 'ajuste', v_id, p_usuario, v_cant, v_costo);
    end if;
    v_ids := v_ids || prod.id;
    v_n := v_n + 1;
    v_vc := v_vc + v_cant * v_costo;
    v_vv := v_vv + v_cant * coalesce(prod.precio, 0);
    v_det := v_det || jsonb_build_object('id', prod.id, 'nombre', prod.nombre, 'unidad', prod.unidad,
                                         'antes', v_antes, 'cantidad', v_cant, 'costo', v_costo);
  end loop;

  if coalesce(p_cero_resto, false) then
    for prod in select id, stock from productos
                 where activo = true and not (id = any(v_ids)) and coalesce(stock, 0) <> 0 for update loop
      update productos set stock = 0, updated_at = now() where id = prod.id;
      insert into stock_movimientos (producto_id, tipo, cantidad, motivo, origen, referencia_id, registrado_por, stock_resultante)
      values (prod.id, 'ajuste', -prod.stock, 'Toma de inventario #' || v_id || ' (no contado: queda en 0)', 'ajuste', v_id, p_usuario, 0);
      v_cero := v_cero + 1;
    end loop;
  end if;

  update tomas_inventario
     set productos = v_n, valor_costo = v_vc, valor_venta = v_vv, puestos_en_cero = v_cero, detalle = v_det
   where id = v_id;
  return jsonb_build_object('id', v_id, 'productos', v_n, 'valor_costo', v_vc, 'valor_venta', v_vv, 'puestos_en_cero', v_cero);
end $$;
revoke all on function public.aplicar_toma_inventario(jsonb, boolean, text, text) from public;
grant execute on function public.aplicar_toma_inventario(jsonb, boolean, text, text) to pq_admin;

notify pgrst, 'reload schema';
commit;
