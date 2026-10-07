-- 業主確認回覆加簽名（全部確認時必填）
alter table public.hb_confirm_replies add column if not exists signer_name text;
alter table public.hb_confirm_replies add column if not exists signature text;
