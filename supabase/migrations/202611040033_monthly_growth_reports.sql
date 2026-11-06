-- Parent-facing activity indicators, not ability scores or reward currencies.
alter table public.task_templates add column growth_category text not null default 'general'
  check(growth_category in ('general','learning','exploration','responsibility'));
alter table public.task_instances add column growth_category text not null default 'general'
  check(growth_category in ('general','learning','exploration','responsibility'));
update public.task_instances set growth_category='learning' where source_type='automatic_wrong_review';

create function public.snapshot_growth_category() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.source_type='automatic_wrong_review' then new.growth_category:='learning';
  elsif new.template_id is not null then
    select growth_category into new.growth_category from public.task_templates where id=new.template_id;
  end if;
  return new;
end $$;
create trigger task_growth_category before insert on public.task_instances for each row execute function public.snapshot_growth_category();
revoke all on function public.snapshot_growth_category() from public,anon,authenticated,service_role;

create or replace function public.save_task_schedule_base(target_child_id uuid, config jsonb, target_template_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare family uuid; zone text; today date; tid uuid; rec public.task_recurrence;
  first_day date; last_day date; rule jsonb; st time; dt time; priority text; expected integer; category text;
begin
  select c.family_id,f.timezone into family,zone from public.children c
    join public.families f on f.id=c.family_id where c.id=target_child_id;
  perform public.require_parent_authorization(family);
  priority:=coalesce(config->>'priority',(select task_priority from public.task_templates where id=target_template_id and child_id=target_child_id),'recommended');
  expected:=coalesce((config->>'expected_minutes')::integer,(select expected_minutes from public.task_templates where id=target_template_id and child_id=target_child_id),greatest(20,ceil((config->>'minimum_seconds')::numeric/60)::integer));
  if priority not in ('required','recommended','challenge') or expected not between 1 and 1440
    or expected::bigint*60<(config->>'minimum_seconds')::bigint then raise exception '目标时长需为1至1440分钟且不少于最低时长，任务类别须有效'; end if;
  category:=coalesce(config->>'growth_category',(select growth_category from public.task_templates where id=target_template_id and child_id=target_child_id),'general');
  if category not in ('general','learning','exploration','responsibility') then raise exception '请选择有效的成长分类'; end if;
  today := (now() at time zone zone)::date;
  rec := (config->>'recurrence')::public.task_recurrence;
  first_day := (config->>'starts_on')::date;
  last_day := (config->>'ends_on')::date;
  st := (config->>'start_time')::time; dt := (config->>'due_time')::time;
  rule := coalesce(config->'rule','{}');
  if nullif(btrim(config->>'title'),'') is null or first_day is null
    or last_day is null or last_day<first_day or last_day-first_day>366
    or st is null or dt is null or dt<=st then raise exception 'Invalid schedule configuration'; end if;
  if target_template_id is null and first_day<today then raise exception 'Start date cannot be in the past'; end if;
  if rec='weekly' and (jsonb_typeof(rule->'weekdays') is distinct from 'array'
      or jsonb_array_length(rule->'weekdays')=0
      or exists(select 1 from jsonb_array_elements_text(rule->'weekdays') d
        where d::integer not between 1 and 7)) then raise exception 'Choose valid weekdays'; end if;
  if rec='custom' and (jsonb_typeof(rule->'dates') is distinct from 'array'
      or jsonb_array_length(rule->'dates')=0
      or exists(select 1 from jsonb_array_elements_text(rule->'dates') d
        where d::date not between first_day and last_day)) then raise exception 'Choose dates within schedule'; end if;
  if rec='once' then rule := jsonb_build_object('date',first_day::text); end if;
  if target_template_id is null then
    insert into public.task_templates(child_id,title,recurrence,recurrence_rule,starts_on,ends_on,
      start_time,due_time,coin_reward,xp_reward,minimum_seconds,task_priority,expected_minutes,growth_category)
    values(target_child_id,btrim(config->>'title'),rec,rule,first_day,last_day,st,dt,
      (config->>'coins')::integer,(config->>'xp')::integer,(config->>'minimum_seconds')::integer,priority,expected,category)
      returning id into tid;
    if coalesce((config->>'long_plan')::boolean,false) then
      if rec='once' then raise exception 'A plan requires recurring tasks'; end if;
      insert into public.long_plans(template_id,minimum_rate,bonus_coins,bonus_xp)
      values(tid,(config->>'minimum_rate')::numeric,
        (config->>'bonus_coins')::integer,(config->>'bonus_xp')::integer);
    end if;
  else
    select id into tid from public.task_templates where id=target_template_id and child_id=target_child_id for update;
    if tid is null then raise exception 'Template not found'; end if;
    if exists(select 1 from public.long_plans where template_id=tid) then
      raise exception 'Plan rules are immutable after creation'; end if;
    -- Old clients omit this field. Read again after obtaining the row lock so a
    -- concurrent classified edit cannot be replaced with the pre-lock value.
    if config->>'growth_category' is null then
      select growth_category into category from public.task_templates where id=tid;
    end if;
    update public.task_templates set title=btrim(config->>'title'),recurrence=rec,recurrence_rule=rule,
      starts_on=first_day,ends_on=last_day,start_time=st,due_time=dt,
      coin_reward=(config->>'coins')::integer,xp_reward=(config->>'xp')::integer,
      minimum_seconds=(config->>'minimum_seconds')::integer,task_priority=priority,expected_minutes=expected,growth_category=category,updated_at=now() where id=tid;
  end if;
  perform public.generate_scheduled_tasks(target_child_id);
  return tid;
end;
$$;

revoke all on function public.save_task_schedule_base(uuid,jsonb,uuid) from public,anon,authenticated,service_role;


-- Raw, independently scaled measures. Do not combine these into a ranking.
create function public.monthly_growth_trends(target_child_id uuid,last_month date,today date,zone text) returns jsonb
language sql stable security definer set search_path='' as $$
  with months as (
    select d::date first_day,least(today,(d+interval '1 month'-interval '1 day')::date) last_day,
      least(today,(d+interval '1 month'-interval '1 day')::date)<(d+interval '1 month'-interval '1 day')::date partial
    from generate_series(greatest(date '2000-01-01',last_month-interval '5 months'),last_month,interval '1 month') d
  ), completed as (
    select t.growth_category,t.accumulated_seconds,(t.completed_at at time zone zone)::date completion_day
    from public.task_instances t where t.child_id=target_child_id and t.status='completed'
      and t.completed_at>=(greatest(date '2000-01-01',last_month-interval '5 months')::timestamp at time zone zone)
      and t.completed_at<((least(today,(last_month+interval '1 month'-interval '1 day')::date)+1)::timestamp at time zone zone)
  ), stats as (
    select m.first_day start_date,m.last_day end_date,m.partial,
      count(t.completion_day)::integer completed,
      count(*) filter(where t.growth_category='learning')::integer learning,
      count(distinct t.completion_day)::integer persistence,
      coalesce(sum(t.accumulated_seconds),0)::bigint focus_seconds,
      count(*) filter(where t.growth_category='exploration')::integer exploration,
      count(*) filter(where t.growth_category='responsibility')::integer responsibility,
      count(*) filter(where t.growth_category='general')::integer unclassified
    from months m left join completed t on t.completion_day between m.first_day and m.last_day
    group by m.first_day,m.last_day,m.partial
  )
  select jsonb_build_object('definition_version','activity-v1','series',jsonb_agg(to_jsonb(s) order by start_date)) from stats s;
$$;
revoke all on function public.monthly_growth_trends(uuid,date,date,text) from public,anon,authenticated,service_role;

create index wrong_questions_created_report on public.wrong_questions(child_id,created_at);
create index review_items_answered_report on public.task_review_items(task_instance_id,answered_at) where result is not null;
create function public.monthly_knowledge_distribution(target_child_id uuid,first_instant timestamptz,last_instant timestamptz) returns jsonb
language sql stable security definer set search_path='' as $$
  with records as (
    select q.subject::text subject,coalesce(nullif(btrim(q.knowledge_point),''),'') knowledge_point,
      1 added,0 answered,0 correct
    from public.wrong_questions q where q.child_id=target_child_id and not q.deleting
      and q.created_at>=first_instant and q.created_at<last_instant
    union all
    select coalesce(i.subject::text,'unknown'),coalesce(nullif(btrim(i.knowledge_point),''),''),
      0,1,case when i.result then 1 else 0 end
    from public.task_review_items i join public.task_instances t on t.id=i.task_instance_id
    where t.child_id=target_child_id and i.answered_at>=first_instant and i.answered_at<last_instant
      and i.result is not null and not i.source_deleted
      and not exists(select 1 from public.wrong_questions q where q.id=i.wrong_question_id and q.deleting)
  ), groups as (
    select subject,knowledge_point,sum(added)::integer added,sum(answered)::integer answered,
      sum(correct)::integer correct from records group by subject,knowledge_point
  ), subjects as (
    select subject,sum(added)::integer added,sum(answered)::integer answered,sum(correct)::integer correct,
      jsonb_agg(jsonb_build_object('knowledge_point',knowledge_point,'added',added,'answered',answered,'correct',correct,
        'accuracy',case when answered>0 then round(correct::numeric/answered,4) else null end) order by knowledge_point) points
    from groups group by subject
  )
  select jsonb_build_object('subjects',coalesce(jsonb_agg(to_jsonb(s) order by subject),'[]'::jsonb),
    'added',coalesce(sum(added),0),'answered',coalesce(sum(answered),0),'correct',coalesce(sum(correct),0)) from subjects s;
$$;
revoke all on function public.monthly_knowledge_distribution(uuid,timestamptz,timestamptz) from public,anon,authenticated,service_role;

create or replace function public.learning_report(target_child_id uuid, report_period text default 'week', anchor_date date default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare family uuid; zone text; today date; first_day date; last_day date;
  first_instant timestamptz; last_instant timestamptz; daily jsonb; totals jsonb;
  reviews jsonb; coins jsonb; activities jsonb; due_now integer; activity_count integer;
begin
  select c.family_id,f.timezone into family,zone from public.children c
    join public.families f on f.id=c.family_id where c.id=target_child_id;
  perform public.require_parent_authorization(family);
  if report_period is null or report_period not in ('day','week','month') then
    raise exception 'Unsupported report period' using errcode='22023';
  end if;
  today:=(now() at time zone zone)::date;
  last_day:=coalesce(anchor_date,today);
  if not isfinite(last_day) or last_day>today or last_day<date '2000-01-01' then
    raise exception 'Invalid report date' using errcode='22023';
  end if;
  if report_period='month' then
    first_day:=date_trunc('month',last_day)::date;
    last_day:=least(today,(first_day+interval '1 month'-interval '1 day')::date);
  else
    first_day:=last_day-case when report_period='week' then 6 else 0 end;
  end if;
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
    and not q.archived and not q.deleting and q.mastery_status<>'mastered'
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
    select id,title,due_date,(completed_at at time zone zone) as completed_at,accumulated_seconds as effective_seconds,source_type,growth_category
    from public.task_instances where child_id=target_child_id and status='completed'
      and completed_at>=first_instant and completed_at<last_instant
    order by completed_at desc,id limit 200
  ) a;
  return jsonb_build_object('child_id',target_child_id,'period',report_period,'timezone',zone,
    'today',today,'start_date',first_day,'end_date',last_day,'generated_at',now(),
    'days',daily,'tasks',totals,'reviews',reviews,'due_now',due_now,'coins',coins,
    'activities',activities,'activity_count',activity_count)||case when report_period='month' then
    jsonb_build_object('growth',public.monthly_growth_trends(target_child_id,first_day,today,zone),
      'knowledge',public.monthly_knowledge_distribution(target_child_id,first_instant,last_instant))
    else '{}'::jsonb end;
end $$;
revoke all on function public.learning_report(uuid,text,date) from public,anon,authenticated;
grant execute on function public.learning_report(uuid,text,date) to authenticated;
