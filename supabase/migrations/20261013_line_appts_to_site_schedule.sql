-- LINE 群組約定：進場／施工類（「明天 8 點到」「週三進場」）直接排進 sitelog_schedule_events（status 'scheduled'）
-- 其他約定維持 open → 工作台待辦。已用 apply_migration 套用（line_appts_to_site_schedule）。
alter table public.hb_line_appts add column if not exists schedule_id uuid;
