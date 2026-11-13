-- Read-only parent reports. Dates and boundaries are always family-local.
create index task_instances_report_idx on public.task_instances(child_id,due_date);
create index task_instances_completed_report_idx on public.task_instances(child_id,completed_at);
create index ledger_entries_report_idx on public.ledger_entries(child_id,created_at);

create function public.learning_report(target_child_id uuid, report_period text default 'week', anchor_date date default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare family uuid; zone text; today date; first_day date; last_day date;
  first_instant timestamptz; last_instant timestamptz; daily jsonb; totals jsonb;
  reviews jsonb; coins jsonb; activities jsonb; due_now integer; activity_count integer;
begin
  select c.family_id,f.timezone into family,zone from public.children c
    join public.families f on f.id=c.family_id where c.id=target_child_id;
  perform public.require_parent_authorization(family);
  if report_period is null or report_period not in ('day','week') then
    raise exception 'Unsupported report period' using errcode='22023';
  end if;
  today:=(now() at time zone zone)::date;
  last_day:=coalesce(anchor_date,today);
  if not isfinite(last_day) or last_day>today or last_day<date '2000-01-01' then
    raise exception 'Invalid report date' using errcode='22023';
  end if;
  first_day:=last_day-case when report_period='week' then 6 else 0 end;
  first_instant:=first_day::timestamp at time zone zone;
  last_instant:=(last_day+1)::timestamp at time zone zone;

  -- The rate is a cohort of generated instances by due date, with approved
  -- plan leave removed. A voluntary skip still counts in the denominator.
  with eligible as (
    select t.* from public.task_instances t
    where t.child_id=target_child_id and t.due_date between first_day and last_day
      and not exists(select 1 from public.long_plans p join public.plan_leaves l on l.plan_id=p.id
        where p.template_id=t.template_id and l.leave_date=t.due_date)
  ), days as (
    select first_day+n as day from generate_series(0,last_day-first_day) n
  ), stats as (
    select d.day,count(t.id)::integer as expected,
      count(t.id) filter(where t.status='completed')::integer as completed,
      coalesce(sum(t.accumulated_seconds),0) as effective_seconds
    from days d left join eligible t on t.due_date=d.day group by d.day
  ) select jsonb_agg(to_jsonb(s) order by day),jsonb_build_object(
    'expected',sum(expected),'completed',sum(completed),'effective_seconds',sum(effective_seconds),
    'completion_rate',case when sum(expected)>0 then round(sum(completed)::numeric/sum(expected),4) else null end)
    into daily,totals from stats s;

  select jsonb_build_object('answered',count(*),'correct',count(*) filter(where i.result),
    'accuracy',case when count(*)>0 then round(count(*) filter(where i.result)::numeric/count(*),4) else null end)
    into reviews from public.task_review_items i join public.task_instances t on t.id=i.task_instance_id
    where t.child_id=target_child_id and i.answered_at>=first_instant and i.answered_at<last_instant
      and i.result is not null;
  select count(*) into due_now from public.wrong_questions q where q.child_id=target_child_id
    and not q.archived and q.mastery_status<>'mastered'
    and q.review_due_at<(today+1)::timestamp at time zone zone;
  -- Freezing and refunding are transfers, not income or consumption.
  select jsonb_build_object(
    'income',coalesce(sum(amount) filter(where asset_type='coin' and amount>0 and source_type<>'redemption_refund'),0),
    'spent',coalesce(sum(-frozen_delta) filter(where source_type='redemption_spend'),0),
    'adjustment_out',coalesce(sum(-amount) filter(where asset_type='coin' and amount<0 and source_type<>'redemption_freeze'),0),
    'xp',coalesce(sum(amount) filter(where asset_type='xp'),0)) into coins
    from public.ledger_entries where child_id=target_child_id and created_at>=first_instant and created_at<last_instant;

  select count(*) into activity_count from public.task_instances
    where child_id=target_child_id and status='completed' and completed_at>=first_instant and completed_at<last_instant;
  select coalesce(jsonb_agg(to_jsonb(a) order by a.completed_at desc,a.id),'[]') into activities from (
    select id,title,due_date,(completed_at at time zone zone) as completed_at,accumulated_seconds as effective_seconds,source_type
    from public.task_instances where child_id=target_child_id and status='completed'
      and completed_at>=first_instant and completed_at<last_instant
    order by completed_at desc,id limit 200
  ) a;
  return jsonb_build_object('child_id',target_child_id,'period',report_period,'timezone',zone,
    'today',today,'start_date',first_day,'end_date',last_day,'generated_at',now(),
    'days',daily,'tasks',totals,'reviews',reviews,'due_now',due_now,'coins',coins,
    'activities',activities,'activity_count',activity_count);
end $$;
revoke all on function public.learning_report(uuid,text,date) from public,anon,authenticated;
grant execute on function public.learning_report(uuid,text,date) to authenticated;
