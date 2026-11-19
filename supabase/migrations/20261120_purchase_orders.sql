-- 文件系統 → 產品訂購單（向廠商下訂）。（已用 apply_migration「purchase_orders」套用）
create table if not exists public.sitelog_purchase_orders (
  id uuid primary key default gen_random_uuid(),
  no text not null default '',
  project_id uuid references public.sitelog_projects(id) on delete set null,
  vendor_id uuid references public.sitelog_vendors(id) on delete set null,
  vendor_name text not null default '', vendor_contact text not null default '', vendor_phone text not null default '',
  order_date date not null default ((now() at time zone 'Asia/Taipei')::date),
  delivery_date date, delivery_address text not null default '', receiver text not null default '',
  items jsonb not null default '[]'::jsonb,
  tax_rate numeric not null default 0, subtotal numeric not null default 0, total numeric not null default 0,
  payment_terms text not null default '', note text not null default '',
  status text not null default 'draft' check (status in ('draft','sent','confirmed','received','cancelled')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists sitelog_purchase_orders_project_idx on public.sitelog_purchase_orders(project_id);
create index if not exists sitelog_purchase_orders_vendor_idx on public.sitelog_purchase_orders(vendor_id);
alter table public.sitelog_purchase_orders enable row level security;
create policy hb_admin_all on public.sitelog_purchase_orders for all to authenticated
  using ((select public.is_hb_admin())) with check ((select public.is_hb_admin()));
