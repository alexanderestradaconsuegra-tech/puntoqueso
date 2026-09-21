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
- Foto de producto: subida manual desde el modal de Productos, comprimida en el navegador (canvas, máx. 800px de lado mayor, JPEG calidad 0.7) y guardada como base64 en `productos.imagen_b64` — sin ningún servicio externo (Cloudinary, S3, etc.). Se muestra como miniatura en la grilla del Terminal de ventas y en la tabla de Productos.

### Catálogo WhatsApp (preparación)

No se implementó ninguna integración de WhatsApp todavía, pero los datos ya quedaron listos para ella: `productos.imagen_b64` + `nombre` + `precio` + `stock` + `activo` es la única fuente de verdad que un futuro catálogo de WhatsApp debería leer directamente, por ejemplo con `GET /productos?activo=eq.true` contra PostgREST. Así el catálogo que vería un cliente por WhatsApp siempre coincide exactamente con lo que está en el sistema de la tienda, sin duplicar datos en otra tabla ni sincronizar nada aparte.

## Catálogo público de pedidos

`catalogo.html` es una página **pública, sin login**, pensada para que un cliente la abra desde su celular (por ejemplo desde un enlace compartido por WhatsApp) y arme su pedido solo: navega el catálogo de productos activos, arma un carrito (incluyendo peso en gramos/kg para los productos "por peso", con chips de 250g/500g/1kg + cantidad personalizada), completa nombre, teléfono y dirección, y al enviar el pedido queda insertado directamente en `pedidos`/`pedido_items` con `estado:'pendiente'`, listo para que el equipo lo vea y lo facture desde la pestaña "Pedidos" del sistema admin (`puntoqueso-os.html`).

Es un archivo completamente aparte del sistema admin: mismo cliente PostgREST (`PG`/`PGQuery`) copiado dentro de su propio `<script>`, mismos colores/tipografía de marca, pero **cero** acceso a login, ventas, gastos, auditoría o edición de productos — solo lee `GET /productos?activo=eq.true` e inserta en `pedidos`/`pedido_items` (el rol `web_anon` ya tiene permiso de insert sobre esas tablas por la política de RLS de `schema.sql`).

**Deploy:** este archivo necesita quedar servido en una URL pública, aparte del sistema admin. Dos formas razonables de hacerlo con la infraestructura actual (EasyPanel + nginx):

- Agregar `catalogo.html` al mismo contenedor nginx que sirve `puntoqueso-os.html`, expuesto en una ruta como `/catalogo` (copiarlo a `/usr/share/nginx/html/catalogo.html` en el `Dockerfile` y compartirlo bajo el mismo dominio).
- O crear un segundo servicio en EasyPanel (mismo patrón del paso 4 de este README, con `catalogo.html` como `index.html`) bajo un subdominio propio, por ejemplo `pedidos.autix.pro`.

La dirección ya no es un solo campo de texto libre: son tres campos separados en `catalogo.html` — `id="pedidoCalle"` (calle y número), `id="pedidoDepto"` (depto/casa, opcional) y `id="pedidoComuna"` (comuna) — que se guardan directo en las columnas `pedidos.direccion_calle`, `pedidos.direccion_depto` y `pedidos.direccion_comuna` (no se concatenan en `notas`; `notas`/observaciones sigue siendo un campo aparte para instrucciones extra). Lo mismo aplica al formulario manual de "Nuevo pedido" del admin (`puntoqueso-os.html`), que ahora también tiene esos tres campos.

**Google Maps Places Autocomplete (pendiente, falta API key):** cuando haya una API key de Google Maps, basta engancharle `google.maps.places.Autocomplete` al input `#pedidoCalle` de `catalogo.html` — el id se dejó estable a propósito para esto.

## WhatsApp (Evolution API)

El sistema puede avisarle automáticamente al cliente por WhatsApp cuando su pedido cambia de etapa (preparando, en camino, entregado, anulado), usando tu Evolution API existente en el VPS (la misma que usa Campolac, pero con su propia instancia/número para Punto Queso).

1. Ve a **Configuración → WhatsApp (Evolution API)** en `puntoqueso-os.html` (requiere login) y completa:
   - **URL de Evolution API** (ej: `https://evolution.tudominio.com`)
   - **API Key**
   - **Instancia** (el nombre/número de WhatsApp de esa instancia)
