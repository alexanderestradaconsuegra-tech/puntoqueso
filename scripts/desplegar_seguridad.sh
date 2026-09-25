#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
#  Despliega la autenticación real (JWT) de Punto Queso en el VPS.
#
#  Uso:   bash desplegar_seguridad.sh <commit>
#  (el <commit> fija la versión exacta de cada archivo que se descarga,
#   así la caché de GitHub nunca puede mezclar versiones viejas y nuevas)
#
#  Es seguro correrlo de nuevo: reutiliza el secreto si ya existe, la
#  migración es idempotente y el resto solo reemplaza archivos.
#  Si cualquier paso falla, se detiene ahí mismo y dice cuál.
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

REF="${1:?Falta el commit. Uso: bash desplegar_seguridad.sh <commit>}"
RAW="https://raw.githubusercontent.com/alexanderestradaconsuegra-tech/puntoqueso/$REF"
API="https://api-puntoqueso.autix.pro"
PG_CONT="postgresql-tnhz-postgresql-1"
PGRST_CONT="puntoqueso-postgrest"
SECRETOS_DIR="/root/puntoqueso-secretos"
CRON_DIR="/root/puntoqueso-cron"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

paso(){ echo; echo "── $* ──"; }
bajar(){ curl -fsSL "$RAW/$1" -o "$2"; }

paso "1/7 Descargando archivos del commit $REF"
bajar schema.sql                          "$TMP/schema.sql"
bajar migraciones/001_auth_jwt.sql        "$TMP/001_auth_jwt.sql"
bajar migraciones/002_anular_ventas.sql   "$TMP/002_anular_ventas.sql"
bajar puntoqueso-os.html                  "$TMP/admin.html"
bajar catalogo.html                       "$TMP/catalogo.html"
bajar scripts/gastos_recurrentes_cron.py  "$TMP/cron.py"
grep -q "rpc('login'" "$TMP/admin.html" || { echo "❌ El panel descargado no es la versión con login por token"; exit 1; }
python3 -c "from zoneinfo import ZoneInfo; ZoneInfo('America/Santiago')" \
  || { echo "❌ Falta la zona horaria en Python (instala: apt install tzdata)"; exit 1; }
echo "ok"

paso "2/7 Secreto de firma (se guarda solo en $SECRETOS_DIR, fuera de las carpetas públicas)"
mkdir -p "$SECRETOS_DIR" && chmod 700 "$SECRETOS_DIR"
if [ ! -s "$SECRETOS_DIR/jwt_secret" ]; then
  ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$SECRETOS_DIR/jwt_secret" )
  echo "secreto nuevo generado"
else
  echo "reutilizando el secreto existente"
fi
JWT_SECRET="$(cat "$SECRETOS_DIR/jwt_secret")"

PG_USER="$(docker exec "$PG_CONT" printenv POSTGRES_USER)"
PG_DB="$(docker exec "$PG_CONT" printenv POSTGRES_DB)"
DB_URI="$(docker inspect "$PGRST_CONT" --format '{{range .Config.Env}}{{println .}}{{end}}' | { grep '^PGRST_DB_URI=' || true; } | head -1 | cut -d= -f2-)"
[ -n "$DB_URI" ] || { echo "❌ No pude leer la conexión actual de PostgREST"; exit 1; }

paso "3/7 Base de datos: columnas nuevas, seguridad y anulaciones"
docker exec -i "$PG_CONT" psql -U "$PG_USER" -d "$PG_DB" -q -v ON_ERROR_STOP=1 < "$TMP/schema.sql"
docker exec -i "$PG_CONT" psql -U "$PG_USER" -d "$PG_DB" -q -v ON_ERROR_STOP=1 \
  -v "jwt_secret=$JWT_SECRET" < "$TMP/001_auth_jwt.sql"
docker exec -i "$PG_CONT" psql -U "$PG_USER" -d "$PG_DB" -q -v ON_ERROR_STOP=1 < "$TMP/002_anular_ventas.sql"
echo "ok"

