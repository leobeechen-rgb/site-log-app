-- 業主 LINE 快速登入（已於 2026-10-05 套用）
create table if not exists public.hb_owner_line_links (
  id uuid primary key default gen_random_uuid(),
  line_user_id text not null,
  project_id uuid not null references public.sitelog_projects(id) on delete cascade,
  display_name text, created_at timestamptz not null default now(), last_login_at timestamptz,
  unique (line_user_id, project_id));
create table if not exists public.hb_line_states (
  id text primary key, mode text not null, project_id uuid, return_to text not null,
  created_at timestamptz not null default now(), used_at timestamptz);
create index if not exists hb_owner_line_links_user on public.hb_owner_line_links(line_user_id);
alter table public.hb_owner_line_links enable row level security;
alter table public.hb_line_states enable row level security;
revoke all on public.hb_owner_line_links, public.hb_line_states from anon, authenticated;
-- 公司帳號 LINE 快速登入
alter table public.hb_line_states add column if not exists staff_user uuid;
create table if not exists public.hb_staff_line_links (
  user_id uuid primary key references auth.users(id) on delete cascade,
  line_user_id text not null unique, display_name text,
  created_at timestamptz not null default now(), last_login_at timestamptz);
alter table public.hb_staff_line_links enable row level security;
revoke all on public.hb_staff_line_links from anon, authenticated;
