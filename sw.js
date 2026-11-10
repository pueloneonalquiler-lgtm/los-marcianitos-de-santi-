// Cotizador Puelo Neón: funciona sin internet.
// Al subir una versión nueva, cambiá el número de VERSION.
const VERSION = 'cotizador-v27';
const SHELL = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png', './icon-maskable-512.png', './apple-touch-icon.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  // La nube (Supabase) nunca se guarda en caché: siempre va directo a internet.
  const u = new URL(req.url);
  if (u.hostname.endsWith('supabase.co') || /\/(rest|auth|storage)\/v1\//.test(u.pathname)) return;
  // La página: primero internet (para tener siempre la última versión), si no hay, la guardada.
  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).then(r => { const copy = r.clone(); caches.open(VERSION).then(c => c.put('./index.html', copy)); return r; })
      .catch(() => caches.match('./index.html')));
    return;
  }
  // Íconos y tipografías: primero lo guardado, si no está, se baja y se guarda.
  e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(r => {
    if (r && (r.ok || r.type === 'opaque')) { const copy = r.clone(); caches.open(VERSION).then(c => c.put(req, copy)); }
    return r;
  }).catch(() => hit)));
});
