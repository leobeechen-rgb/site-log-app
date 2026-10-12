-- 案件 LINE 群組裡提到的約定 → hb_line_appts（工作台待辦自動列出）＋通知設計師
-- 已用 apply_migration 套用（line_group_appointments）；此檔為紀錄。
create table if not exists public.hb_line_appts (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  event_id text unique,
  project_id uuid references public.sitelog_projects(id) on delete cascade,
  appt_date date not null,
  appt_time text check (appt_time is null or appt_time ~ '^\d{2}:\d{2}$'),
  body text not null check (length(body) <= 500),
  sender_name text,
  status text not null default 'open' check (status in ('open','done','dismissed'))
);
-- RLS：admin only；hb_line_appt_add(p_event,p_key,p_sender,p_sender_name,p_text,p_date,p_time) security definer，只給 service role。
