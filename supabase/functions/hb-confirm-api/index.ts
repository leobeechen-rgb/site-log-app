// 赫柏空間設計｜業主確認 API
// 公司端：Supabase 會員登入 + hb_admins（reviewer 只能看 scope_project）
// 業主端：確認連結 token（只能讀寫該筆確認單，可撤銷）
const BASE = Deno.env.get('SUPABASE_URL')!, KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const BUCKET = 'hb-confirm';
const allowed = new Set(['https://www.herfulsinsvip.com', 'https://herfulsinsvip.com', 'null']);
const cors = (req: Request) => { const o = req.headers.get('origin') || ''; return { 'Access-Control-Allow-Origin': allowed.has(o) ? o : 'https://www.herfulsinsvip.com', 'Access-Control-Allow-Headers': 'authorization,content-type,x-hb-confirm', 'Access-Control-Allow-Methods': 'GET,POST,OPTIONS', 'Vary': 'Origin', 'Cache-Control': 'no-store', 'Content-Type': 'application/json' } };
const json = (req: Request, data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers: cors(req) });
class HttpError extends Error { constructor(public status: number, msg: string) { super(msg) } }
const fail = (status: number, msg: string) => { throw new HttpError(status, msg) };

async function db(path: string, init: RequestInit = {}) {
  const r = await fetch(BASE + '/rest/v1/' + path, { ...init, headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json', Prefer: 'return=representation', ...(init.headers || {}) } });
  const text = await r.text();
  if (!r.ok) { if (r.status === 409 || /duplicate key/.test(text)) throw new HttpError(409, 'conflict'); throw new Error('db_' + r.status + ' ' + text.slice(0, 200)) }
  return text.trim() ? JSON.parse(text) : null;
}
const enc = (v: string) => encodeURIComponent(v);
async function body(req: Request) { if (Number(req.headers.get('content-length') || 0) > 300000) fail(413, '資料過大'); try { return await req.json() } catch { fail(400, '資料格式錯誤') } }
const clean = (s: unknown, n: number) => String(s ?? '').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '').trim().slice(0, n);
const isDate = (s: unknown) => typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s);
const token = () => { const b = new Uint8Array(24); crypto.getRandomValues(b); return btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '') };
const asciiName = (n: string) => { const m = n.match(/\.([A-Za-z0-9]{1,6})$/); return crypto.randomUUID().slice(0, 8) + (m ? '.' + m[1].toLowerCase() : '') };

