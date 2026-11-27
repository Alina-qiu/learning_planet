-- A provider acceptance is not a task read receipt or proof of presentation.
-- Each installation/scope gets at most one job for a merged reminder instant.
create table public.task_push_jobs (
  id uuid primary key default gen_random_uuid(),
  device_id uuid not null references public.task_push_devices(device_id) on delete cascade,
  device_version bigint not null,
  device_token_hash text,
  family_id uuid not null,
  owner_id uuid not null,
  child_id uuid not null references public.children(id) on delete cascade,
  reminder_key text not null,
  scheduled_at timestamptz not null,
  expires_at timestamptz not null,
  state text not null default 'queued' check(state in ('queued','running','sent','cancelled')),
  attempts integer not null default 0 check(attempts between 0 and 5),
  next_attempt_at timestamptz not null default now(),
  lease_token uuid,
  lease_until timestamptz,
  result_code text,
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  foreign key(family_id,owner_id) references public.family_members(family_id,user_id) on delete cascade,
  unique(device_id,device_version,reminder_key)
);
create index task_push_jobs_due on public.task_push_jobs(next_attempt_at,id) where state in ('queued','running');
alter table public.task_push_jobs enable row level security;
revoke all on public.task_push_jobs from public,anon,authenticated,service_role;

create function public.task_push_is_allowed(child uuid,actor uuid,instant timestamptz) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.children c join public.families f on f.id=c.family_id
    left join public.reminder_settings s on s.child_id=c.id
    where c.id=child and public.family_member_is_active(c.family_id,actor)
      and not exists(select 1 from public.child_deletion_tombstones t where t.child_id=c.id)
      and coalesce(s.enabled,true) and not (
        case when coalesce(s.quiet_start,'21:00')=coalesce(s.quiet_end,'07:00') then false
          when coalesce(s.quiet_start,'21:00')<coalesce(s.quiet_end,'07:00') then
            (instant at time zone f.timezone)::time>=coalesce(s.quiet_start,'21:00') and (instant at time zone f.timezone)::time<coalesce(s.quiet_end,'07:00')
          else (instant at time zone f.timezone)::time>=coalesce(s.quiet_start,'21:00') or (instant at time zone f.timezone)::time<coalesce(s.quiet_end,'07:00') end));
$$;
revoke all on function public.task_push_is_allowed(uuid,uuid,timestamptz) from public,anon,authenticated,service_role;

create function public.enqueue_task_push_jobs() returns integer
language plpgsql security definer set search_path='' as $$
declare candidates jsonb; row record; added integer;
begin
  select coalesce(jsonb_agg(to_jsonb(c)),'[]') into candidates from (
    select d.device_id,d.intent_version,d.family_id,d.owner_id,d.child_id,r.reminder_key,r.remind_at
    from public.task_push_devices d cross join lateral public.task_reminder_candidates(d.child_id,now(),true) r
    where d.state='enabled' and d.expires_at>now() and r.remind_at<=now() and r.remind_at>now()-interval '15 minutes'
      and public.task_push_is_allowed(d.child_id,d.owner_id,now())
      and not exists(select 1 from public.task_push_jobs j where j.device_id=d.device_id and j.device_version=d.intent_version and j.reminder_key=r.reminder_key)
    order by r.remind_at,d.device_id limit 200
  ) c;
  -- Account/membership/child barriers match registration and privacy deletion.
  for row in select distinct c.owner_id from jsonb_to_recordset(candidates) c(owner_id uuid) order by c.owner_id loop
    perform 1 from auth.users where id=row.owner_id for share;
  end loop;
  for row in select distinct c.family_id,c.owner_id from jsonb_to_recordset(candidates) c(family_id uuid,owner_id uuid) order by c.family_id,c.owner_id loop
    perform 1 from public.family_members where family_id=row.family_id and user_id=row.owner_id for share;
  end loop;
  for row in select distinct c.child_id from jsonb_to_recordset(candidates) c(child_id uuid) order by c.child_id loop
    perform pg_advisory_xact_lock(hashtextextended('cleanup:'||row.child_id::text,0));
    perform 1 from public.children where id=row.child_id for share;
  end loop;
  insert into public.task_push_jobs(device_id,device_version,family_id,owner_id,child_id,reminder_key,scheduled_at,expires_at)
    select d.device_id,d.intent_version,d.family_id,d.owner_id,d.child_id,c.reminder_key,c.remind_at,c.remind_at+interval '15 minutes'
    from jsonb_to_recordset(candidates) c(device_id uuid,intent_version bigint,child_id uuid,reminder_key text,remind_at timestamptz)
    join public.task_push_devices d on d.device_id=c.device_id and d.intent_version=c.intent_version and d.child_id=c.child_id
    where d.state='enabled' and d.expires_at>now() and public.task_push_is_allowed(d.child_id,d.owner_id,now())
      and exists(select 1 from public.task_reminder_candidates(d.child_id,now(),true) r where r.reminder_key=c.reminder_key and r.remind_at=c.remind_at)
    on conflict do nothing;
  get diagnostics added=row_count;
  return added;
