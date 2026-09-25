-- ══════════════════════════════════════════════════════════════════
--  SOLO PARA EMERGENCIAS: deshace 001_auth_jwt.sql y vuelve a dejar la
--  API abierta como estaba antes (web_anon con acceso total).
--  Úsalo solo si el login con token falla en producción y necesitas
--  operar mientras se arregla; junto con esto hay que volver a publicar
--  el panel y el catálogo del commit anterior a la migración.
-- ══════════════════════════════════════════════════════════════════
begin;
do $$
declare t text;
begin
  for t in select unnest(array[
    'productos','clientes','ventas','venta_items','pedidos','pedido_items',
    'gastos','stock_movimientos','config','auditlog',
    'proveedores','facturas_compra','factura_compra_items','cierres_caja',
    'gastos_recurrentes'
  ]) loop
    execute format('grant select, insert, update, delete on %I to web_anon', t);
    execute format('drop policy if exists "web_anon acceso total" on %I', t);
    execute format('create policy "web_anon acceso total" on %I for all to web_anon using (true) with check (true)', t);
  end loop;
end $$;
grant usage, select on all sequences in schema public to web_anon;
grant select (id, usuario, nombre, rol, activo, permisos) on usuarios to web_anon;
grant update (nombre, rol, activo, permisos) on usuarios to web_anon;
grant insert (usuario, nombre, rol, activo, permisos, password_hash) on usuarios to web_anon;
drop policy if exists "web_anon lectura basica" on usuarios;
create policy "web_anon lectura basica" on usuarios for all to web_anon using (true) with check (true);
grant execute on function verificar_login(text, text), verificar_pin(bigint, text),
  set_pin_hash(bigint, text), set_password_hash(bigint, text) to web_anon;
notify pgrst, 'reload schema';
commit;
