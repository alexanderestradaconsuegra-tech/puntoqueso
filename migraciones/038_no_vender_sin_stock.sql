-- ══════════════════════════════════════════════════════════════════
--  038 — No se puede vender lo que no hay en stock
--
--  Todo descuento de stock (ventas del Terminal, pedidos cobrados,
--  devoluciones a proveedor…) pasa por mover_stock(). Ahora, si una
--  salida dejaría el stock en negativo, se rechaza con un mensaje claro y
--  NADA se guarda (la venta completa se revierte).
--   · Se puede apagar desde el panel: Configuración → "No dejar vender en
--     caja lo que no tiene stock" (config pos_control_stock; por defecto
--     encendido).
--   · Las tomas de inventario y los ajustes no se bloquean: son la forma
--     de corregir el stock.
--   · Productos que hoy están en 0 o negativo no se podrán vender hasta
--     cargar su stock (toma de inventario o factura de compra).
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

create or replace function public.mover_stock(
  p_producto bigint, p_delta numeric, p_tipo text, p_motivo text, p_origen text,
  p_ref bigint default null, p_usuario text default null, p_costo numeric default null
) returns numeric
language plpgsql security invoker set search_path = public as $$
declare
  v_stock numeric; v_ant numeric; v_nom text;
  v_ctrl boolean := coalesce(lower(private.cfg_txt('pos_control_stock')), 'true') not in ('false','0','no');
  f text := '(\.?0+)$';
begin
  if p_delta is null or p_delta = 0 then
    select stock into v_stock from productos where id = p_producto;
    return v_stock;
  end if;
  if p_tipo not in ('entrada','salida','ajuste') then raise exception 'Tipo de movimiento inválido'; end if;

  -- salida: no se puede sacar más de lo que hay (la fila se bloquea: dos ventas a la vez no se llevan el mismo stock)
  if p_tipo = 'salida' and p_delta < 0 and v_ctrl then
    select nombre, coalesce(stock, 0) into v_nom, v_ant from productos where id = p_producto for update;
    if found and v_ant + p_delta < -0.0000001 then
      raise exception 'Sin stock de "%": hay % y se necesitan %. Carga el stock (factura de compra o toma de inventario) antes de vender.',
        v_nom, regexp_replace(round(v_ant, 3)::text, f, ''), regexp_replace(round(-p_delta, 3)::text, f, '');
    end if;
  end if;

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

notify pgrst, 'reload schema';
commit;
