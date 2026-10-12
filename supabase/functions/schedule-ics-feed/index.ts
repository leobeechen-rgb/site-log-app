// Supabase Edge Function: schedule-ics-feed
// 用途：提供 iPhone／Google 行事曆訂閱的 .ics：客戶預約＋行程表＋今日待辦（有日期的手動待辦）＋LINE 群組約定。
// 2026-09-30：改成必須帶私密金鑰 ?t=...（網址只給登入的管理端看），避免客戶電話地址外流。
// 2026-09-30：App 審核用的示範案件（hb_admins reviewer 的 scope_project）不放進行事曆。
// 2026-10-13：加入案件 LINE 群組裡提到的約定（hb_line_appts，狀態 open；在工作台標完成或刪除的不放）。

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

Deno.serve(async (req: Request) => {
  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const t = new URL(req.url).searchParams.get("t") || "";
  if (!/^[0-9a-f]{64}$/.test(t)) return new Response("需要訂閱金鑰，請到工地紀錄本重新取得行事曆連結", { status: 403 });
  const { data: key } = await sb.from("hb_calendar_feed").select("token").eq("id", 1).maybeSingle();
  if (!key || key.token !== t) return new Response("訂閱連結已失效，請到工地紀錄本重新取得", { status: 403 });

  const since = addDays(taipeiToday(), -14);
  const [{ data: bookings, error: e1 }, { data: events, error: e2 }, { data: todo }, { data: reviewers }, { data: appts }, { data: projs }] = await Promise.all([
    sb.from("sitelog_bookings").select("*").in("status", ["pending", "confirmed"]),
    sb.from("sitelog_schedule_events").select("*").neq("status", "cancelled"),
    sb.from("hb_today_cloud").select("payload").eq("workspace", "company").maybeSingle(),
    sb.from("hb_admins").select("scope_project").eq("role", "reviewer"),
    sb.from("hb_line_appts").select("id,project_id,appt_date,appt_time,body,sender_name,status").eq("status", "open").gte("appt_date", since),
    sb.from("sitelog_projects").select("id,name"),
  ]);
  if (e1 || e2) return new Response("讀取資料失敗", { status: 500 });
  const demo = new Set((reviewers || []).map((r: any) => r.scope_project).filter(Boolean));
  const pname = new Map((projs || []).map((p: any) => [p.id, p.name]));

  const lines: string[] = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Herfulsins Interior Design//Schedule Feed//ZH-TW", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
    "X-WR-CALNAME:赫柏空間設計 行程表", "X-WR-TIMEZONE:Asia/Taipei", "REFRESH-INTERVAL;VALUE=DURATION:PT1H", "X-PUBLISHED-TTL:PT1H",
  ];
  const stamp = new Date();

  for (const b of bookings || []) {
    if (!isDate(b.date)) continue;
    const hm = toHM(b.time) || [0, 0];
    const [y, m, d] = String(b.date).split("-").map(Number);
    const start = new Date(y, m - 1, d, hm[0], hm[1]);
    const end = new Date(start.getTime() + 60 * 60 * 1000);
    const desc = [`聯絡人：${b.name || ""}`, `電話：${b.phone || ""}`];
    if (b.note) desc.push(`需求簡述：${b.note}`);
    lines.push("BEGIN:VEVENT", `UID:booking-${b.id}@herfulsins-schedule`, `DTSTAMP:${fmtUTC(stamp)}`, `DTSTART:${fmtLocal(start)}`, `DTEND:${fmtLocal(end)}`,
      `SUMMARY:${icsEscape("客戶預約：" + (b.service_type || "") + "－" + (b.name || ""))}`, b.address ? `LOCATION:${icsEscape(b.address)}` : "",
      `DESCRIPTION:${icsEscape(desc.join("\n"))}`, "END:VEVENT");
  }

  for (const s of events || []) {
    if (!isDate(s.start_date)) continue;
    if (s.project_id && demo.has(s.project_id)) continue;
    const typeLabel = SCHEDULE_TYPE_LABEL[s.type] || s.type || "";
    const summary = (typeLabel ? `【${typeLabel}】` : "") + (s.title || "") + (s.project_name ? `（${s.project_name}）` : "");
    const desc: string[] = [];
    if (s.project_name) desc.push(`關聯案件：${s.project_name}`);
    if (s.assignee) desc.push(`負責人／工班：${s.assignee}`);
    if (s.note) desc.push(`備註：${s.note}`);
    lines.push("BEGIN:VEVENT", `UID:schedule-${s.id}@herfulsins-schedule`, `DTSTAMP:${fmtUTC(stamp)}`);
    const hm = toHM(s.time);
    if (s.all_day || !hm) {
      const endD = isDate(s.end_date) && s.end_date >= s.start_date ? s.end_date : s.start_date;
      lines.push(`DTSTART;VALUE=DATE:${fmtDateOnly(s.start_date)}`, `DTEND;VALUE=DATE:${fmtDateOnly(addDays(endD, 1))}`);
    } else {
      const [y, m, d] = String(s.start_date).split("-").map(Number);
      const start = new Date(y, m - 1, d, hm[0], hm[1]);
      lines.push(`DTSTART:${fmtLocal(start)}`, `DTEND:${fmtLocal(new Date(start.getTime() + 60 * 60 * 1000))}`);
    }
    lines.push(`SUMMARY:${icsEscape(summary)}`, s.location ? `LOCATION:${icsEscape(s.location)}` : "", desc.length ? `DESCRIPTION:${icsEscape(desc.join("\n"))}` : "", "END:VEVENT");
  }

  /* 今日待辦：有日期的手動待辦（未完成、未刪除；過去 14 天以後的） */
  const manual: any[] = Array.isArray(todo?.payload?.manual) ? todo!.payload.manual : [];
  for (const t of manual) {
    if (!t || t.deleted || t.done || !isDate(t.due) || t.due < since || !t.id) continue;
    if (t.projectId && demo.has(t.projectId)) continue;
    const uid = String(t.id).replace(/[^A-Za-z0-9-]/g, "").slice(0, 60);
    const title = (t.category === "採購" ? "【採購】" : "【待辦】") + String(t.title || "").slice(0, 200);
    lines.push("BEGIN:VEVENT", `UID:todo-${uid}@herfulsins-schedule`, `DTSTAMP:${fmtUTC(stamp)}`);
    const hm = toHM(t.time);
    if (hm) {
      const [y, m, d] = String(t.due).split("-").map(Number);
      const start = new Date(y, m - 1, d, hm[0], hm[1]);
      const he = toHM(t.end);
      let end = he ? new Date(y, m - 1, d, he[0], he[1]) : new Date(start.getTime() + 60 * 60 * 1000);
      if (end <= start) end = new Date(start.getTime() + 60 * 60 * 1000);
      lines.push(`DTSTART:${fmtLocal(start)}`, `DTEND:${fmtLocal(end)}`);
    } else {
      lines.push(`DTSTART;VALUE=DATE:${fmtDateOnly(t.due)}`, `DTEND;VALUE=DATE:${fmtDateOnly(addDays(t.due, 1))}`);
    }
    lines.push(`SUMMARY:${icsEscape(title)}`, t.note ? `DESCRIPTION:${icsEscape(String(t.note).slice(0, 1000))}` : "", "END:VEVENT");
  }

  /* LINE 群組約定：工作台裡標完成／刪除／改日期的，以工作台為準 */
  const ov: Record<string, any> = (todo?.payload?.overrides && typeof todo.payload.overrides === "object") ? todo!.payload.overrides : {};
  for (const a of appts || []) {
    if (a.project_id && demo.has(a.project_id)) continue;
    const o = ov["appt:" + a.id] || {};
    if (o.deleted || o.done) continue;
    const due = isDate(o.due) ? o.due : String(a.appt_date).slice(0, 10);
    if (!isDate(due)) continue;
    const tm = o.time !== undefined ? o.time : a.appt_time;
    const proj = a.project_id ? pname.get(a.project_id) : "";
    const title = "【LINE 約定】" + String(o.title || a.body || "").replace(/^LINE 約定・/, "").replace(/\s+/g, " ").slice(0, 60) + (proj ? `（${proj}）` : "");
    const desc = (a.sender_name ? a.sender_name + " 在 LINE 群組說：" : "LINE 群組：") + "「" + String(a.body || "").slice(0, 500) + "」";
    lines.push("BEGIN:VEVENT", `UID:lineappt-${a.id}@herfulsins-schedule`, `DTSTAMP:${fmtUTC(stamp)}`);
    const hm = toHM(tm);
    if (hm) {
      const [y, m, d] = due.split("-").map(Number);
      const start = new Date(y, m - 1, d, hm[0], hm[1]);
      lines.push(`DTSTART:${fmtLocal(start)}`, `DTEND:${fmtLocal(new Date(start.getTime() + 60 * 60 * 1000))}`, "BEGIN:VALARM", "ACTION:DISPLAY", `DESCRIPTION:${icsEscape(title)}`, "TRIGGER:-PT1H", "END:VALARM");
    } else {
      lines.push(`DTSTART;VALUE=DATE:${fmtDateOnly(due)}`, `DTEND;VALUE=DATE:${fmtDateOnly(addDays(due, 1))}`);
    }
    lines.push(`SUMMARY:${icsEscape(title)}`, `DESCRIPTION:${icsEscape(desc)}`, "END:VEVENT");
  }

  lines.push("END:VCALENDAR");
  return new Response(lines.filter(Boolean).join("\r\n"), {
    headers: { "Content-Type": "text/calendar; charset=utf-8", "Content-Disposition": 'inline; filename="herfulsins-schedule.ics"', "Cache-Control": "no-store" },
  });
});
