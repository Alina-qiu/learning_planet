-- Carry the family policy to native delivery; keep candidate generation and access unchanged.
drop function public.load_task_reminders(uuid);
create function public.load_task_reminders(target_child_id uuid)
returns table(reminder_key text, remind_at timestamptz, titles text, remind_local text, tasks jsonb, delivery_policy jsonb)
language plpgsql security definer set search_path=public as $$
declare zone text; enabled boolean; qs time; qe time;
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required' using errcode='42501'; end if;
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  select s.enabled,s.quiet_start,s.quiet_end into enabled,qs,qe from public.reminder_settings s where s.child_id=target_child_id;
  if enabled=false then return; end if;
  qs := coalesce(qs,'21:00'); qe := coalesce(qe,'07:00');
  return query with candidates as (
    select i.id task_id,i.template_id,i.due_date,i.title,i.scheduled_at,i.due_at from public.task_instances i
      where i.child_id=target_child_id and i.status not in ('completed','skipped','expired','abandoned')
    union all
    select null::uuid,t.id,d.day::date,t.title,(d.day::date+t.start_time) at time zone zone,(d.day::date+t.due_time) at time zone zone
    from public.task_templates t
    cross join generate_series((now() at time zone zone)::date::timestamp,
      ((now() at time zone zone)::date+7)::timestamp,interval '1 day') d(day)
    left join public.long_plans p on p.template_id=t.id
    where t.child_id=target_child_id and t.active and public.template_due_on(t,d.day::date)
      and not exists(select 1 from public.task_instances i where i.template_id=t.id and i.due_date=d.day::date)
      and not exists(select 1 from public.plan_leaves l where l.plan_id=p.id and l.leave_date=d.day::date)
  ), slots as (
    select i.task_id,i.template_id,i.due_date,i.title,v.at from candidates i
    cross join lateral(values(i.scheduled_at-interval '10 minutes'),(i.scheduled_at),(i.due_at-interval '15 minutes')) v(at)
    where v.at between now()-interval '1 day' and now()+interval '7 days'
      and (i.scheduled_at is null or v.at>=i.scheduled_at-interval '10 minutes')
  ), grouped as (
    select 'slot:'||extract(epoch from s.at)::bigint::text k,s.at,string_agg(distinct s.title,'、' order by s.title) names,
      jsonb_agg(distinct jsonb_build_object('task_id',s.task_id,'template_id',s.template_id,'due_date',s.due_date,'title',s.title)) entries
    from slots s where qs=qe or not (
      case when qs<qe then (s.at at time zone zone)::time>=qs and (s.at at time zone zone)::time<qe
      else (s.at at time zone zone)::time>=qs or (s.at at time zone zone)::time<qe end)
    group by s.at
  ) select g.k,g.at,g.names,to_char(g.at at time zone zone,'YYYY-MM-DD HH24:MI')||' '||zone,g.entries,jsonb_build_object('version','task-reminder-v1','timezone',zone,'quiet_start',to_char(qs,'HH24:MI:SS'),'quiet_end',to_char(qe,'HH24:MI:SS')) from grouped g where not exists(
    select 1 from public.reminder_receipts r where r.child_id=target_child_id and r.reminder_key=g.k)
    order by g.at;
end;
$$;


revoke all on function public.load_task_reminders(uuid) from public,anon;
grant execute on function public.load_task_reminders(uuid) to authenticated;
