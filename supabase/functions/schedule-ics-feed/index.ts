// Supabase Edge Function: schedule-ics-feed
// 用途：提供 iPhone／Google 行事曆訂閱的 .ics：客戶預約＋行程表＋今日待辦（有日期的手動待辦）＋LINE 群組約定。
// 2026-09-30：改成必須帶私密金鑰 ?t=...（網址只給登入的管理端看），避免客戶電話地址外流。
// 2026-09-30：App 審核用的示範案件（hb_admins reviewer 的 scope_project）不放進行事曆。
// 2026-10-13：加入案件 LINE 群組裡提到的約定（hb_line_appts，狀態 open；在工作台標完成或刪除的不放）。
// 2026-11-11：可拆成三個行事曆訂閱（?cal=work 工程／meet 約定／todo 待辦；不帶＝全部，舊連結照常）；
//             補上工班排程（hb_crew_jobs）；標題統一「案名｜事項」；工程類帶案件地址；
//             工作台裡對自動事項的修改（完成、移除、改日期時間標題）一律套用。

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const pad2 = (n: number) => String(n).padStart(2, "0");
function icsEscape(s: string) {
  return String(s || "").replace(/\\/g, "\\\\").replace(/\r?\n/g, "\\n").replace(/,/g, "\\,").replace(/;/g, "\\;");
}
const fmtLocal = (dt: Date) => `${dt.getFullYear()}${pad2(dt.getMonth() + 1)}${pad2(dt.getDate())}T${pad2(dt.getHours())}${pad2(dt.getMinutes())}00`;
const fmtUTC = (dt: Date) => `${dt.getUTCFullYear()}${pad2(dt.getUTCMonth() + 1)}${pad2(dt.getUTCDate())}T${pad2(dt.getUTCHours())}${pad2(dt.getUTCMinutes())}${pad2(dt.getUTCSeconds())}Z`;
const fmtDateOnly = (s: string) => s.replaceAll("-", "");
function addDays(dateStr: string, days: number) {
  const [y, m, d] = dateStr.split("-").map(Number);
  const dt = new Date(y, m - 1, d + days);
  return `${dt.getFullYear()}-${pad2(dt.getMonth() + 1)}-${pad2(dt.getDate())}`;
}
const isDate = (s: unknown) => /^\d{4}-\d{2}-\d{2}$/.test(String(s || ""));
const toHM = (s: unknown) => { const m = /^(\d{1,2}):(\d{2})/.exec(String(s || "")); return m ? [Number(m[1]), Number(m[2])] : null; };
function taipeiToday() { return new Intl.DateTimeFormat("sv-SE", { timeZone: "Asia/Taipei" }).format(new Date()); }

const SCHEDULE_TYPE_LABEL: Record<string, string> = { consult: "諮詢預約", site: "案件行程", personal: "私人行程", other: "其他" };

const CALS: Record<string, { name: string; color: string }> = {
  all: { name: "赫柏空間設計 行程表", color: "#2E4A3C" },
  work: { name: "赫柏・工程", color: "#2E4A3C" },
  meet: { name: "赫柏・約定", color: "#B4573A" },
  todo: { name: "赫柏・待辦", color: "#8F887A" },
};
// 案件短名：去掉「X公館／小姐／先生／設計案」等尾巴，太長取前 5 字
function shortName(name: string) {
  let n = String(name || "").trim();
  const o = n;
  n = n.replace(/[一-鿿]公館$/, "").replace(/(小姐|先生|太太)$/, "").replace(/(設計案|翻新案)$/, "").trim();
  if (!n) n = o;
  return n.length > 6 ? n.slice(0, 5) : n;
}
const clean = (s: unknown, max = 30) => {
  const t = String(s || "").replace(/^LINE 約定・/, "").replace(/@/g, "").replace(/\s+/g, " ").trim();
  return t.length > max ? t.slice(0, max) + "…" : t;
};

