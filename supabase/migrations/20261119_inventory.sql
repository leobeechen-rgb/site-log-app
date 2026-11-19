-- 公司資料庫 → 材料庫存（工地剩料／常備材料）。（已用 apply_migration「inventory_items_logs」套用）
create table if not exists public.sitelog_inventory_items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null default '其他',
  source text not null default 'buy' check (source in ('buy','left')),
  spec text, qty numeric not null default 0, unit text, min_qty numeric, unit_price numeric,
  location text, project_id uuid references public.sitelog_projects(id) on delete set null,
  case_name text, vendor text, note text, photo_url text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.sitelog_inventory_logs (
  id uuid primary key default gen_random_uuid(),
  item_id uuid references public.sitelog_inventory_items(id) on delete set null,
  item_name text,
  move_type text not null check (move_type in ('in','out')),
  qty numeric not null check (qty > 0),
  move_date date not null default ((now() at time zone 'Asia/Taipei')::date),
  project_id uuid references public.sitelog_projects(id) on delete set null,
  case_name text, note text, created_at timestamptz not null default now()
);
create index if not exists sitelog_inventory_logs_item_idx on public.sitelog_inventory_logs(item_id);
create index if not exists sitelog_inventory_logs_project_idx on public.sitelog_inventory_logs(project_id);
create index if not exists sitelog_inventory_items_project_idx on public.sitelog_inventory_items(project_id);
alter table public.sitelog_inventory_items enable row level security;
alter table public.sitelog_inventory_logs enable row level security;
create policy hb_admin_all on public.sitelog_inventory_items for all to authenticated
  using ((select public.is_hb_admin())) with check ((select public.is_hb_admin()));
create policy hb_admin_all on public.sitelog_inventory_logs for all to authenticated
  using ((select public.is_hb_admin())) with check ((select public.is_hb_admin()));
create or replace function public.sitelog_inventory_move(
  p_item uuid, p_type text, p_qty numeric, p_date date, p_project uuid, p_case text, p_note text)
returns numeric language plpgsql security invoker set search_path to '' as $$
declare v_qty numeric; v_name text;
begin
  if p_qty is null or p_qty <= 0 then raise exception '數量要大於 0'; end if;
  select qty, name into v_qty, v_name from public.sitelog_inventory_items where id = p_item for update;
  if not found then raise exception '找不到這項材料'; end if;
  if p_type = 'out' and p_qty > v_qty then raise exception '出庫數量超過現有庫存'; end if;
  v_qty := v_qty + case when p_type = 'in' then p_qty else -p_qty end;
  update public.sitelog_inventory_items set qty = v_qty, updated_at = now() where id = p_item;
  insert into public.sitelog_inventory_logs(item_id,item_name,move_type,qty,move_date,project_id,case_name,note)
  values (p_item, v_name, p_type, p_qty, coalesce(p_date,(now() at time zone 'Asia/Taipei')::date), p_project, nullif(p_case,''), nullif(p_note,''));
  return v_qty;
end $$;
revoke execute on function public.sitelog_inventory_move(uuid,text,numeric,date,uuid,text,text) from public, anon;
grant execute on function public.sitelog_inventory_move(uuid,text,numeric,date,uuid,text,text) to authenticated;
