-- ══════════════════════════════════════════════════════════════════
--  031 — Abonos a facturas de proveedores (pagos parciales)
--
--  Cada abono es un gasto (categoría mercadería) por ese monto, desde la
--  cuenta elegida y con su fecha: la plata sale de la cuenta cuando se
--  abona, no antes. facturas_compra.pagado = suma de abonos; cuando llega
--  al total la factura queda "pagada".
--  Facturas pagadas antes de esto (un solo gasto por el total) quedan igual.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════
begin;

create table if not exists abonos_factura (
  id             bigserial primary key,
  factura_id     bigint not null references facturas_compra(id) on delete cascade,
  fecha          date not null default (now() at time zone 'America/Santiago')::date,
  monto          numeric not null check (monto > 0),
  cuenta         text not null default 'bancoestado',
  gasto_id       bigint references gastos(id) on delete set null,
  notas          text,
  registrado_por text,
  created_at     timestamptz default now()
);
create index if not exists abonos_factura_factura_idx on abonos_factura(factura_id);
alter table abonos_factura enable row level security;
drop policy if exists "pq_admin abonos" on abonos_factura;
create policy "pq_admin abonos" on abonos_factura for all to pq_admin using (true) with check (true);
grant select, insert, update, delete on abonos_factura to pq_admin;
grant usage, select on sequence abonos_factura_id_seq to pq_admin;

alter table facturas_compra add column if not exists pagado numeric not null default 0;
update facturas_compra set pagado = total where estado_pago = 'pagada' and pagado = 0;

