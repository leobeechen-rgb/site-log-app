-- 案件別名：待歸檔依檔名判斷案件時使用（例如「豐收」「孫公館」）
alter table public.sitelog_projects add column if not exists aliases text[] not null default '{}';
