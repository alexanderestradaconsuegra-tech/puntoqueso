// Service worker — Punto Queso (admin POS)
// Minimal PWA shell caching. Network-first for navigation, cached shell only as last resort.
// This is a live POS: never cache API calls, only the app shell (index.html) itself.
//
// VERSIONING: bump CACHE_NAME (e.g. pq-shell-v2) on every deploy that changes
// puntoqueso-os.html, so old clients pick up the new shell instead of a stale cache.
const CACHE_NAME = 'pq-shell-v1';
const SHELL_URLS = ['/', '/index.html'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_URLS)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // Never touch anything that isn't a same-origin document navigation:
  // API calls (PostgREST, Evolution, MercadoPago, OpenAI, etc.), non-GET
  // requests, and cross-origin requests all pass straight through to network.
  if (req.method !== 'GET') return;
  if (url.origin !== self.location.origin) return;
  if (req.mode !== 'navigate' && req.destination !== 'document') return;

  event.respondWith(
    fetch(req)
      .then((res) => {
        const copy = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put('/index.html', copy)).catch(() => {});
        return res;
      })
      .catch(() => caches.match('/index.html'))
  );
});
