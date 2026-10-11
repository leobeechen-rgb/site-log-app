// hb-line-oa：LINE 官方帳號 webhook（只聽、不回覆客人）
// 客人在官方 LINE（一對一或有加官方帳號的案件群組）說「已匯款／轉帳／查收」→ 建立匯款回報 → 工作台通知中心＋手機推播 → 點開就是填好的收據草稿。
// 案件群組（設計師輸入「綁定 案名」連結後）：客人傳的照片自動存進案件照片；回報問題（漏水、裂縫…）自動新增缺失。
// 需要在 Supabase → Edge Functions → Secrets 設定（請自己貼，不要貼在對話裡）：
//   HB_OA_CHANNEL_SECRET  LINE Developers → 官方帳號的 Messaging API Channel → Basic settings → Channel secret（必填）
//   HB_OA_ACCESS_TOKEN    同一個 Channel → Messaging API → Channel access token（存照片、群組回覆、顯示群組名稱需要）
// LINE Developers 的 Webhook URL 設為 https://rqndozhhvuimqjqtmeli.supabase.co/functions/v1/hb-line-oa 並開啟 Use webhook。
import { isPaymentText, parseAmount, isDefectText, bindQuery } from './detect.mjs';
const VERSION = '2026-10-12.1';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!, SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SECRET = (Deno.env.get('HB_OA_CHANNEL_SECRET') || '').trim(), TOKEN = (Deno.env.get('HB_OA_ACCESS_TOKEN') || '').trim();
const enc = new TextEncoder();
declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void };
const log = (stage: string, extra: Record<string, unknown> = {}) => console.log(JSON.stringify({ service: 'hb-line-oa', stage, ...extra }));

