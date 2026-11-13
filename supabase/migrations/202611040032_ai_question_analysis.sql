-- Disabled until an operator configures and validates a provider. No API keys here.
alter table public.children add column ai_generation integer not null default 0;
create table public.ai_gateway_config (
  singleton boolean primary key default true check(singleton), enabled boolean not null default false,
  provider text not null default 'openai' check(provider='openai'), model text,
  reserve_cents integer not null default 100 check(reserve_cents between 1 and 30000)
);
insert into public.ai_gateway_config(singleton) values(true);
create table public.family_ai_settings (
  family_id uuid primary key references public.families(id) on delete cascade,
  enabled boolean not null default false, version integer not null default 0,
  monthly_limit integer not null default 100 check(monthly_limit between 1 and 500),
  budget_cents integer not null default 10000 check(budget_cents between 100 and 30000),
  retention_days integer not null default 7 check(retention_days in (1,7,30))
);
create table public.family_ai_usage (
  family_id uuid references public.families(id) on delete cascade, month date not null,
  requests integer not null default 0, reserved_cents integer not null default 0,
  primary key(family_id,month)
);
create table public.ai_analysis_requests (
  id uuid primary key, family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  input_hash text not null, policy_version integer not null, generation integer not null default 0,
  state text not null check(state in ('running','completed','failed','cancelled','discarded','expired')),
  claim_token uuid, model text, prompt_version text not null default 'question-structure-v1',
  reserve_cents integer not null default 0, created_at timestamptz not null default now(),
  expires_at timestamptz not null, result jsonb
);
create index ai_requests_child on public.ai_analysis_requests(child_id);
create index ai_requests_expiry on public.ai_analysis_requests(expires_at) where result is not null;
do $$ declare t text; begin
  foreach t in array array['ai_gateway_config','family_ai_settings','family_ai_usage','ai_analysis_requests'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
  end loop;
end $$;

create function public.read_ai_context(target_child_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare child public.children;
begin
  select * into child from public.children where id=target_child_id;
  return public.read_ai_settings(child.family_id)||jsonb_build_object('generation',child.ai_generation,'grade',child.grade);
end $$;

create function public.read_ai_settings(target_family_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.family_ai_settings; u public.family_ai_usage; c public.ai_gateway_config;
begin
  perform public.require_parent_authorization(target_family_id);
  select * into s from public.family_ai_settings where family_id=target_family_id;
  select * into u from public.family_ai_usage where family_id=target_family_id and month=date_trunc('month',now() at time zone 'UTC')::date;
  select * into c from public.ai_gateway_config;
  return jsonb_build_object('enabled',coalesce(s.enabled,false),'version',coalesce(s.version,0),
    'monthly_limit',coalesce(s.monthly_limit,100),'budget_cents',coalesce(s.budget_cents,10000),
    'retention_days',coalesce(s.retention_days,7),'requests',coalesce(u.requests,0),
    'reserved_cents',coalesce(u.reserved_cents,0),'reserve_cents',c.reserve_cents,
    'available',c.enabled and nullif(c.model,'') is not null,'can_manage',public.is_family_admin(target_family_id));
end $$;

create function public.update_ai_settings(target_family_id uuid,expected_version integer,settings jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.family_ai_settings; desired public.family_ai_settings;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  perform 1 from public.families where id=target_family_id for key share;
  perform public.require_parent_authorization(target_family_id);
  if jsonb_typeof(settings) is distinct from 'object' or
    jsonb_typeof(settings->'enabled') is distinct from 'boolean' or
    (settings->>'monthly_limit') !~ '^[0-9]{1,3}$' or
    (settings->>'budget_cents') !~ '^[0-9]{1,5}$' or
    (settings->>'retention_days') !~ '^(1|7|30)$' or
    not(settings ?& array['enabled','monthly_limit','budget_cents','retention_days']) then
    raise exception 'AI设置格式不正确' using errcode='22023'; end if;
  insert into public.family_ai_settings(family_id) values(target_family_id) on conflict do nothing;
  select * into s from public.family_ai_settings where family_id=target_family_id for update;
  desired:=s; desired.enabled:=(settings->>'enabled')::boolean;
  desired.monthly_limit:=(settings->>'monthly_limit')::integer;
  desired.budget_cents:=(settings->>'budget_cents')::integer;
  desired.retention_days:=(settings->>'retention_days')::integer;
  if not public.is_family_admin(target_family_id) and (desired.enabled or desired.monthly_limit<>s.monthly_limit
      or desired.budget_cents<>s.budget_cents or desired.retention_days<>s.retention_days) then
    raise exception '仅管理员可以启用AI或调整额度；家长均可关闭' using errcode='42501'; end if;
  if desired=s then return public.read_ai_settings(target_family_id); end if;
  if expected_version is distinct from s.version then raise exception '设置已变化，请刷新后再保存' using errcode='40001'; end if;
  update public.family_ai_settings set enabled=desired.enabled,monthly_limit=desired.monthly_limit,
    budget_cents=desired.budget_cents,retention_days=desired.retention_days,version=version+1 where family_id=target_family_id;
  -- Every policy change fences in-flight results. Shorter retention also applies to existing output.
  update public.ai_analysis_requests set
    state=case when not desired.enabled or state='running' then 'discarded' else state end,
    result=case when not desired.enabled then null else result end,
    expires_at=least(expires_at,created_at+make_interval(days=>desired.retention_days))
    where family_id=target_family_id;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(target_family_id,auth.uid(),'ai.settings','family',target_family_id::text,
      jsonb_build_object('enabled',desired.enabled,'version',s.version+1));
  return public.read_ai_settings(target_family_id);
end $$;

create function public.ai_request_receipt(r public.ai_analysis_requests) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('request_id',r.id,'child_id',r.child_id,
    'status',case when r.expires_at<=now() and r.state='completed' then 'expired' else r.state end,
    'result',case when r.expires_at>now() and r.state='completed' then r.result else null end,
    'created_at',r.created_at,'expires_at',r.expires_at);
$$;
revoke all on function public.ai_request_receipt(public.ai_analysis_requests) from public,anon,authenticated,service_role;

-- Caller can claim only once. A lost/ambiguous provider response never becomes a new dispatch.
create function public.resolve_ai_analysis(target_child_id uuid,request_id uuid,input jsonb,operation text default 'inspect',expected_generation integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare family uuid; generation integer; fingerprint text; r public.ai_analysis_requests;
  s public.family_ai_settings;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  select ch.family_id,ch.ai_generation into family,generation from public.children ch where ch.id=target_child_id for share;
  perform public.require_parent_authorization(family);
  if request_id is null or operation is null or operation not in ('inspect','submit','cancel')
    or jsonb_typeof(input) is distinct from 'object' or octet_length(input::text)>10000
    or jsonb_typeof(input->'text') is distinct from 'string' or length(btrim(input->>'text')) not between 1 and 2000
    or input->>'subject' is null or input->>'subject' not in ('math','chinese','english')
    or input- 'text'- 'subject'<>'{}'::jsonb then raise exception 'AI请求格式不正确' using errcode='22023'; end if;
  fingerprint:=encode(sha256(convert_to(input::text,'UTF8')),'hex');
  -- Settings precede request locks in all writers.
  insert into public.family_ai_settings(family_id) values(family) on conflict do nothing;
  select * into s from public.family_ai_settings where family_id=family for update;
  perform pg_advisory_xact_lock(hashtextextended('ai-request:'||request_id::text,0));
  select * into r from public.ai_analysis_requests where id=request_id;
  if found then
    if r.owner_id<>auth.uid() or r.child_id<>target_child_id then raise exception 'AI请求无权访问' using errcode='42501'; end if;
    if r.input_hash<>fingerprint or r.generation is distinct from expected_generation then raise exception '请求编号已绑定其他题目' using errcode='22023'; end if;
    if operation='cancel' and r.state in ('running','completed') then
      update public.ai_analysis_requests set state='discarded',result=null where id=request_id returning * into r;
    end if;
    return public.ai_request_receipt(r);
  end if;
  if expected_generation is distinct from generation then
    return jsonb_build_object('request_id',request_id,'child_id',target_child_id,'status','discarded'); end if;
  if operation='inspect' then return jsonb_build_object('request_id',request_id,'child_id',target_child_id,'status','unknown'); end if;
  if operation='cancel' then
    insert into public.ai_analysis_requests(id,family_id,child_id,owner_id,input_hash,policy_version,generation,state,expires_at)
      values(request_id,family,target_child_id,auth.uid(),fingerprint,s.version,generation,'cancelled',now()) returning * into r;
    return public.ai_request_receipt(r);
  end if;
  -- Only the Edge service may dispatch a model. The parent receives a receipt, never a claim token.
  raise exception '请通过AI网关提交请求' using errcode='42501';
end $$;

-- Edge supplies the verified caller identity/session; service credentials never reach the app.
create function public.claim_ai_analysis(caller_id uuid,caller_session text,target_child_id uuid,request_id uuid,input jsonb,expected_generation integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare previous text:=current_setting('request.jwt.claims',true); receipt jsonb; family uuid; grade integer;
  s public.family_ai_settings; c public.ai_gateway_config; u public.family_ai_usage; r public.ai_analysis_requests; period date;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'service only' using errcode='42501'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',caller_id,'role','authenticated','session_id',caller_session)::text,true);
  receipt:=public.resolve_ai_analysis(target_child_id,request_id,input,'inspect',expected_generation);
  if receipt->>'status'<>'unknown' then
    perform set_config('request.jwt.claims',coalesce(previous,''),true); return receipt; end if;
  select ch.family_id,ch.grade into family,grade from public.children ch where ch.id=target_child_id;
  select * into s from public.family_ai_settings where family_id=family;
  select * into c from public.ai_gateway_config;
  if not s.enabled then raise exception 'AI_DISABLED'; end if;
  if not c.enabled or nullif(c.model,'') is null then raise exception 'AI_UNAVAILABLE'; end if;
  period:=date_trunc('month',now() at time zone 'UTC')::date;
  insert into public.family_ai_usage(family_id,month) values(family,period) on conflict do nothing;
  select * into u from public.family_ai_usage where family_id=family and month=period for update;
  if u.requests>=s.monthly_limit or u.reserved_cents+c.reserve_cents>s.budget_cents then raise exception 'AI_LIMIT_REACHED'; end if;
  update public.family_ai_usage set requests=requests+1,reserved_cents=reserved_cents+c.reserve_cents where family_id=family and month=period;
  insert into public.ai_analysis_requests(id,family_id,child_id,owner_id,input_hash,policy_version,generation,state,claim_token,model,reserve_cents,expires_at)
    values(request_id,family,target_child_id,caller_id,encode(sha256(convert_to(input::text,'UTF8')),'hex'),s.version,expected_generation,
      'running',gen_random_uuid(),c.model,c.reserve_cents,now()+make_interval(days=>s.retention_days)) returning * into r;
  perform set_config('request.jwt.claims',coalesce(previous,''),true);
  return public.ai_request_receipt(r)||jsonb_build_object('status','claimed','token',r.claim_token,
    'model',r.model,'provider',c.provider,'prompt_version',r.prompt_version,'grade',grade);
exception when others then perform set_config('request.jwt.claims',coalesce(previous,''),true); raise;
end $$;

create function public.discard_ai_on_cleanup() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  -- Text-only analysis cannot be reliably matched to a saved question. Clear this child's
  -- pending analyses conservatively, including requests prepared but not yet dispatched.
  update public.children set ai_generation=ai_generation+1 where id=new.child_id;
  perform 1 from public.family_ai_settings where family_id=new.family_id for update;
  update public.ai_analysis_requests set state='discarded',result=null where child_id=new.child_id;
  return new;
end $$;
create trigger discard_ai_on_cleanup before insert on public.cleanup_jobs for each row execute function public.discard_ai_on_cleanup();
revoke all on function public.discard_ai_on_cleanup() from public,anon,authenticated,service_role;

create function public.erase_account_ai_requests() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  -- Include this parent's requests in other families, without erasing shared child data.
  delete from public.ai_analysis_requests where owner_id=new.user_id;
  return new;
end $$;
create trigger erase_account_ai_requests after insert on public.account_deletion_jobs for each row execute function public.erase_account_ai_requests();
revoke all on function public.erase_account_ai_requests() from public,anon,authenticated,service_role;

create function public.finish_ai_analysis(request_id uuid,token uuid,output jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare r public.ai_analysis_requests; s public.family_ai_settings; family uuid;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'service only' using errcode='42501'; end if;
  select family_id into family from public.ai_analysis_requests where id=request_id;
  if family is null then return; end if; -- Deleted child/account: never recreate output.
  select * into s from public.family_ai_settings where family_id=family for update;
  select * into r from public.ai_analysis_requests where id=request_id for update;
  if r.id is null then return; end if;
  if token is distinct from r.claim_token then raise exception 'invalid claim' using errcode='42501'; end if;
  if r.state<>'running' then return; end if;
  if not s.enabled or s.version<>r.policy_version or r.expires_at<=now()
    or not public.account_is_active(r.owner_id)
    or not exists(select 1 from public.family_members where family_id=r.family_id and user_id=r.owner_id)
    or exists(select 1 from public.account_deletion_jobs where r.family_id=any(owned_family_ids)) then
    update public.ai_analysis_requests set state='discarded',result=null where id=request_id; return; end if;
  if output is not null and (jsonb_typeof(output) is distinct from 'object' or octet_length(output::text)>16000
    or output->>'model_version' is distinct from r.model or output->>'prompt_version' is distinct from r.prompt_version
    or not(output ?& array['confidence','raw_output','structured_output','safety_flags'])) then raise exception 'invalid AI output'; end if;
  update public.ai_analysis_requests set state=case when output is null then 'failed' else 'completed' end,result=output where id=request_id;
end $$;

-- Keep minimal deduplication receipts, erase output on expiry and revoke server export copies.
create function public.revoke_ai_export_copy() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if old.result is not null and (TG_OP='DELETE' or new.result is null or new.expires_at<old.expires_at) then
    update public.child_export_jobs set state='revoked' where child_id=old.child_id and state='ready';
    delete from public.child_export_rows where export_id in(select id from public.child_export_jobs where child_id=old.child_id);
  end if;
  if TG_OP='DELETE' then return old; end if;
  return new;
end $$;
create trigger ai_export_retention before update or delete on public.ai_analysis_requests for each row execute function public.revoke_ai_export_copy();
revoke all on function public.revoke_ai_export_copy() from public,anon,authenticated,service_role;

create function public.purge_expired_ai_output() returns integer
language plpgsql security definer set search_path='' as $$
declare count integer;
begin
  update public.ai_analysis_requests set result=null,state=case when state='completed' then 'expired' else state end
    where expires_at<=now() and result is not null;
  get diagnostics count=row_count; return count;
end $$;
revoke all on function public.purge_expired_ai_output() from public,anon,authenticated;
grant execute on function public.purge_expired_ai_output() to service_role;
do $$ begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    perform cron.schedule('learning-planet-ai-retention','* * * * *','select public.purge_expired_ai_output();');
  end if;
end $$;

alter function public.child_export_source(uuid) rename to child_export_source_before_ai;
create function public.child_export_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select public.child_export_source_before_ai(target_child_id)||jsonb_build_array(jsonb_build_object(
    'name','ai_analysis','columns',jsonb_build_array('request_id','child_id','status','result','created_at','expires_at'),
    'rows',coalesce((select jsonb_agg(public.ai_request_receipt(r) order by created_at,id) from public.ai_analysis_requests r where child_id=target_child_id),'[]'::jsonb)));
$$;
revoke all on function public.child_export_source(uuid) from public,anon,authenticated,service_role;

alter function public.child_deletion_source(uuid) rename to child_deletion_source_before_ai;
create function public.child_deletion_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_set(public.child_deletion_source_before_ai(target_child_id),'{counts,ai_requests}',
    to_jsonb((select count(*) from public.ai_analysis_requests where child_id=target_child_id)));
$$;
revoke all on function public.child_deletion_source(uuid) from public,anon,authenticated,service_role;

do $$ declare signature text; begin
  foreach signature in array array['read_ai_settings(uuid)','read_ai_context(uuid)','update_ai_settings(uuid,integer,jsonb)',
    'resolve_ai_analysis(uuid,uuid,jsonb,text,integer)'] loop
    execute 'revoke all on function public.'||signature||' from public,anon,service_role';
    execute 'grant execute on function public.'||signature||' to authenticated';
  end loop;
  foreach signature in array array['claim_ai_analysis(uuid,text,uuid,uuid,jsonb,integer)','finish_ai_analysis(uuid,uuid,jsonb)'] loop
    execute 'revoke all on function public.'||signature||' from public,anon,authenticated';
    execute 'grant execute on function public.'||signature||' to service_role';
  end loop;
end $$;
