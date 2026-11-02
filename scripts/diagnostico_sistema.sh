#!/bin/bash
# Diagnóstico general del sistema (SOLO LEE, no cambia nada ni muestra claves).
# Uso:  PGU=<usuario_db> PGD=<base_db> bash diagnostico_sistema.sh
C=postgresql-tnhz-postgresql-1
API=https://api-puntoqueso.autix.pro
echo "== 1) Contenedores (todos deben decir Up)"
docker ps -a --format '{{.Names}}  {{.Status}}' | grep -i -E "puntoqueso|postgres|traefik|quesosvenezolanos|evolution" || echo "(no se ven)"
echo
echo "== 2) Ultimas lineas del log de PostgREST (errores aqui explican una pantalla vacia)"
docker logs --tail 15 puntoqueso-postgrest 2>&1 | cut -c1-200
echo
echo "== 3) La API responde? (productos activos, como lo ve el catalogo)"
curl -s -m15 -o /tmp/dq_api.json -w "HTTP %{http_code}  tiempo %{time_total}s  tamaño %{size_download} bytes\n" "$API/productos?select=id&activo=eq.true&limit=1"
head -c 200 /tmp/dq_api.json; echo
echo
echo "== 4) Los archivos del panel y su version"
for u in https://puntoqueso.autix.pro/sw.js https://puntoqueso.autix.pro/; do
  curl -s -m15 -o /tmp/dq_f -w "$u -> HTTP %{http_code}  %{size_download} bytes  %{time_total}s\n" "$u"
done
curl -s -m15 https://puntoqueso.autix.pro/sw.js | grep -m1 "CACHE_NAME ="
echo
if [ -n "$PGU" ] && [ -n "$PGD" ]; then
  echo "== 5) Base de datos"
  docker exec -i "$C" psql -U "$PGU" -d "$PGD" -At -c "select 'productos activos: '||count(*) from productos where activo; select 'tabla empleados existe: '||(to_regclass('public.empleados') is not null); select 'conexiones abiertas: '||count(*) from pg_stat_activity;"
fi
