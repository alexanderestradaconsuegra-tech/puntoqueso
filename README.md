# Punto Queso — Sistema de ventas

Sistema de un solo archivo (`puntoqueso-os.html`), igual patrón que Campolac, pero corriendo sobre **Postgres + PostgREST** en tu propio VPS en vez de Supabase.

## 1. Base de datos

Corre `schema.sql` completo en tu Postgres **una sola vez**. Antes de correrlo:

- Cambia `'TU_CLAVE_AQUI'` por la contraseña real del usuario `admin`.
- Cambia `'clave_segura_aqui'` por una contraseña real para el rol `authenticator` (la va a usar PostgREST para conectarse).

```bash
psql "postgresql://usuario:password@localhost:5432/tu_base" -f schema.sql
```

## 2. Instalar PostgREST en EasyPanel

PostgREST es un contenedor liviano que expone tu Postgres como una API REST — es la misma tecnología que usa Supabase por debajo, así que el sistema le habla exactamente igual que le hablaría a Supabase.

1. En EasyPanel, crea un nuevo servicio → **App** → imagen Docker: `postgrest/postgrest`
2. Variables de entorno:
   ```
   PGRST_DB_URI=postgres://authenticator:clave_segura_aqui@<host-de-tu-postgres>:5432/<tu_base>
   PGRST_DB_SCHEMA=public
   PGRST_DB_ANON_ROLE=web_anon
   PGRST_SERVER_PORT=3000
   ```
   `<host-de-tu-postgres>` es el nombre interno del servicio de Postgres en EasyPanel (normalmente algo como `postgresql` o el nombre que le pusiste — EasyPanel te lo muestra en la pestaña de conexión del servicio de Postgres).
3. Puerto interno: `3000`. Actívale un dominio (puede ser un subdominio tuyo, ej: `api-puntoqueso.tudominio.com`) con HTTPS automático de EasyPanel.
4. Una vez arriba, prueba en el navegador: `https://api-puntoqueso.tudominio.com/productos` — debería devolver `[]` (lista vacía, todavía sin productos).

## 3. Conectar el sistema a tu PostgREST

Abre `puntoqueso-os.html` y edita esta línea (cerca del inicio del `<script>`):

```js
const PG_URL = 'https://TU-DOMINIO-POSTGREST.aqui';
```

Reemplázala por la URL real de tu PostgREST (la del paso 2.3).

## 4. Desplegar el HTML

Igual que Campolac / velos-landing: un `Dockerfile` simple con nginx sirviendo el archivo.

```dockerfile
FROM nginx:alpine
COPY puntoqueso-os.html /usr/share/nginx/html/index.html
EXPOSE 80
```

Sube esto como un nuevo servicio en EasyPanel (App → Source: este repo de GitHub), con su propio dominio.

## 5. Primer ingreso

Usuario: `admin` — Contraseña: la que pusiste en el paso 1.

## Ya implementado

- Escáner de código de barras (detección por velocidad de tecleo) + lectura de códigos de balanza EAN-13 para venta por peso.
- Selector de peso (teclado numérico) para productos "por kilo", con presets y validación de stock.
- Login rápido de cajero por PIN (`Cambiar de cajero`), separado del login de usuario/contraseña del admin — el PIN se guarda hasheado (bcrypt vía `crypt()`/`pgcrypto`) y se valida con la función `verificar_pin`.
- Roles y permisos por usuario (`permisos` jsonb: verCostos, editarInventario, eliminarVentas, verReportes, verGastos, gestionarUsuarios), editables desde Configuración → Usuarios y permisos (solo admin).
- Auditoría: bitácora de acciones clave (ventas, productos, config, permisos, PIN) visible en la pestaña "Auditoría" (gestionarUsuarios / admin).
- Exportar a Excel (ventas, productos, clientes, gastos) e importar productos desde Excel (por SKU, con upsert), vía SheetJS.
- Métodos de pago: Efectivo, Transferencia, Tarjeta y Mixto (split que valida en vivo que la suma cuadre con el total antes de habilitar "Cobrar").

## Pendiente (próximos pasos)

- **WhatsApp**: conectar el catálogo a tu Evolution API existente (nueva instancia/número solo para Punto Queso) para que los pedidos lleguen directo a la pestaña "Pedidos".
- **MercadoPago**: integración de cobro con tarjeta/QR — pendiente de que nos entregues el Access Token de tu cuenta de MercadoPago Chile.
