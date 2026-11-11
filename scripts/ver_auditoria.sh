#!/bin/bash
# Auditoría por servidor (ya no aparece en el panel; el sistema sigue registrando todo).
# Uso:
#   bash ver_auditoria.sh              -> últimas 50 acciones
#   bash ver_auditoria.sh 200          -> últimas 200
#   bash ver_auditoria.sh 50 conciliac -> últimas 50 que contengan "conciliac" (acción, módulo o detalle)
N="${1:-50}"; F="${2:-}"
case "$N" in ''|*[!0-9]*) echo "El primer valor debe ser un número"; exit 1;; esac
F="${F//\'/}"
docker exec -i postgresql-tnhz-postgresql-1 psql -U OQs9rmDuLK6xjVFL -d cEdIvrO6Xfggdl0A -P pager=off -c "
select to_char(created_at at time zone 'America/Santiago','DD-MM-YYYY HH24:MI') as cuando, usuario, accion, modulo, detalle
  from auditlog
 where '${F}' = '' or accion ilike '%${F}%' or modulo ilike '%${F}%' or detalle ilike '%${F}%'
 order by created_at desc limit ${N};"
