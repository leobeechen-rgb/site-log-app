-- 業主端只能讀「業主可見」的圖面版本（2026-10-06，統一上傳中心）
-- 可見條件：版本 note 有 [[HB_OWNER_PUBLISHED]]（逐張發布），或所在資料夾鏈有業主共享且版本沒有 [[HB_OWNER_INTERNAL]]
-- 公司管理端（hb_admin_all）與審核示範帳號（hb_reviewer_all）不受影響

create or replace function public.hb_drawing_folder_shared(p_folder uuid)
returns boolean language sql stable security definer set search_path = public as $$
  with recursive chain as (
    select id, parent_id, owner_shared, 0 as depth from sitelog_drawing_folders where id = p_folder
    union all
    select f.id, f.parent_id, f.owner_shared, c.depth + 1
      from sitelog_drawing_folders f join chain c on f.id = c.parent_id
     where c.depth < 60
  )
  select coalesce(bool_or(owner_shared), false) from chain
$$;

create or replace function public.hb_drawing_version_owner_visible(p_drawing uuid, p_note text)
returns boolean language sql stable security definer set search_path = public as $$
  select position('[[HB_OWNER_PUBLISHED]]' in coalesce(p_note, '')) > 0
      or (position('[[HB_OWNER_INTERNAL]]' in coalesce(p_note, '')) = 0
          and public.hb_drawing_folder_shared((select folder_id from sitelog_drawings where id = p_drawing)))
$$;

create or replace function public.hb_drawing_owner_has_visible(p_drawing uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from sitelog_drawing_versions v
     where v.drawing_id = p_drawing
       and public.hb_drawing_version_owner_visible(v.drawing_id, v.note)
  )
$$;

drop policy if exists hb_owner_read on public.sitelog_drawing_versions;
create policy hb_owner_read on public.sitelog_drawing_versions for select to anon, authenticated
using (
  exists (
    select 1 from sitelog_drawings d
     where d.id = sitelog_drawing_versions.drawing_id
       and hb_drawing_folder_project(d.folder_id) = (select hb_owner_project_id())
  )
  and public.hb_drawing_version_owner_visible(drawing_id, note)
);

drop policy if exists hb_owner_read on public.sitelog_drawings;
create policy hb_owner_read on public.sitelog_drawings for select to anon, authenticated
using (
  hb_drawing_folder_project(folder_id) = (select hb_owner_project_id())
  and public.hb_drawing_owner_has_visible(id)
);
