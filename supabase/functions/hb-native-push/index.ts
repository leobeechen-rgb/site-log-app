// hb-native-push：由資料庫觸發，發送 iOS App 推播（Apple APNs）
// 需要在 Supabase → Edge Functions → Secrets 設定：
//   APNS_KEY_P8     Apple 推播金鑰 .p8 檔的完整內容（含 BEGIN/END 那兩行）
//   APNS_KEY_ID     金鑰 ID（10 碼）
//   APNS_TEAM_ID    Apple Developer Team ID（10 碼）
//   APNS_BUNDLE_ID  App 的 Bundle Identifier
// 伺服器會先送正式環境，若裝置是 Xcode 直接安裝的開發版，會自動改送測試環境。
// 2026-10-08：支援 user_ids（只送給有權限、沒關掉通知的帳號）與 nid／url（點推播後開到對應通知）。
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!, SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const P8 = Deno.env.get('APNS_KEY_P8') || '', KEY_ID = Deno.env.get('APNS_KEY_ID') || '', TEAM_ID = Deno.env.get('APNS_TEAM_ID') || '', BUNDLE = Deno.env.get('APNS_BUNDLE_ID') || '';
const json = (d: unknown, s = 200) => new Response(JSON.stringify(d), { status: s, headers: { 'Content-Type': 'application/json' } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
async function db(path: string, init: RequestInit = {}) {
  const r = await fetch(SUPABASE_URL + '/rest/v1/' + path, { ...init, headers: { apikey: SERVICE, Authorization: 'Bearer ' + SERVICE, 'Content-Type': 'application/json', ...(init.headers || {}) } });
  if (!r.ok) throw new Error('db_' + r.status);
  const t = await r.text(); return t.trim() ? JSON.parse(t) : null;
}
const b64url = (buf: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(buf as ArrayBuffer))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
let cachedJwt = '', cachedAt = 0, cachedKey: CryptoKey | null = null;
async function apnsJwt() {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now - cachedAt < 45 * 60) return cachedJwt;
  if (!cachedKey) {
    const pem = P8.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
    const der = Uint8Array.from(atob(pem), c => c.charCodeAt(0));
    cachedKey = await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  }
  const enc = new TextEncoder();
  const head = b64url(enc.encode(JSON.stringify({ alg: 'ES256', kid: KEY_ID })));
  const claims = b64url(enc.encode(JSON.stringify({ iss: TEAM_ID, iat: now })));
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, cachedKey, enc.encode(head + '.' + claims));
  cachedJwt = head + '.' + claims + '.' + b64url(sig); cachedAt = now;
  return cachedJwt;
}
async function sendOne(host: string, token: string, payload: string) {
  const r = await fetch(`https://${host}/3/device/${token}`, {
    method: 'POST',
    headers: { authorization: 'bearer ' + await apnsJwt(), 'apns-topic': BUNDLE, 'apns-push-type': 'alert', 'apns-priority': '10', 'content-type': 'application/json' },
    body: payload,
  });
  let reason = ''; if (!r.ok) { try { reason = (await r.json()).reason || ''; } catch { reason = ''; } }
  return { status: r.status, reason };
}
Deno.serve(async (req: Request) => {
  try {
    if (req.method !== 'POST') return json({ error: 'Not found' }, 404);
    const secret = req.headers.get('x-hb-push-secret') || '';
    const ok = secret.length === 64 && await db('rpc/hb_push_secret_ok', { method: 'POST', body: JSON.stringify({ p: secret }) });
    if (ok !== true) return json({ error: 'forbidden' }, 403);
    if (!P8 || !KEY_ID || !TEAM_ID || !BUNDLE) return json({ skipped: 'APNs secrets not set' });
    const b = await req.json();
    const audience = b.audience === 'admin' ? 'admin' : 'owner';
    let q = 'hb_device_tokens?select=token&audience=eq.' + audience;
    if (audience === 'owner') { if (!UUID.test(String(b.project_id || ''))) return json({ error: 'project required' }, 400); q += '&project_id=eq.' + b.project_id; }
    if (Array.isArray(b.user_ids)) {
      const ids = b.user_ids.map(String).filter((x: string) => UUID.test(x));
      if (!ids.length) return json({ sent: 0, removed: 0, total: 0 });
      q += '&user_id=in.(' + ids.join(',') + ')';
    }
    const rows: { token: string }[] = (await db(q)) || [];
    const nid = UUID.test(String(b.nid || '')) ? String(b.nid) : null;
    const url = typeof b.url === 'string' && /^https:\/\/www\.herfulsinsvip\.com\//.test(b.url) ? b.url : null;
    const payload = JSON.stringify({
      aps: { alert: { title: String(b.title || '赫柏工地紀錄本').slice(0, 80), body: String(b.body || '').slice(0, 180) }, sound: 'default', 'thread-id': nid ? 'owner-updates' : undefined },
      kind: String(b.kind || ''), project_id: b.project_id || null, nid, url,
    });
    let sent = 0, removed = 0;
    for (const { token } of rows) {
      let res = await sendOne('api.push.apple.com', token, payload);
      if (res.status === 400 && res.reason === 'BadDeviceToken') res = await sendOne('api.sandbox.push.apple.com', token, payload);
      if (res.status === 200) sent++;
      else if (res.status === 410 || res.reason === 'BadDeviceToken' || res.reason === 'Unregistered') {
        await db('hb_device_tokens?token=eq.' + encodeURIComponent(token), { method: 'DELETE' }); removed++;
      }
    }
    return json({ sent, removed, total: rows.length });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
