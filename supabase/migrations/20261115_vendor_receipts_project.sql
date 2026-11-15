-- 廠商領據加「案件」欄位；既有資料依工程地址比對案件地址自動歸類。（已用 apply_migration 套用）
alter table public.sitelog_vendor_receipts add column if not exists project_id uuid references public.sitelog_projects(id) on delete set null;
create index if not exists sitelog_vendor_receipts_project_idx on public.sitelog_vendor_receipts(project_id);
