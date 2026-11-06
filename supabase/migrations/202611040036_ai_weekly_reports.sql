-- Aggregate-only weekly interpretation. Source evidence shares the AI result's
-- lifecycle, including while running: no second copy can outlive privacy purge.
alter table public.ai_analysis_requests drop constraint ai_analysis_requests_purpose_check;
alter table public.ai_analysis_requests add constraint ai_analysis_requests_purpose_check
  check(purpose in ('classification','similar','weekly_report'));

create or replace function public.ai_request_receipt(r public.ai_analysis_requests) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('request_id',r.id,'child_id',r.child_id,
    'status',case when r.expires_at<=now() and r.state in ('running','completed') then 'expired' else r.state end,
    'result',case when r.expires_at>now() and r.state='completed' then r.result else null end,
    'created_at',r.created_at,'expires_at',r.expires_at);
$$;
create or replace function public.purge_expired_ai_output() returns integer
language plpgsql security definer set search_path='' as $$
declare count integer;
begin
  update public.ai_analysis_requests set result=null,state=case when state in ('running','completed') then 'expired' else state end
    where expires_at<=now() and (result is not null or state='running');
  get diagnostics count=row_count;return count;
end $$;

create function public.weekly_report_ai_context(target_child_id uuid,anchor_date date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare report jsonb:=public.learning_report(target_child_id,'week',anchor_date); snapshot jsonb; family uuid;
begin
  select family_id into family from public.children where id=target_child_id;
  snapshot:=jsonb_build_object('schema_version','weekly-facts-v1',
    'start_date',report->'start_date','end_date',report->'end_date','as_of_date',report->'today',
    'tasks',(report->'tasks')-'completion_rate','reviews',(report->'reviews')-'accuracy',
    'due_now',report->'due_now','coins',(report->'coins')-'xp',
    'activity_count',report->'activity_count','days',report->'days');
  return jsonb_build_object('child_id',target_child_id,'family_id',family,
    'input',jsonb_build_object('kind','weekly_report','end_date',report->'end_date','snapshot',snapshot));
end $$;
revoke all on function public.weekly_report_ai_context(uuid,date) from public,anon,service_role;
grant execute on function public.weekly_report_ai_context(uuid,date) to authenticated;

create function public.valid_weekly_ai_input(input jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
declare s jsonb:=input->'snapshot'; item jsonb; n jsonb; first_day date; last_day date; i integer:=0;
begin
  if jsonb_typeof(input) is distinct from 'object' or input->>'kind' is distinct from 'weekly_report'
    or input-'kind'-'end_date'-'snapshot'<>'{}' or jsonb_typeof(s) is distinct from 'object'
    or s->>'schema_version' is distinct from 'weekly-facts-v1'
    or s-'schema_version'-'start_date'-'end_date'-'as_of_date'-'tasks'-'reviews'-'due_now'-'coins'-'activity_count'-'days'<>'{}'
    or input->>'end_date' is distinct from s->>'end_date' then return false; end if;
  foreach item in array array[s->'start_date',s->'end_date',s->'as_of_date'] loop
    if jsonb_typeof(item) is distinct from 'string' or item#>>'{}' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then return false;end if;
  end loop;
  first_day:=(s->>'start_date')::date;last_day:=(s->>'end_date')::date;
  if last_day-first_day<>6 or last_day<date '2000-01-01' or (s->>'as_of_date')::date<last_day then return false;end if;
  if jsonb_typeof(s->'tasks') is distinct from 'object' or (s->'tasks')-'expected'-'completed'-'effective_seconds'<>'{}'
    or jsonb_typeof(s->'reviews') is distinct from 'object' or (s->'reviews')-'answered'-'correct'<>'{}'
    or jsonb_typeof(s->'coins') is distinct from 'object' or (s->'coins')-'income'-'spent'-'adjustment_out'<>'{}'
    or jsonb_typeof(s->'days') is distinct from 'array' or jsonb_array_length(s->'days')<>7 then return false;end if;
  foreach n in array array[s#>'{tasks,expected}',s#>'{tasks,completed}',s#>'{tasks,effective_seconds}',
    s#>'{reviews,answered}',s#>'{reviews,correct}',s#>'{coins,income}',s#>'{coins,spent}',s#>'{coins,adjustment_out}',s->'due_now',s->'activity_count'] loop
    if jsonb_typeof(n) is distinct from 'number' or n::text !~ '^[0-9]{1,15}$' then return false;end if;
  end loop;
  if (s#>>'{tasks,completed}')::numeric>(s#>>'{tasks,expected}')::numeric
    or (s#>>'{reviews,correct}')::numeric>(s#>>'{reviews,answered}')::numeric then return false;end if;
  for item in select value from jsonb_array_elements(s->'days') loop
    if jsonb_typeof(item) is distinct from 'object' or item-'day'-'expected'-'completed'-'effective_seconds'<>'{}'
      or item->>'day' is distinct from (first_day+i)::text then return false;end if;
    foreach n in array array[item->'expected',item->'completed',item->'effective_seconds'] loop
      if jsonb_typeof(n) is distinct from 'number' or n::text !~ '^[0-9]{1,15}$' then return false;end if;
    end loop;
    if (item->>'completed')::numeric>(item->>'expected')::numeric then return false;end if;i:=i+1;
  end loop;
  return (select sum((d->>'expected')::numeric)=(s#>>'{tasks,expected}')::numeric
    and sum((d->>'completed')::numeric)=(s#>>'{tasks,completed}')::numeric
    and sum((d->>'effective_seconds')::numeric)=(s#>>'{tasks,effective_seconds}')::numeric from jsonb_array_elements(s->'days') d);
exception when others then return false;
end $$;
revoke all on function public.valid_weekly_ai_input(jsonb) from public,anon,authenticated,service_role;

create function public.valid_weekly_ai_output(output jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
declare s jsonb:=output->'structured_output'; item jsonb; flags jsonb:=output->'safety_flags';
begin
  if jsonb_typeof(output) is distinct from 'object' or output-'model_version'-'prompt_version'-'confidence'-'raw_output'-'structured_output'-'safety_flags'<>'{}'
    or jsonb_typeof(output->'confidence') is distinct from 'number' or (output->>'confidence')::numeric not between 0 and 1
    or jsonb_typeof(output->'raw_output') is distinct from 'string' or length(output->>'raw_output')>9000
    or jsonb_typeof(flags) is distinct from 'array' or jsonb_array_length(flags)>5 then return false; end if;
  if exists(select 1 from jsonb_array_elements(flags) v where jsonb_typeof(v)<>'string'
    or v#>>'{}' not in ('self_harm','violence','bullying','personal_data','refused')) then return false;end if;
  if jsonb_array_length(flags)>0 then return s='{}'::jsonb and output->>'raw_output'='' and (output->>'confidence')::numeric=0;end if;
  if jsonb_typeof(s) is distinct from 'object' or s-'summaries'-'recommendation'<>'{}'
    or jsonb_typeof(s->'summaries') is distinct from 'array' or jsonb_array_length(s->'summaries') not between 1 and 3
    or jsonb_typeof(s->'recommendation') is distinct from 'object' then return false;end if;
  for item in select value from jsonb_array_elements((s->'summaries')||jsonb_build_array(s->'recommendation')) loop
    if jsonb_typeof(item) is distinct from 'object' or item-'text'-'evidence_ids'<>'{}'
      or jsonb_typeof(item->'text') is distinct from 'string' or length(btrim(item->>'text')) not between 1 and 500
      or item->>'text' ~* '(懒惰|退步|笨蛋|差劲|没用|低能|智商|https?://|www\.|@)'
      or jsonb_typeof(item->'evidence_ids') is distinct from 'array' or jsonb_array_length(item->'evidence_ids') not between 1 and 3 then return false;end if;
    if exists(select 1 from jsonb_array_elements(item->'evidence_ids') v where jsonb_typeof(v)<>'string'
      or v#>>'{}' not in ('tasks','daily','activities','reviews','due_now','coins'))
      or (select count(distinct v) from jsonb_array_elements(item->'evidence_ids') v)<>jsonb_array_length(item->'evidence_ids') then return false;end if;
  end loop;
  return true;
exception when others then return false;
end $$;
revoke all on function public.valid_weekly_ai_output(jsonb) from public,anon,authenticated,service_role;

create table public.ai_report_feedback (
  request_id uuid references public.ai_analysis_requests(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  item_key text not null check(item_key in ('summary:0','summary:1','summary:2','recommendation')),
  reason text not null check(reason='inaccurate'),created_at timestamptz not null default now(),
  primary key(request_id,item_key)
);
alter table public.ai_report_feedback enable row level security;
revoke all on public.ai_report_feedback from public,anon,authenticated,service_role;
create function public.feedback_ai_report(target_child_id uuid,request_id uuid,item_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.ai_analysis_requests; family uuid;
begin
  select family_id into family from public.children where id=target_child_id;perform public.require_parent_authorization(family);
  select * into r from public.ai_analysis_requests where id=request_id;
  if r.child_id is distinct from target_child_id or r.owner_id is distinct from auth.uid() or r.purpose<>'weekly_report'
    or r.state<>'completed' or r.expires_at<=now() or r.result is null or r.result->'safety_flags'<>'[]'::jsonb then
    raise exception '周报已失效或无权反馈' using errcode='42501';end if;
  if item_key is null or item_key not in ('summary:0','summary:1','summary:2','recommendation') then raise exception '反馈条目不正确';end if;
  if item_key<>'recommendation' and (substring(item_key from 9))::integer>=jsonb_array_length(r.result#>'{structured_output,summaries}') then
    raise exception '反馈条目不存在';end if;
  insert into public.ai_report_feedback(request_id,child_id,item_key,reason) values(request_id,target_child_id,item_key,'inaccurate')
    on conflict on constraint ai_report_feedback_pkey do nothing;
  return jsonb_build_object('request_id',request_id,'item_key',item_key,'reason','inaccurate');
end $$;
revoke all on function public.feedback_ai_report(uuid,uuid,text) from public,anon,service_role;
grant execute on function public.feedback_ai_report(uuid,uuid,text) to authenticated;

alter function public.child_export_source(uuid) rename to child_export_source_before_ai_reports;
create function public.child_export_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select public.child_export_source_before_ai_reports(target_child_id)||jsonb_build_array(jsonb_build_object(
    'name','ai_report_feedback','columns',jsonb_build_array('request_id','child_id','item_key','reason','created_at','model_version','prompt_version'),
    'rows',coalesce((select jsonb_agg(to_jsonb(f)||jsonb_build_object('model_version',r.model,'prompt_version',r.prompt_version) order by f.request_id,f.item_key)
      from public.ai_report_feedback f join public.ai_analysis_requests r on r.id=f.request_id where f.child_id=target_child_id),'[]'::jsonb)));
$$;
revoke all on function public.child_export_source(uuid),public.child_export_source_before_ai_reports(uuid) from public,anon,authenticated,service_role;
alter function public.child_deletion_source(uuid) rename to child_deletion_source_before_ai_reports;
create function public.child_deletion_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_set(public.child_deletion_source_before_ai_reports(target_child_id),'{counts,ai_report_feedback}',
    to_jsonb((select count(*) from public.ai_report_feedback where child_id=target_child_id)));
$$;
revoke all on function public.child_deletion_source(uuid),public.child_deletion_source_before_ai_reports(uuid) from public,anon,authenticated,service_role;

-- Preserve the existing request, quota, authorization and privacy fences.
create or replace function public.resolve_ai_analysis(target_child_id uuid,request_id uuid,input jsonb,operation text default 'inspect',expected_generation integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare family uuid; generation integer; fingerprint text; r public.ai_analysis_requests;
  s public.family_ai_settings;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  select ch.family_id,ch.ai_generation into family,generation from public.children ch where ch.id=target_child_id for share;
  perform public.require_parent_authorization(family);
  if request_id is null or operation is null or operation not in ('inspect','submit','cancel')
    or jsonb_typeof(input) is distinct from 'object' or octet_length(input::text)>10000
    or (case when input->>'kind'='weekly_report' then not public.valid_weekly_ai_input(input) else
      jsonb_typeof(input->'text') is distinct from 'string' or length(btrim(input->>'text')) not between 1 and 2000
      or input->>'subject' is null or input->>'subject' not in ('math','chinese','english')
      or not public.valid_ai_input(input) end) then raise exception 'AI请求格式不正确' using errcode='22023'; end if;
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
    insert into public.ai_analysis_requests(id,family_id,child_id,owner_id,input_hash,policy_version,generation,state,expires_at,purpose)
      values(request_id,family,target_child_id,auth.uid(),fingerprint,s.version,generation,'cancelled',now(),case when input->>'kind'='weekly_report' then 'weekly_report' when input->>'kind'='similar' then 'similar' else 'classification' end) returning * into r;
    return public.ai_request_receipt(r);
  end if;
  -- Only the Edge service may dispatch a model. The parent receives a receipt, never a claim token.
  raise exception '请通过AI网关提交请求' using errcode='42501';
end $$;
create or replace function public.claim_ai_analysis(caller_id uuid,caller_session text,target_child_id uuid,request_id uuid,input jsonb,expected_generation integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare previous text:=current_setting('request.jwt.claims',true); receipt jsonb; family uuid; grade integer;
  s public.family_ai_settings; c public.ai_gateway_config; u public.family_ai_usage; r public.ai_analysis_requests; period date; source public.wrong_questions;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'service only' using errcode='42501'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',caller_id,'role','authenticated','session_id',caller_session)::text,true);
  receipt:=public.resolve_ai_analysis(target_child_id,request_id,input,'inspect',expected_generation);
  if receipt->>'status'<>'unknown' then
    perform set_config('request.jwt.claims',coalesce(previous,''),true); return receipt; end if;
  if input->>'kind'='similar' then
    select * into source from public.wrong_questions where id=(input->>'source_question_id')::uuid and child_id=target_child_id and not deleting for share;
    if source.id is null or source.review_kind<>'question' or source.content_version<>(input->>'source_version')::integer
      or source.final_text is distinct from input->>'text' or source.subject is distinct from input->>'subject' then
      raise exception '原题已变化，请重新打开相似题'; end if;
  end if;
  if input->>'kind'='weekly_report' and (public.weekly_report_ai_context(target_child_id,(input->>'end_date')::date)->'input') is distinct from input then
    raise exception 'AI_REPORT_CHANGED'; end if;
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
  insert into public.ai_analysis_requests(id,family_id,child_id,owner_id,input_hash,policy_version,generation,state,claim_token,model,reserve_cents,expires_at,purpose,source_question_id,source_version,subject,prompt_version)
    values(request_id,family,target_child_id,caller_id,encode(sha256(convert_to(input::text,'UTF8')),'hex'),s.version,expected_generation,
      'running',gen_random_uuid(),c.model,c.reserve_cents,now()+make_interval(days=>s.retention_days),case when input->>'kind'='weekly_report' then 'weekly_report' when input->>'kind'='similar' then 'similar' else 'classification' end,
      source.id,source.content_version,input->>'subject',case when input->>'kind'='weekly_report' then 'weekly-report-v1' when input->>'kind'='similar' then 'similar-question-v1' else 'question-structure-v1' end) returning * into r;
  if input->>'kind'='weekly_report' then
    update public.ai_analysis_requests set result=jsonb_build_object('evidence',input) where id=request_id returning * into r;
  end if;
  perform set_config('request.jwt.claims',coalesce(previous,''),true);
  return public.ai_request_receipt(r)||jsonb_build_object('status','claimed','token',r.claim_token,
    'model',r.model,'provider',c.provider,'prompt_version',r.prompt_version,'grade',grade);
exception when others then perform set_config('request.jwt.claims',coalesce(previous,''),true); raise;
end $$;
create or replace function public.finish_ai_analysis(request_id uuid,token uuid,output jsonb) returns void
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
  if output is not null and (jsonb_typeof(output) is distinct from 'object' or octet_length(output::text)>32000
    or output->>'model_version' is distinct from r.model or output->>'prompt_version' is distinct from r.prompt_version
    or not(output ?& array['confidence','raw_output','structured_output','safety_flags'])) then raise exception 'invalid AI output'; end if;
  if output is not null and r.purpose='weekly_report' then
    if not public.valid_weekly_ai_output(output) or not public.valid_weekly_ai_input(r.result->'evidence') then raise exception 'invalid AI report';end if;
    if jsonb_array_length(output->'safety_flags')=0 then
      output:=output||jsonb_build_object('evidence',r.result->'evidence');
    end if;
  end if;
  if output is not null and r.purpose='similar' then
    if jsonb_typeof(output->'safety_flags') is distinct from 'array' then raise exception 'invalid safety flags'; end if;
    if jsonb_array_length(output->'safety_flags')=0 then
      if not public.valid_similar_question(output->'structured_output') or output#>>'{structured_output,subject}' is distinct from r.subject then
        raise exception 'invalid similar question'; end if;
      output:=jsonb_set(output,'{structured_output,answer_check}',public.check_practice_answer(r.subject,output#>>'{structured_output,prompt}',output#>'{structured_output,answers}'));
    end if;
  end if;
  update public.ai_analysis_requests set state=case when output is null then 'failed' else 'completed' end,result=output where id=request_id;
end $$;
