-- 合約「初步預算書」收取比例（%），新增合約時會寫入
alter table public.sitelog_contracts add column if not exists budget_rate numeric;
notify pgrst, 'reload schema';
