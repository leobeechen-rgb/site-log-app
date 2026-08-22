/* 赫柏空間設計 · 工地紀錄本 — Service Worker
   目的：讓 App 在工地沒訊號時也能打得開（離線可開啟、可看已載入過的頁面）

   部署方式：把這個 sw.js 放在跟 index.html 同一層（GitHub Pages 的 /site-log-app/ 目錄下）即可。
   策略：
     - 導覽請求（開啟 App）：網路優先，失敗才用快取 → 每次有網路一定拿到最新版，不會卡舊版
     - CDN 函式庫 / 靜態資源：快取優先，背景更新
     - 上傳與資料庫請求（R2 / Supabase）：一律不攔截，直接走網路
*/

const HB_CACHE = 'hb-sitelog-v1';

const PRECACHE = [
  './',
  './index.html',
  './manifest.json'
];

self.addEventListener('install', (e) => {
  self.skipWaiting();
  e.waitUntil(
    caches.open(HB_CACHE).then((c) => c.addAll(PRECACHE).catch(() => {}))
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== HB_CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

function isBypass(url) {
  return (
    url.includes('.supabase.co') ||
    url.includes('workers.dev') ||
    url.includes('.r2.dev') ||
    url.includes('accounts.google.com') ||
    url.includes('apis.google.com') ||
    url.includes('googleapis.com/drive') ||
    url.includes('googleapis.com/upload')
  );
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  if (isBypass(req.url)) return;

  // 開啟 App：網路優先
  if (req.mode === 'navigate') {
    e.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(HB_CACHE).then((c) => c.put('./index.html', copy)).catch(() => {});
          return res;
        })
        .catch(() => caches.match('./index.html').then((r) => r || caches.match('./')))
    );
    return;
  }

  // 其他靜態資源：快取優先，背景更新
  e.respondWith(
    caches.match(req).then((hit) => {
      const net = fetch(req)
        .then((res) => {
          if (res && (res.status === 200 || res.type === 'opaque')) {
            const copy = res.clone();
            caches.open(HB_CACHE).then((c) => c.put(req, copy)).catch(() => {});
          }
          return res;
        })
        .catch(() => hit);
      return hit || net;
    })
  );
});
