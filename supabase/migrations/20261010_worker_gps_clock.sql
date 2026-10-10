-- 師傅 GPS 打卡
-- 每位師傅有一條專屬打卡連結（clock.html?t=…），不用登入。到工地按「上工打卡／下工打卡」，
-- 系統記下時間與手機定位，並算出離案件地址多遠；記錄直接進「師傅出勤紀錄」。
-- 另外補上出勤表原本少掉的 period 欄位（上午／下午／全天），手動記工才不會失敗。

alter table public.sitelog_workers add column if not exists clock_token text unique;
alter table public.sitelog_workers add column if not exists daily_rate numeric;

alter table public.sitelog_attendance add column if not exists period text;
alter table public.sitelog_attendance add column if not exists worker_id uuid references public.sitelog_workers(id) on delete set null;
alter table public.sitelog_attendance add column if not exists project_id uuid references public.sitelog_projects(id) on delete set null;
alter table public.sitelog_attendance add column if not exists clock_in timestamptz;
alter table public.sitelog_attendance add column if not exists clock_out timestamptz;
alter table public.sitelog_attendance add column if not exists in_lat double precision;
alter table public.sitelog_attendance add column if not exists in_lng double precision;
alter table public.sitelog_attendance add column if not exists in_acc double precision;
alter table public.sitelog_attendance add column if not exists in_dist double precision;
alter table public.sitelog_attendance add column if not exists out_lat double precision;
alter table public.sitelog_attendance add column if not exists out_lng double precision;
alter table public.sitelog_attendance add column if not exists out_dist double precision;
alter table public.sitelog_attendance add column if not exists source text;
create index if not exists sitelog_attendance_worker_day on public.sitelog_attendance (worker_id, work_date);

-- 兩點距離（公尺）
create or replace function public.hb_geo_m(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision)
returns double precision language sql immutable set search_path to '' as $$
  select case when a_lat is null or a_lng is null or b_lat is null or b_lng is null then null else
    2 * 6371000 * asin(sqrt(power(sin(radians(b_lat - a_lat) / 2), 2) + cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lng - a_lng) / 2), 2))) end;
$$;

create or replace function public.hb_clock_worker(p_token text)
returns public.sitelog_workers language sql stable security definer set search_path to '' as $$
  select w.* from public.sitelog_workers w
   where p_token ~ '^[A-Za-z0-9_-]{24,64}$' and w.clock_token = p_token and w.active limit 1;
$$;

-- 打卡頁開啟時：師傅名字、今天的紀錄、進行中的案件（只給名稱、地址、座標）
create or replace function public.hb_clock_info(p_token text)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare w public.sitelog_workers; d date := (now() at time zone 'Asia/Taipei')::date;
begin
  w := public.hb_clock_worker(p_token);
  if w.id is null then return jsonb_build_object('ok', false); end if;
  return jsonb_build_object('ok', true, 'name', w.name, 'today', d,
    'records', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'site', a.site_location, 'project_id', a.project_id,
        'in', a.clock_in, 'out', a.clock_out, 'in_dist', a.in_dist, 'out_dist', a.out_dist) order by a.clock_in)
      from public.sitelog_attendance a where a.worker_id = w.id and a.work_date = d and a.source = 'gps'), '[]'::jsonb),
    'projects', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'address', p.address, 'lat', p.lat, 'lng', p.lng) order by p.updated_at desc nulls last)
      from public.sitelog_projects p
      where coalesce(p.status, '') not in ('工程已完工', '流標') and p.name !~ '示範'), '[]'::jsonb));
end $$;

create or replace function public.hb_clock_in(p_token text, p_project uuid, p_lat double precision, p_lng double precision, p_acc double precision)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare w public.sitelog_workers; p record; d date := (now() at time zone 'Asia/Taipei')::date; v_id uuid; v_dist double precision; v_open uuid;
begin
  w := public.hb_clock_worker(p_token);
  if w.id is null then return jsonb_build_object('ok', false, 'why', 'token'); end if;
  if p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180) then return jsonb_build_object('ok', false, 'why', 'gps'); end if;
  select id, name, lat, lng into p from public.sitelog_projects where id = p_project;
  if p.id is null then return jsonb_build_object('ok', false, 'why', 'project'); end if;
  -- 還沒下工的那筆先幫他收掉（換工地時）
  select id into v_open from public.sitelog_attendance where worker_id = w.id and work_date = d and source = 'gps' and clock_out is null order by clock_in desc limit 1;
  if v_open is not null and (select project_id from public.sitelog_attendance where id = v_open) = p.id then
    return jsonb_build_object('ok', true, 'already', true, 'id', v_open);
  end if;
  if v_open is not null then update public.sitelog_attendance set clock_out = now(),
      hours = round((extract(epoch from (now() - clock_in)) / 3600)::numeric, 1),
      days = case when extract(epoch from (now() - clock_in)) / 3600 < 4.5 then 0.5 else 1 end,
      period = case when extract(epoch from (now() - clock_in)) / 3600 >= 4.5 then '全天' when (clock_in at time zone 'Asia/Taipei')::time < '12:00' then '上午' else '下午' end
      where id = v_open; end if;
  v_dist := public.hb_geo_m(p_lat, p_lng, p.lat, p.lng);
  insert into public.sitelog_attendance(worker_id, worker_name, project_id, site_location, work_date, days, period, daily_rate, clock_in, in_lat, in_lng, in_acc, in_dist, source, note)
  values (w.id, w.name, p.id, p.name, d, 1, '全天', w.daily_rate, now(), p_lat, p_lng, p_acc, v_dist, 'gps', null)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'dist', v_dist, 'site', p.name);
end $$;

create or replace function public.hb_clock_out(p_token text, p_lat double precision, p_lng double precision)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare w public.sitelog_workers; d date := (now() at time zone 'Asia/Taipei')::date; r record; v_h numeric;
begin
  w := public.hb_clock_worker(p_token);
  if w.id is null then return jsonb_build_object('ok', false, 'why', 'token'); end if;
  select a.id, a.clock_in, p.lat, p.lng into r from public.sitelog_attendance a left join public.sitelog_projects p on p.id = a.project_id
   where a.worker_id = w.id and a.work_date = d and a.source = 'gps' and a.clock_out is null order by a.clock_in desc limit 1;
  if r.id is null then return jsonb_build_object('ok', false, 'why', 'none'); end if;
  v_h := round((extract(epoch from (now() - r.clock_in)) / 3600)::numeric, 1);
  -- 不到 4.5 小時算半天（上午或下午）；之後可在出勤紀錄手動調整
  update public.sitelog_attendance set clock_out = now(), out_lat = p_lat, out_lng = p_lng,
         out_dist = public.hb_geo_m(p_lat, p_lng, r.lat, r.lng), hours = v_h,
         days = case when v_h < 4.5 then 0.5 else 1 end,
         period = case when v_h >= 4.5 then '全天' when (r.clock_in at time zone 'Asia/Taipei')::time < '12:00' then '上午' else '下午' end
   where id = r.id;
  return jsonb_build_object('ok', true, 'hours', v_h);
end $$;

revoke execute on function public.hb_clock_worker(text) from public, anon, authenticated;
revoke execute on function public.hb_clock_info(text), public.hb_clock_in(text, uuid, double precision, double precision, double precision), public.hb_clock_out(text, double precision, double precision) from public;
grant execute on function public.hb_clock_info(text), public.hb_clock_in(text, uuid, double precision, double precision, double precision),
  public.hb_clock_out(text, double precision, double precision) to anon, authenticated;
