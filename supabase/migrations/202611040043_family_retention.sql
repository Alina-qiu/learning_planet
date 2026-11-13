-- Family-level, minimal retention metadata; no child, account or task identifiers.
create table public.family_retention (
  family_id uuid primary key references public.families(id) on delete cascade,
  anchor_source text not null check(anchor_source in ('observed','legacy')),
  first_task_at timestamptz,
  cohort_date date,
  cohort_timezone text,
  collection_started_at timestamptz,
  check ((first_task_at is null)=(cohort_date is null)),
  check ((first_task_at is null)=(cohort_timezone is null))
);
create table public.family_activity_days (
  family_id uuid not null references public.family_retention(family_id) on delete cascade,
  activity_date date not null,
  primary key(family_id,activity_date)
);
alter table public.family_retention enable row level security;
alter table public.family_activity_days enable row level security;
revoke all on public.family_retention,public.family_activity_days from public,anon,authenticated;

-- Remaining tasks cannot prove the original first task after historic deletions.
-- Preserve that uncertainty, including existing families with no remaining tasks.
insert into public.family_retention(family_id,anchor_source,first_task_at,cohort_date,cohort_timezone)
select f.id,'legacy',t.first_at,(t.first_at at time zone f.timezone)::date,
  case when t.first_at is not null then f.timezone end
from public.families f left join lateral (
  select min(t.created_at) first_at from public.task_instances t join public.children c on c.id=t.child_id
  where c.family_id=f.id and t.source_type<>'automatic_wrong_review'
) t on true;

create function public.capture_family_first_task() returns trigger
language plpgsql security definer set search_path='' as $$
declare family uuid; zone text; instant timestamptz:=clock_timestamp();
begin
  if new.source_type='automatic_wrong_review' then return new; end if;
  select c.family_id,f.timezone into family,zone from public.children c join public.families f on f.id=c.family_id where c.id=new.child_id;
  insert into public.family_retention(family_id,anchor_source,first_task_at,cohort_date,cohort_timezone)
    values(family,'observed',instant,(instant at time zone zone)::date,zone)
    on conflict(family_id) do update set first_task_at=excluded.first_task_at,
      cohort_date=excluded.cohort_date,cohort_timezone=excluded.cohort_timezone
    where family_retention.first_task_at is null;
  return new;
end $$;
revoke all on function public.capture_family_first_task() from public,anon,authenticated,service_role;
create trigger capture_family_first_task after insert on public.task_instances
for each row execute function public.capture_family_first_task();

create function public.record_family_activity(target_family_id uuid, moments jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); sample jsonb; instant timestamptz; observed timestamptz:=clock_timestamp();
  cohort public.family_retention; day date; accepted integer:=0;
