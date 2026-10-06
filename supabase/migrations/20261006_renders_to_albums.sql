-- 渲染圖／效果圖從「圖面管理」搬到「現場照片」相簿（2026-10-06）
-- 範圍：圖面資料夾名稱含「渲染」或「效果圖」、或圖面類別為「渲染」的圖片（示範案件不動）
-- 做法：每個資料夾變成同名相簿（案件根目錄的渲染圖放進「渲染效果圖」相簿），照片沿用原本的檔案網址，不重新上傳
--       搬移前先把圖面與版本資料備份到 sitelog_render_migration_backup，之後才從圖面管理移除
-- 這份 SQL 可以重複執行：已經搬過的不會再搬一次

create table if not exists public.sitelog_render_migration_backup (
  drawing_id uuid, folder_id uuid, drawing_name text, drawing_no text, category text, drawing_created timestamptz,
  version_id uuid, version_no int, mime text, size bigint, url text, path text, note text, change_note text, uploaded_at timestamptz,
  photo_id uuid, album_id uuid, migrated_at timestamptz default now()
);
alter table public.sitelog_render_migration_backup enable row level security;

do $$
declare
  r record; v_album uuid; v_album_name text; v_photo uuid;
begin
  for r in
    select d.id as did, d.name as dname, d.drawing_no as dno, d.category as dcat, d.created_at as dcreated,
           f.id as fid, f.name as fname, f.parent_id as fparent,
           cv.url as curl, cv.size as csize, cv.change_note as cnote, cv.uploaded_at as cat,
           (with recursive c as (
              select id, parent_id, project_id from sitelog_drawing_folders where id = d.folder_id
              union all
              select x.id, x.parent_id, x.project_id from sitelog_drawing_folders x join c on x.id = c.parent_id
            ) select project_id from c where parent_id is null limit 1) as pid
      from sitelog_drawings d
      join sitelog_drawing_versions cv on cv.id = d.current_version_id
      join sitelog_drawing_folders f on f.id = d.folder_id
     where cv.mime like 'image/%'
       and (f.name ~ '(渲染|效果圖)' or d.category = '渲染')
     order by cv.uploaded_at, d.name
  loop
    continue when r.pid is null;
    continue when exists (select 1 from sitelog_projects p where p.id = r.pid and p.name like '示範案件%');

    v_album_name := case when r.fparent is null or r.fname !~ '(渲染|效果圖)' then '渲染效果圖' else r.fname end;
    v_album := null;
    select id into v_album from sitelog_albums where project_id = r.pid and name = v_album_name order by created_at limit 1;
    if v_album is null then
      insert into sitelog_albums(project_id, name) values (r.pid, v_album_name) returning id into v_album;
    end if;

    insert into sitelog_photos(project_id, album_id, url, path, note, size, uploaded_at)
    values (r.pid, v_album, r.curl, null, nullif(trim(coalesce(r.cnote, '')), ''), r.csize, coalesce(r.cat, now()))
    returning id into v_photo;

    insert into sitelog_render_migration_backup
      (drawing_id, folder_id, drawing_name, drawing_no, category, drawing_created,
       version_id, version_no, mime, size, url, path, note, change_note, uploaded_at, photo_id, album_id)
    select r.did, r.fid, r.dname, r.dno, r.dcat, r.dcreated,
           v.id, v.version_no, v.mime, v.size, v.url, v.path, v.note, v.change_note, v.uploaded_at, v_photo, v_album
      from sitelog_drawing_versions v where v.drawing_id = r.did;

    delete from sitelog_drawings where id = r.did;   -- 版本隨之刪除（cascade）；R2 檔案保留，照片仍用同一網址
  end loop;

  -- 搬空的渲染資料夾一併移除（裡面已經沒有圖面也沒有子資料夾才刪）
  delete from sitelog_drawing_folders f
   where f.parent_id is not null and f.name ~ '(渲染|效果圖)'
     and not exists (select 1 from sitelog_drawings d where d.folder_id = f.id)
     and not exists (select 1 from sitelog_drawing_folders c where c.parent_id = f.id)
     and exists (select 1 from sitelog_render_migration_backup b where b.folder_id = f.id);
end $$;

-- 結果：每個相簿搬進幾張
select p.name as 案件, a.name as 相簿, count(distinct b.photo_id) as 搬入張數
  from sitelog_render_migration_backup b
  join sitelog_albums a on a.id = b.album_id
  join sitelog_projects p on p.id = a.project_id
 group by 1, 2 order by 1, 2;
