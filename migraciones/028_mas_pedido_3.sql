-- 028: "Lo más pedido" de la tienda web muestra 3 productos, elegidos en el panel
-- (Productos → Más pedido web). Se quitan las posiciones 4 a 6 que hubiera.
update productos set destacado_web = null where destacado_web > 3;
