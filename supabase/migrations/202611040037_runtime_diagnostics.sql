-- Fixed, non-content diagnostics. Receipts are private and account scoped;
-- daily counters contain no account, family, child or request identifiers.
create table public.runtime_diagnostic_receipts (
  owner_id uuid not null references auth.users(id) on delete cascade,
  event_id uuid not null, payload jsonb not null,
  received_at timestamptz not null default now(), primary key(owner_id,event_id)
);
create index runtime_receipts_retention on public.runtime_diagnostic_receipts(received_at);
create index runtime_receipts_rate on public.runtime_diagnostic_receipts(owner_id,received_at);
create table public.runtime_diagnostic_daily (
  day date not null, origin text not null check(origin in ('client','server')),
  kind text not null, operation text not null, outcome text not null,
  error_code text not null, latency_bucket smallint not null check(latency_bucket between 0 and 6),
  events bigint not null check(events>0),
  primary key(day,origin,kind,operation,outcome,error_code,latency_bucket)
);
alter table public.runtime_diagnostic_receipts enable row level security;
alter table public.runtime_diagnostic_daily enable row level security;
revoke all on public.runtime_diagnostic_receipts,public.runtime_diagnostic_daily from public,anon,authenticated,service_role;

create function public.valid_runtime_diagnostic(e jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
declare field text;
begin
  if jsonb_typeof(e) is distinct from 'object' or
    (select array_agg(k order by k) from jsonb_object_keys(e) k) is distinct from
      array['bucket','day','error','event_id','kind','operation','outcome'] then return false; end if;
  if jsonb_typeof(e->'event_id') is distinct from 'string' or
    (e->>'event_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or
    jsonb_typeof(e->'day') is distinct from 'string' or (e->>'day') !~ '^\d{4}-\d{2}-\d{2}$' or
    jsonb_typeof(e->'bucket') is distinct from 'number' or (e->>'bucket') !~ '^[0-6]$' then return false; end if;
  perform (e->>'day')::date;
  foreach field in array array['error','kind','operation','outcome'] loop
    if jsonb_typeof(e->field) is distinct from 'string' then return false; end if;
  end loop;
  if not (e->>'error'=any(array['none','state','format','type','range','unsupported','unknown'])) or
    not (e->>'outcome'=any(array['ok','client_error','server_error','network','timeout','cancelled','conflict','authorization','unexpected'])) then return false; end if;
  if e->>'kind'='api' then
    return coalesce(e->>'operation'=any(array['auth','database','storage','edge']),false);
  elsif e->>'kind'='sync' then
    return coalesce(e->>'operation'=any(array['tasks','reviews','images']),false);
  elsif e->>'kind'='runtime' then
    return coalesce(e->>'operation'=any(array['framework','async','startup']) and e->>'outcome'='unexpected' and e->>'bucket'='0',false);
  end if;
  return false;
exception when others then return false;
end $$;
revoke all on function public.valid_runtime_diagnostic(jsonb) from public,anon,authenticated,service_role;

create function public.record_runtime_diagnostics(events jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); e jsonb; previous jsonb;
  today date:=(now() at time zone 'UTC')::date; used integer; ids jsonb:='[]';
begin
  if actor is null then raise exception 'DIAGNOSTICS_ACCESS_DENIED' using errcode='42501'; end if;
  -- Account deletion takes FOR UPDATE on this row before its privacy barrier.
  perform 1 from auth.users where id=actor for share;
  if not found or not public.account_is_active(actor) then raise exception 'DIAGNOSTICS_ACCESS_DENIED' using errcode='42501'; end if;
  if jsonb_typeof(events) is distinct from 'array' or jsonb_array_length(events) not between 1 and 50 then
    raise exception 'INVALID_DIAGNOSTICS'; end if;
  if (select count(distinct x->>'event_id') from jsonb_array_elements(events) x)<>jsonb_array_length(events) then
    raise exception 'DUPLICATE_DIAGNOSTICS'; end if;
  -- Validate the entire batch before any mutation; unknown fields cannot carry text.
  for e in select value from jsonb_array_elements(events) loop
    if not public.valid_runtime_diagnostic(e) then raise exception 'INVALID_DIAGNOSTICS'; end if;
    if (e->>'day')::date not between today-7 and today then raise exception 'DIAGNOSTICS_EXPIRED'; end if;
  end loop;
  perform pg_advisory_xact_lock(hashtextextended('runtime-diagnostics:'||actor::text,0));
  select count(*) into used from public.runtime_diagnostic_receipts where owner_id=actor and received_at>=now()-interval '1 day';
  for e in select value from jsonb_array_elements(events) loop
    select payload into previous from public.runtime_diagnostic_receipts where owner_id=actor and event_id=(e->>'event_id')::uuid;
    if found then
      if previous<>e then raise exception 'DIAGNOSTICS_RECEIPT_MISMATCH'; end if;
    else
      if used>=10000 then raise exception 'DIAGNOSTICS_RATE_LIMIT'; end if;
      insert into public.runtime_diagnostic_receipts(owner_id,event_id,payload) values(actor,(e->>'event_id')::uuid,e);
      used:=used+1;
      insert into public.runtime_diagnostic_daily(day,origin,kind,operation,outcome,error_code,latency_bucket,events)
        values((e->>'day')::date,'client',e->>'kind',e->>'operation',e->>'outcome',e->>'error',(e->>'bucket')::smallint,1)
        on conflict(day,origin,kind,operation,outcome,error_code,latency_bucket)
        do update set events=runtime_diagnostic_daily.events+1;
    end if;
    ids:=ids||jsonb_build_array(e->>'event_id');
  end loop;
  return jsonb_build_object('event_ids',ids);
end $$;
revoke all on function public.record_runtime_diagnostics(jsonb) from public,anon,authenticated,service_role;
grant execute on function public.record_runtime_diagnostics(jsonb) to authenticated;

create function public.erase_account_runtime_receipts() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  delete from public.runtime_diagnostic_receipts where owner_id=new.user_id;
  return new;
end $$;
create trigger erase_account_runtime_receipts after insert on public.account_deletion_jobs
  for each row execute function public.erase_account_runtime_receipts();
revoke all on function public.erase_account_runtime_receipts() from public,anon,authenticated,service_role;

-- Record confirmed AI terminal outcomes inside the same transaction. No model
-- body, provider error message, identity or request UUID enters these counters.
create function public.count_ai_runtime_outcome() returns trigger
language plpgsql security definer set search_path='' as $$
declare elapsed double precision; bucket smallint;
begin
  if old.state<>'running' or new.state not in ('completed','failed') then return new; end if;
  elapsed:=greatest(0,extract(epoch from (clock_timestamp()-new.created_at))*1000);
  bucket:=case when elapsed<100 then 0 when elapsed<500 then 1 when elapsed<1500 then 2
    when elapsed<3000 then 3 when elapsed<10000 then 4 when elapsed<30000 then 5 else 6 end;
  insert into public.runtime_diagnostic_daily(day,origin,kind,operation,outcome,error_code,latency_bucket,events)
    values((now() at time zone 'UTC')::date,'server','ai',new.purpose,
      case when new.state='completed' then 'ok' else 'failed' end,'none',bucket,1)
    on conflict(day,origin,kind,operation,outcome,error_code,latency_bucket)
    do update set events=runtime_diagnostic_daily.events+1;
  return new;
end $$;
create trigger count_ai_runtime_outcome after update of state on public.ai_analysis_requests
  for each row execute function public.count_ai_runtime_outcome();
revoke all on function public.count_ai_runtime_outcome() from public,anon,authenticated,service_role;

create function public.purge_runtime_diagnostics() returns void
language plpgsql security definer set search_path='' as $$
begin
  -- Keep deduplication longer than the entire accepted (UTC day) replay window.
  delete from public.runtime_diagnostic_receipts where received_at<now()-interval '9 days';
  delete from public.runtime_diagnostic_daily where day<(now() at time zone 'UTC')::date-89;
end $$;
revoke all on function public.purge_runtime_diagnostics() from public,anon,authenticated,service_role;
grant execute on function public.purge_runtime_diagnostics() to service_role;

create function public.runtime_health_report(days integer default 7) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  if days is null or days not between 1 and 90 then raise exception 'INVALID_DIAGNOSTIC_RANGE'; end if;
  return jsonb_build_object('timezone','UTC','days',days,
    'bucket_upper_ms',jsonb_build_array(100,500,1500,3000,10000,30000,null),
    'counts',coalesce((select jsonb_agg(to_jsonb(r) order by r.day,r.origin,r.kind,r.operation,r.outcome,r.error_code,r.latency_bucket)
      from (select * from public.runtime_diagnostic_daily where day>=(now() at time zone 'UTC')::date-(days-1)) r),'[]'::jsonb),
    'ai',coalesce((select jsonb_agg(to_jsonb(a) order by a.operation) from (
      select operation,coalesce(sum(events) filter(where outcome='ok'),0) as succeeded,
        coalesce(sum(events) filter(where outcome='failed'),0) as failed,
        round(coalesce(sum(events) filter(where outcome='failed'),0)::numeric/nullif(sum(events),0),4) as failure_rate
      from public.runtime_diagnostic_daily where origin='server' and kind='ai'
        and day>=(now() at time zone 'UTC')::date-(days-1) group by operation
    ) a),'[]'::jsonb));
end $$;
revoke all on function public.runtime_health_report(integer) from public,anon,authenticated,service_role;
grant execute on function public.runtime_health_report(integer) to service_role;
