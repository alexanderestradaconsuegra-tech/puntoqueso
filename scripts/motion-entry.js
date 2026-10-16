// Fuente del bundle de Motion que va inline en catalogo.html (<script id="motion-lib">).
// Motion (MIT) https://motion.dev — versión 14.3.0, solo lo que usa la tienda (~11 KB, ~4,5 KB gzip).
// Para regenerar (en una carpeta temporal, no en el repo):
//   npm init -y && npm install motion esbuild
//   cp <repo>/scripts/motion-entry.js entry.js
//   npx esbuild entry.js --bundle --minify --format=iife --target=es2019 --outfile=motion-pq.js
// y pegar motion-pq.js dentro de <script id="motion-lib"> en catalogo.html.
import { animate } from "motion/mini";
import { inView, stagger } from "motion";
window.PQMotion = { animate, inView, stagger };
