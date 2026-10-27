#!/bin/bash
# Diagnóstico de WhatsApp (Evolution API). No cambia nada y no muestra la API key.
# Uso:  PGU=<usuario_db> PGD=<base_db> bash diagnostico_whatsapp.sh [numero_para_prueba]
# Lee la URL, la key y la instancia desde la configuración del sistema y consulta a Evolution.
C=postgresql-tnhz-postgresql-1
[ -n "$PGU" ] && [ -n "$PGD" ] || { echo "Falta PGU y PGD (usuario y base de datos)"; exit 1; }
q(){ docker exec -i "$C" psql -U "$PGU" -d "$PGD" -At -c "select valor #>> '{}' from config where clave='$1'" | tr -d '\r\n'; }
URL=$(q evolution_api_url); KEY=$(q evolution_api_key); INST=$(q evolution_instance)
URL=${URL%/}
INSTU=${INST// /%20}   # el nombre puede llevar espacios ("Punto Queso")
echo "URL de Evolution : ${URL:-(vacía)}"
echo "Instancia        : ${INST:-(vacía)}"
echo "API key          : $([ -n "$KEY" ] && echo "configurada (${#KEY} caracteres)" || echo "(vacía)")"
[ -n "$URL" ] && [ -n "$KEY" ] && [ -n "$INST" ] || { echo "Falta configurar WhatsApp en Configuración."; exit 1; }
echo
echo "== Contenedores de Evolution"
docker ps -a --format '{{.Names}}  {{.Status}}' | grep -i evolution || echo "(no hay contenedor con 'evolution' en el nombre)"
echo
echo "== Estado de la conexión de la instancia (debe decir \"state\":\"open\")"
curl -s -m15 -w '\nHTTP %{http_code}\n' -H "apikey: $KEY" "$URL/instance/connectionState/$INSTU"
if [ -n "$1" ]; then
  N=$(echo "$1" | tr -cd '0-9'); case "$N" in 56*) ;; *) N="56$N";; esac
  echo
  echo "== Mensaje de prueba a +$N"
  curl -s -m20 -w '\nHTTP %{http_code}\n' -X POST -H "apikey: $KEY" -H 'Content-Type: application/json' \
    -d "{\"number\":\"$N\",\"text\":\"Prueba de diagnóstico de WhatsApp\"}" "$URL/message/sendText/$INSTU"
fi