async function signMany(paths: string[], expiresIn = 3600): Promise<Record<string, string>> {
  const uniq = [...new Set(paths.filter(Boolean))]; if (!uniq.length) return {};
  const r = await fetch(BASE + '/storage/v1/object/sign/' + BUCKET, { method: 'POST', headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ expiresIn, paths: uniq }) });
  if (!r.ok) return {};
  const arr = await r.json(); const out: Record<string, string> = {};
  for (const x of arr || []) if (x.signedURL && x.path) out[x.path] = BASE + '/storage/v1' + x.signedURL;
  return out;
}
async function signUpload(path: string) {
  const r = await fetch(BASE + '/storage/v1/object/upload/sign/' + BUCKET + '/' + path.split('/').map(enc).join('/'), { method: 'POST', headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' }, body: '{}' });
  if (!r.ok) throw new Error('sign_upload_' + r.status);
  const j = await r.json(); return BASE + '/storage/v1' + j.url;
}
async function objectExists(path: string) {
  const r = await fetch(BASE + '/storage/v1/object/info/' + BUCKET + '/' + path.split('/').map(enc).join('/'), { headers: { apikey: KEY, Authorization: 'Bearer ' + KEY } });
  return r.ok;
}

// ── 公司端身分 ──
async function staff(req: Request) {
  // 內部呼叫（資料庫排程／測試）：使用 vault 中的 hb_push_secret
  const internal = req.headers.get('x-hb-push-secret') || '';
  if (internal.length === 64 && (await db('rpc/hb_push_secret_ok', { method: 'POST', body: JSON.stringify({ p: internal }) })) === true) return { username: 'system', reviewer: false, scope: null as string | null };
  const t = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!t || t.split('.').length !== 3) return null;
  const r = await fetch(BASE + '/auth/v1/user', { headers: { apikey: KEY, Authorization: 'Bearer ' + t } }); if (!r.ok) return null;
  const u = await r.json(); if (!u?.id) return null;
  const rows = await db('hb_admins?user_id=eq.' + u.id + '&select=role,scope_project'); const row = rows?.[0]; if (!row?.role) return null;
  return { username: (u.email || 'admin') as string, reviewer: row.role === 'reviewer', scope: row.scope_project as string | null };
}
type Staff = NonNullable<Awaited<ReturnType<typeof staff>>>;
const scopeFilter = (s: Staff) => s.reviewer ? '&project_id=eq.' + (s.scope || '00000000-0000-0000-0000-000000000000') : '';
async function loadReq(s: Staff, id: string) {
  if (!/^[0-9a-f-]{36}$/i.test(id || '')) fail(400, '缺少確認單');
  const rows = await db('hb_confirm_requests?id=eq.' + id + scopeFilter(s) + '&select=*'); if (!rows?.[0]) fail(404, '找不到這筆確認'); return rows[0];
}
async function event(request_id: string, kind: string, text: string, by: string, meta: Record<string, unknown> = {}) {
  await db('hb_confirm_events', { method: 'POST', body: JSON.stringify({ request_id, kind, text, created_by: by, meta }), headers: { Prefer: 'return=minimal' } });
}
function summarize(r: any) {
  const items = (r.items || []) as any[], st = r.item_state || {};
  const counts = { ok: 0, change: 0, pending: 0 };
  for (const it of items) { const x = st[it.id]?.result; if (x === 'ok') counts.ok++; else if (x === 'change') counts.change++; else counts.pending++ }
  const { link_token, ...rest } = r;
  return { ...rest, counts, link_active: !!(link_token && !r.link_revoked_at) };
}
async function latestFiles(request_id: string) {
  const files = await db('hb_confirm_files?request_id=eq.' + request_id + '&select=*&order=version.desc') as any[];
  const latest: Record<string, any> = {};
  for (const f of files) if (!latest[f.group_key]) latest[f.group_key] = f;
  return { files, latest };
}
const fileSig = (fs: any[]) => fs.map((f: any) => f.group_key + ':' + f.version).sort().join('|');

async function staffRoute(req: Request, s: Staff, route: string, url: URL) {
  if (req.method === 'GET' && route === 'list') {
    const rows = await db('hb_confirm_requests?select=*&order=updated_at.desc&limit=300' + scopeFilter(s)) as any[];
    return rows.map(summarize);
  }
  if (req.method === 'GET' && route === 'get') {
    const r = await loadReq(s, url.searchParams.get('id') || '');
    const [{ files }, rounds, replies, events] = await Promise.all([
      latestFiles(r.id),
      db('hb_confirm_rounds?request_id=eq.' + r.id + '&select=*&order=round_no.desc'),
      db('hb_confirm_replies?request_id=eq.' + r.id + '&select=id,round_id,results,message,created_at,signer_name,signature&order=created_at.desc'),
      db('hb_confirm_events?request_id=eq.' + r.id + '&select=*&order=created_at.desc&limit=200')]);
    const paths = [...files.map((f: any) => f.path), ...(replies as any[]).flatMap((x: any) => (x.results || []).flatMap((y: any) => y.photos || []))];
    const urls = await signMany(paths);
    return { request: { ...summarize(r), link_token: r.link_revoked_at ? null : r.link_token },
      files: files.map((f: any) => ({ ...f, url: urls[f.path] || null })), rounds, events,
      replies: (replies as any[]).map((x: any) => ({ ...x, results: (x.results || []).map((y: any) => ({ ...y, photo_urls: (y.photos || []).map((p: string) => urls[p]).filter(Boolean) })) })) };
  }
  if (req.method !== 'POST') fail(404, 'Not found');
  const b = await body(req);
  if (route === 'save') {
    const items = Array.isArray(b.items) ? b.items.slice(0, 20).map((x: any) => ({ id: clean(x.id, 40) || crypto.randomUUID().slice(0, 8), title: clean(x.title, 120) })).filter((x: any) => x.title) : [];
    const patch: Record<string, unknown> = { title: clean(b.title, 120), intro: clean(b.intro, 600), items, due_date: isDate(b.due_date) ? b.due_date : null, project_id: /^[0-9a-f-]{36}$/i.test(b.project_id || '') ? b.project_id : null, updated_at: new Date().toISOString() };
    if (!patch.title) fail(400, '請填寫事項名稱');
    if (s.reviewer && patch.project_id !== s.scope) fail(403, '示範帳號只能使用示範案件');
    if (b.id) {
      const r = await loadReq(s, b.id); if (r.status === 'closed') fail(409, '已結案，請先重新開啟');
      const ids = new Set(items.map((x: any) => x.id)), st = { ...(r.item_state || {}) }; for (const k of Object.keys(st)) if (!ids.has(k)) delete st[k];
      const out = await db('hb_confirm_requests?id=eq.' + r.id, { method: 'PATCH', body: JSON.stringify({ ...patch, item_state: st }) });
      return { request: summarize(out[0]) };
    }
    const out = await db('hb_confirm_requests', { method: 'POST', body: JSON.stringify({ ...patch, created_by: s.username }) });
    await event(out[0].id, 'create', '建立確認單', s.username);
    return { request: summarize(out[0]) };
  }
  if (route === 'upload-url') {
    const r = await loadReq(s, b.request_id); const item = (r.items || []).find((x: any) => x.id === b.item_id); if (!item) fail(400, '請先選擇項目並儲存');
    const size = Number(b.size) || 0; if (size <= 0 || size > 50 * 1024 * 1024) fail(400, '檔案需小於 50MB');
    const mime = clean(b.mime, 100); if (!/^(application\/pdf|image\/)/.test(mime)) fail(400, '只支援 PDF 與圖片');
    let group = clean(b.group_key, 40), version = 1;
    if (group) { const rows = await db('hb_confirm_files?request_id=eq.' + r.id + '&group_key=eq.' + enc(group) + '&select=version&order=version.desc&limit=1'); if (!rows?.[0]) fail(400, '找不到原附件'); version = rows[0].version + 1 }
    else group = crypto.randomUUID().slice(0, 12);
    const path = r.id + '/' + group + '/v' + version + '-' + asciiName(String(b.name || ''));
    return { upload_url: await signUpload(path), path, group_key: group, version };
  }
  if (route === 'upload-done') {
    const r = await loadReq(s, b.request_id); const item = (r.items || []).find((x: any) => x.id === b.item_id); if (!item) fail(400, '項目不存在');
    const path = String(b.path || ''); if (!path.startsWith(r.id + '/' + b.group_key + '/v' + b.version + '-')) fail(400, '路徑錯誤');
    if (!(await objectExists(path))) fail(400, '檔案尚未上傳完成');
    try {
      const out = await db('hb_confirm_files', { method: 'POST', body: JSON.stringify({ request_id: r.id, item_id: b.item_id, group_key: b.group_key, version: b.version, name: clean(b.name, 120) || 'file', mime: clean(b.mime, 100), path, size: Number(b.size) || 0, created_by: s.username }) });
      await db('hb_confirm_requests?id=eq.' + r.id, { method: 'PATCH', body: JSON.stringify({ updated_at: new Date().toISOString() }), headers: { Prefer: 'return=minimal' } });
      await event(r.id, 'file', (b.version > 1 ? '上傳新版 ' : '加入附件 ') + clean(b.name, 120) + ' v' + b.version, s.username, { group_key: b.group_key, version: b.version, item_id: b.item_id });
      return { file: out[0] };
    } catch (e) { if (e instanceof HttpError && e.status === 409) fail(409, '同時有另一個新版上傳，請重新上傳'); throw e }
  }
  if (route === 'send') {
    const r = await loadReq(s, b.id); if (r.status === 'closed') fail(409, '已結案，請先重新開啟');
    const items = (r.items || []) as any[]; if (!items.length) fail(400, '請至少加入一個待確認項目');
    const due = isDate(b.due_date) ? b.due_date : r.due_date;
    const { latest } = await latestFiles(r.id);
    const prev = r.current_round ? (await db('hb_confirm_rounds?request_id=eq.' + r.id + '&round_no=eq.' + r.current_round + '&select=snapshot'))?.[0]?.snapshot : null;
    const st = r.item_state || {}, newState: Record<string, unknown> = {};
    const snapItems = items.map((it: any) => {
      const fs = Object.values(latest).filter((f: any) => f.item_id === it.id).map((f: any) => ({ file_id: f.id, group_key: f.group_key, version: f.version, name: f.name, mime: f.mime, path: f.path }));
      const before = prev?.items?.find((x: any) => x.id === it.id);
      const unchanged = before && before.title === it.title && fileSig(before.files || []) === fileSig(fs);
      const carried = unchanged && st[it.id]?.result === 'ok' ? { result: 'ok', round_no: st[it.id].round_no, reply_at: st[it.id].reply_at } : null;
      newState[it.id] = carried ? st[it.id] : { result: 'pending' };
      return { id: it.id, title: it.title, files: fs, carried };
    });
    if (!snapItems.some((x: any) => !x.carried)) fail(409, '所有項目都已確認且沒有新版本，不需要重新送出');
    const round_no = (r.current_round || 0) + 1;
    try { await db('hb_confirm_rounds', { method: 'POST', body: JSON.stringify({ request_id: r.id, round_no, snapshot: { items: snapItems, intro: r.intro }, due_date: due, sent_by: s.username }), headers: { Prefer: 'return=minimal' } }) }
    catch (e) { if (e instanceof HttpError && e.status === 409) fail(409, '剛剛已送出，請重新整理'); throw e }
    const now = new Date().toISOString();
    const patch: Record<string, unknown> = { current_round: round_no, sent_at: now, due_date: due, status: 'waiting', item_state: newState, updated_at: now };
    if (!r.link_token || r.link_revoked_at) { patch.link_token = token(); patch.link_created_at = now; patch.link_revoked_at = null }
    const out = await db('hb_confirm_requests?id=eq.' + r.id, { method: 'PATCH', body: JSON.stringify(patch) });
    const vers = snapItems.flatMap((x: any) => x.files.map((f: any) => f.name + ' v' + f.version)).join('、');
    const need = snapItems.filter((x: any) => !x.carried).length;
    await event(r.id, 'sent', '第 ' + round_no + ' 次送出確認：' + need + ' 項待回覆' + (vers ? '（' + vers + '）' : ''), s.username, { round_no });
    return { request: { ...summarize(out[0]), link_token: out[0].link_token } };
  }
  if (route === 'link') {
    const r = await loadReq(s, b.id); const now = new Date().toISOString();
    if (b.action === 'revoke') { await db('hb_confirm_requests?id=eq.' + r.id, { method: 'PATCH', body: JSON.stringify({ link_revoked_at: now, updated_at: now }), headers: { Prefer: 'return=minimal' } }); await event(r.id, 'revoke', '已撤銷確認連結', s.username); return { link_token: null } }
    const t = token(); await db('hb_confirm_requests?id=eq.' + r.id, { method: 'PATCH', body: JSON.stringify({ link_token: t, link_created_at: now, link_revoked_at: null, updated_at: now }), headers: { Prefer: 'return=minimal' } });
    await event(r.id, 'link', r.link_token ? '已重新產生確認連結（舊連結失效）' : '已產生確認連結', s.username); return { link_token: t };
  }
  if (route === 'note') {
    const r = await loadReq(s, b.id); const text = clean(b.text, 1000); if (!text) fail(400, '請輸入內容');
    await event(r.id, 'note', text, s.username); await db('hb_confirm_requests?id=eq.' + r.id, { method: 'PATCH', body: JSON.stringify({ updated_at: new Date().toISOString() }), headers: { Prefer: 'return=minimal' } }); return { ok: true };
  }
  if (route === 'close') {
    const r = await loadReq(s, b.id); const closing = !!b.closed;
    const st = r.item_state || {}, items = r.items || [];
    const status = closing ? 'closed' : !r.current_round ? 'draft' : items.some((x: any) => st[x.id]?.result === 'change') ? 'changes' : items.every((x: any) => st[x.id]?.result === 'ok') ? 'confirmed' : 'waiting';
    const out = await db('hb_confirm_requests?id=eq.' + r.id, { method: 'PATCH', body: JSON.stringify({ status, updated_at: new Date().toISOString() }) });
    await event(r.id, closing ? 'close' : 'reopen', closing ? '已結案' : '重新開啟', s.username); return { request: summarize(out[0]) };
  }
  if (route === 'delete') {
    // 只能刪除從未送出的草稿（業主沒看過、沒有任何回覆）
    const r = await loadReq(s, b.id);
    if (r.status !== 'draft' || r.current_round) fail(409, '已送出的確認不能刪除，可以改用「結案」');
    const files = await db('hb_confirm_files?request_id=eq.' + r.id + '&select=path') as any[];
    const paths = (files || []).map((f: any) => f.path).filter(Boolean);
    if (paths.length) {
      await fetch(BASE + '/storage/v1/object/' + BUCKET, { method: 'DELETE', headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ prefixes: paths }) }).catch(() => null);
    }
    await db('hb_confirm_requests?id=eq.' + r.id + '&status=eq.draft', { method: 'DELETE', headers: { Prefer: 'return=minimal' } });
    return { ok: true };
  }
  fail(404, 'Not found');
}