async function verify(raw: Uint8Array, sig: string | null) {
  if (!sig || !/^[A-Za-z0-9+/]{43}=$/.test(sig)) return false;
  const key = await crypto.subtle.importKey('raw', enc.encode(SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
  return crypto.subtle.verify('HMAC', key, Uint8Array.from(atob(sig), c => c.charCodeAt(0)), raw);
}
async function lineGet(path: string) {
  if (!TOKEN) return null;
  try {
    const r = await fetch('https://api.line.me/v2/bot/' + path, { headers: { Authorization: 'Bearer ' + TOKEN }, signal: AbortSignal.timeout(4000) });
    return r.ok ? await r.json() : null;
  } catch { return null; }
}
// 群組用群組名稱（例如「大嘉A棟5F-5」），個人用 LINE 名稱
// deno-lint-ignore no-explicit-any
async function chatName(src: any) {
  let n = '';
  if (src.type === 'group') n = (await lineGet('group/' + src.groupId + '/summary'))?.groupName || '';
  else if (src.type === 'user') n = (await lineGet('profile/' + src.userId))?.displayName || '';
  return String(n).slice(0, 60) || null;
}
async function rpc(name: string, args: Record<string, unknown>) {
  const r = await fetch(SUPABASE_URL + '/rest/v1/rpc/' + name, {
    method: 'POST', headers: { apikey: SERVICE, Authorization: 'Bearer ' + SERVICE, 'Content-Type': 'application/json' },
    body: JSON.stringify(args), signal: AbortSignal.timeout(6000),
  });
  if (!r.ok) throw new Error(name + '_' + r.status);
  return await r.json();
}
// 官方帳號在群組回覆（回覆訊息不佔每月則數）
async function reply(token: string, text: string) {
  if (!TOKEN || !token) return;
  try {
    await fetch('https://api.line.me/v2/bot/message/reply', { method: 'POST', headers: { Authorization: 'Bearer ' + TOKEN, 'Content-Type': 'application/json' },
      body: JSON.stringify({ replyToken: token, messages: [{ type: 'text', text: text.slice(0, 1000) }] }), signal: AbortSignal.timeout(5000) });
  } catch { /* 回覆失敗不影響其他 */ }
}
// 下載 LINE 圖片 → 存到 Supabase Storage（sitelog-photos，公開網址與施工照片相同方式）
// deno-lint-ignore no-explicit-any
async function savePhoto(e: any, key: string, sender: string | null) {
  if (!TOKEN || e.message?.contentProvider?.type === 'external') return 'no_token';
  const info = await rpc('hb_line_chat_info', { p_key: key, p_sender: sender });
  if (!info?.project_id || info.staff) return info?.staff ? 'staff' : 'unbound';
  const r = await fetch('https://api-data.line.me/v2/bot/message/' + e.message.id + '/content', { headers: { Authorization: 'Bearer ' + TOKEN }, signal: AbortSignal.timeout(15000) });
  if (!r.ok) throw new Error('content_' + r.status);
  const buf = new Uint8Array(await r.arrayBuffer());
  if (!buf.length || buf.length > 20 * 1024 * 1024) return 'size';
  const ct = r.headers.get('content-type') || 'image/jpeg', ext = ct.includes('png') ? 'png' : 'jpg';
  const path = 'line/' + info.project_id + '/' + new Date().toISOString().slice(0, 10) + '-' + crypto.randomUUID() + '.' + ext;
  const up = await fetch(SUPABASE_URL + '/storage/v1/object/sitelog-photos/' + path, { method: 'POST', headers: { apikey: SERVICE, Authorization: 'Bearer ' + SERVICE, 'Content-Type': ct, 'x-upsert': 'false' }, body: buf });
  if (!up.ok) throw new Error('storage_' + up.status);
  const url = SUPABASE_URL + '/storage/v1/object/public/sitelog-photos/' + path;
  const id = await rpc('hb_line_photo_add', { p_event: String(e.webhookEventId), p_key: key, p_sender: sender, p_url: url, p_path: path, p_size: buf.length });
  return id ? 'saved' : 'dup';
}
async function report(args: Record<string, unknown>) {
  const r = await fetch(SUPABASE_URL + '/rest/v1/rpc/hb_payment_report_add', {
    method: 'POST', headers: { apikey: SERVICE, Authorization: 'Bearer ' + SERVICE, 'Content-Type': 'application/json' },
    body: JSON.stringify(args), signal: AbortSignal.timeout(6000),
  });
  if (!r.ok) throw new Error('db_' + r.status);
  return await r.json();
}
// ── 排程發送到案件 LINE 群組（pg_cron 每分鐘呼叫 ?run=scheduled）──
async function rest(path: string, init: RequestInit = {}) {
  const r = await fetch(SUPABASE_URL + '/rest/v1/' + path, { ...init, headers: { apikey: SERVICE, Authorization: 'Bearer ' + SERVICE, 'Content-Type': 'application/json', Prefer: 'return=representation', ...(init.headers || {}) }, signal: AbortSignal.timeout(8000) });
  const t = await r.text(); if (!r.ok) throw new Error('rest_' + r.status + ' ' + t.slice(0, 120));
  return t.trim() ? JSON.parse(t) : null;
}
async function runScheduled() {
  if (!TOKEN) return { ok: false, why: 'no_token' };
  const now = new Date().toISOString();
  // deno-lint-ignore no-explicit-any
  const due = (await rest('hb_line_posts?status=eq.pending&send_at=lte.' + encodeURIComponent(now) + '&select=*&order=send_at.asc&limit=20')) as any[] || [];
  let sent = 0, failed = 0;
  for (const p of due) {
    // 先搶下這一筆，避免同時兩次呼叫重複發送
    const got = await rest('hb_line_posts?id=eq.' + p.id + '&status=eq.pending', { method: 'PATCH', body: JSON.stringify({ status: 'sending' }) });
    if (!got || !got.length) continue;
    // deno-lint-ignore no-explicit-any
    const msgs: any[] = [];
    if (String(p.body || '').trim()) msgs.push({ type: 'text', text: String(p.body).slice(0, 4900) });
    for (const u of (p.photo_urls || []).slice(0, 4)) if (/^https:\/\//.test(u)) msgs.push({ type: 'image', originalContentUrl: u, previewImageUrl: u });
    let err = '';
    if (!msgs.length) err = '沒有內容';
    else {
      try {
        const r = await fetch('https://api.line.me/v2/bot/message/push', { method: 'POST', headers: { Authorization: 'Bearer ' + TOKEN, 'Content-Type': 'application/json' },
          body: JSON.stringify({ to: p.line_key, messages: msgs.slice(0, 5) }), signal: AbortSignal.timeout(10000) });
        if (!r.ok) { const t = await r.text(); err = 'LINE ' + r.status + ' ' + t.slice(0, 200); }
      } catch (x) { err = String((x as Error)?.message || x).slice(0, 200); }
    }
    await rest('hb_line_posts?id=eq.' + p.id, { method: 'PATCH', headers: { Prefer: 'return=minimal' },
      body: JSON.stringify(err ? { status: 'failed', error: err } : { status: 'sent', sent_at: new Date().toISOString(), error: null }) });
    if (err) { failed++; log('post_failed', { code: err.slice(0, 80) }); } else { sent++; log('post_sent', {}); }
  }
  return { ok: true, due: due.length, sent, failed };
}

// deno-lint-ignore no-explicit-any
async function handle(e: any) {
  const src = e?.source || {};
  const key = src.type === 'group' ? src.groupId : src.type === 'room' ? src.roomId : src.userId;
  if (e?.type !== 'message' || !/^[UCR][0-9a-f]{32}$/.test(key || '') || !e.webhookEventId) { log('skip', { t: e?.type, s: src.type, k: /^[UCR][0-9a-f]{32}$/.test(key || ''), id: !!e?.webhookEventId }); return; }
  if (e.deliveryContext?.isRedelivery && Math.abs(Date.now() - Number(e.timestamp || 0)) > 6 * 3600e3) return;
  // 記下這個群組（含名稱），讓設計師在工地紀錄本「編輯專案」裡選擇連結
  if (src.type !== 'user') {
    try { if (await rpc('hb_line_seen', { p_key: key, p_name: null })) { const n = await chatName(src); if (n) await rpc('hb_line_seen', { p_key: key, p_name: n }); } }
    catch (err) { log('seen_failed', { code: String((err as Error)?.message).slice(0, 60) }); }
  }
  const mt = e.message?.type;
  const sender = /^U[0-9a-f]{32}$/.test(src.userId || '') ? src.userId : null;
  if (mt === 'image') {
    // 匯款截圖會併進匯款回報；同時存進案件照片
    try { await report({ p_event: String(e.webhookEventId), p_uid: key, p_name: null, p_text: '', p_kind: 'image', p_amount: null, p_sender: sender }); } catch (err) { log('pay_img_failed', { code: String((err as Error)?.message).slice(0, 60) }); }
    log('photo', { r: await savePhoto(e, key, sender), s: src.type });
    return;
  }
  if (mt !== 'text') return;
  const text = String(e.message.text || '');
  const bq = bindQuery(text);
  if (bq && src.type !== 'user') {
    const b = await rpc('hb_line_bind', { p_key: key, p_sender: sender, p_query: bq, p_name: await chatName(src) });
    log('bind', { ok: !!b?.ok, why: b?.why });
    if (b?.ok) await reply(e.replyToken, '✅ 這個群組已連結到工地紀錄本的案件「' + b.name + '」。之後業主在這裡傳的照片、回報的問題、匯款訊息，都會自動整理到案件裡。');
    else if (b?.why === 'many') await reply(e.replyToken, '找到好幾個案件：' + (b.names || []).join('、') + '。請輸入完整案名，例如「綁定 ' + ((b.names || [])[0] || '') + '」。');
    else if (b?.why === 'none') await reply(e.replyToken, '找不到「' + bq + '」這個案件，請確認工地紀錄本裡的案名。');
    return;
  }
  if (isPaymentText(text)) {
    const r = await report({ p_event: String(e.webhookEventId), p_uid: key, p_name: await chatName(src),
      p_text: text, p_kind: 'text', p_amount: parseAmount(text), p_sender: sender });
    log(r ? 'reported' : 'ignored', { kind: 'text', s: src.type });
    return;
  }
  if (src.type !== 'user' && isDefectText(text)) {
    const d = await rpc('hb_line_defect_add', { p_event: String(e.webhookEventId), p_key: key, p_sender: sender, p_text: text });
    log(d ? 'defect' : 'defect_ignored', { s: src.type });
    return;
  }
  log('not_matched', { s: src.type });
}

Deno.serve(async (req: Request) => {
  const headers = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
  if (req.method === 'GET' && new URL(req.url).searchParams.get('run') === 'scheduled') {
    try { return new Response(JSON.stringify(await runScheduled()), { headers }); }
    catch (err) { log('scheduled_failed', { code: String((err as Error)?.message).slice(0, 80) }); return new Response(JSON.stringify({ ok: false }), { status: 500, headers }); }
  }
  if (req.method === 'GET') return new Response(JSON.stringify({ service: 'hb-line-oa', version: VERSION, configured: !!SECRET, profile_names: !!TOKEN }), { status: SECRET ? 200 : 503, headers });
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  if (!SECRET) return new Response('Not configured', { status: 503 });
  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.length > 262144) return new Response('Too large', { status: 413 });
  if (!await verify(raw, req.headers.get('x-line-signature'))) return new Response('Invalid signature', { status: 401 });
  // deno-lint-ignore no-explicit-any
  let body: any; try { body = JSON.parse(new TextDecoder().decode(raw)); } catch { return new Response('Invalid JSON', { status: 400 }); }
  const events = Array.isArray(body?.events) ? body.events.slice(0, 100) : [];
  // deno-lint-ignore no-explicit-any
  if (events.length) log('received', { n: events.length, types: events.map((e: any) => e?.type + ':' + (e?.message?.type || e?.source?.type || '')).join(',').slice(0, 120) });
  // deno-lint-ignore no-explicit-any
  const work = (async () => { for (const e of events.sort((a: any, b: any) => (a.timestamp || 0) - (b.timestamp || 0))) { try { await handle(e); } catch (err) { log('event_failed', { code: String((err as Error)?.message || err).slice(0, 60) }); } } })();
  // 照片下載上傳需要幾秒，先回 LINE 200，背景繼續處理
  try { EdgeRuntime.waitUntil(work); } catch { await work; }
  return new Response('OK');   // LINE 的「Verify」按鈕送空事件，也回 200
});
