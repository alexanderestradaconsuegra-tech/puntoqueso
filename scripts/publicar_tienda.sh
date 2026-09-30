#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
#  Publica la tienda (catalogo.html) en pedidos.autix.pro y en
#  quesosvenezolanos.cl.
#
#  Uso:   bash publicar_tienda.sh <commit>
#
#  quesosvenezolanos.cl: la primera vez busca la carpeta que hoy sirve la
#  página "en preparación", deja un respaldo (index-preparacion.html) y
#  anota la carpeta en /root/.quesosvenezolanos_carpeta para las próximas
#  veces. Si no la encuentra con seguridad, NO toca nada y muestra lo que
#  vio para decidir a mano.
#  Volver a la página en preparación:
#    cp "$(cat /root/.quesosvenezolanos_carpeta)/index-preparacion.html" "$(cat /root/.quesosvenezolanos_carpeta)/index.html"
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

REF="${1:?Falta el commit. Uso: bash publicar_tienda.sh <commit>}"
RAW="https://raw.githubusercontent.com/alexanderestradaconsuegra-tech/puntoqueso/$REF"
CATALOGO_DIR="/root/puntoqueso-catalogo"
MEMO="/root/.quesosvenezolanos_carpeta"
MARCA="Página en preparación"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bajar(){ curl -fsSL "$RAW/$1" -o "$TMP/$2"; }

echo "── 1/3 Descargando la tienda del commit $REF"
bajar catalogo.html                  index.html
bajar manifest-catalogo.json         manifest-catalogo.json
bajar sw-catalogo.js                 sw.js
for f in icon-192.png icon-512.png icon-180.png favicon.png favicon.ico logo.png hero-quesos.webp hero-arepa.webp fiambres-quesos.webp llanero-campolac.webp mayorista-camion.webp og-image.jpg; do bajar "$f" "$f"; done
bajar proximamente/robots.txt        robots.txt
bajar proximamente/sitemap.xml       sitemap.xml
grep -q "crear_pedido_web" "$TMP/index.html" || { echo "ERROR: el archivo descargado no es la tienda nueva"; exit 1; }

echo "── 2/3 pedidos.autix.pro"
cp "$TMP/index.html" "$CATALOGO_DIR/index.html"
echo "   OK: $CATALOGO_DIR/index.html"

echo "── 3/3 quesosvenezolanos.cl"
DIR=""
if [ -f "$MEMO" ] && [ -d "$(cat "$MEMO")" ]; then
  DIR="$(cat "$MEMO")"
else
  mapfile -t CAND < <(grep -rls --include=index.html "$MARCA" \
      /root /srv /var/www /opt /home /data /etc/easypanel /var/lib/docker/volumes 2>/dev/null \
      | grep -v "/puntoqueso/proximamente/" | xargs -r -n1 dirname | sort -u)
  if [ "${#CAND[@]}" -eq 1 ]; then
    DIR="${CAND[0]}"
  else
    echo "   No pude decidir con seguridad dónde está quesosvenezolanos.cl (encontré ${#CAND[@]} carpetas):"
    printf '     %s\n' "${CAND[@]:-(ninguna)}"
    echo "   Contenedores que mencionan quesosvenezolanos:"
    for c in $(docker ps -q); do
      if docker inspect "$c" | grep -qi quesosvenezolanos; then
        docker inspect "$c" --format '     {{.Name}} → {{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}'
      fi
    done
    echo "   pedidos.autix.pro SÍ quedó actualizado. Mándame este texto para terminar quesosvenezolanos.cl."
    exit 2
  fi
fi

[ -f "$DIR/index-preparacion.html" ] || { grep -qs "$MARCA" "$DIR/index.html" && cp "$DIR/index.html" "$DIR/index-preparacion.html"; } || true
cp "$TMP"/* "$DIR/"
echo "$DIR" > "$MEMO"
echo "   OK: $DIR (respaldo de la página anterior: index-preparacion.html)"
echo
echo "Listo. Abre https://quesosvenezolanos.cl y https://pedidos.autix.pro con Ctrl + Shift + R."
