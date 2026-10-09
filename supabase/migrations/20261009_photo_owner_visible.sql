-- 照片可設定是否分享給業主（工作台案件面板上傳照片時可選）
-- 既有照片一律維持可見（default true）；設成 false 的照片，業主端讀不到（RLS）
alter table public.sitelog_photos add column if not exists visible_to_owner boolean not null default true;
alter policy hb_owner_read on public.sitelog_photos
  using (project_id = (select public.hb_owner_project_id()) and visible_to_owner);
