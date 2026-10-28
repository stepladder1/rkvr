// Keeps the app opening even with no signal. Bump VERSION whenever you upload a new index.html.
const VERSION = 'rkvr-client-v8';
const FILES = ['./', './index.html', './manifest.webmanifest', './icon-180.png', './icon-192.png', './icon-512.png', './favicon.png', './products/glp1.webp', './products/tirz.webp', './products/nad.webp', './products/ret.webp', './products/b12.webp', './products/eye.webp', './products/lash.webp', './products/lip.webp'];
self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  // Network first so updates show up right away; fall back to the saved copy offline.
  e.respondWith(fetch(e.request).then(r => {
    const copy = r.clone(); caches.open(VERSION).then(c => c.put(e.request, copy)); return r;
  }).catch(() => caches.match(e.request).then(m => m || caches.match('./index.html'))));
});