2. Guarda. Desde ese momento, cada vez que un pedido pasa a `preparando`, `en_camino`, `entregado` o se anula desde la pestaña "Pedidos", el sistema le manda automáticamente un mensaje corto al teléfono del cliente (`pedidos.cliente_tel`).
3. Si estos tres campos no están completos, el envío simplemente no ocurre (no rompe nada del flujo de Pedidos) — solo queda un `console.warn` en la consola del navegador para debug.

## Mercado Pago

El **Access Token** de tu cuenta de Mercado Pago Chile se configura en **Configuración → Mercado Pago** (admin, con login). Con eso guardado, en la pestaña **Pedidos** aparece un botón **"Generar link de pago"** en cada pedido: genera una preferencia de Checkout Pro por el total del pedido y te muestra el link (`init_point`) para copiarlo o enviarlo directo por WhatsApp (reutilizando la integración de Evolution API de arriba).

**Por qué esto es admin-only y no está en `catalogo.html`:** el Access Token es una credencial secreta de tu cuenta de Mercado Pago. `catalogo.html` es una página pública sin login que cualquiera puede abrir — si el token se usara ahí, quedaría expuesto en las peticiones de red a cada visitante del catálogo. Por eso la generación del link vive exclusivamente en el sistema admin (autenticado), y el catálogo público nunca hace ninguna llamada a Mercado Pago. El link ya generado se guarda en `pedidos.mp_link`/`pedidos.mp_preference_id` para poder reutilizarlo o regenerarlo después sin volver a exponer el token en ningún lado público.

## OpenAI (lectura de facturas de compra)

La **API Key** de OpenAI se configura en **Configuración → OpenAI (lectura de facturas)** (admin, con login). Con eso guardado, en **Proveedores → Nueva factura de compra** aparece un campo para subir una **foto de la factura**: la imagen se comprime en el navegador y se envía a la API de OpenAI (`gpt-4o-mini`, visión) para extraer proveedor, número de factura, fecha y las líneas de producto (nombre, cantidad, costo unitario).

El resultado **solo pre-llena el formulario existente** — proveedor, número, fecha e ítems — y nunca guarda nada por sí solo. Los productos detectados que no coinciden con ningún producto del catálogo quedan marcados con una advertencia y un selector vacío: el admin debe asignarlos manualmente (o eliminarlos) antes de que el botón **"Guardar factura"** quede habilitado para esa línea. El admin siempre revisa y confirma los datos antes de que la factura toque stock/inventario, igual que el resto de las importaciones de este sistema.

**Misma postura de seguridad que Mercado Pago:** la API Key de OpenAI es una credencial secreta y se usa exclusivamente desde el sistema admin autenticado (`puntoqueso-os.html`), nunca desde `catalogo.html`, que es público y sin login.

## PWA / Instalación como app

Ambos sistemas (`puntoqueso-os.html` en `puntoqueso.autix.pro` y `catalogo.html` en `pedidos.autix.pro`) son instalables como app en el celular:

- **Android/Chrome:** menú (⋮) → "Instalar app" / "Agregar a pantalla de inicio".
- **iOS Safari:** botón de compartir (□↑) → "Agregar a pantalla de inicio".

Una vez instalados abren en pantalla completa (sin barra de direcciones), con ícono propio y color de estado a juego con la marca — se sienten como una app nativa aunque siguen siendo la misma página web de siempre.

Esto se logra con, para cada app, sus propios archivos (no se comparte nada entre las dos porque cada una vive en su propio contenedor nginx con su propio dominio):

| Archivo (repo) | Para | Sirve como |
|---|---|---|
| `manifest.json` | `puntoqueso-os.html` | `/manifest.json` |
| `manifest-catalogo.json` | `catalogo.html` | `/manifest-catalogo.json` |
| `sw.js` | `puntoqueso-os.html` | `/sw.js` |
| `sw-catalogo.js` | `catalogo.html` | `/sw.js` (mismo nombre en su propio contenedor) |
| `icon-192.png`, `icon-512.png`, `icon-180.png` | ambas | `/icon-192.png`, `/icon-512.png`, `/icon-180.png` |
| `favicon.png`, `favicon.ico` | ambas | `/favicon.png`, `/favicon.ico` |
| `logo.png` | ambas | `/logo.png` (logo de marca para uso dentro de la UI, ver abajo) |

### Logo oficial

El logo oficial de Punto Queso vive en `assets/logo-original.jpg` (225×225px, fondo amarillo de marca, ilustración de queso con contorno negro y texto "PUNTO QUESO"). Todos los archivos de íconos/favicon del repo (`icon-192.png`, `icon-512.png`, `icon-180.png`, `favicon.png`, `favicon.ico`, `logo.png`) están derivados de ese archivo fuente con Pillow (reescalado Lanczos) — **reemplazan** el ícono genérico "PQ" (lettermark) que se había generado antes de tener el logo real, en la misma pasada de configuración de PWA.

