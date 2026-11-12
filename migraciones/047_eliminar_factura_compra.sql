-- ══════════════════════════════════════════════════════════════════
--  047 — Eliminar una factura de compra devuelve el stock
--
--  Antes: eliminar una factura borraba el registro pero el stock que había
--  sumado se quedaba (decía "NO revierte el stock"). Ahora:
--   · el stock neto que sumó (cantidad - devuelto) se descuenta de nuevo con un
--     movimiento "Factura de compra eliminada" en el historial (kardex);
--   · opcionalmente se borran también los pagos registrados (el gasto de la
--     factura y sus abonos). Si algún pago salió de la caja (retiro de efectivo)
--     no se borra: hay que anularlo antes desde Caja.
--  Todo en una sola operación: si algo falla, no se guarda nada. Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

create or replace function public.eliminar_factura_compra(p_id bigint, p_usuario text default null, p_borrar_pagos boolean default false)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  f record; it record; v_n int := 0; v_g int := 0; v_gids bigint[] := '{}'; v_label text;
begin
  select * into f from facturas_compra where id = p_id for update;
  if not found then raise exception 'La factura no existe (quizá ya fue eliminada)'; end if;
  v_label := coalesce('N° ' || f.numero_factura, '#' || p_id) || ' · ' || coalesce(f.proveedor_nombre, '');

  -- stock: se descuenta lo que la factura sumó (neto de devoluciones)
  for it in
    select producto_id, sum(cantidad - coalesce(devuelto, 0)) as neto
      from factura_compra_items where factura_id = p_id and producto_id is not null group by producto_id
  loop
    if it.neto <> 0 then
      perform public.mover_stock(it.producto_id, -it.neto, 'ajuste', 'Factura de compra eliminada (' || v_label || ')', 'compra', p_id, p_usuario, null);
      v_n := v_n + 1;
    end if;
  end loop;

  if p_borrar_pagos then
    select coalesce(array_agg(g), '{}') into v_gids from (
      select f.gasto_id as g where f.gasto_id is not null
      union select gasto_id from abonos_factura where factura_id = p_id and gasto_id is not null) x;
    if exists (select 1 from caja_movimientos where gasto_id = any(v_gids)) then
      raise exception 'Un pago de esta factura salió de la caja (retiro de efectivo). Anúlalo desde Caja antes de eliminar la factura';
    end if;
  end if;

  delete from factura_compra_items where factura_id = p_id;
  delete from facturas_compra where id = p_id;
  if p_borrar_pagos and coalesce(array_length(v_gids, 1), 0) > 0 then
    delete from gastos where id = any(v_gids);
    get diagnostics v_g = row_count;
  end if;
  return jsonb_build_object('factura', p_id, 'productos_revertidos', v_n, 'pagos_borrados', v_g);
end $$;
revoke all on function public.eliminar_factura_compra(bigint, text, boolean) from public;
grant execute on function public.eliminar_factura_compra(bigint, text, boolean) to pq_admin;

notify pgrst, 'reload schema';
commit;
