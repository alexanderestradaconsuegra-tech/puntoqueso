-- ══════════════════════════════════════════════════════════════════
--  007 — Orden de los productos a elección del dueño
--
--  productos.orden: 1 sale primero, 2 segundo… null = después de los
--  ordenados, por nombre. Se usa en la Terminal y en la tienda web
--  (dentro de cada categoría y en Destacados).
--  mover_producto(id, pos): pone el producto en esa posición y corre a
--  los demás (como insertar en una lista), dejando 1, 2, 3… sin huecos.
--  pos vacío o 0 = quitarle la posición.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

alter table productos add column if not exists orden int;

-- El catálogo público necesita leer el orden (solo eso, nada interno)
grant select (orden) on productos to web_anon;

create or replace function public.mover_producto(p_id bigint, p_pos int)
returns void
language plpgsql security invoker set search_path = public as $$
declare ids bigint[];
begin
  if not exists (select 1 from productos where id = p_id and activo) then
    raise exception 'Producto no encontrado';
  end if;
  -- los eliminados no ocupan posición
  update productos set orden = null where not activo and orden is not null;

  select coalesce(array_agg(id order by orden, nombre, id), '{}'::bigint[]) into ids
    from productos where orden is not null and activo and id <> p_id;

  if p_pos is not null and p_pos > 0 then
    p_pos := least(p_pos, coalesce(array_length(ids, 1), 0) + 1);
    ids := ids[1:p_pos - 1] || p_id || ids[p_pos:];
  else
    update productos set orden = null where id = p_id;
  end if;

  update productos p set orden = x.n
    from unnest(ids) with ordinality as x(id, n)
   where p.id = x.id and p.orden is distinct from x.n;
end $$;
revoke all on function public.mover_producto(bigint, int) from public;
grant execute on function public.mover_producto(bigint, int) to pq_admin;

commit;
