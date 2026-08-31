/**
 * 工地紀錄本　Service Worker
 *
 * 刻意只做推播，完全不碰快取。
 * 這是一支每天在用的工作工具，index.html 又是 1.8MB 的打包檔，
 * 如果讓 SW 去快取頁面，一旦策略寫錯就可能讓現場的人一直看到舊版，
 * 那種問題很難察覺也很難救。離線功能之後要再加，另外討論。
 */

self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let d = {};
  try {
    d = event.data ? event.data.json() : {};
  } catch (_) {
    d = { title: "工地紀錄本", body: event.data ? event.data.text() : "" };
  }

  event.waitUntil(
    self.registration.showNotification(d.title || "工地紀錄本", {
      body: d.body || "",
      icon: "./icon-192.png",
      badge: "./icon-192.png",
      tag: d.tag || "sitelog",
      renotify: false,
      data: { url: d.url || "./" },
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || "./";

  event.waitUntil(
    self.clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then((list) => {
        for (const c of list) {
          if ("focus" in c) return c.focus();
        }
        return self.clients.openWindow(target);
      }),
  );
});
