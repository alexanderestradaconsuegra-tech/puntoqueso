-- ══════════════════════════════════════════════════════════════════
--  039 — La tienda revisa el stock del carrito antes de seguir
--
--  La tienda solo sabía "agotado / últimas unidades" al abrir la página. Si
--  alguien dejaba la página abierta, o pedía más de lo que queda, el pedido
--  recién se rechazaba al enviarlo.
--  stock_carrito_web(items) devuelve, SOLO de los productos que pide el
--  cliente, cuánto queda disponible (stock − lo ya apartado por otros
--  pedidos, tope 100) y si está agotado. La tienda lo usa al abrir el carrito
--  y al continuar al pago para quitar lo agotado y bajar lo que excede.
--  Respeta el interruptor web_control_stock. Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

create or replace function public.stock_carrito_web(p_items jsonb)
returns table (id bigint, disp numeric, agotado boolean)
language sql stable security definer set search_path = public, private as $$
  with ctrl as (
    select coalesce(lower(private.cfg_txt('web_control_stock')), 'true') not in ('false','0','no') as on_
  ), ids as (
    select distinct (e->>'producto_id')::bigint as pid
      from jsonb_array_elements(case when jsonb_typeof(coalesce(p_items, '[]'::jsonb)) = 'array' then p_items else '[]'::jsonb end) e
     where e->>'producto_id' ~ '^[0-9]+$'
     limit 60
  )
  select p.id,
         case when (select on_ from ctrl) then least(greatest(coalesce(p.stock, 0) - private.reservado(p.id), 0), 100) else 100 end,
         (select on_ from ctrl) and (coalesce(p.stock, 0) - private.reservado(p.id)) < (case when p.vender_por_peso then 0.1 else 1 end)
    from productos p join ids on ids.pid = p.id
   where p.activo and p.en_catalogo
$$;
revoke all on function public.stock_carrito_web(jsonb) from public;
grant execute on function public.stock_carrito_web(jsonb) to web_anon, pq_admin;

notify pgrst, 'reload schema';
commit;