Como el archivo fuente es de baja resolución (225×225), los íconos grandes (`icon-512.png` en particular) son un escalado hacia arriba y por lo tanto se ven algo suaves/borrosos — es una limitación real del archivo fuente, no algo que se pueda arreglar sin pedirle al dueño un logo en mayor resolución (idealmente un SVG o un PNG de al menos 1024×1024).

El logo se muestra en estos lugares — si el logo cambia alguna vez, hay que regenerar los archivos derivados y estos son los puntos a revisar para que todo quede sincronizado:

- **Favicon** de `puntoqueso-os.html` y `catalogo.html` (`favicon.ico` / `favicon.png`, enlazados en el `<head>`).
- **Apple touch icon** (`icon-180.png`, ya enlazado desde la pasada de PWA anterior).
- **Sidebar** del admin (`puntoqueso-os.html`, `.sb-brand`, junto al texto "PuntoQueso").
- **Pantalla de login** del admin (`puntoqueso-os.html`, `#login .brand`, arriba del nombre del sistema).
- **Header** del catálogo público (`catalogo.html`, `header.topbar`, junto al wordmark "Punto Queso").
- **Boleta imprimible** (función `generarReciboHTML` en `puntoqueso-os.html`): el logo se referencia con una URL absoluta (`${location.origin}/logo.png`, porque la ventana de impresión se abre con `document.write` sobre `about:blank` y una ruta relativa no resolvería) y se le aplica `filter: grayscale(1) contrast(1.6)` solo en esa vista, porque las impresoras térmicas son monocromáticas y no reproducen bien fotos a color.

El `sw.js`/`sw-catalogo.js` es un service worker mínimo: solo cachea el shell (el HTML) para que la app no muestre una pantalla en blanco si la conexión se corta un instante, con estrategia *network-first* (siempre intenta la red primero; solo usa la copia cacheada como último recurso). **Nunca cachea las llamadas a la API** (`api-puntoqueso.autix.pro/...`, PostgREST, Evolution API, Mercado Pago, OpenAI) — eso sigue siempre yendo directo a la red, como debe ser en un POS en vivo. Cada vez que se cambie sustancialmente `puntoqueso-os.html` o `catalogo.html` conviene subir el número de versión de `CACHE_NAME` dentro del `sw.js` correspondiente (ej. `pq-shell-v1` → `pq-shell-v2`) para forzar que los celus con la app instalada bajen el shell nuevo.

### Requisito de deploy

No hace falta configuración extra de nginx (sirve estos archivos como estáticos igual que el HTML), pero **si el deploy en el VPS usa el patrón de imagen Docker construida por EasyPanel a partir del `Dockerfile`** (como está documentado arriba), ya está resuelto: `Dockerfile` (admin) y `Dockerfile.catalogo` (catálogo) fueron actualizados para copiar también `manifest*.json`, `sw*.js` y los tres `icon-*.png` a `/usr/share/nginx/html/` — con volver a construir/desplegar el servicio en EasyPanel desde este repo alcanza, no hay pasos manuales sueltos en el VPS.

Si en cambio algún servicio quedó corriendo con un **bind-mount manual** de un solo archivo (`-v /ruta/en/vps/puntoqueso-os.html:/usr/share/nginx/html/index.html`) en vez de construir la imagen con el `Dockerfile`, hay que además copiar ahí mismo, junto al HTML, estos archivos nuevos (ajustando `/ruta/en/vps/` a la carpeta real usada en ese `docker run`/`docker-compose`):

```bash
# Admin (puntoqueso.autix.pro)
scp manifest.json icon-192.png icon-512.png icon-180.png favicon.png favicon.ico logo.png sw.js usuario@vps:/ruta/en/vps/admin/

# Catálogo (pedidos.autix.pro) — sw-catalogo.js se sube como sw.js
scp manifest-catalogo.json icon-192.png icon-512.png icon-180.png favicon.png favicon.ico logo.png usuario@vps:/ruta/en/vps/catalogo/
scp sw-catalogo.js usuario@vps:/ruta/en/vps/catalogo/sw.js
```

## Pendiente (próximos pasos)

- Nada pendiente de WhatsApp/MercadoPago por ahora — ambas integraciones están implementadas y solo falta que completes tus credenciales reales en Configuración.
