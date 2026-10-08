// hb-line-oa：LINE 官方帳號 webhook（只聽、不回覆客人）
// 客人在官方 LINE（一對一或有加官方帳號的案件群組）說「已匯款／轉帳／查收」→ 建立匯款回報 → 工作台通知中心＋手機推播 → 點開就是填好的收據草稿。
// 需要在 Supabase → Edge Functions → Secrets 設定（請自己貼，不要貼在對話裡）：
//   HB_OA_CHANNEL_SECRET  LINE Developers → 官方帳號的 Messaging API Channel → Basic settings → Channel secret（必填）
//   HB_OA_ACCESS_TOKEN    同一個 Channel → Messaging API → Channel access token（選填：用來顯示客人的 LINE 名稱）
// LINE Developers 的 Webhook URL 設為 https://rqndozhhvuimqjqtmeli.supabase.co/functions/v1/hb-line-oa 並開啟 Use webhook。
import { isPaymentText, parseAmount } from './detect.mjs';
const VERSION = '2026-10-09.4';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!, SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SECRET = (Deno.env.get('HB_OA_CHANNEL_SECRET') || '').trim(), TOKEN = (Deno.env.get('HB_OA_ACCESS_TOKEN') || '').trim();
const enc = new TextEncoder();
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
async function report(args: Record<string, unknown>) {
  const r = await fetch(SUPABASE_URL + '/rest/v1/rpc/hb_payment_report_add', {
    method: 'POST', headers: { apikey: SERVICE, Authorization: 'Bearer ' + SERVICE, 'Content-Type': 'application/json' },
    body: JSON.stringify(args), signal: AbortSignal.timeout(6000),
  });
  if (!r.ok) throw new Error('db_' + r.status);
  return await r.json();
}
// deno-lint-ignore no-explicit-any
async function handle(e: any) {
  const src = e?.source || {};
  const key = src.type === 'group' ? src.groupId : src.type === 'room' ? src.roomId : src.userId;
  if (e?.type !== 'message' || !/^[UCR][0-9a-f]{32}$/.test(key || '') || !e.webhookEventId) { log('skip', { t: e?.type, s: src.type, k: /^[UCR][0-9a-f]{32}$/.test(key || ''), id: !!e?.webhookEventId }); return; }
  if (e.deliveryContext?.isRedelivery && Math.abs(Date.now() - Number(e.timestamp || 0)) > 6 * 3600e3) return;
  const mt = e.message?.type;
  let kind = '', text = '';
  if (mt === 'text') { text = String(e.message.text || ''); if (!isPaymentText(text)) { log('not_payment', { s: src.type }); return; } kind = 'text'; }
  else if (mt === 'image') kind = 'image';     // 只會併入一小時內的匯款回報（轉帳截圖）
  else return;
  const sender = /^U[0-9a-f]{32}$/.test(src.userId || '') ? src.userId : null;
  const r = await report({ p_event: String(e.webhookEventId), p_uid: key, p_name: kind === 'text' ? await chatName(src) : null,
    p_text: text, p_kind: kind, p_amount: kind === 'text' ? parseAmount(text) : null, p_sender: sender });
  log(r ? 'reported' : 'ignored', { kind, s: src.type });
}

Deno.serve(async (req: Request) => {
  const headers = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
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
  await work;   // 幾則訊息處理很快，直接等完再回 LINE，紀錄也比較完整
  return new Response('OK');   // LINE 的「Verify」按鈕送空事件，也回 200
});
