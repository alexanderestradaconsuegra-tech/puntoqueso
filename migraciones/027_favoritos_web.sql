-- 027: la tienda web muestra en "Lo más pedido" los ★ favoritos del sistema
-- (los mismos de la Terminal). Solo se expone la marca, no el stock.
grant select (favorito) on productos to web_anon;
