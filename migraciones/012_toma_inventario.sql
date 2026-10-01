-- ══════════════════════════════════════════════════════════════════
--  012 — Toma de inventario
--
--  Cargar el inventario contado de una sola vez (inventario inicial o
--  conteo mensual): fija el stock y el costo de cada producto contado y,
--  si se pide, deja en 0 los que no se contaron. NO es una compra: no
--  genera gasto ni mueve las cuentas (esa mercadería ya está pagada).
--  Cada cambio queda en stock_movimientos (tipo 'ajuste') y la toma
--  completa en tomas_inventario, con su detalle y valor total.
--  Todo ocurre en una sola transacción: o se aplica completa o nada.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

create table if not exists tomas_inventario (
  id             bigserial primary key,
  fecha          timestamptz default now(),
  registrado_por text,
  productos      int,
  valor_costo    numeric,
  valor_venta    numeric,
  cero_resto     boolean not null default false,
  puestos_en_cero int,
  notas          text,
  detalle        jsonb
);
alter table tomas_inventario enable row level security;
drop policy if exists "pq_admin acceso total" on tomas_inventario;
create policy "pq_admin acceso total" on tomas_inventario for all to pq_admin using (true) with check (true);
grant select, insert, update, delete on tomas_inventario to pq_admin;
grant usage, select on all sequences in schema public to pq_admin;

-- p_items: [{producto_id, cantidad, costo}]  (costo vacío = se mantiene el actual)
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
      insert into stock_movimientos (producto_id, tipo, cantidad, motivo, origen, referencia_id, registrado_por)
      values (prod.id, 'ajuste', v_cant - v_antes, 'Toma de inventario #' || v_id, 'ajuste', v_id, p_usuario);
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
      insert into stock_movimientos (producto_id, tipo, cantidad, motivo, origen, referencia_id, registrado_por)
      values (prod.id, 'ajuste', -prod.stock, 'Toma de inventario #' || v_id || ' (no contado: queda en 0)', 'ajuste', v_id, p_usuario);
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
