-- 估價單監工費（%）：以工程合計乘上比例，加在折讓與營業稅之前
alter table public.sitelog_estimates add column if not exists supervise_rate numeric not null default 0;
