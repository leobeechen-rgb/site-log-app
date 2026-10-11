-- 排程發送到案件 LINE 群組（官方帳號 push 訊息）
-- 設計師在工作台挑照片、寫文字、選時間；時間到由 pg_cron 每分鐘叫 hb-line-oa?run=scheduled 送出。
-- 一則最多 1 段文字 + 4 張照片（LINE 一次 push 最多 5 則訊息）。push 訊息會用到官方帳號的每月訊息額度。

create table if not exists public.hb_line_posts (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  project_id uuid references public.sitelog_projects(id) on delete cascade,
  line_key text not null check (line_key ~ '^[CRU][0-9a-f]{32}$'),
  body text not null default '' check (length(body) <= 4000),
  photo_urls text[] not null default '{}' check (coalesce(array_length(photo_urls, 1), 0) <= 4),
  send_at timestamptz not null,
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'cancelled')),
  error text,
  sent_at timestamptz,
  created_by text
);
create index if not exists hb_line_posts_due on public.hb_line_posts (status, send_at);
create index if not exists hb_line_posts_project on public.hb_line_posts (project_id, send_at desc);
alter table public.hb_line_posts enable row level security;
create policy hb_admin_all on public.hb_line_posts for all to authenticated
  using ((select public.is_hb_admin())) with check ((select public.is_hb_admin()));
revoke all on public.hb_line_posts from anon;

-- 每分鐘檢查一次到期的排程（只會送出已到時間、狀態 pending 的，重複呼叫也不會重發）
select cron.schedule('hb-line-posts-minutely', '* * * * *',
  $$select net.http_get('https://rqndozhhvuimqjqtmeli.supabase.co/functions/v1/hb-line-oa?run=scheduled')$$);