Deno.serve(async (req: Request) => {
  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const qs = new URL(req.url).searchParams;
  const t = qs.get("t") || "";
  const cal = (qs.get("cal") || "all") in CALS ? (qs.get("cal") || "all") : "all";
  const want = (c: string) => cal === "all" || cal === c;
  if (!/^[0-9a-f]{64}$/.test(t)) return new Response("需要訂閱金鑰，請到工地紀錄本重新取得行事曆連結", { status: 403 });
  const { data: key } = await sb.from("hb_calendar_feed").select("token").eq("id", 1).maybeSingle();
  if (!key || key.token !== t) return new Response("訂閱連結已失效，請到工地紀錄本重新取得", { status: 403 });

  const since = addDays(taipeiToday(), -14);
  const [{ data: bookings, error: e1 }, { data: events, error: e2 }, { data: todo }, { data: reviewers }, { data: appts }, { data: projs }, { data: crews }, { data: crewNames }] = await Promise.all([
    sb.from("sitelog_bookings").select("*").in("status", ["pending", "confirmed"]),
    sb.from("sitelog_schedule_events").select("*").neq("status", "cancelled"),
    sb.from("hb_today_cloud").select("payload").eq("workspace", "company").maybeSingle(),
    sb.from("hb_admins").select("scope_project").eq("role", "reviewer"),
    sb.from("hb_line_appts").select("id,project_id,appt_date,appt_time,body,sender_name,status").eq("status", "open").gte("appt_date", since),
    sb.from("sitelog_projects").select("id,name,address"),
    sb.from("hb_crew_jobs").select("id,project_id,crew_id,crew_name,trade,start_date,end_date,start_time,note,status").eq("status", "planned"),
    sb.from("hb_crew").select("id,name,trade"),
  ]);
  if (e1 || e2) return new Response("讀取資料失敗", { status: 500 });
  const demo = new Set((reviewers || []).map((r: any) => r.scope_project).filter(Boolean));
  const proj = new Map((projs || []).map((p: any) => [p.id, p]));
  const pname = (id: string) => (id && proj.get(id)?.name) || "";
  const paddr = (id: string) => (id && proj.get(id)?.address) || "";
  const tag = (id: string) => { const n = pname(id); return n ? shortName(n) + "｜" : ""; };
  // 事項本身若又以案名開頭（例「金石龍悅冷氣配管」），去掉重複的案名
  const strip = (txt: string, id: string) => { const n = pname(id), sn = n ? shortName(n) : ""; let x = txt; for (const k of [n, sn]) if (k && x.startsWith(k) && x.length > k.length) { x = x.slice(k.length).replace(/^[\s｜|:：・-]+/, ""); break; } return x; };
  const seen = new Set<string>();
  const ov: Record<string, any> = (todo?.payload?.overrides && typeof todo.payload.overrides === "object") ? todo!.payload.overrides : {};
  const crewMap = new Map((crewNames || []).map((c: any) => [c.id, c]));

  const C = CALS[cal];
  const lines: string[] = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Herfulsins Interior Design//Schedule Feed//ZH-TW", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
    `X-WR-CALNAME:${icsEscape(C.name)}`, `X-APPLE-CALENDAR-COLOR:${C.color}`, "X-WR-TIMEZONE:Asia/Taipei", "REFRESH-INTERVAL;VALUE=DURATION:PT1H", "X-PUBLISHED-TTL:PT1H",
  ];
  const stamp = new Date();
  // 共用：輸出一筆（timed 或整天／多天）
  const push = (o: { uid: string; title: string; date: string; endDate?: string; time?: unknown; mins?: number; loc?: string; desc?: string; alarm?: boolean }) => {
    const k = o.date + "|" + o.title; if (seen.has(k)) return; seen.add(k); // 同一天同標題只留一筆
    lines.push("BEGIN:VEVENT", `UID:${o.uid}@herfulsins-schedule`, `DTSTAMP:${fmtUTC(stamp)}`);
    const hm = toHM(o.time);
    if (hm && (!o.endDate || o.endDate === o.date)) {
      const [y, m, d] = o.date.split("-").map(Number);
      const start = new Date(y, m - 1, d, hm[0], hm[1]);
      lines.push(`DTSTART:${fmtLocal(start)}`, `DTEND:${fmtLocal(new Date(start.getTime() + (o.mins || 60) * 60 * 1000))}`);
      if (o.alarm) lines.push("BEGIN:VALARM", "ACTION:DISPLAY", `DESCRIPTION:${icsEscape(o.title)}`, "TRIGGER:-PT1H", "END:VALARM");
    } else {
      const endD = o.endDate && isDate(o.endDate) && o.endDate >= o.date ? o.endDate : o.date;
      lines.push(`DTSTART;VALUE=DATE:${fmtDateOnly(o.date)}`, `DTEND;VALUE=DATE:${fmtDateOnly(addDays(endD, 1))}`);
    }
    lines.push(`SUMMARY:${icsEscape(o.title)}`, o.loc ? `LOCATION:${icsEscape(o.loc)}` : "", o.desc ? `DESCRIPTION:${icsEscape(o.desc)}` : "", "END:VEVENT");
  };

  /* 約定：客戶預約 */
  if (want("meet")) for (const b of bookings || []) {
    if (!isDate(b.date)) continue;
    const desc = [`聯絡人：${b.name || ""}`, `電話：${b.phone || ""}`];
    if (b.note) desc.push(`需求簡述：${b.note}`);
    push({ uid: `booking-${b.id}`, title: `客戶預約｜${b.service_type || "諮詢"}－${b.name || ""}`, date: String(b.date), time: b.time || "00:00", loc: b.address || "", desc: desc.join("\n"), alarm: true });
  }

  /* 工程行程（諮詢類放「約定」、私人行程放「待辦」，其餘放「工程」） */
  for (const s of events || []) {
    if (!isDate(s.start_date)) continue;
    if (s.project_id && demo.has(s.project_id)) continue;
    const c = s.type === "consult" ? "meet" : s.type === "personal" ? "todo" : "work";
    if (!want(c)) continue;
    const o = ov["schedule:" + s.id] || {};
    if (o.deleted || o.done || s.status === "completed") continue;
    const date = isDate(o.due) ? o.due : String(s.start_date).slice(0, 10);
    if (date < since && !(isDate(s.end_date) && s.end_date >= since)) continue;
    const desc: string[] = [];
    if (s.project_name || s.project_id) desc.push(`案件：${s.project_name || pname(s.project_id)}`);
    if (s.assignee) desc.push(`負責人／工班：${s.assignee}`);
    if (s.note) desc.push(`備註：${s.note}`);
    if (SCHEDULE_TYPE_LABEL[s.type]) desc.push(`類型：${SCHEDULE_TYPE_LABEL[s.type]}`);
    const title = (s.project_id ? tag(s.project_id) : (s.project_name ? shortName(s.project_name) + "｜" : "")) + strip(clean(o.title || s.title || "行程", 22), s.project_id);
    const time = o.time !== undefined ? o.time : (s.all_day ? "" : s.time);
    push({ uid: `schedule-${s.id}`, title, date, endDate: isDate(o.due) ? o.due : s.end_date, time, loc: s.location || paddr(s.project_id), desc: desc.join("\n") });
  }

  /* 工程：工班排程（多天的畫成一條） */
  if (want("work")) for (const j of crews || []) {
    if (!isDate(j.start_date)) continue;
    if (j.project_id && demo.has(j.project_id)) continue;
    const o = ov["crew:" + j.id] || {};
    if (o.deleted || o.done) continue;
    const end = isDate(j.end_date) ? j.end_date : j.start_date;
    if (end < since) continue;
    const cr = crewMap.get(j.crew_id) || {};
    const who = j.crew_name || cr.name || "";
    const trade = j.trade || cr.trade || "工班";
    const desc = [`案件：${pname(j.project_id)}`, `工項：${trade}`, who ? `師傅：${who}` : "", j.start_time ? `每天開工：${String(j.start_time).slice(0, 5)}` : "", j.note ? `備註：${j.note}` : "", "來自工班排程（官方 LINE 會在前一天提醒師傅）"].filter(Boolean);
    push({ uid: `crew-${j.id}`, title: tag(j.project_id) + trade + (who ? `（${who}）` : ""), date: String(j.start_date).slice(0, 10), endDate: String(end).slice(0, 10), loc: paddr(j.project_id), desc: desc.join("\n") });
  }

  /* 待辦：有日期的手動待辦 */
  const manual: any[] = Array.isArray(todo?.payload?.manual) ? todo!.payload.manual : [];
  if (want("todo")) for (const tk of manual) {
    if (!tk || tk.deleted || tk.done || !isDate(tk.due) || tk.due < since || !tk.id) continue;
    if (tk.projectId && demo.has(tk.projectId)) continue;
    const uid = String(tk.id).replace(/[^A-Za-z0-9-]/g, "").slice(0, 60);
    const kind = tk.kind === "follow" ? "追蹤・" : tk.category === "採購" ? "採購・" : "";
    const desc = [tk.projectId ? `案件：${pname(tk.projectId)}` : "公司事務", tk.waitingFor ? `等待：${tk.waitingFor}` : "", tk.note ? String(tk.note).slice(0, 1000) : ""].filter(Boolean);
    let mins = 60; const he = toHM(tk.end), hs = toHM(tk.time);
    if (he && hs) { const d = (he[0] * 60 + he[1]) - (hs[0] * 60 + hs[1]); if (d > 0) mins = d; }
    push({ uid: `todo-${uid}`, title: tag(tk.projectId) + kind + strip(clean(tk.title, 30), tk.projectId), date: tk.due, time: tk.time, mins, desc: desc.join("\n") });
  }

  /* 約定：LINE 群組約定（工作台裡完成／移除／改日期時間標題的，以工作台為準） */
  if (want("meet")) for (const a of appts || []) {
    if (a.project_id && demo.has(a.project_id)) continue;
    const o = ov["appt:" + a.id] || {};
    if (o.deleted || o.done) continue;
    const due = isDate(o.due) ? o.due : String(a.appt_date).slice(0, 10);
    if (!isDate(due)) continue;
    const tm = o.time !== undefined ? o.time : a.appt_time;
    const desc = (a.sender_name ? a.sender_name + " 在 LINE 群組說：" : "LINE 群組：") + "「" + String(a.body || "").slice(0, 500) + "」" + (a.project_id ? `\n案件：${pname(a.project_id)}` : "");
    push({ uid: `lineappt-${a.id}`, title: tag(a.project_id) + strip(clean(o.title || a.body, 18), a.project_id), date: due, time: tm, desc, alarm: true });
  }

  lines.push("END:VCALENDAR");
  return new Response(lines.filter(Boolean).join("\r\n"), {
    headers: { "Content-Type": "text/calendar; charset=utf-8", "Content-Disposition": `inline; filename="herfulsins-${cal}.ics"`, "Cache-Control": "no-store" },
  });
});
