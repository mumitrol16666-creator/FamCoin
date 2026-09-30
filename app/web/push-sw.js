// FamCoin: приём push-уведомлений. Кеш и офлайн-режим не используются.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { /* пустое сообщение */ }
  // Без tag: iOS требует показывать каждое push, а одинаковый tag склеивает их.
  e.waitUntil(self.registration.showNotification(d.title || 'FamCoin', {
    body: d.body || '',
    icon: 'icons/Icon-192.png',
    // Куда вести по нажатию, например «./?close=2026-09» — сверка месяца.
    data: { url: d.url || './' },
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const target = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) {
      if (!('focus' in c)) continue;
      // Уже открытое окно: показываем его и переводим на нужный адрес.
      return c.focus().then((w) => {
        if (w && 'navigate' in w && w.url !== target) return w.navigate(target).catch(() => self.clients.openWindow(target));
        return w;
      });
    }
    return self.clients.openWindow(target);
  }));
});
