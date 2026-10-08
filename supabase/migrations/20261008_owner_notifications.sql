-- 業主更新通知（站內通知中心＋手機推播）
-- 業主的操作成功寫入資料庫後，由 trigger 建立通知；同一來源只建一次（dedupe_key），
-- 3 分鐘內同案、同類、同目標的連續提交合併成一則（只推播第一次）。
-- 已讀狀態依登入帳號分開存在資料庫，跨裝置同步。

create table if not exists public.hb_notifications (
  id uuid primary key default gen_random_uuid(),
  category text not null check (category in ('owner','system')),
  kind text not null,                       -- client_info | upload | comment | confirm | booking | lead
  project_id uuid references public.sitelog_projects(id) on delete cascade,
  actor text,
  title text not null,
  summary text,
  target jsonb not null default '{}'::jsonb, -- {view, tab, cf}
  grp text,                                  -- 合併用的群組鍵
  dedupe_key text unique,
  n int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists hb_notifications_updated on public.hb_notifications (updated_at desc);
create index if not exists hb_notifications_grp on public.hb_notifications (grp, updated_at desc);

create table if not exists public.hb_notification_reads (
  user_id uuid not null,
  notification_id uuid not null references public.hb_notifications(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (user_id, notification_id)
);

create table if not exists public.hb_notif_user (
  user_id uuid primary key,
  cleared_before timestamptz,
  prefs jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.hb_notifications enable row level security;
alter table public.hb_notification_reads enable row level security;
alter table public.hb_notif_user enable row level security;
-- 不開放直接讀寫，一律走下面的 security definer 函式（會檢查權限）
revoke all on public.hb_notifications, public.hb_notification_reads, public.hb_notif_user from anon, authenticated;

-- 這個帳號能不能看這則通知（公司管理員看全部；審核帳號只看自己那一案）
create or replace function public.hb_notif_can_see(p_project uuid)
returns boolean language sql stable security definer set search_path to '' as $$
  select public.is_hb_admin() or (p_project is not null and p_project = public.hb_reviewer_project());
$$;

create or replace function public.hb_notif_pref_on(p_prefs jsonb, p_kind text)
returns boolean language sql immutable as $$
  select coalesce((p_prefs->>p_kind)::boolean, true);
$$;

-- 手機推播：只送給有權限、且沒有關掉這類通知／推播的人；推播失敗不影響任何資料
create or replace function public.hb_notify_push(p_id uuid, p_kind text, p_project uuid, p_title text, p_body text)
returns void language plpgsql security definer set search_path to '' as $$
declare v_users uuid[];
begin
  select array_agg(a.user_id) into v_users
    from public.hb_admins a left join public.hb_notif_user u on u.user_id = a.user_id
   where (case when p_project is not null and exists (select 1 from public.hb_admins r where r.role = 'reviewer' and r.scope_project = p_project)
               then a.role = 'reviewer' and a.scope_project = p_project          -- 示範案件只通知審核帳號
               else a.role in ('owner','staff') end)
     and public.hb_notif_pref_on(coalesce(u.prefs,'{}'::jsonb), p_kind)
     and public.hb_notif_pref_on(coalesce(u.prefs,'{}'::jsonb), 'push');
  if v_users is null or not exists (select 1 from public.hb_device_tokens t where t.audience = 'admin' and t.user_id = any(v_users)) then return; end if;
  perform net.http_post(
    url := 'https://rqndozhhvuimqjqtmeli.supabase.co/functions/v1/hb-native-push',
    headers := jsonb_build_object('Content-Type','application/json','x-hb-push-secret', public.hb_push_secret_read()),
    body := jsonb_build_object('audience','admin','project_id', p_project, 'user_ids', to_jsonb(v_users),
      'title', left(p_title,80), 'body', left(p_body,180), 'kind', 'notif_' || p_kind, 'nid', p_id,
      'url', 'https://www.herfulsinsvip.com/?hbn=' || p_id));
exception when others then
  raise warning 'hb_notify_push failed: %', sqlerrm;
end $$;
revoke execute on function public.hb_notify_push(uuid,text,uuid,text,text) from public, anon, authenticated;

-- 建立通知（只給 trigger 用）
create or replace function public.hb_notify(
  p_category text, p_kind text, p_project uuid, p_actor text, p_title text, p_summary text,
  p_target jsonb, p_dedupe text, p_group text, p_push_title text, p_push_body text)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v_id uuid;
begin
  if p_dedupe is not null and exists (select 1 from public.hb_notifications where dedupe_key = p_dedupe) then return null; end if;
  if p_group is not null then
    select id into v_id from public.hb_notifications
      where grp = p_group and updated_at > now() - interval '3 minutes' order by updated_at desc limit 1;
    if v_id is not null then
      -- 合併：更新時間往後推，已讀紀錄（read_at 早於 updated_at）自動變回未讀；不再推播
      update public.hb_notifications set n = n + 1, summary = coalesce(p_summary, summary), actor = coalesce(p_actor, actor), updated_at = now() where id = v_id;
      return v_id;
    end if;
  end if;
  insert into public.hb_notifications(category, kind, project_id, actor, title, summary, target, grp, dedupe_key)
  values (p_category, p_kind, p_project, p_actor, p_title, p_summary, coalesce(p_target,'{}'::jsonb), p_group, p_dedupe)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is null then return null; end if;
  begin
    perform public.hb_notify_push(v_id, p_kind, p_project, p_push_title, p_push_body);
  exception when others then raise warning 'hb_notify push failed: %', sqlerrm;
  end;
  return v_id;
end $$;
revoke execute on function public.hb_notify(text,text,uuid,text,text,text,jsonb,text,text,text,text) from public, anon, authenticated;

create or replace function public.hb_notif_pname(p uuid) returns text language sql stable security definer set search_path to '' as $$
  select coalesce((select name from public.sitelog_projects where id = p), '案件');
$$;
create or replace function public.hb_notif_owner_name(p uuid) returns text language sql stable security definer set search_path to '' as $$
  select coalesce(nullif(btrim((select client_info->>'name' from public.sitelog_projects where id = p)),''), '業主');
$$;
revoke execute on function public.hb_notif_pname(uuid), public.hb_notif_owner_name(uuid) from public, anon, authenticated;

-- ===== 前端用 =====
create or replace function public.hb_notif_list(p_limit int default 50)
returns table(id uuid, category text, kind text, project_id uuid, project_name text, actor text, title text, summary text,
              target jsonb, n int, created_at timestamptz, updated_at timestamptz, unread boolean)
language sql stable security definer set search_path to '' as $$
  with me as (select auth.uid() uid, coalesce((select prefs from public.hb_notif_user where user_id = auth.uid()),'{}'::jsonb) prefs,
                     (select cleared_before from public.hb_notif_user where user_id = auth.uid()) cb)
  select x.id, x.category, x.kind, x.project_id, p.name, x.actor, x.title, x.summary, x.target, x.n, x.created_at, x.updated_at,
         (me.cb is null or x.updated_at > me.cb) and not exists (select 1 from public.hb_notification_reads r where r.user_id = me.uid and r.notification_id = x.id and r.read_at >= x.updated_at)
    from public.hb_notifications x cross join me left join public.sitelog_projects p on p.id = x.project_id
   where me.uid is not null and public.hb_notif_can_see(x.project_id) and (x.category = 'owner' or public.is_hb_admin())
     and public.hb_notif_pref_on(me.prefs, x.kind)
   order by x.updated_at desc limit least(greatest(coalesce(p_limit,50),1),200);
$$;

create or replace function public.hb_notif_get(p_id uuid)
returns table(id uuid, project_id uuid, kind text, target jsonb)
language sql stable security definer set search_path to '' as $$
  select x.id, x.project_id, x.kind, x.target from public.hb_notifications x
   where x.id = p_id and auth.uid() is not null and public.hb_notif_can_see(x.project_id) and (x.category = 'owner' or public.is_hb_admin());
$$;

create or replace function public.hb_notif_read(p_id uuid)
returns boolean language plpgsql security definer set search_path to '' as $$
begin
  if auth.uid() is null or not exists (select 1 from public.hb_notifications x where x.id = p_id and public.hb_notif_can_see(x.project_id)) then return false; end if;
  insert into public.hb_notification_reads(user_id, notification_id, read_at) values (auth.uid(), p_id, now())
  on conflict (user_id, notification_id) do update set read_at = now();
  return true;
end $$;

create or replace function public.hb_notif_read_all(p_category text default null)
returns boolean language plpgsql security definer set search_path to '' as $$
begin
  if auth.uid() is null or not public.hb_staff_access() then return false; end if;
  if p_category is null then
    insert into public.hb_notif_user(user_id, cleared_before, updated_at) values (auth.uid(), now(), now())
    on conflict (user_id) do update set cleared_before = now(), updated_at = now();
  else
    insert into public.hb_notification_reads(user_id, notification_id, read_at)
    select auth.uid(), x.id, now() from public.hb_notifications x where x.category = p_category and public.hb_notif_can_see(x.project_id)
    on conflict (user_id, notification_id) do update set read_at = now();
  end if;
  return true;
end $$;

create or replace function public.hb_notif_prefs()
returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce((select prefs from public.hb_notif_user where user_id = auth.uid()),'{}'::jsonb);
$$;
create or replace function public.hb_notif_prefs_set(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v jsonb := '{}'::jsonb; k text;
begin
  if auth.uid() is null or not public.hb_staff_access() then raise exception 'forbidden'; end if;
  foreach k in array array['client_info','upload','comment','confirm','booking','lead','push'] loop
    if p ? k then v := v || jsonb_build_object(k, (p->>k)::boolean); end if;
  end loop;
  insert into public.hb_notif_user(user_id, prefs, updated_at) values (auth.uid(), v, now())
  on conflict (user_id) do update set prefs = public.hb_notif_user.prefs || v, updated_at = now();
  return public.hb_notif_prefs();
end $$;
revoke execute on function public.hb_notif_list(int), public.hb_notif_get(uuid), public.hb_notif_read(uuid), public.hb_notif_read_all(text),
  public.hb_notif_prefs(), public.hb_notif_prefs_set(jsonb) from public, anon;
grant execute on function public.hb_notif_list(int), public.hb_notif_get(uuid), public.hb_notif_read(uuid), public.hb_notif_read_all(text),
  public.hb_notif_prefs(), public.hb_notif_prefs_set(jsonb) to authenticated;

-- ===== 業主操作 → 通知 =====
-- 確認回覆（業主確認頁送出）
create or replace function public.hb_tg_push_confirm_reply()
returns trigger language plpgsql security definer set search_path to '' as $$
declare v_title text; v_project uuid; v_ok int; v_ch int; v_pn text;
begin
  select r.title, r.project_id into v_title, v_project from public.hb_confirm_requests r where r.id = new.request_id;
  select count(*) filter (where x->>'result'='ok'), count(*) filter (where x->>'result'='change') into v_ok, v_ch from jsonb_array_elements(new.results) x;
  v_pn := public.hb_notif_pname(v_project);
  perform public.hb_notify('owner','confirm', v_project, coalesce(nullif(btrim(new.signer_name),''), public.hb_notif_owner_name(v_project)),
    '業主已回覆確認', coalesce(v_title,'確認事項') || '：' || v_ok || ' 項確認' || case when v_ch > 0 then '、' || v_ch || ' 項需要修改' else '' end,
    jsonb_build_object('view','home','cf', new.request_id), 'confirm_reply:' || new.id, 'confirm:' || new.request_id,
    '業主更新', v_pn || '有新的業主更新，點擊查看。');
  return new;
exception when others then raise warning 'notify confirm: %', sqlerrm; return new;
end $$;

-- 缺失回報（業主新增）
create or replace function public.hb_tg_push_defect()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.created_by = 'owner' then
    perform public.hb_notify('owner','comment', new.project_id, public.hb_notif_owner_name(new.project_id), '業主回報缺失',
      left(coalesce(nullif(new.location,'') || '：','') || coalesce(new.description,''), 120),
      jsonb_build_object('tab','defects'), 'defect:' || new.id, 'defect:' || new.project_id,
      '業主更新', public.hb_notif_pname(new.project_id) || '有新的業主更新，點擊查看。');
  end if;
  return new;
exception when others then raise warning 'notify defect: %', sqlerrm; return new;
end $$;

-- 缺失留言（業主留言 → 通知公司；公司留言 → 照舊推播給業主）
create or replace function public.hb_tg_push_defect_comment()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.author_role = 'owner' then
    perform public.hb_notify('owner','comment', new.project_id, public.hb_notif_owner_name(new.project_id), '業主留言回覆',
      left(coalesce(new.message,''), 120), jsonb_build_object('tab','defects'), 'defect_comment:' || new.id, 'dcomment:' || new.defect_id,
      '業主更新', public.hb_notif_pname(new.project_id) || '有新的業主更新，點擊查看。');
  else
    perform public.hb_push('owner', new.project_id, '缺失有新回覆', left(coalesce(new.message,''), 120), 'defect_comment');
  end if;
  return new;
exception when others then raise warning 'notify defect comment: %', sqlerrm; return new;
end $$;

-- 設備／參考照片、檔案（業主新增或修改）
create or replace function public.hb_tg_notify_appliance()
returns trigger language plpgsql security definer set search_path to '' as $$
declare v_owner boolean; v_files int;
begin
  v_owner := case when tg_op = 'INSERT' then new.created_by = 'owner' else auth.uid() is null and public.hb_owner_project_id() = new.project_id end;
  if not coalesce(v_owner,false) then return new; end if;
  if tg_op = 'UPDATE' and new.photo_url is not distinct from old.photo_url and new.file_url is not distinct from old.file_url
     and new.name is not distinct from old.name and new.note is not distinct from old.note and new.link is not distinct from old.link
     and new.width_cm is not distinct from old.width_cm and new.height_cm is not distinct from old.height_cm and new.depth_cm is not distinct from old.depth_cm then
    return new;
  end if;
  v_files := (case when new.photo_url is not null then 1 else 0 end) + (case when new.file_url is not null then 1 else 0 end);
  perform public.hb_notify('owner','upload', new.project_id, public.hb_notif_owner_name(new.project_id),
    case when tg_op = 'INSERT' then (case when v_files > 0 then '業主已上傳參考照片／檔案' else '業主新增設備資料' end) else '業主已更新設備資料' end,
    left(coalesce(new.name,'設備') || case when v_files > 0 then '（附 ' || v_files || ' 個檔案）' else '' end, 120),
    jsonb_build_object('tab','appliances'), 'appliance:' || new.id || ':' || tg_op || ':' || (extract(epoch from now())::bigint / 60)::text,
    'appliance:' || new.project_id, '業主更新', public.hb_notif_pname(new.project_id) || '有新的業主更新，點擊查看。');
  return new;
exception when others then raise warning 'notify appliance: %', sqlerrm; return new;
end $$;
create or replace trigger hb_notify_appliance after insert or update on public.sitelog_appliances for each row execute function public.hb_tg_notify_appliance();

-- 客戶基本資料／需求問卷送出（有案件 → 業主更新；沒有案件 → 系統通知「新的客戶資料」）
create or replace function public.hb_tg_push_questionnaire()
returns trigger language plpgsql security definer set search_path to '' as $$
declare v_name text; v_src text;
begin
  if new.status is distinct from 'submitted' then return new; end if;
  if tg_op = 'UPDATE' and old.status = 'submitted' and old.answers is not distinct from new.answers then return new; end if;
  v_name := coalesce(nullif(btrim(new.client_name),''), nullif(btrim(new.answers->>'name'),''), '新客戶');
  v_src := case when new.answers->>'from' = '官網聯絡頁' then '官網聯絡頁' when new.source = 'open' then '客戶資料表' else coalesce(nullif(new.title,''),'設計需求問卷') end;
  if new.project_id is not null then
    perform public.hb_notify('owner','client_info', new.project_id, v_name, '業主已更新客戶資料',
      v_src || '：聯絡方式與裝修需求已更新', jsonb_build_object('view','survey'),
      'questionnaire:' || new.id || ':' || coalesce(new.submitted_at, now())::text, 'q:' || new.id,
      '業主更新', public.hb_notif_pname(new.project_id) || '有新的業主更新，點擊查看。');
  else
    perform public.hb_notify('system','lead', null, v_name, '新的客戶資料・' || v_src, v_name || ' 已送出資料',
      jsonb_build_object('view','survey'), 'questionnaire:' || new.id || ':' || coalesce(new.submitted_at, now())::text, null,
      '新的客戶資料', '有新的客戶資料表（' || v_src || '），點擊查看。');
  end if;
  return new;
exception when others then raise warning 'notify questionnaire: %', sqlerrm; return new;
end $$;

-- 客戶預約（系統通知；推播不帶姓名、電話）
create or replace function public.hb_tg_push_booking()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  perform public.hb_notify('system','booking', null, new.name, '新的客戶預約',
    coalesce(new.service_type,'') || '・' || coalesce(to_char(new.date,'MM/DD'),'') || ' ' || coalesce(new.time,''),
    jsonb_build_object('view','home'), 'booking:' || new.id, null,
    '新的客戶預約', '有一筆新的預約（' || coalesce(to_char(new.date,'MM/DD'),'') || ' ' || coalesce(new.time,'') || '），點擊查看。');
  return new;
exception when others then raise warning 'notify booking: %', sqlerrm; return new;
end $$;

-- 估價單線上簽署、會議紀錄確認、追加減簽署（圖面／文件確認類）
create or replace function public.hb_tg_notify_signed()
returns trigger language plpgsql security definer set search_path to '' as $$
declare v_pid uuid; v_title text; v_sum text; v_target jsonb; v_key text;
begin
  if tg_table_name = 'sitelog_estimates' then
    if new.signed_at is null or old.signed_at is not distinct from new.signed_at then return new; end if;
    v_pid := new.project_id; v_title := '業主已簽署估價單'; v_sum := coalesce(nullif(new.eng_name,''), '估價單') || ' 已完成線上簽署';
    v_target := jsonb_build_object('view','estimateHub'); v_key := 'estimate_sign:' || new.id || ':' || new.signed_at::text;
  elsif tg_table_name = 'sitelog_meetings' then
    if new.owner_confirmed_at is null or old.owner_confirmed_at is not distinct from new.owner_confirmed_at then return new; end if;
    v_pid := new.project_id; v_title := '業主已確認會議紀錄'; v_sum := coalesce(to_char(new.met_at,'MM/DD'),'') || ' ' || coalesce(nullif(new.kind,''),'會議') || ' 紀錄已確認';
    v_target := jsonb_build_object('tab','meetings'); v_key := 'meeting_confirm:' || new.id || ':' || new.owner_confirmed_at::text;
  elsif tg_table_name = 'sitelog_change_orders' then
    if new.signed_at is null or old.signed_at is not distinct from new.signed_at then return new; end if;
    v_pid := new.project_id; v_title := '業主已簽署追加減單'; v_sum := coalesce(nullif(new.title,''), '追加減單') || ' 已完成簽署';
    v_target := jsonb_build_object('view','changeOrders'); v_key := 'change_order:' || new.id || ':' || new.signed_at::text;
  else return new; end if;
  if v_pid is null then return new; end if;
  perform public.hb_notify('owner','confirm', v_pid, public.hb_notif_owner_name(v_pid), v_title, v_sum, v_target, v_key, null,
    '業主更新', public.hb_notif_pname(v_pid) || '有新的業主更新，點擊查看。');
  return new;
exception when others then raise warning 'notify signed: %', sqlerrm; return new;
end $$;
create or replace trigger hb_notify_signed after update of signed_at on public.sitelog_estimates for each row execute function public.hb_tg_notify_signed();
create or replace trigger hb_notify_signed after update of owner_confirmed_at on public.sitelog_meetings for each row execute function public.hb_tg_notify_signed();
create or replace trigger hb_notify_signed after update of signed_at on public.sitelog_change_orders for each row execute function public.hb_tg_notify_signed();
