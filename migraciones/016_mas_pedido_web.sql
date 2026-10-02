-- ══════════════════════════════════════════════════════════════════
--  016 — "Lo más pedido" de la tienda web, elegido a mano
--
--  Antes la tienda completaba esa sección con una regla automática
--  (quesos con foto y más caros) y se mezclaba con la estrella de la
--  Terminal. Ahora hay una marca propia: productos.destacado_web
--  (1 sale primero, 2 segundo… null = no está en "Lo más pedido").
--  Si no hay ninguno marcado, la tienda usa la regla automática.
--
--  Deja marcados, en este orden: llanero madurado, queso de mano y
--  queso trenza, solo si cada nombre coincide con UN producto activo
--  (si hay 0 o varios, avisa y no marca: se elige desde el panel).
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

alter table productos add column if not exists destacado_web int;
grant select (destacado_web) on productos to web_anon;

do $$
declare
  pats text[] := array['%llanero%madur%', '%de mano%', '%trenza%'];
  i int; n int; v_id bigint; v_nom text;
begin
  for i in 1 .. array_length(pats, 1) loop
    select count(*) into n from productos where activo and nombre ilike pats[i];
    if n = 1 then
      select id, nombre into v_id, v_nom from productos where activo and nombre ilike pats[i];
      update productos set destacado_web = i where id = v_id;
      raise notice 'Lo más pedido #%: % (id %)', i, v_nom, v_id;
      if not exists (select 1 from productos where id = v_id and en_catalogo) then
        raise notice '  AVISO: "%" no está visible en la web; actívalo en Productos para que aparezca', v_nom;
      end if;
    else
      raise notice 'Lo más pedido #%: hay % productos que coinciden con "%"; elígelo en el panel (Productos, columna Más pedido)', i, n, pats[i];
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
commit;
