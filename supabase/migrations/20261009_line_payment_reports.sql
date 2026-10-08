-- 官方 LINE「已匯款」偵測 → 收據草稿 + 通知中心 + 手機推播
-- 流程：LINE 官方帳號 webhook（edge function hb-line-oa）偵測客人說已匯款／轉帳／查收
--       → hb_payment_report_add 建立「匯款回報」→ hb_notify 通知（kind = payment）
--       → 設計師點通知 → 工程收據頁開好填好的收據草稿，確認金額後才建立、列印。
-- 收據一定要設計師按下「建立」才會產生，系統不會自動寄給客人。

create table if not exists public.hb_payment_reports (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  line_user_id text not null,
  line_name text,
  message text,
  amount numeric,
  has_image boolean not null default false,
  project_id uuid references public.sitelog_projects(id) on delete set null,
  status text not null default 'pending' check (status in ('pending','done','dismissed')),
  receipt_id uuid references public.sitelog_receipts(id) on delete set null
);
create index if not exists hb_payment_reports_pending on public.hb_payment_reports (status, created_at desc);
create index if not exists hb_payment_reports_user on public.hb_payment_reports (line_user_id, updated_at desc);
alter table public.hb_payment_reports enable row level security;
create policy hb_admin_all on public.hb_payment_reports for all to authenticated
  using ((select public.is_hb_admin())) with check ((select public.is_hb_admin()));
revoke all on public.hb_payment_reports from anon;

-- LINE 好友 ↔ 案件（第一次開收據時選的案件會記住，下次自動帶入）
create table if not exists public.hb_line_contacts (
  line_user_id text primary key,
  project_id uuid references public.sitelog_projects(id) on delete set null,
  line_name text,
  updated_at timestamptz not null default now()
);
alter table public.hb_line_contacts enable row level security;
create policy hb_admin_all on public.hb_line_contacts for all to authenticated
  using ((select public.is_hb_admin())) with check ((select public.is_hb_admin()));
revoke all on public.hb_line_contacts from anon;

-- 防止 LINE 重送同一事件
create table if not exists public.hb_line_oa_events (
  event_id text primary key,
  created_at timestamptz not null default now()
);
alter table public.hb_line_oa_events enable row level security;
revoke all on public.hb_line_oa_events from anon, authenticated;

alter table public.sitelog_receipts add column if not exists project_id uuid references public.sitelog_projects(id) on delete set null;
alter table public.sitelog_receipts add column if not exists report_id uuid references public.hb_payment_reports(id) on delete set null;

-- 只給 edge function（service role）呼叫
create or replace function public.hb_payment_report_add(
  p_event text, p_uid text, p_name text, p_text text, p_kind text, p_amount numeric)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v_id uuid; v_proj uuid; v_nproj uuid; v_pname text; v_who text; v_n int;
begin
  if p_uid !~ '^U[0-9a-f]{32}$' or length(coalesce(p_event,'')) not between 1 and 160 then raise exception 'invalid input'; end if;
  insert into public.hb_line_oa_events(event_id) values (p_event) on conflict do nothing;
  get diagnostics v_n = row_count;
  if v_n = 0 then return null; end if;
  p_text := left(btrim(coalesce(p_text,'')), 500);
  p_name := nullif(left(btrim(coalesce(p_name,'')), 60), '');
  if p_amount is not null and (p_amount <= 0 or p_amount > 100000000) then p_amount := null; end if;

  -- 一小時內同一人的未處理回報：合併（客人常先傳文字再傳轉帳截圖）
  select id into v_id from public.hb_payment_reports
   where line_user_id = p_uid and status = 'pending' and updated_at > now() - interval '60 minutes'
   order by updated_at desc limit 1;
  if v_id is not null then
    update public.hb_payment_reports
       set message = left(case when p_kind = 'image' then coalesce(message,'') || E'\n〔傳了一張圖片〕'
                               else coalesce(nullif(message,'') || E'\n','') || p_text end, 2000),
           has_image = has_image or p_kind = 'image',
           amount = coalesce(p_amount, amount),
           line_name = coalesce(p_name, line_name),
           updated_at = now()
     where id = v_id;
    return v_id;
  end if;
  if p_kind = 'image' then return null; end if;   -- 單獨一張圖不判斷

  select project_id into v_proj from public.hb_line_contacts where line_user_id = p_uid;
  if v_proj is null then
    -- 業主用 LINE 登入過業主頁（同一個 Provider，LINE 使用者 ID 相同）且只對應一個案件
    select min(project_id::text)::uuid into v_proj from public.hb_owner_line_links
     where line_user_id = p_uid having count(distinct project_id) = 1;
  end if;

  insert into public.hb_payment_reports(line_user_id, line_name, message, amount, project_id)
  values (p_uid, p_name, p_text, p_amount, v_proj) returning id into v_id;

  v_pname := (select name from public.sitelog_projects where id = v_proj);
  -- 示範案件（審核帳號專用）不帶案件，避免推播給審核帳號
  v_nproj := case when v_proj is not null and exists (select 1 from public.hb_admins r where r.role = 'reviewer' and r.scope_project = v_proj)
                  then null else v_proj end;
  v_who := coalesce(p_name, 'LINE 好友');
  perform public.hb_notify('owner', 'payment', v_nproj, v_who,
    '回報已匯款' || case when p_amount is not null then ' NT$' || to_char(p_amount, 'FM999,999,999') else '' end,
    'LINE「' || v_who || '」：' || left(p_text, 90),
    jsonb_build_object('pr', v_id), 'pay:' || v_id, null,
    coalesce(v_pname, v_who) || ' 回報已匯款',
    left(p_text, 110) || '｜點開確認並開收據');
  return v_id;
end $$;
revoke execute on function public.hb_payment_report_add(text,text,text,text,text,numeric) from public, anon, authenticated;
grant execute on function public.hb_payment_report_add(text,text,text,text,text,numeric) to service_role;
