-- ══════════════════════════════════════════════════════════════════
--  006 — Categorías de productos ordenadas (sin repetidas)
--
--  Quedaban categorías viejas en minúscula (queso, fiambre, otros) junto
--  a las oficiales del panel (Quesos, Jamones, Embutidos, Congelados,
--  Bebidas, Golosinas, Otros), y se veían repetidas en filtros y catálogo.
--    queso    → Quesos
--    fiambre  → Jamones si el nombre dice "jamón", si no Embutidos
--    otros    → Otros
--    cualquier otra que coincida con una oficial sin importar mayúsculas
--    o el plural (bebida, BEBIDAS) → la oficial
--    el resto → primera letra en mayúscula
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

alter table productos alter column categoria set default 'Otros';

-- Espacios sobrantes y vacías
update productos set categoria = btrim(categoria) where categoria <> btrim(categoria);
update productos set categoria = 'Otros' where categoria is null or categoria = '';

-- fiambre: se separa por el nombre, igual que el importador del panel
update productos set categoria = case
    when lower(nombre) ~ 'jam[oó]n' and lower(nombre) !~ 'jamonada|mortadela' then 'Jamones'
    else 'Embutidos' end
  where lower(categoria) in ('fiambre', 'fiambres');

-- Oficiales, sin importar mayúsculas ni singular/plural
update productos p set categoria = o.nombre
  from (values ('Quesos'),('Jamones'),('Embutidos'),('Congelados'),('Bebidas'),('Golosinas'),('Otros')) as o(nombre)
 where p.categoria <> o.nombre
   and lower(o.nombre) in (lower(p.categoria), lower(p.categoria) || 's', lower(p.categoria) || 'es');

-- Resto: primera letra en mayúscula
update productos set categoria = upper(left(categoria, 1)) || substr(categoria, 2)
  where left(categoria, 1) <> upper(left(categoria, 1));

commit;

-- Resultado: cuántos productos quedan en cada categoría
select categoria, count(*) as productos from productos where activo group by categoria order by categoria;
