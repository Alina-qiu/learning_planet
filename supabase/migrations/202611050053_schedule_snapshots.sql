-- Keyset pages include plan progress in one read, rather than one HTTP request
-- per plan. Reading schedules never generates tasks or settles rewards.
create index task_templates_child_page_idx on public.task_templates(child_id,created_at desc,id desc);

create function public.task_schedule_page(target_child_id uuid,
  after_created_at timestamptz default null,after_id uuid default null,page_size integer default 100)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare family uuid; zone text; result jsonb; cursor jsonb; more boolean;
begin
  if not public.child_is_visible(target_child_id) then
    raise exception 'Child access required' using errcode='42501'; end if;
  if page_size is null or page_size<1 or page_size>200
    or (after_created_at is null)<>(after_id is null)
    or (after_created_at is not null and not isfinite(after_created_at)) then
    raise exception 'Invalid schedule page' using errcode='22023'; end if;
  select c.family_id,f.timezone into family,zone from public.children c join public.families f on f.id=c.family_id
    where c.id=target_child_id;
  with candidates as materialized (
    select t.* from public.task_templates t where t.child_id=target_child_id
      and (after_created_at is null or (t.created_at,t.id)<(after_created_at,after_id))
    order by t.created_at desc,t.id desc limit page_size+1
  ), page as materialized (
    select * from candidates order by created_at desc,id desc limit page_size
  ), details as (
    select t.id,t.created_at,to_jsonb(t)||jsonb_build_object('long_plans',
      case when p.id is null then null else to_jsonb(p)||jsonb_build_object(
        'plan_leaves',coalesce((select jsonb_agg(jsonb_build_object('leave_date',l.leave_date) order by l.leave_date)
          from public.plan_leaves l where l.plan_id=p.id),'[]'),
        'plan_stage_rewards',coalesce((select jsonb_agg(to_jsonb(s) order by s.completed_count)
          from public.plan_stage_rewards s where s.plan_id=p.id),'[]'),
        'plan_bonus_tiers',coalesce((select jsonb_agg(to_jsonb(b) order by b.minimum_rate)
          from public.plan_bonus_tiers b where b.plan_id=p.id),'[]'),
        'progress',(select to_jsonb(progress) from public.long_plan_progress(p.id) progress)
      ) end) as value
    from page t left join public.long_plans p on p.template_id=t.id
  )
  select coalesce((select jsonb_agg(value order by created_at desc,id desc) from details),'[]'),
    (select count(*)>page_size from candidates),
    (select jsonb_build_object('created_at',created_at,'id',id) from page order by created_at,id limit 1)
    into result,more,cursor;
  return jsonb_build_object('child_id',target_child_id,'family_id',family,'family_today',(now() at time zone zone)::date,
    'fetched_at',now(),'items',result,'next_cursor',case when more then cursor else null end);
end $$;
revoke all on function public.task_schedule_page(uuid,timestamptz,uuid,integer) from public,anon,service_role;
grant execute on function public.task_schedule_page(uuid,timestamptz,uuid,integer) to authenticated;
