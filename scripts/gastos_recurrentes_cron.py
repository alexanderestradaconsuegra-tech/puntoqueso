#!/usr/bin/env python3
"""
Genera los gastos recurrentes de Punto Queso que tocan hoy y avisa por
WhatsApp (Evolution API) al número del negocio. Es lo mismo que hace el
panel al abrirse, pero corre solo en el VPS aunque nadie abra nada.

Instalación (la hace scripts/desplegar_seguridad.sh):
  /root/puntoqueso-cron/gastos_recurrentes_cron.py   este archivo
  /root/puntoqueso-cron/token                        token de servicio (chmod 600)
  crontab: 0 * * * *  → corre cada hora, pero solo actúa a las 9:00 de Chile,
  así funciona bien sin importar la zona horaria del servidor ni el horario
  de verano.

Prueba manual (ignora la hora):  python3 gastos_recurrentes_cron.py --forzar
Solo usa la librería estándar de Python 3.9+.
"""
import json
import sys
import urllib.request
from datetime import datetime, date
from zoneinfo import ZoneInfo

PG_URL = "https://api-puntoqueso.autix.pro"
TOKEN_PATH = "/root/puntoqueso-cron/token"
ZONA = ZoneInfo("America/Santiago")
HORA_AVISO = 9

with open(TOKEN_PATH) as f:
    TOKEN = f.read().strip()


def _pedir(metodo, path, body=None):
    headers = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(PG_URL + path, data=data, headers=headers, method=metodo)
    with urllib.request.urlopen(req, timeout=15) as r:
        cuerpo = r.read().decode()
        return json.loads(cuerpo) if cuerpo else None


def get_config():
    return {r["clave"]: r.get("valor") for r in _pedir("GET", "/config?select=clave,valor")}


def enviar_whatsapp(cfg, mensaje):
    url, key, instance = cfg.get("evolution_api_url"), cfg.get("evolution_api_key"), cfg.get("evolution_instance")
    if not url or not key or not instance:
        print("Evolution API no configurada: se generaron los gastos pero no se avisa por WhatsApp.")
        return
    numero = (cfg.get("negocio_telefono") or "+56939045793").strip()
    if not numero.startswith("+"):
        numero = "+56" + numero.lstrip("0")
    req = urllib.request.Request(
        f"{url.rstrip('/')}/message/sendText/{instance}",
        data=json.dumps({"number": numero, "text": mensaje}).encode(),
        headers={"Content-Type": "application/json", "apikey": key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            r.read()
        print("WhatsApp enviado.")
    except Exception as e:
        print("No se pudo enviar el WhatsApp:", e)


def es_due(r, hoy):
    """Misma regla que generarGastosRecurrentesPendientes() en el panel."""
    frecuencia = r.get("frecuencia") or "mensual"
    ultima = date.fromisoformat(r["ultima_generacion"]) if r.get("ultima_generacion") else None

    if frecuencia == "semanal":
        if r.get("dia_semana") is None:
            return False
        hoy_js = (hoy.weekday() + 1) % 7  # domingo=0 .. sábado=6, igual que getDay() en JS
        return hoy_js == int(r["dia_semana"]) and (ultima is None or (hoy - ultima).days > 6)

    if frecuencia == "quincenal":
        return ultima is None or (hoy - ultima).days >= 15

    mismo_mes = ultima is not None and (ultima.year, ultima.month) == (hoy.year, hoy.month)
    return hoy.day >= int(r.get("dia_mes") or 1) and not mismo_mes


def pesos(n):
    return f"${int(n or 0):,}".replace(",", ".")


def main():
    ahora = datetime.now(ZONA)
    if ahora.hour != HORA_AVISO and "--forzar" not in sys.argv:
        return
    hoy = ahora.date()
    generados = []

    for r in _pedir("GET", "/gastos_recurrentes?activo=eq.true"):
        if not es_due(r, hoy):
            continue
        try:
            _pedir("POST", "/gastos", {
                "fecha": hoy.isoformat(),
                "descripcion": "(Recurrente) " + (r.get("descripcion") or ""),
                "categoria": r.get("categoria") or "otros",
                "monto": r.get("monto"),
                "notas": f"Generado automáticamente (cron VPS) desde gasto recurrente #{r['id']}",
            })
        except Exception as e:
            print(f"Error generando gasto recurrente #{r['id']}:", e)
            continue
        try:
            _pedir("PATCH", f"/gastos_recurrentes?id=eq.{r['id']}", {"ultima_generacion": hoy.isoformat()})
        except Exception as e:
            print(f"Error actualizando ultima_generacion #{r['id']}:", e)
        try:
            _pedir("POST", "/auditlog", {
                "usuario": "cron", "accion": "Gasto recurrente generado (cron VPS)", "modulo": "gastos",
                "detalle": f"{r.get('descripcion')} — {pesos(r.get('monto'))}",
            })
        except Exception:
            pass
        generados.append(r)
        print(f"{ahora:%Y-%m-%d %H:%M} generado: {r.get('descripcion')} - {pesos(r.get('monto'))}")

    if not generados:
        print(f"{ahora:%Y-%m-%d %H:%M} sin gastos recurrentes pendientes.")
        return
    lineas = "\n".join(f"• {r.get('descripcion')} — {pesos(r.get('monto'))}" for r in generados)
    total = sum(int(r.get("monto") or 0) for r in generados)
    enviar_whatsapp(get_config(),
        f"🧾 *Punto Queso* — Gastos recurrentes de hoy ({hoy:%d-%m-%Y})\n\n{lineas}\n\n*Total: {pesos(total)}*")


if __name__ == "__main__":
    main()
