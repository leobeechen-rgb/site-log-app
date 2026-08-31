/**
 * 工地紀錄本　Service Worker
 *
 * 刻意只做推播，完全不碰快取。
 * 這是每天在用的工作工具，index.html 又是 1.8MB 的打包檔，
 * 讓 SW 去管快取一旦策略寫錯，現場的人可能一直看到舊版而且很難察覺。
 *
 * 推播分兩種：
 *   有酬載 → 工地行程提醒，內容由伺服器帶來，直接顯示。
 *   無酬載 → 朔望的提醒，伺服器只負責叫醒，內容從本機 IndexedDB 讀出來組。
 *            這樣週期資料就不會離開這支手機。
 */

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

/* ── 小型 IndexedDB ───────────────────────── */
function idb() {
  return new Promise((ok, no) => {
    const r = indexedDB.open("sitelog-sw", 1);
    r.onupgradeneeded = () => r.result.createObjectStore("kv");
    r.onsuccess = () => ok(r.result);
    r.onerror = () => no(r.error);
  });
}
async function kvGet(k) {
  const d = await idb();
  return new Promise((ok) => {
    const q = d.transaction("kv").objectStore("kv").get(k);
    q.onsuccess = () => ok(q.result);
    q.onerror = () => ok(undefined);
  });
}
async function kvSet(k, v) {
  const d = await idb();
  return new Promise((ok) => {
    const t = d.transaction("kv", "readwrite");
    t.objectStore("kv").put(v, k);
    t.oncomplete = () => ok();
  });
}

/* 頁面把朔望的排程送過來存著 */
self.addEventListener("message", (e) => {
  if (e.data && e.data.type === "moon-schedule") {
    kvSet("moon-schedule", e.data.items || []);
  }
});

/* ── 朔望：從本機排程組出今天的通知 ──────────── */
async function moonFire() {
  const now = new Date();
  now.setMinutes(now.getMinutes() - now.getTimezoneOffset());
  const today = now.toISOString().slice(0, 10);

  const items = (await kvGet("moon-schedule")) || [];
  const sent = (await kvGet("moon-sent")) || {};
  let shown = 0;

  for (const it of items) {
    if (it.date !== today) continue;
    const key = it.date + ":" + it.kind;
    sent[key] = 1;
    shown++;
    await self.registration.showNotification(it.title, {
      body: it.body,
      icon: "./icon-192.png",
      badge: "./icon-192.png",
      tag: "moon-" + key,
    });
  }
  await kvSet("moon-sent", sent);

  // 推播規定一定要顯示通知，否則瀏覽器會自己跳一則系統訊息
  if (shown === 0) {
    await self.registration.showNotification("朔望", {
      body: "打開看看目前走到週期第幾天。",
      icon: "./icon-192.png",
      badge: "./icon-192.png",
      tag: "moon-fallback",
    });
  }
}

/* ── 推播 ─────────────────────────────────── */
self.addEventListener("push", (event) => {
  // 沒有酬載 = 朔望的喚醒
  if (!event.data) {
    event.waitUntil(moonFire());
    return;
  }

  let d;
  try {
    d = event.data.json();
  } catch (_) {
    d = { title: "工地紀錄本", body: event.data.text() };
  }

  event.waitUntil(
    self.registration.showNotification(d.title || "工地紀錄本", {
      body: d.body || "",
      icon: "./icon-192.png",
      badge: "./icon-192.png",
      tag: d.tag || "sitelog",
      data: { url: d.url || "./" },
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || "./";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      for (const c of list) if ("focus" in c) return c.focus();
      return self.clients.openWindow(target);
    }),
  );
});
