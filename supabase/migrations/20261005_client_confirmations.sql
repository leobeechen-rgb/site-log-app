-- 業主確認＋附件（已於 2026-10-05 套用到 Supabase 專案 rqndozhhvuimqjqtmeli）
-- 資料表只允許 Edge Function（service role）存取；瀏覽器端無法直接讀寫。
create table if not exists public.hb_confirm_requests (
  id uuid primary key default gen_random_uuid(),
  project_id uuid references public.sitelog_projects(id) on delete set null,
  title text not null default '', intro text not null default '',
  items jsonb not null default '[]'::jsonb,            -- [{id,title}]
  due_date date,
  status text not null default 'draft',                -- draft / waiting / changes / confirmed / closed
  item_state jsonb not null default '{}'::jsonb,        -- {item_id:{result,round_no,reply_at,comment}}
  current_round int not null default 0,
  sent_at timestamptz, replied_at timestamptz,
  link_token text unique, link_created_at timestamptz, link_revoked_at timestamptz,
  created_by text, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.hb_confirm_files (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.hb_confirm_requests(id) on delete cascade,
  item_id text not null, group_key text not null, version int not null,
  name text not null, mime text not null default '', path text not null, size bigint not null default 0,
  created_by text, created_at timestamptz not null default now(),
  unique (request_id, group_key, version));
create table if not exists public.hb_confirm_rounds (           -- 每次送出的快照（項目＋當時附件版本）
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.hb_confirm_requests(id) on delete cascade,
  round_no int not null, snapshot jsonb not null, due_date date, sent_by text, sent_at timestamptz not null default now(),
  unique (request_id, round_no));
create table if not exists public.hb_confirm_replies (          -- 業主回覆：每個版本一筆，nonce 防重複送出
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.hb_confirm_requests(id) on delete cascade,
  round_id uuid not null references public.hb_confirm_rounds(id) on delete cascade,
  nonce text not null unique, results jsonb not null, message text not null default '', ua text,
  created_at timestamptz not null default now(), unique (round_id));
create table if not exists public.hb_confirm_events (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.hb_confirm_requests(id) on delete cascade,
  kind text not null, text text not null default '', meta jsonb not null default '{}'::jsonb,
  created_by text, created_at timestamptz not null default now());
create index if not exists hb_confirm_files_req on public.hb_confirm_files(request_id);
create index if not exists hb_confirm_rounds_req on public.hb_confirm_rounds(request_id);
create index if not exists hb_confirm_replies_req on public.hb_confirm_replies(request_id);
create index if not exists hb_confirm_events_req on public.hb_confirm_events(request_id, created_at);
create index if not exists hb_confirm_requests_project on public.hb_confirm_requests(project_id);
alter table public.hb_confirm_requests enable row level security;
alter table public.hb_confirm_files enable row level security;
alter table public.hb_confirm_rounds enable row level security;
alter table public.hb_confirm_replies enable row level security;
alter table public.hb_confirm_events enable row level security;
revoke all on public.hb_confirm_requests, public.hb_confirm_files, public.hb_confirm_rounds, public.hb_confirm_replies, public.hb_confirm_events from anon, authenticated;
insert into storage.buckets (id, name, public, file_size_limit) values ('hb-confirm','hb-confirm', false, 52428800) on conflict (id) do nothing;
create or replace function public.hb_tg_push_confirm_reply()
returns trigger language plpgsql security definer set search_path to '' as $$
declare v_title text; v_project uuid; v_ok int; v_ch int;
begin
  select r.title, r.project_id into v_title, v_project from public.hb_confirm_requests r where r.id = new.request_id;
  select count(*) filter (where x->>'result'='ok'), count(*) filter (where x->>'result'='change') into v_ok, v_ch from jsonb_array_elements(new.results) x;
  perform public.hb_push('admin', v_project, '業主已回覆・' || coalesce(v_title,'確認事項'),
    v_ok || ' 項確認' || case when v_ch > 0 then '、' || v_ch || ' 項需要修改' else '' end || '，到工作台「待業主確認」查看', 'confirm');
  return new;
end $$;
create trigger hb_push_confirm_reply after insert on public.hb_confirm_replies for each row execute function public.hb_tg_push_confirm_reply();
revoke execute on function public.hb_tg_push_confirm_reply() from public, anon, authenticated;
