-- 專案工程合約：工程期限條款加開工日
alter table public.sitelog_contracts add column if not exists start_date date;
comment on column public.sitelog_contracts.start_date is '專案工程合約：開工日（工程期限條款）';