paso "4/7 Reiniciando PostgREST con el secreto de firma"
docker stop "$PGRST_CONT" >/dev/null && docker rm "$PGRST_CONT" >/dev/null
docker run -d \
  --name "$PGRST_CONT" \
  --network postgresql-tnhz_default \
  --restart unless-stopped \
  -e PGRST_DB_URI="$DB_URI" \
  -e PGRST_DB_SCHEMA=public \
  -e PGRST_DB_ANON_ROLE=web_anon \
  -e PGRST_SERVER_PORT=3000 \
  -e PGRST_JWT_SECRET="$JWT_SECRET" \
  -l "traefik.enable=true" \
  -l "traefik.http.routers.puntoqueso-api.entrypoints=websecure" \
  -l "traefik.http.routers.puntoqueso-api.rule=Host(\`api-puntoqueso.autix.pro\`)" \
  -l "traefik.http.routers.puntoqueso-api.tls.certresolver=letsencrypt" \
  -l "traefik.http.services.puntoqueso-api.loadbalancer.server.port=3000" \
  postgrest/postgrest >/dev/null
docker network connect bridge "$PGRST_CONT" 2>/dev/null || true
code=000
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$API/productos?select=id&limit=1" || true)"
  [ "$code" = "200" ] && break
  sleep 2
done
[ "$code" = "200" ] || { echo "❌ La API no volvió a responder (último código: $code). Revisa: docker logs $PGRST_CONT"; exit 1; }
echo "ok, API respondiendo"

paso "5/7 Publicando panel y catálogo nuevos"
mv "$TMP/admin.html"    /root/puntoqueso-app/index.html
mv "$TMP/catalogo.html" /root/puntoqueso-catalogo/index.html
chmod 644 /root/puntoqueso-app/index.html /root/puntoqueso-catalogo/index.html
# copias viejas que quedaron en la carpeta pública del panel (se podían descargar desde internet)
rm -f /root/puntoqueso-app/gastos_recurrentes_cron.py /root/puntoqueso-app/gastos_recurrentes_cron.log \
      /root/puntoqueso-app/puntoqueso-os.html /root/puntoqueso-app/catalogo.html
echo "ok"

paso "6/7 Gastos recurrentes automáticos (carpeta privada $CRON_DIR)"
mkdir -p "$CRON_DIR" && chmod 700 "$CRON_DIR"
mv "$TMP/cron.py" "$CRON_DIR/gastos_recurrentes_cron.py"
CRON_TOKEN="$(docker exec "$PG_CONT" psql -U "$PG_USER" -d "$PG_DB" -tA -c \
  "select private.firmar_jwt(json_build_object('role','pq_admin','usuario','cron','exp',extract(epoch from now()+interval '5 years')::bigint))")"
( umask 077; printf '%s' "$CRON_TOKEN" > "$CRON_DIR/token" )
LINEA='0 * * * * /usr/bin/python3 /root/puntoqueso-cron/gastos_recurrentes_cron.py >> /root/puntoqueso-cron/cron.log 2>&1'
ACTUAL="$(crontab -l 2>/dev/null || true)"
LIMPIO="$(printf '%s\n' "$ACTUAL" | grep -v 'gastos_recurrentes_cron' | grep -v '^TZ=America/Santiago$' || true)"
printf '%s\n%s\n' "$LIMPIO" "$LINEA" | sed '/^$/d' | crontab -
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $CRON_TOKEN" "$API/gastos_recurrentes?select=id&limit=1")"
[ "$code" = "200" ] || { echo "❌ El token del cron no funciona (HTTP $code)"; exit 1; }
echo "ok, corre cada hora y actúa a las 9:00 de Chile"

paso "7/7 Verificando que la API ya no regala datos"
claves="$(curl -s "$API/config?select=clave" | { grep -o -E 'mercadopago|openai|evolution' || true; } | wc -l | tr -d ' ')"
clientes="$(curl -s -o /dev/null -w '%{http_code}' "$API/clientes")"
password="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d '{"p_usuario_id":1,"p_password":"x"}' "$API/rpc/set_password_hash")"
[ "$claves" = "0" ]    && echo "✅ claves de Mercado Pago/OpenAI/Evolution ocultas al público" || { echo "❌ las claves siguen visibles"; exit 1; }
[ "$clientes" = "401" ] && echo "✅ clientes ocultos al público"                                  || { echo "❌ clientes visibles (HTTP $clientes)"; exit 1; }
[ "$password" = "401" ] && echo "✅ nadie de afuera puede cambiar contraseñas"                     || { echo "❌ set_password_hash abierto (HTTP $password)"; exit 1; }

echo
echo "LISTO. Vuelve a iniciar sesión en el panel (la sesión anterior ya no sirve)."