begin
  perform 1 from auth.users where id=actor for share;
  if not found or not public.account_is_active(actor) or not public.is_family_member(target_family_id) then
    raise exception 'FAMILY_ACTIVITY_ACCESS_DENIED' using errcode='42501'; end if;
  perform 1 from public.family_members where family_id=target_family_id and user_id=actor for share;
  if not found then raise exception 'FAMILY_ACTIVITY_ACCESS_DENIED' using errcode='42501'; end if;
  perform 1 from public.families where id=target_family_id for share;
  if not found then raise exception 'FAMILY_ACTIVITY_ACCESS_DENIED' using errcode='42501'; end if;
  if jsonb_typeof(moments) is distinct from 'array' or jsonb_array_length(moments) not between 1 and 16 then
    raise exception 'INVALID_FAMILY_ACTIVITY'; end if;
  -- Whole-batch validation; only canonical UTC instants, never arbitrary strings.
  for sample in select value from jsonb_array_elements(moments) loop
    if jsonb_typeof(sample) is distinct from 'string' or
      (sample#>>'{}') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$' then
      raise exception 'INVALID_FAMILY_ACTIVITY'; end if;
    instant:=(sample#>>'{}')::timestamptz;
  end loop;
  insert into public.family_retention(family_id,anchor_source) values(target_family_id,'observed') on conflict do nothing;
  select * into cohort from public.family_retention where family_id=target_family_id for update;
  for sample in select value from jsonb_array_elements(moments) loop
    instant:=(sample#>>'{}')::timestamptz;
    -- Acknowledged expired/future samples are discarded, never shifted to today.
    if instant>observed or instant<observed-interval '168 hours' then continue; end if;
    accepted:=accepted+1;
    if cohort.collection_started_at is null or instant<cohort.collection_started_at then
      update public.family_retention set collection_started_at=instant where family_id=target_family_id;
      cohort.collection_started_at:=instant;
    end if;
    if cohort.first_task_at is not null then
      day:=(instant at time zone cohort.cohort_timezone)::date;
      if day between cohort.cohort_date and cohort.cohort_date+7 then
        insert into public.family_activity_days values(target_family_id,day) on conflict do nothing;
      end if;
    end if;
  end loop;
  return jsonb_build_object('family_id',target_family_id,'server_time',observed,'acknowledged',moments,'accepted',accepted,
    'cohort_timezone',cohort.cohort_timezone,'complete',coalesce(observed>=
      ((cohort.cohort_date+8)::timestamp at time zone cohort.cohort_timezone)+interval '168 hours',false));
end $$;
revoke all on function public.record_family_activity(uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.record_family_activity(uuid,jsonb) to authenticated;

create function public.family_retention_snapshot(target_family_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('version','retention-v1','family_id',target_family_id,
    'cohort_date',c.cohort_date,'timezone',c.cohort_timezone,'anchor_source',c.anchor_source,
    'days',coalesce((select jsonb_agg(jsonb_build_object('offset',n,'date',c.cohort_date+n,
      'mature',coalesce(now()>=((c.cohort_date+n+1)::timestamp at time zone c.cohort_timezone)+interval '168 hours',false),
      'status',case
        when c.cohort_date is null then 'no_task'
        when c.anchor_source='legacy' then 'historical_unknown'
        when c.collection_started_at is null or (c.collection_started_at at time zone c.cohort_timezone)::date>c.cohort_date then 'collection_unknown'
        when exists(select 1 from public.family_activity_days a where a.family_id=target_family_id and a.activity_date=c.cohort_date+n) then 'returned'
        when now()<((c.cohort_date+n)::timestamp at time zone c.cohort_timezone) then 'pending'
        when now()<((c.cohort_date+n+1)::timestamp at time zone c.cohort_timezone)+interval '168 hours' then 'collecting'
        else 'not_observed' end) order by n) from unnest(array[1,7]) n),'[]'))
  from (select r.* from public.family_retention r where r.family_id=target_family_id
    union all select target_family_id,'observed',null,null,null,null
      where not exists(select 1 from public.family_retention where family_id=target_family_id)) c;
$$;
revoke all on function public.family_retention_snapshot(uuid) from public,anon,authenticated,service_role;

-- Aggregate only mature, instrumented cohorts. No family identifiers leave this RPC.
create function public.family_retention_summary(cohort_from date,cohort_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  if cohort_from is null or cohort_to is null or cohort_to<cohort_from or cohort_to-cohort_from>366 then
    raise exception 'INVALID_RETENTION_RANGE'; end if;
  with observations as (
    select r.*,n,
      r.anchor_source='observed' and (r.collection_started_at at time zone r.cohort_timezone)::date<=r.cohort_date eligible,
      now()>=((r.cohort_date+n+1)::timestamp at time zone r.cohort_timezone)+interval '168 hours' mature,
      exists(select 1 from public.family_activity_days a where a.family_id=r.family_id and a.activity_date=r.cohort_date+n) returned
    from public.family_retention r cross join unnest(array[1,7]) n where r.cohort_date between cohort_from and cohort_to
  ), totals as (
    select n,count(*) families,count(*) filter(where eligible and mature) denominator,
      count(*) filter(where eligible and mature and returned) numerator,
      count(*) filter(where eligible and not mature) pending,
      count(*) filter(where eligible is not true) unknown
    from observations group by n
  ) select jsonb_agg(jsonb_build_object('offset',n,'families',families,'denominator',denominator,'numerator',numerator,
      'pending',pending,'unknown',unknown,'rate',case when denominator>0 then round(numerator::numeric/denominator,4) end) order by n)
    into result from totals;
  return jsonb_build_object('version','retention-v1','cohort_from',cohort_from,'cohort_to',cohort_to,'days',coalesce(result,'[]'));
end $$;
revoke all on function public.family_retention_summary(date,date) from public,anon,authenticated,service_role;
grant execute on function public.family_retention_summary(date,date) to service_role;

alter function public.learning_report(uuid,text,date) rename to learning_report_before_retention;
create function public.learning_report(target_child_id uuid,report_period text default 'week',anchor_date date default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare report jsonb; family uuid;
begin
  report:=public.learning_report_before_retention(target_child_id,report_period,anchor_date);
  select family_id into family from public.children where id=target_child_id;
  return report||jsonb_build_object('family_retention',public.family_retention_snapshot(family));
end $$;
revoke all on function public.learning_report_before_retention(uuid,text,date),public.learning_report(uuid,text,date) from public,anon,authenticated,service_role;
grant execute on function public.learning_report(uuid,text,date) to authenticated;

-- Family-shared metadata is included in each child's parent-authorized export.
alter function public.child_export_source(uuid) rename to child_export_source_before_retention;
create function public.child_export_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select public.child_export_source_before_retention(target_child_id)||jsonb_build_array(
    jsonb_build_object('name','family_retention','columns',jsonb_build_array('family_id','anchor_source','first_task_at','cohort_date','cohort_timezone','collection_started_at'),
      'rows',coalesce((select jsonb_agg(to_jsonb(r)) from public.family_retention r where r.family_id=(select family_id from public.children where id=target_child_id)),'[]')),
    jsonb_build_object('name','family_activity_days','columns',jsonb_build_array('family_id','activity_date'),
      'rows',coalesce((select jsonb_agg(to_jsonb(a) order by a.activity_date) from public.family_activity_days a where a.family_id=(select family_id from public.children where id=target_child_id)),'[]')));
$$;
revoke all on function public.child_export_source(uuid),public.child_export_source_before_retention(uuid) from public,anon,authenticated,service_role;