-- Registra un abono (lo usan el panel y el agente). Devuelve el estado de la factura.
create or replace function private.registrar_abono(p_id bigint, p_monto numeric, p_cuenta text, p_fecha date, p_usuario text, p_notas text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare f record; v_gid bigint; v_pagado numeric; v_saldo numeric; v_fecha date; v_n int;
begin
  if p_cuenta not in ('efectivo','bancoestado','mercadopago') then raise exception 'Cuenta inválida'; end if;
  select * into f from facturas_compra where id = p_id for update;
  if not found then raise exception 'La factura % no existe', p_id; end if;
  if f.estado_pago = 'pagada' then raise exception 'Esta factura ya está pagada'; end if;
  v_saldo := f.total - coalesce(f.pagado, 0);
  if p_monto is null or p_monto <= 0 then raise exception 'Escribe el monto del abono'; end if;
  if p_monto > v_saldo + 0.5 then raise exception 'El abono (%) es mayor que lo que se debe (%)', private.clp(p_monto), private.clp(v_saldo); end if;
  v_fecha := coalesce(p_fecha, (now() at time zone 'America/Santiago')::date);
  select count(*) + 1 into v_n from abonos_factura where factura_id = p_id;
  insert into gastos (fecha, descripcion, categoria, monto, cuenta, notas)
  values (v_fecha,
          case when p_monto >= v_saldo - 0.5 and v_n = 1 then 'Factura de compra ' else 'Abono ' || v_n || ' factura de compra ' end
            || coalesce('#' || f.numero_factura, '#' || f.id) || ' — ' || coalesce(f.proveedor_nombre, ''),
          'mercaderia', p_monto, p_cuenta,
          coalesce(nullif(btrim(p_notas), '') || ' · ', '') || 'Abono a la factura de compra #' || f.id)
  returning id into v_gid;
  insert into abonos_factura (factura_id, fecha, monto, cuenta, gasto_id, notas, registrado_por)
  values (p_id, v_fecha, p_monto, p_cuenta, v_gid, nullif(btrim(p_notas), ''), p_usuario);
  v_pagado := coalesce(f.pagado, 0) + p_monto;
  update facturas_compra set pagado = v_pagado,
         estado_pago = case when v_pagado >= total - 0.5 then 'pagada' else 'pendiente' end
   where id = p_id;
  return jsonb_build_object('factura_id', p_id, 'abonado', v_pagado, 'saldo', greatest(f.total - v_pagado, 0),
                            'estado_pago', case when v_pagado >= f.total - 0.5 then 'pagada' else 'pendiente' end);
end $$;
revoke all on function private.registrar_abono(bigint, numeric, text, date, text, text) from public;

create or replace function public.abonar_factura(p_id bigint, p_monto numeric, p_cuenta text default 'bancoestado',
                                                 p_fecha date default null, p_usuario text default null, p_notas text default null)
returns jsonb language sql security definer set search_path = public, private, pg_temp as $$
  select private.registrar_abono(p_id, p_monto, p_cuenta, p_fecha, p_usuario, p_notas)
$$;
revoke all on function public.abonar_factura(bigint, numeric, text, date, text, text) from public;
grant execute on function public.abonar_factura(bigint, numeric, text, date, text, text) to pq_admin;

-- Quitar un abono mal ingresado: borra su gasto y la factura vuelve a deber ese monto
create or replace function public.eliminar_abono_factura(p_abono bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare a record; v_pagado numeric;
begin
  select * into a from abonos_factura where id = p_abono for update;
  if not found then raise exception 'El abono no existe'; end if;
  if a.gasto_id is not null and exists (select 1 from caja_movimientos where gasto_id = a.gasto_id) then
    raise exception 'Este abono salió de la caja (retiro de efectivo): anúlalo desde Caja';
  end if;
  delete from abonos_factura where id = p_abono;
  if a.gasto_id is not null then delete from gastos where id = a.gasto_id; end if;
  select coalesce(sum(monto), 0) into v_pagado from abonos_factura where factura_id = a.factura_id;
  update facturas_compra set pagado = v_pagado,
         estado_pago = case when v_pagado >= total - 0.5 and v_pagado > 0 then 'pagada' else 'pendiente' end
   where id = a.factura_id;
  return jsonb_build_object('factura_id', a.factura_id, 'abonado', v_pagado);
end $$;
revoke all on function public.eliminar_abono_factura(bigint) from public;
grant execute on function public.eliminar_abono_factura(bigint) to pq_admin;

-- Editar factura: con abonos, el estado sale de los abonos
create or replace function public.editar_factura_compra(p_id bigint, p jsonb, p_usuario text default null)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  f record; prov record; it jsonb; r record;
  v_fecha date; v_num text; v_total numeric; v_suma numeric := 0; v_ajustes int := 0;
  v_nom text; v_cant numeric; v_costo numeric;
  v_ultima boolean; v_estado text; v_cuenta text; v_gid bigint; v_abonado numeric;
begin
  select * into f from facturas_compra where id = p_id for update;
  if not found then raise exception 'La factura % no existe', p_id; end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'La factura no tiene productos'; end if;
  if jsonb_array_length(p->'items') > 200 then raise exception 'Demasiadas líneas'; end if;

  select id, nombre into prov from proveedores where id = nullif(p->>'proveedor_id', '')::bigint;
  if not found then raise exception 'Elige un proveedor'; end if;
  v_fecha := coalesce(nullif(p->>'fecha', '')::date, f.fecha);
  v_num   := nullif(btrim(coalesce(p->>'numero', '')), '');

  -- lo nuevo, validado
  for it in select * from jsonb_array_elements(p->'items') loop
    select nombre into v_nom from productos where id = (it->>'producto_id')::bigint;
    if not found then raise exception 'Producto % no existe', it->>'producto_id'; end if;
    v_cant  := (it->>'cantidad')::numeric;
    v_costo := (it->>'costo_unitario')::numeric;
    if v_cant is null or v_cant <= 0 then raise exception 'Cantidad inválida en "%"', v_nom; end if;
    if v_costo is null or v_costo < 0 then raise exception 'Costo inválido en "%"', v_nom; end if;
    v_suma := v_suma + round(v_cant * v_costo);
  end loop;
  v_total := coalesce(nullif(p->>'total', '')::numeric, v_suma);

  -- stock: diferencia por producto (viejo → nuevo)
  for r in
    select coalesce(o.producto_id, n.producto_id) as producto_id, coalesce(n.cant, 0) - coalesce(o.cant, 0) as delta
      from (select producto_id, sum(cantidad) cant from factura_compra_items where factura_id = p_id and producto_id is not null group by 1) o
      full join (select producto_id, sum(cantidad) cant from jsonb_to_recordset(p->'items') as x(producto_id bigint, cantidad numeric) group by 1) n
             on n.producto_id = o.producto_id
  loop
    if r.delta <> 0 then
      perform public.mover_stock(r.producto_id, r.delta, case when r.delta > 0 then 'entrada' else 'salida' end,
        'Corrección factura de compra ' || coalesce('N° ' || v_num, '#' || p_id) || ' · ' || prov.nombre,
        'compra', p_id, p_usuario, null);
      v_ajustes := v_ajustes + 1;
    end if;
  end loop;

  -- costo: solo si esta es la última factura que trae el producto
  for r in select distinct on ((e->>'producto_id')::bigint) (e->>'producto_id')::bigint as producto_id, (e->>'costo_unitario')::numeric as costo
             from jsonb_array_elements(p->'items') with ordinality as t(e, linea)
            order by (e->>'producto_id')::bigint, linea desc loop
    select not exists (select 1 from factura_compra_items i where i.producto_id = r.producto_id and i.factura_id > p_id) into v_ultima;
    if v_ultima then update productos set costo = r.costo, updated_at = now() where id = r.producto_id and costo is distinct from r.costo; end if;
  end loop;

  delete from factura_compra_items where factura_id = p_id;
  insert into factura_compra_items (factura_id, producto_id, producto_nombre, cantidad, costo_unitario, subtotal)
  select p_id, (t.e->>'producto_id')::bigint, pr.nombre, (t.e->>'cantidad')::numeric, (t.e->>'costo_unitario')::numeric,
         round((t.e->>'cantidad')::numeric * (t.e->>'costo_unitario')::numeric)
    from jsonb_array_elements(p->'items') with ordinality as t(e, linea)
    join productos pr on pr.id = (t.e->>'producto_id')::bigint
   order by t.linea;

  -- con abonos el estado lo deciden los abonos (no se crea ni borra un gasto por el total)
  select coalesce(sum(monto), 0) into v_abonado from abonos_factura where factura_id = p_id;
  if v_abonado > 0 then
    update facturas_compra set proveedor_id = prov.id, proveedor_nombre = prov.nombre, numero_factura = v_num, fecha = v_fecha, total = v_total,
           pagado = v_abonado, estado_pago = case when v_abonado >= v_total - 0.5 then 'pagada' else 'pendiente' end
     where id = p_id;
    return jsonb_build_object('factura_id', p_id, 'total', v_total, 'productos_con_stock_ajustado', v_ajustes,
                              'estado_pago', case when v_abonado >= v_total - 0.5 then 'pagada' else 'pendiente' end,
                              'abonado', v_abonado, 'saldo', greatest(v_total - v_abonado, 0));
  end if;

  -- pago: estado y cuenta
  v_estado := coalesce(nullif(p->>'estado_pago', ''), f.estado_pago);
  if v_estado not in ('pendiente','pagada') then raise exception 'Estado de pago inválido'; end if;
  v_gid := f.gasto_id;
  if v_estado = 'pagada' then
    v_cuenta := nullif(p->>'cuenta', '');
    if v_cuenta is null and v_gid is not null then select cuenta into v_cuenta from gastos where id = v_gid; end if;
    v_cuenta := coalesce(v_cuenta, 'bancoestado');
    if v_cuenta not in ('efectivo','bancoestado','mercadopago') then raise exception 'Cuenta inválida'; end if;
    if v_gid is null then
      insert into gastos (fecha, descripcion, categoria, monto, cuenta, notas)
      values (v_fecha, 'Factura de compra ' || coalesce('#' || v_num, '#' || p_id) || ' — ' || prov.nombre,
              'mercaderia', v_total, v_cuenta, 'Generado al marcar pagada la factura de compra #' || p_id)
      returning id into v_gid;
    else
      update gastos set monto = v_total, fecha = v_fecha, cuenta = v_cuenta,
             descripcion = 'Factura de compra ' || coalesce('#' || v_num, '#' || p_id) || ' — ' || prov.nombre
       where id = v_gid;
    end if;
  elsif v_gid is not null then
    if exists (select 1 from caja_movimientos where gasto_id = v_gid) then
      raise exception 'Este pago salió de la caja (retiro de efectivo). Anúlalo desde Caja antes de pasar la factura a pendiente';
    end if;
    delete from gastos where id = v_gid;   -- facturas_compra.gasto_id queda en null
    v_gid := null;
  end if;

  update facturas_compra set proveedor_id = prov.id, proveedor_nombre = prov.nombre, numero_factura = v_num, fecha = v_fecha, total = v_total,
         estado_pago = v_estado, gasto_id = v_gid, pagado = case when v_estado = 'pagada' then v_total else 0 end
   where id = p_id;
  return jsonb_build_object('factura_id', p_id, 'total', v_total, 'productos_con_stock_ajustado', v_ajustes,
                            'estado_pago', v_estado, 'cuenta', v_cuenta);
end $$;
revoke all on function public.editar_factura_compra(bigint, jsonb, text) from public;
grant execute on function public.editar_factura_compra(bigint, jsonb, text) to pq_admin;

-- Agente (Hermes): "pagar" = abonar lo que falta; por pagar = saldo
create or replace function public.agente_factura_pagar(p_factura bigint, p_cuenta text default 'bancoestado')
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare f record; r jsonb;
begin
  select * into f from facturas_compra where id = p_factura;
  if not found then raise exception 'Factura % no existe', p_factura; end if;
  r := private.registrar_abono(p_factura, f.total - coalesce(f.pagado, 0), coalesce(p_cuenta, 'bancoestado'), null, 'agente', 'Pagada por el agente');
  perform private.agente_log('Factura de compra pagada', 'proveedores', 'Factura #' || f.id);
  return r;
end $$;
create or replace function public.agente_facturas_por_pagar()
returns jsonb language sql security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object(
    'total_por_pagar', coalesce(sum(total - pagado), 0),
    'facturas', coalesce(jsonb_agg(jsonb_build_object('id', id, 'proveedor', proveedor_nombre, 'numero', numero_factura, 'fecha', fecha,
                                                      'total', total, 'abonado', pagado, 'saldo', total - pagado) order by fecha), '[]'::jsonb))
  from facturas_compra where estado_pago = 'pendiente'
$$;
revoke all on function public.agente_factura_pagar(bigint, text) from public;
revoke all on function public.agente_facturas_por_pagar() from public;
grant execute on function public.agente_factura_pagar(bigint, text) to pq_agente;
grant execute on function public.agente_facturas_por_pagar() to pq_agente;

notify pgrst, 'reload schema';
commit;