// ── 業主端（確認連結） ──
async function byToken(t: string) {
  if (!t || t.length < 20 || t.length > 64 || !/^[\w-]+$/.test(t)) fail(403, '連結無效');
  const rows = await db('hb_confirm_requests?link_token=eq.' + enc(t) + '&link_revoked_at=is.null&select=*');
  const r = rows?.[0]; if (!r || !r.current_round) fail(403, '連結無效或已失效，請向設計師索取新連結');
  return r;
}
async function publicRoute(req: Request, route: string, url: URL) {
  const r = await byToken(req.headers.get('x-hb-confirm') || url.searchParams.get('t') || '');
  if (req.method === 'GET' && route === 'view') {
    const [proj, rounds, replies] = await Promise.all([
      r.project_id ? db('sitelog_projects?id=eq.' + r.project_id + '&select=name') : Promise.resolve([]),
      db('hb_confirm_rounds?request_id=eq.' + r.id + '&select=id,round_no,snapshot,due_date,sent_at&order=round_no.desc'),
      db('hb_confirm_replies?request_id=eq.' + r.id + '&select=id,round_id,results,message,created_at,signer_name,signature&order=created_at.desc')]);
    const cur = (rounds as any[])[0];
    const paths = [...(cur?.snapshot?.items || []).flatMap((x: any) => (x.files || []).map((f: any) => f.path)), ...(replies as any[]).flatMap((x: any) => (x.results || []).flatMap((y: any) => y.photos || []))];
    const urls = await signMany(paths);
    const strip = (it: any) => ({ id: it.id, title: it.title, carried: it.carried, files: (it.files || []).map((f: any) => ({ name: f.name, mime: f.mime, version: f.version, group_key: f.group_key, url: urls[f.path] || null })) });
    const roundNo = new Map((rounds as any[]).map((x: any) => [x.id, x.round_no]));
    return { project: proj?.[0]?.name || '', title: r.title, status: r.status, closed: r.status === 'closed',
      round: cur ? { id: cur.id, round_no: cur.round_no, sent_at: cur.sent_at, due_date: cur.due_date, intro: cur.snapshot?.intro || r.intro, items: (cur.snapshot?.items || []).map(strip) } : null,
      replies: (replies as any[]).map((x: any) => ({ round_no: roundNo.get(x.round_id), current: x.round_id === cur?.id, created_at: x.created_at, message: x.message, signer_name: x.signer_name || '', signature: x.signature || '',
        results: (x.results || []).map((y: any) => ({ item_id: y.item_id, title: y.title, result: y.result, comment: y.comment, files: y.files, photo_urls: (y.photos || []).map((p: string) => urls[p]).filter(Boolean) })) })) };
  }
  if (req.method !== 'POST') fail(404, 'Not found');
  if (r.status === 'closed') fail(409, '這筆確認已結案，如需調整請聯絡設計師');
  const b = await body(req);
  if (route === 'photo-url') {
    const size = Number(b.size) || 0, mime = clean(b.mime, 60);
    if (!/^image\//.test(mime) || size <= 0 || size > 15 * 1024 * 1024) fail(400, '照片需小於 15MB');
    const path = r.id + '/replies/' + crypto.randomUUID() + '.' + (mime.split('/')[1] || 'jpg').replace(/[^a-z0-9]/g, '').slice(0, 5);
    return { upload_url: await signUpload(path), path };
  }
  if (route === 'submit') {
    const nonce = clean(b.nonce, 64); if (nonce.length < 8) fail(400, '資料格式錯誤');
    const dup = await db('hb_confirm_replies?nonce=eq.' + enc(nonce) + '&request_id=eq.' + r.id + '&select=id,created_at');
    if (dup?.[0]) return { ok: true, duplicate: true, created_at: dup[0].created_at };
    const cur = (await db('hb_confirm_rounds?request_id=eq.' + r.id + '&round_no=eq.' + r.current_round + '&select=id,round_no,snapshot'))?.[0];
    if (!cur || cur.id !== b.round_id) fail(409, '設計師已更新內容，請重新整理後再回覆');
    const done = await db('hb_confirm_replies?round_id=eq.' + cur.id + '&select=id'); if (done?.[0]) fail(409, '這個版本已經回覆過了');
    const need = (cur.snapshot.items || []).filter((x: any) => !x.carried);
    const given = new Map((Array.isArray(b.results) ? b.results : []).map((x: any) => [String(x.item_id), x]));
    const results = [] as any[];
    for (const it of need) {
      const x: any = given.get(it.id); if (!x || !['ok', 'change'].includes(x.result)) fail(400, '請回覆每一個項目');
      const comment = clean(x.comment, 1000); if (x.result === 'change' && !comment) fail(400, '「' + it.title + '」需要填寫修改意見');
      const photos = (Array.isArray(x.photos) ? x.photos : []).slice(0, 6).map(String).filter((p: string) => p.startsWith(r.id + '/replies/') && !p.includes('..'));
      results.push({ item_id: it.id, title: it.title, result: x.result, comment, photos, files: (it.files || []).map((f: any) => ({ group_key: f.group_key, version: f.version, name: f.name })) });
    }
    // 全部確認時需業主簽名（PNG data URL，限制大小）
    const allOk = results.every(x => x.result === 'ok');
    let signature = '', signer_name = '';
    if (allOk) {
      signer_name = clean(b.signer_name, 40); signature = String(b.signature || '');
      if (!signer_name) fail(400, '請填寫簽名人姓名');
      if (!/^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(signature) || signature.length > 200000) fail(400, '請在簽名框內簽名');
    }
    let reply;
    try { reply = (await db('hb_confirm_replies', { method: 'POST', body: JSON.stringify({ request_id: r.id, round_id: cur.id, nonce, results, message: clean(b.message, 1000), ua: clean(req.headers.get('user-agent'), 200), signer_name: signer_name || null, signature: signature || null }) }))[0] }
    catch (e) { if (e instanceof HttpError && e.status === 409) { const again = await db('hb_confirm_replies?nonce=eq.' + enc(nonce) + '&select=created_at'); if (again?.[0]) return { ok: true, duplicate: true, created_at: again[0].created_at }; fail(409, '這個版本已經回覆過了') } throw e }
    const st = { ...(r.item_state || {}) };
    for (const x of results) st[x.item_id] = { result: x.result, round_no: cur.round_no, reply_at: reply.created_at, comment: x.comment };
    const items = r.items || [];
    const status = items.some((x: any) => st[x.id]?.result === 'change') ? 'changes' : items.every((x: any) => st[x.id]?.result === 'ok') ? 'confirmed' : 'waiting';
    await db('hb_confirm_requests?id=eq.' + r.id, { method: 'PATCH', body: JSON.stringify({ item_state: st, status, replied_at: reply.created_at, updated_at: reply.created_at }), headers: { Prefer: 'return=minimal' } });
    const ok = results.filter(x => x.result === 'ok').length, ch = results.length - ok;
    await event(r.id, 'reply', '業主回覆：' + ok + ' 項確認' + (ch ? '、' + ch + ' 項需要修改' : '') + (signer_name ? '（' + signer_name + ' 已簽名）' : ''), '業主', { round_no: cur.round_no, reply_id: reply.id, signed: !!signer_name });
    return { ok: true, created_at: reply.created_at, status };
  }
  fail(404, 'Not found');
}

Deno.serve(async (req: Request) => {
  try {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(req) });
    const url = new URL(req.url), parts = url.pathname.split('/').filter(Boolean), i = parts.indexOf('hb-confirm-api');
    const [scope, route] = parts.slice(i + 1);
    if (scope === 'health') return json(req, { ok: true, version: '2026-10-08.1' });
    if (scope === 'public') return json(req, await publicRoute(req, route || '', url));
    if (scope === 'staff') { const s = await staff(req); if (!s) return json(req, { error: '請重新登入' }, 401); return json(req, await staffRoute(req, s, route || '', url)) }
    return json(req, { error: 'Not found' }, 404);
  } catch (e) {
    if (e instanceof HttpError) return json(req, { error: e.message }, e.status);
    console.error(e); return json(req, { error: '伺服器暫時無法處理，請稍後再試' }, 500);
  }
});
