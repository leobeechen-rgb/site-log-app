-- 每兩個月自動在「今日待辦」加入「寄發票給會計師」（營業稅每單月 15 日前申報）
-- 永遠預先建立下一次（下一個單月 1 號）的待辦；同一期只建立一次，完成或刪除後不會重建。
create or replace function public.hb_today_ensure_invoice_task()
returns void language plpgsql security definer set search_path to '' as $$
declare
  d date := (now() at time zone 'Asia/Taipei')::date;
  due date; tid text; ttl text; m1 int; m2 int;
begin
  due := date_trunc('month', d)::date;
  if due < d then due := (due + interval '1 month')::date; end if;
  while extract(month from due)::int % 2 = 0 loop due := (due + interval '1 month')::date; end loop;
  tid := 'auto-invoice-' || to_char(due, 'YYYY-MM');
  m1 := extract(month from (due - interval '2 month'))::int;
  m2 := extract(month from (due - interval '1 month'))::int;
  ttl := '寄 ' || m1 || '–' || m2 || ' 月發票給會計師';
  update public.hb_today_cloud c
     set payload = jsonb_set(coalesce(c.payload, '{}'::jsonb), '{manual}',
           coalesce(c.payload->'manual', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
             'id', tid, 'title', ttl, 'projectId', '', 'assignee', '', 'due', to_char(due, 'YYYY-MM-DD'),
             'time', '', 'category', '一般', 'urgent', false, 'source', 'manual', 'recurring', 'invoice-bimonthly',
             'note', '營業稅每兩個月申報一次（單月 15 日前）。請整理 ' || m1 || '–' || m2 || ' 月的進項、銷項發票交給會計師。',
             'createdAt', to_char(d, 'YYYY-MM-DD')))),
         revision = c.revision + 1, updated_at = now(), updated_by = 'auto-invoice'
   where c.workspace = 'company'
     and not exists (select 1 from jsonb_array_elements(coalesce(c.payload->'manual', '[]'::jsonb)) x where x->>'id' = tid);
end $$;
revoke execute on function public.hb_today_ensure_invoice_task() from public, anon, authenticated;
-- 每天台北 00:10 檢查一次
select cron.schedule('hb-today-invoice-bimonthly', '10 16 * * *', $$select public.hb_today_ensure_invoice_task()$$);
select public.hb_today_ensure_invoice_task();
