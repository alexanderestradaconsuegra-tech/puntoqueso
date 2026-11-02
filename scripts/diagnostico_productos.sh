#!/bin/bash
# Revisa por qué el panel no carga los productos (SOLO LEE, no cambia nada ni muestra claves).
# Uso:  PGU=<usuario_db> PGD=<base_db> bash diagnostico_productos.sh
C=postgresql-tnhz-postgresql-1
PSQL=${PSQL:-docker exec -i $C psql -U $PGU -d $PGD}
PANEL=${PANEL:-https://puntoqueso.autix.pro/}
echo "== 1) Columnas que pide el panel y que NO existen en la tabla productos (debe quedar vacío)"
COLS=$(curl -s -m20 "$PANEL" | grep -o "const PRODUCTO_COLS='[^']*'" | head -1 | sed "s/const PRODUCTO_COLS='//; s/'$//")
[ -n "$COLS" ] || { echo "No pude leer la lista de columnas del panel en $PANEL"; exit 1; }
LISTA=$(echo "$COLS" | tr ',' '\n' | sed "s/.*/'&'/" | paste -sd, -)
$PSQL -At -c "select c from unnest(array[$LISTA]) c where c not in (select column_name from information_schema.columns where table_schema='public' and table_name='productos');"
echo "(fin de la lista)"
echo
echo "== 2) La consulta exacta del panel, ejecutada como lo hace el usuario con sesión (pq_admin)"
$PSQL -At <<SQL
begin;
set local role pq_admin;
select 'filas visibles: '||count(*) from productos where activo = true;
select 'consulta completa OK, filas: '||count(*) from (select $COLS from productos where activo = true order by nombre) t;
rollback;
SQL
echo
echo "== 3) Tamaño de la respuesta (si pasa de unos pocos MB, el celular tarda o falla)"
$PSQL -At -c "select 'productos activos: '||count(*)||' · tamaño de los datos sin fotos: '||pg_size_pretty(coalesce(sum(length((to_jsonb(p) - 'imagen_b64' - 'pieza_imagen_b64')::text)),0)::bigint) from productos p where activo = true;"
echo
echo "== 4) Versión del panel que sirve el servidor"
curl -s -m15 "${PANEL%/}/sw.js" | grep -m1 "CACHE_NAME ="
curl -s -m20 "$PANEL" | grep -c "bannerCarga" | sed 's/^/líneas con el aviso nuevo de carga: /'
