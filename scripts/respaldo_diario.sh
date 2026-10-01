#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
#  Respaldo diario de la base de datos de Punto Queso.
#
#  Guarda una copia completa (ventas, stock, movimientos, caja, gastos,
#  cuentas, pedidos, usuarios, configuración) en /root/respaldos-puntoqueso,
#  comprimida y con fecha. Borra las de más de 30 días.
#  Lo corre el cron todas las noches; también se puede correr a mano:
#     bash /root/respaldo_diario.sh
#
#  Usuario y base salen de /root/.pq_respaldo.env o del propio contenedor
#  (no hay claves en este archivo, que está en un repositorio público).
#  Para restaurar un respaldo, pide ayuda: se hace con psql sobre una base vacía.
# ══════════════════════════════════════════════════════════════════
set -euo pipefail
# usuario/base locales del VPS (archivo fuera del repo, lo crea la instalación)
[ -f /root/.pq_respaldo.env ] && . /root/.pq_respaldo.env
CONT="${PQ_PG_CONT:-postgresql-tnhz-postgresql-1}"
DIR="${PQ_RESPALDOS:-/root/respaldos-puntoqueso}"
DIAS="${PQ_RESPALDOS_DIAS:-30}"
mkdir -p "$DIR"
F="$DIR/puntoqueso-$(date +%F_%H%M).sql.gz"
trap 'rm -f "$F.tmp"; [ -f "$F" ] || echo "$(date "+%F %T") ERROR: no se pudo hacer el respaldo" >&2' EXIT
docker exec -e U="${PQ_PG_USER:-}" -e D="${PQ_PG_DB:-}" "$CONT" \
  sh -c 'pg_dump -U "${U:-$POSTGRES_USER}" -d "${D:-$POSTGRES_DB}" --no-owner --no-privileges' | gzip -9 > "$F.tmp"
# un respaldo vacío o cortado no reemplaza a nada
if [ "$(gzip -cd "$F.tmp" | head -c 2000 | grep -c 'PostgreSQL database dump')" -lt 1 ]; then
  echo "$(date '+%F %T') ERROR: el respaldo salió vacío o incompleto" >&2; rm -f "$F.tmp"; exit 1
fi
mv "$F.tmp" "$F"
find "$DIR" -name 'puntoqueso-*.sql.gz' -mtime +"$DIAS" -delete
echo "$(date '+%F %T') OK $(du -h "$F" | cut -f1) $F"
