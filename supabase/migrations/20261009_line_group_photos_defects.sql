-- 官方 LINE 案件群組 → 工地紀錄本
--   1. 客人在群組傳的照片 → 自動存進該案件「照片」的「LINE 群組照片」相簿（通知：業主上傳照片）
--   2. 客人在群組回報問題（漏水、裂縫、壞掉…）→ 自動在該案件「缺失」新增一筆（沿用業主回報缺失通知）
--   3. 設計師在群組輸入「綁定 案件名稱」→ 這個群組綁定到案件（官方帳號回覆確認）
-- 只有綁定過案件的群組才會存；設計師自己（員工 LINE 登入綁定過的帳號）傳的照片與訊息不會存。
-- 以下函式只給 edge function（service role）呼叫。

-- 這個對話綁定的案件、發話者是不是自己
create or replace function public.hb_line_chat_info(p_key text, p_sender text)
returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object(
    'project_id', (select c.project_id from public.hb_line_contacts c where c.line_user_id = p_key),
    'project_name', (select p.name from public.hb_line_contacts c join public.sitelog_projects p on p.id = c.project_id where c.line_user_id = p_key),
    'staff', p_sender is not null and exists (select 1 from public.hb_staff_line_links s where s.line_user_id = p_sender));
$$;

-- 綁定：名稱比對案件（完全相同優先，其次包含）
create or replace function public.hb_line_bind(p_key text, p_sender text, p_query text, p_name text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare q text := btrim(coalesce(p_query,'')); v_ids uuid[]; v_names text[];
begin
  if p_key !~ '^[UCR][0-9a-f]{32}$' then raise exception 'invalid input'; end if;
  -- 第一次綁定誰都可以（群組裡只有你知道案名）；已綁定後只有自己（員工 LINE）可以改
  if exists (select 1 from public.hb_line_contacts where line_user_id = p_key and project_id is not null)
     and (p_sender is null or not exists (select 1 from public.hb_staff_line_links where line_user_id = p_sender)) then
    return jsonb_build_object('ok', false, 'why', 'not_staff');
  end if;
  if length(q) < 2 then return jsonb_build_object('ok', false, 'why', 'empty'); end if;
  select array_agg(id), array_agg(name) into v_ids, v_names from public.sitelog_projects where btrim(name) = q;
  if v_ids is null then
    select array_agg(id order by updated_at desc nulls last), array_agg(name order by updated_at desc nulls last) into v_ids, v_names
      from (select id, name, updated_at from public.sitelog_projects
             where replace(name,' ','') ilike '%' || replace(q,' ','') || '%' limit 6) x;
  end if;
  if v_ids is null then return jsonb_build_object('ok', false, 'why', 'none'); end if;
  if array_length(v_ids,1) > 1 then return jsonb_build_object('ok', false, 'why', 'many', 'names', to_jsonb(v_names)); end if;
  insert into public.hb_line_contacts(line_user_id, project_id, line_name, updated_at)
  values (p_key, v_ids[1], nullif(left(btrim(coalesce(p_name,'')),60),''), now())
  on conflict (line_user_id) do update set project_id = excluded.project_id, line_name = coalesce(excluded.line_name, public.hb_line_contacts.line_name), updated_at = now();
  return jsonb_build_object('ok', true, 'name', v_names[1]);
end $$;

-- 照片：存進「LINE 群組照片」相簿；10 分鐘內若有剛從 LINE 回報的缺失、且還沒照片，順便當作缺失照片
create or replace function public.hb_line_photo_add(p_event text, p_key text, p_sender text, p_url text, p_path text, p_size bigint)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v_proj uuid; v_album uuid; v_id uuid; v_n int; v_def uuid;
begin
  if p_key !~ '^[UCR][0-9a-f]{32}$' or length(coalesce(p_event,'')) not between 1 and 160 or p_url !~ '^https://' then raise exception 'invalid input'; end if;
  if p_sender is not null and exists (select 1 from public.hb_staff_line_links where line_user_id = p_sender) then return null; end if;
  select project_id into v_proj from public.hb_line_contacts where line_user_id = p_key;
  if v_proj is null then return null; end if;
  insert into public.hb_line_oa_events(event_id) values ('photo:' || p_event) on conflict do nothing;
  get diagnostics v_n = row_count;
  if v_n = 0 then return null; end if;
  select id into v_album from public.sitelog_albums where project_id = v_proj and name = 'LINE 群組照片' order by created_at limit 1;
  if v_album is null then
    insert into public.sitelog_albums(project_id, name) values (v_proj, 'LINE 群組照片') returning id into v_album;
  end if;
  insert into public.sitelog_photos(project_id, album_id, url, path, note, size)
  values (v_proj, v_album, p_url, p_path, '業主在 LINE 群組傳的照片', p_size) returning id into v_id;
  select id into v_def from public.sitelog_defects
   where project_id = v_proj and created_by = 'owner' and photo_url is null and location = 'LINE 群組'
     and created_at > now() - interval '10 minutes' order by created_at desc limit 1;
  if v_def is not null then update public.sitelog_defects set photo_url = p_url where id = v_def; end if;
  perform public.hb_notify('owner', 'upload', v_proj, public.hb_notif_owner_name(v_proj), '業主在 LINE 群組傳了照片',
    '已自動存到「照片 › LINE 群組照片」', jsonb_build_object('tab','photos'), 'linephoto:' || v_id, 'linephoto:' || v_proj,
    '業主更新', public.hb_notif_pname(v_proj) || '：業主在 LINE 群組傳了照片，已自動存進案件。');
  return v_id;
end $$;

-- 缺失：客人在群組回報問題
create or replace function public.hb_line_defect_add(p_event text, p_key text, p_sender text, p_text text)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v_proj uuid; v_id uuid; v_n int;
begin
  if p_key !~ '^[UCR][0-9a-f]{32}$' or length(coalesce(p_event,'')) not between 1 and 160 then raise exception 'invalid input'; end if;
  if p_sender is not null and exists (select 1 from public.hb_staff_line_links where line_user_id = p_sender) then return null; end if;
  select project_id into v_proj from public.hb_line_contacts where line_user_id = p_key;
  if v_proj is null then return null; end if;
  insert into public.hb_line_oa_events(event_id) values ('defect:' || p_event) on conflict do nothing;
  get diagnostics v_n = row_count;
  if v_n = 0 then return null; end if;
  -- 同一群組 3 分鐘內連續描述，併成同一筆
  select id into v_id from public.sitelog_defects
   where project_id = v_proj and created_by = 'owner' and location = 'LINE 群組' and completed = false
     and created_at > now() - interval '3 minutes' order by created_at desc limit 1;
  if v_id is not null then
    update public.sitelog_defects set description = left(description || E'\n' || btrim(p_text), 1000) where id = v_id;
    return v_id;
  end if;
  insert into public.sitelog_defects(project_id, description, location, completed, created_by)
  values (v_proj, left(btrim(p_text), 1000), 'LINE 群組', false, 'owner') returning id into v_id;   -- 觸發「業主回報缺失」通知
  return v_id;
end $$;

revoke execute on function public.hb_line_chat_info(text,text), public.hb_line_bind(text,text,text,text),
  public.hb_line_photo_add(text,text,text,text,text,bigint), public.hb_line_defect_add(text,text,text,text) from public, anon, authenticated;
grant execute on function public.hb_line_chat_info(text,text), public.hb_line_bind(text,text,text,text),
  public.hb_line_photo_add(text,text,text,text,text,bigint), public.hb_line_defect_add(text,text,text,text) to service_role;
