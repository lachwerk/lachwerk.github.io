// Lachwerk – Service Worker: macht die Seite installierbar und zeigt sie auch ohne Netz an.
// Strategie: immer zuerst das Netz (damit Updates sofort ankommen), bei Funkloch der Zwischenspeicher.
// Anfragen an Supabase (andere Adresse) werden nie zwischengespeichert.
const CACHE = "lachwerk-v34";
const SHELL = ["./", "index.html", "style.css?v=34", "app.js?v=34", "config.js", "favicon.svg", "icons/icon-192.png", "manifest.webmanifest", "qr.svg"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET" || new URL(req.url).origin !== self.location.origin) return;
  e.respondWith(
    fetch(req).then((res) => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
      return res;
    }).catch(() => caches.match(req).then((hit) => hit || (req.mode === "navigate" ? caches.match("index.html") : Response.error())))
  );
});

// Push-Nachrichten anzeigen (kommen von der Edge Function „push“)
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { title: "Lachwerk", body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "Lachwerk", {
    body: d.body || "", icon: "icons/icon-192.png", badge: "icons/icon-192.png", lang: "de",
    data: { url: d.url || "./" }, tag: d.tag || undefined,
  }));
});
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "./";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
    for (const c of list) { if ("focus" in c) { c.navigate(url).catch(() => {}); return c.focus(); } }
    return self.clients.openWindow(url);
  }));
});