end $$;
revoke all on function public.enqueue_task_push_jobs() from public,anon,authenticated,service_role;
grant execute on function public.enqueue_task_push_jobs() to service_role;

create function public.claim_task_push_jobs(max_jobs integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job record; claims jsonb:='[]'; token uuid;
begin
  if max_jobs is null or max_jobs not between 1 and 20 then raise exception 'INVALID_TASK_PUSH_CLAIM'; end if;
  update public.task_push_jobs set state='cancelled',result_code='expired',finished_at=now(),lease_until=null
    where state in ('queued','running') and (expires_at<=now() or attempts>=5 and (state='queued' or lease_until<=now()));
  for job in select j.id,d.registration_hash from public.task_push_jobs j join public.task_push_devices d on d.device_id=j.device_id
    where (j.state='queued' and j.next_attempt_at<=now() or j.state='running' and j.lease_until<=now())
      and j.expires_at>now() and j.attempts<5 and d.state='enabled' and d.expires_at>now()
      and d.intent_version=j.device_version and d.child_id=j.child_id and d.owner_id=j.owner_id
      and public.task_push_is_allowed(j.child_id,j.owner_id,now())
    order by j.scheduled_at,j.id limit max_jobs for update of j skip locked
  loop
    token:=gen_random_uuid();
    update public.task_push_jobs set state='running',attempts=attempts+1,device_token_hash=job.registration_hash,
      lease_token=token,lease_until=least(clock_timestamp()+interval '2 minutes',expires_at) where id=job.id;
    claims:=claims||jsonb_build_array(jsonb_build_object('job_id',job.id,'lease_token',token));
  end loop;
  return claims;
end $$;
revoke all on function public.claim_task_push_jobs(integer) from public,anon,authenticated,service_role;
grant execute on function public.claim_task_push_jobs(integer) to service_role;

create function public.authorize_task_push_job(target_job_id uuid,token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job public.task_push_jobs; device public.task_push_devices; instant timestamptz; zone text; qs time; qe time; version bigint;
begin
  select * into job from public.task_push_jobs where id=target_job_id;
  if not found then return jsonb_build_object('status','stale'); end if;
  begin perform public.lock_task_push_scope(job.child_id,job.owner_id);
  exception when insufficient_privilege then return jsonb_build_object('status','stale'); end;
  -- Lock the device before its dependent job, matching deletion cascades.
  select * into device from public.task_push_devices where device_id=job.device_id for update;
  select * into job from public.task_push_jobs where id=target_job_id for update;
  instant:=clock_timestamp();
  if not found or job.state<>'running' or job.lease_token is distinct from token or job.lease_until<=instant then return jsonb_build_object('status','stale'); end if;
  if device.state is distinct from 'enabled' or device.intent_version is distinct from job.device_version
    or device.child_id is distinct from job.child_id or device.owner_id is distinct from job.owner_id
    or device.expires_at<=instant or job.expires_at<=instant
    or not public.task_push_is_allowed(job.child_id,job.owner_id,instant)
    or not exists(select 1 from public.task_reminder_candidates(job.child_id,instant,true) r where r.reminder_key=job.reminder_key and r.remind_at=job.scheduled_at) then
    update public.task_push_jobs set state='cancelled',result_code='superseded',finished_at=instant,lease_until=null where id=job.id;
    return jsonb_build_object('status','cancelled');
  end if;
  if device.registration_hash is distinct from job.device_token_hash then
    update public.task_push_jobs set state='queued',next_attempt_at=instant,lease_token=null,lease_until=null,attempts=greatest(0,attempts-1) where id=job.id;
    return jsonb_build_object('status','deferred');
  end if;
  select f.timezone,coalesce(s.quiet_start,'21:00'),coalesce(s.quiet_end,'07:00'),coalesce(v.version,1) into zone,qs,qe,version
    from public.families f left join public.reminder_settings s on s.child_id=job.child_id
      left join public.task_push_policy_versions v on v.child_id=job.child_id where f.id=job.family_id;
  return jsonb_build_object('status','authorized','transport','apns','registration_token',device.registration_token,
    'data',jsonb_build_object('version','task-push-v1','message_id',job.id::text,'scope_nonce',device.scope_nonce::text,'kind','task',
      'scheduled_ms',floor(extract(epoch from job.scheduled_at)*1000)::bigint::text,
      'issued_ms',floor(extract(epoch from instant)*1000)::bigint::text,
      'expires_ms',floor(extract(epoch from least(instant+interval '60 seconds',job.expires_at,device.expires_at))*1000)::bigint::text,
      'timezone',zone,'quiet_start',qs::text,'quiet_end',qe::text,'settings_version',version::text));
end $$;
revoke all on function public.authorize_task_push_job(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.authorize_task_push_job(uuid,uuid) to service_role;

create function public.finish_task_push_job(target_job_id uuid,token uuid,outcome text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job public.task_push_jobs; device public.task_push_devices; instant timestamptz;
begin
  if outcome is null or outcome not in ('accepted','retry','rejected','invalid_token') then raise exception 'INVALID_TASK_PUSH_OUTCOME'; end if;
  select * into job from public.task_push_jobs where id=target_job_id;
  if not found then return jsonb_build_object('status','stale'); end if;
  begin perform public.lock_task_push_scope(job.child_id,job.owner_id);
  exception when insufficient_privilege then return jsonb_build_object('status','stale'); end;
  select * into device from public.task_push_devices where device_id=job.device_id for update;
  select * into job from public.task_push_jobs where id=target_job_id for update;
  instant:=clock_timestamp();
  if not found or job.lease_token is distinct from token then return jsonb_build_object('status','stale'); end if;
  if job.state='sent' then return jsonb_build_object('status','sent'); end if;
  if job.state<>'running' or job.lease_until<=instant then return jsonb_build_object('status','stale'); end if;
  if device.state is distinct from 'enabled' or device.intent_version is distinct from job.device_version
    or device.child_id is distinct from job.child_id or device.owner_id is distinct from job.owner_id or device.expires_at<=instant then
    update public.task_push_jobs set state='cancelled',result_code='superseded',finished_at=instant,lease_until=null where id=job.id;
    return jsonb_build_object('status','cancelled');
  end if;
  if device.registration_hash is distinct from job.device_token_hash then
    update public.task_push_jobs set state='queued',next_attempt_at=instant,lease_token=null,lease_until=null,attempts=greatest(0,attempts-1) where id=job.id;
    return jsonb_build_object('status','deferred');
  end if;
  if outcome='accepted' then
    update public.task_push_jobs set state='sent',result_code=outcome,finished_at=instant,lease_until=null where id=job.id;
  elsif outcome='retry' and job.attempts<5 then
    update public.task_push_jobs set state='queued',result_code=outcome,next_attempt_at=instant+make_interval(secs=>30*power(2,job.attempts-1)::integer),
      lease_token=null,lease_until=null where id=job.id;
  else
    update public.task_push_jobs set state='cancelled',result_code=outcome,finished_at=instant,lease_until=null where id=job.id;
    if outcome='invalid_token' then
      update public.task_push_devices set state='disabled',registration_token=null,registration_hash=null,expires_at=null,updated_at=instant
        where device_id=job.device_id and intent_version=job.device_version and registration_hash=job.device_token_hash;
    end if;
  end if;
  return jsonb_build_object('status',case when outcome='accepted' then 'sent' when outcome='retry' and job.attempts<5 then 'queued' else 'cancelled' end);
end $$;
revoke all on function public.finish_task_push_job(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.finish_task_push_job(uuid,uuid,text) to service_role;

create function public.purge_task_push() returns void
language plpgsql security definer set search_path='' as $$
begin
  delete from public.task_push_jobs where expires_at<now()-interval '7 days';
  perform public.purge_task_push_devices();
end $$;
revoke all on function public.purge_task_push() from public,anon,authenticated,service_role;
grant execute on function public.purge_task_push() to service_role;
