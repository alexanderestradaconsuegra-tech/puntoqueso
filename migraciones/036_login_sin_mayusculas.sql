-- ══════════════════════════════════════════════════════════════════
--  036 — Login: el usuario no distingue mayúsculas ni espacios
--
--  Antes "Natalia" y "natalia" eran usuarios distintos: el teclado del
--  celular pone la primera letra en mayúscula y el sistema respondía
--  "contraseña incorrecta" aunque la clave estuviera bien. Ahora se
--  compara sin mayúsculas y sin espacios al borde. La contraseña sigue
--  siendo exacta. Si hubiera dos usuarios que solo difieren en mayúsculas,
--  gana el que coincide exacto.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;
create or replace function public.login(p_usuario text, p_password text) returns json
language plpgsql security definer set search_path = public, private as $$
declare u record;
begin
  select id, usuario, nombre, rol, permisos into u
    from usuarios
   where lower(usuario) = lower(btrim(p_usuario)) and activo = true
     and password_hash = crypt(p_password, password_hash)
   order by (usuario = btrim(p_usuario)) desc
   limit 1;
  if not found then return null; end if;
  return json_build_object(
    'token', private.firmar_jwt(json_build_object(
      'role', 'pq_admin', 'usuario', u.usuario, 'uid', u.id,
      'exp', extract(epoch from now() + interval '7 days')::bigint)),
    'usuario', json_build_object(
      'id', u.id, 'usuario', u.usuario, 'nombre', u.nombre, 'rol', u.rol,
      'permisos', coalesce(u.permisos, '{}'::jsonb)));
end $$;
revoke all on function public.login(text, text) from public;
grant execute on function public.login(text, text) to web_anon, pq_admin;
notify pgrst, 'reload schema';
commit;
