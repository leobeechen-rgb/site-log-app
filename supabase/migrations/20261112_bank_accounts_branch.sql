-- 付款帳戶加「分行」欄位（選填）。已用 apply_migration 套用（bank_accounts_add_branch）；此檔為紀錄。
alter table public.sitelog_bank_accounts add column if not exists bank_branch text;
