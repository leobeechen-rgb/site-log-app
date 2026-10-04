// 赫柏工地紀錄本：業主 LINE 快速登入
// POST /begin   {mode:'login'|'link'}（link 需帶 x-hb-owner）-> {url}  前往 LINE 授權頁
// GET  /callback?code&state                                    -> 302 回到網站
// POST /status  (x-hb-owner) -> {linked, name}
// POST /unlink  (x-hb-owner) -> {ok}
// 需要 Secrets：LINE_LOGIN_CHANNEL_ID、LINE_LOGIN_CHANNEL_SECRET
const BASE = Deno.env.get('SUPABASE_URL')!, KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const CID = Deno.env.get('LINE_LOGIN_CHANNEL_ID') || '', CSECRET = Deno.env.get('LINE_LOGIN_CHANNEL_SECRET') || '';
const CALLBACK = BASE + '/functions/v1/hb-line-login/callback';
const SITE = 'https://www.herfulsinsvip.com/';
const RETURNS = ['https://www.herfulsinsvip.com/', 'https://herfulsinsvip.com/'];
const allowed = new Set(['https://www.herfulsinsvip.com', 'https://herfulsinsvip.com', 'null']);
const enc = new TextEncoder();
const cors = (req: Request) => { const o = req.headers.get('origin') || ''; return { 'Access-Control-Allow-Origin': allowed.has(o) ? o : 'https://www.herfulsinsvip.com', 'Access-Control-Allow-Headers': 'content-type,x-hb-owner', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS', 'Vary': 'Origin', 'Cache-Control': 'no-store', 'Content-Type': 'application/json' } };
const json = (req: Request, d: unknown, s = 200) => new Response(JSON.stringify(d), { status: s, headers: cors(req) });
const go = (url: string) => new Response(null, { status: 302, headers: { Location: url, 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' } });
async function sha(v: string) { return [...new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(v)))].map(x => x.toString(16).padStart(2, '0')).join('') }
const rand = (n: number) => btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(n)))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
async function db(path: string, init: RequestInit = {}) { const r = await fetch(BASE + '/rest/v1/' + path, { ...init, headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json', Prefer: 'return=representation', ...(init.headers || {}) } }); if (!r.ok) throw new Error('db_' + r.status + ' ' + (await r.text()).slice(0, 200)); if (r.status === 204) return null; const t = await r.text(); return t.trim() ? JSON.parse(t) : null }
async function ownerProject(req: Request) {
  const t = req.headers.get('x-hb-owner') || ''; if (!/^[A-Za-z0-9_-]{43}$/.test(t)) return null;
  const rows = await db('hb_owner_sessions?token_hash=eq.' + await sha(t) + '&expires_at=gt.' + encodeURIComponent(new Date().toISOString()) + '&select=project_id');
  return rows?.[0]?.project_id || null;
}
const back = (ret: string, params: Record<string, string>) => { const u = new URL(RETURNS.includes(ret) ? ret : SITE); u.hash = new URLSearchParams(params).toString(); return u.toString() };
Deno.serve(async (req: Request) => {
  try {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(req) });
    const url = new URL(req.url), route = url.pathname.split('/').pop();
    if (route === 'health') return json(req, { ok: true, configured: !!(CID && CSECRET), version: '2026-10-05.1' });
    if (req.method === 'POST' && route === 'begin') {
      if (!CID || !CSECRET) return json(req, { error: 'LINE 登入尚未設定完成，請先用案件密碼登入' }, 503);
      const b = await req.json().catch(() => ({}));
      const mode = b.mode === 'link' ? 'link' : 'login';
      let project_id = null;
      if (mode === 'link') { project_id = await ownerProject(req); if (!project_id) return json(req, { error: '請先用案件密碼登入' }, 401) }
      const ret = RETURNS.includes(String(b.return_to || '')) ? String(b.return_to) : SITE;
      const state = rand(24), nonce = rand(16);
      await db('hb_line_states', { method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ id: state, mode, project_id, return_to: ret }) });
      db('hb_line_states?created_at=lt.' + encodeURIComponent(new Date(Date.now() - 86400000).toISOString()), { method: 'DELETE', headers: { Prefer: 'return=minimal' } }).catch(() => {});
      const q = new URLSearchParams({ response_type: 'code', client_id: CID, redirect_uri: CALLBACK, state, scope: 'profile openid', nonce });
      return json(req, { url: 'https://access.line.me/oauth2/v2.1/authorize?' + q.toString() });
    }
    if (req.method === 'GET' && route === 'callback') {
      const state = url.searchParams.get('state') || '', code = url.searchParams.get('code') || '';
      if (!/^[\w-]{20,64}$/.test(state)) return go(back(SITE, { hbline: 'error' }));
      const st = (await db('hb_line_states?id=eq.' + state + '&used_at=is.null&select=*'))?.[0];
      if (!st || Date.now() - new Date(st.created_at).getTime() > 10 * 60000) return go(back(SITE, { hbline: 'expired' }));
      await db('hb_line_states?id=eq.' + state, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ used_at: new Date().toISOString() }) });
      if (!code) return go(back(st.return_to, { hbline: 'cancel' }));
      const tr = await fetch('https://api.line.me/oauth2/v2.1/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: CALLBACK, client_id: CID, client_secret: CSECRET }) });
      if (!tr.ok) return go(back(st.return_to, { hbline: 'error' }));
      const tk = await tr.json();
      const vr = await fetch('https://api.line.me/oauth2/v2.1/verify', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ id_token: tk.id_token || '', client_id: CID }) });
      if (!vr.ok) return go(back(st.return_to, { hbline: 'error' }));
      const idt = await vr.json(); const sub = String(idt.sub || ''); if (!/^U[0-9a-f]{32}$/.test(sub)) return go(back(st.return_to, { hbline: 'error' }));
      const name = String(idt.name || '').slice(0, 60);
      if (st.mode === 'link') {
        await db('hb_owner_line_links?on_conflict=line_user_id,project_id', { method: 'POST', headers: { Prefer: 'resolution=merge-duplicates,return=minimal' }, body: JSON.stringify({ line_user_id: sub, project_id: st.project_id, display_name: name }) });
        return go(back(st.return_to, { hbline: 'linked' }));
      }
      const links = await db('hb_owner_line_links?line_user_id=eq.' + sub + '&select=id,project_id,created_at,last_login_at&order=last_login_at.desc.nullslast,created_at.desc');
      if (!links?.length) return go(back(st.return_to, { hbline: 'notlinked' }));
      const pid = links[0].project_id;
      const token = rand(32), expiresAt = new Date(Date.now() + 30 * 86400000).toISOString();
      await db('hb_owner_sessions', { method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ token_hash: await sha(token), project_id: pid, expires_at: expiresAt }) });
      await db('hb_owner_line_links?id=eq.' + links[0].id, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ last_login_at: new Date().toISOString(), display_name: name }) });
      return go(back(st.return_to, { hbline: 'ok', t: token, p: pid }));
    }
    if (req.method === 'POST' && (route === 'status' || route === 'unlink')) {
      const pid = await ownerProject(req); if (!pid) return json(req, { error: '請重新登入' }, 401);
      if (route === 'unlink') { await db('hb_owner_line_links?project_id=eq.' + pid, { method: 'DELETE', headers: { Prefer: 'return=minimal' } }); return json(req, { ok: true }) }
      const rows = await db('hb_owner_line_links?project_id=eq.' + pid + '&select=display_name&limit=1');
      return json(req, { configured: !!(CID && CSECRET), linked: !!rows?.length, name: rows?.[0]?.display_name || '' });
    }
    return json(req, { error: 'Not found' }, 404);
  } catch (e) { console.error(e); return json(req, { error: '伺服器暫時無法處理' }, 500) }
});
