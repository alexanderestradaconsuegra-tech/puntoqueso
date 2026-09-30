-- ══════════════════════════════════════════════════════════════════
--  005 — Catálogo web a elección y productos favoritos
--
--  productos.en_catalogo: el dueño elige qué se ve en la tienda web.
--    El filtro está en la base (policy de web_anon y crear_pedido_publico),
--    no solo en la pantalla: un producto oculto no se puede ver ni pedir
--    desde internet. Empieza en false para TODOS: el dueño marca los que
--    quiere mostrar.
--  productos.favorito: los que la Terminal muestra primero.
--  marcar_favoritos_mas_vendidos(): pone la estrella a los N productos
--    que salieron en más ventas (no anuladas) de los últimos N días.
--
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

alter table productos add column if not exists en_catalogo boolean not null default false;
alter table productos add column if not exists favorito    boolean not null default false;

-- ── Lo que ve el público: activos Y marcados para la web ──
drop policy if exists "web_anon catalogo" on productos;
create policy "web_anon catalogo" on productos for select to web_anon
  using (activo = true and en_catalogo = true);

-- ── Pedido público: solo productos visibles en la web ──
create or replace function public.crear_pedido_publico(
  p_cliente_nombre   text,
  p_cliente_tel      text,
  p_direccion_calle  text default null,
  p_direccion_depto  text default null,
  p_direccion_comuna text default null,
  p_notas            text default null,
  p_items            jsonb default '[]'::jsonb
) returns bigint
language plpgsql security definer set search_path = public, private as $$
declare
  v_id    bigint;
  v_total numeric := 0;
  v_cant  numeric;
  it      jsonb;
  prod    record;
begin
  if private.limpiar_texto(p_cliente_nombre, 80) is null then raise exception 'Ingresa tu nombre'; end if;
  if private.limpiar_texto(p_cliente_tel, 30) is null then raise exception 'Ingresa tu teléfono'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El pedido no tiene productos';
  end if;
  if jsonb_array_length(p_items) > 50 then raise exception 'Demasiados productos en un solo pedido'; end if;

  insert into pedidos (cliente_nombre, cliente_tel, direccion_calle, direccion_depto,
                       direccion_comuna, notas, total, estado)
  values (private.limpiar_texto(p_cliente_nombre, 80),   private.limpiar_texto(p_cliente_tel, 30),
          private.limpiar_texto(p_direccion_calle, 150), private.limpiar_texto(p_direccion_depto, 60),
          private.limpiar_texto(p_direccion_comuna, 80), private.limpiar_texto(p_notas, 500),
          0, 'pendiente')
  returning id into v_id;

  for it in select * from jsonb_array_elements(p_items) loop
    v_cant := (it->>'cantidad')::numeric;
    if v_cant is null or v_cant <= 0 or v_cant > 1000 then raise exception 'Cantidad inválida'; end if;
    select id, nombre, precio into prod
      from productos where id = (it->>'producto_id')::bigint and activo = true and en_catalogo = true;
    if not found then raise exception 'Un producto de tu pedido ya no está disponible'; end if;
    insert into pedido_items (pedido_id, producto_id, producto_nombre, cantidad, precio_unitario, subtotal)
    values (v_id, prod.id, prod.nombre, v_cant, prod.precio, prod.precio * v_cant);
    v_total := v_total + prod.precio * v_cant;
  end loop;

  update pedidos set total = v_total where id = v_id;
  return v_id;
end $$;
revoke all on function public.crear_pedido_publico(text, text, text, text, text, text, jsonb) from public;
grant execute on function public.crear_pedido_publico(text, text, text, text, text, text, jsonb) to web_anon, pq_admin;

-- ── Favoritos automáticos: los que salen en más ventas ──
-- Se cuenta en cuántas ventas aparece cada producto (no kilos ni pesos):
-- es lo que el cajero toca más seguido. Solo agrega estrellas, no quita.
-- Corre con los permisos de quien la llama (pq_admin) y respeta sus RLS.
create or replace function public.marcar_favoritos_mas_vendidos(p_limite int default 20, p_dias int default 30)
returns int
language plpgsql security invoker set search_path = public as $$
declare v_n int;
begin
  if p_limite is null or p_limite < 1 or p_limite > 100 then raise exception 'Límite inválido'; end if;
  if p_dias   is null or p_dias   < 1 or p_dias   > 365 then raise exception 'Período inválido'; end if;
  with top as (
    select vi.producto_id
      from venta_items vi
      join ventas v on v.id = vi.venta_id
      join productos p on p.id = vi.producto_id
     where v.anulada = false
       and p.activo = true
       and vi.created_at >= now() - make_interval(days => p_dias)
     group by vi.producto_id
     order by count(distinct vi.venta_id) desc, sum(vi.subtotal) desc
     limit p_limite
  )
  update productos set favorito = true
   where id in (select producto_id from top) and favorito = false;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.marcar_favoritos_mas_vendidos(int, int) from public;
grant execute on function public.marcar_favoritos_mas_vendidos(int, int) to pq_admin;

commit;
