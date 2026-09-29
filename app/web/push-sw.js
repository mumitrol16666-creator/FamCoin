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
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) if ('focus' in c) return c.focus();
    return self.clients.openWindow('./');
  }));
});
