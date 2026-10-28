-- Arma el texto de la lista de precios por mayor para pegar en WhatsApp (SOLO LEE, no cambia nada).
-- Toma los productos activos que tienen "Precio mayorista" en su ficha, ordenados por categoría y nombre.
-- Uso: curl -fsSL <url de este archivo> | docker exec -i postgresql-tnhz-postgresql-1 psql -U <usuario> -d <base> -At
select '*LISTA DE PRECIOS POR MAYOR*' || E'\n' || '🧀 Punto Queso · Quesos venezolanos' || E'\n' ||
       coalesce((
         select string_agg(
                  case when rn = 1 then E'\n*' || upper(coalesce(nullif(categoria, ''), 'Otros')) || '*' || E'\n' else '' end
                  || '• ' || nombre || ' — $' || replace(to_char(precio_mayor, 'FM999,999,999'), ',', '.')
                  || ' ' || case when coalesce(unidad, 'kg') in ('kg', 'Kg', 'KG') then 'x kg' else 'c/u' end,
                  E'\n' order by categoria, nombre)
           from (select *, row_number() over (partition by categoria order by nombre) rn
                   from productos
                  where activo and precio_mayor > 0 and nombre not ilike '%delivery%') t
       ), '(ningún producto activo tiene precio mayorista: cárgalo en la ficha del producto)')
       || E'\n\n' || 'Pedidos por mayor: escríbenos con la cantidad que necesitas, tu comuna y cada cuánto compras, y coordinamos la entrega.' || E'\n' ||
       '📍 Arturo Prat 2045, Santiago';
