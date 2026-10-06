-- 案件圓形大頭貼（例如 LINE 群組照片），公司端在案件列表自行上傳
alter table public.sitelog_projects add column if not exists avatar_url text;
comment on column public.sitelog_projects.avatar_url is '案件圓形大頭貼（例如 LINE 群組照片），公司端自行上傳，存 R2 公開網址';
