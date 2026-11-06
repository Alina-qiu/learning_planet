-- Similar questions share the existing consent, quota, retention and cancellation fence.
alter table public.ai_analysis_requests
  add column purpose text not null default 'classification' check(purpose in ('classification','similar')),
  add column source_question_id uuid references public.wrong_questions(id) on delete set null,
  add column source_version integer,
  add column subject text;
alter table public.wrong_questions
  add column ai_generated boolean not null default false,
  add column difficulty text not null default 'unknown' check(difficulty in ('easy','medium','hard','unknown'));
create index wrong_questions_similar_lookup on public.wrong_questions(child_id,subject,updated_at desc,id)
  where not deleting and not archived and review_kind='question';

-- Exact rational arithmetic; no SQL/expression evaluation of user or model text.
create function public.practice_fraction(n numeric,d numeric) returns jsonb
language plpgsql immutable set search_path='' as $$
declare a numeric:=abs(n); b numeric:=abs(d); t numeric;
begin
  if d=0 or abs(n)>1e60 or abs(d)>1e60 then raise exception 'arithmetic limit'; end if;
  while b<>0 loop t:=mod(a,b);a:=b;b:=t;end loop;
  return jsonb_build_object('n',div(n,coalesce(nullif(a,0),1))*sign(d),'d',div(abs(d),coalesce(nullif(a,0),1)));
end $$;
create function public.practice_expression(tokens text[],start_at integer,depth integer,minimum integer) returns jsonb
language plpgsql immutable set search_path='' as $$
declare token text:=tokens[start_at]; left_value jsonb; right_value jsonb; value jsonb;
  p integer:=start_at; precedence integer; places integer;
  a numeric;b numeric;c numeric;d numeric;
begin
  if depth>20 or p>cardinality(tokens) then raise exception 'arithmetic syntax'; end if;
  if token in ('+','-') then
    left_value:=public.practice_expression(tokens,p+1,depth+1,3);
    if token='-' then left_value:=jsonb_set(left_value,'{n}',to_jsonb(-(left_value->>'n')::numeric)); end if;
    p:=(left_value->>'pos')::integer;
  elsif token='(' then
    left_value:=public.practice_expression(tokens,p+1,depth+1,0);p:=(left_value->>'pos')::integer;
    if tokens[p] is distinct from ')' then raise exception 'arithmetic syntax'; end if;p:=p+1;
  elsif token~'^[0-9]+(\.[0-9]+)?$' and length(token)<=18 then
    places:=case when strpos(token,'.')>0 then length(split_part(token,'.',2)) else 0 end;
    left_value:=public.practice_fraction(replace(token,'.','')::numeric,power(10::numeric,places));p:=p+1;
  else raise exception 'arithmetic syntax'; end if;
  loop
    token:=tokens[p];precedence:=case when token in ('+','-') then 1 when token in ('*','/') then 2 else -1 end;
    exit when precedence<minimum;
    right_value:=public.practice_expression(tokens,p+1,depth+1,precedence+1);p:=(right_value->>'pos')::integer;
    a:=(left_value->>'n')::numeric;b:=(left_value->>'d')::numeric;c:=(right_value->>'n')::numeric;d:=(right_value->>'d')::numeric;
    value:=case token when '+' then public.practice_fraction(a*d+c*b,b*d) when '-' then public.practice_fraction(a*d-c*b,b*d)
      when '*' then public.practice_fraction(a*c,b*d) else public.practice_fraction(a*d,b*c) end;
    left_value:=value;
  end loop;
  return left_value||jsonb_build_object('pos',p);
end $$;
create function public.practice_calculate(expression text) returns jsonb
language plpgsql immutable set search_path='' as $$
declare tokens text[]; result jsonb;
begin
  if expression is null or length(expression) not between 1 and 240 or expression!~'^[0-9.+*/()\-]+$' then raise exception 'arithmetic syntax'; end if;
  select array_agg(m[1]) into tokens from regexp_matches(expression,'[0-9]+(?:\.[0-9]+)?|[-+*/()]','g') m;
  if cardinality(tokens)>81 or array_to_string(tokens,'')<>expression then raise exception 'arithmetic limit'; end if;
  result:=public.practice_expression(tokens,1,0,0);
  if (result->>'pos')::integer<>cardinality(tokens)+1 then raise exception 'arithmetic syntax'; end if;
  return result-'pos';
end $$;
create function public.check_practice_answer(subject text,prompt text,answers jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare expression text; expected jsonb; answer text; actual jsonb; manual boolean:=false;
begin
  if subject is distinct from 'math' then return jsonb_build_object('status','manual','rule','arithmetic-v1','message','语文、英语、拼音及开放题需家长核对答案与解析。'); end if;
  expression:=regexp_replace(translate(coalesce(prompt,''),'×÷−（）：','*/-():'),'[[:space:]]','','g');
  expression:=regexp_replace(expression,'^(请)?(计算|求值):?','');
  expression:=regexp_replace(expression,'=[?？]?$|[?？]$','');
  if expression!~'^[0-9.+*/()\-]+$' then return jsonb_build_object('status','manual','rule','arithmetic-v1','message','题干不是可直接复算的四则算式，请家长核对题意、答案与解析。'); end if;
  expected:=public.practice_calculate(expression);
  if jsonb_typeof(answers) is distinct from 'array' or jsonb_array_length(answers) not between 1 and 5 then raise exception 'answer syntax'; end if;
  for answer in select jsonb_array_elements_text(answers) loop
    answer:=regexp_replace(translate(answer,'−','-'),'[[:space:]]','','g');
    if answer!~'^[+-]?[0-9]+(\.[0-9]+)?(/[+-]?[0-9]+(\.[0-9]+)?)?$' then manual:=true;continue;end if;
    actual:=public.practice_calculate(answer);
    if actual<>expected then return jsonb_build_object('status','failed','rule','arithmetic-v1','message','至少一个标准答案与题干算式复算结果不一致，请修改后重试。'); end if;
  end loop;
  if manual then return jsonb_build_object('status','manual','rule','arithmetic-v1','message','答案包含单位或非数值表达，请家长核对答案与解析。'); end if;
  return jsonb_build_object('status','passed','rule','arithmetic-v1','expected',expected->>'n'||case when expected->>'d'='1' then '' else '/'||(expected->>'d') end,
    'message','题干四则算式及全部数值答案已复算；解析仍需家长审核。');
exception when others then return jsonb_build_object('status','failed','rule','arithmetic-v1','message','算式含除零、格式错误或超出复算限制，请修正或改为完整题意后人工核对。');
end $$;
revoke all on function public.practice_fraction(numeric,numeric),public.practice_expression(text[],integer,integer,integer),
  public.practice_calculate(text),public.check_practice_answer(text,text,jsonb) from public,anon,authenticated,service_role;

create function public.valid_ai_input(input jsonb) returns boolean language sql immutable set search_path='' as $$
  select case when not(input ? 'kind') then input-'text'-'subject'='{}'::jsonb else
    input->>'kind'='similar' and input-'kind'-'source_question_id'-'source_version'-'text'-'subject'-'knowledge_point'-'difficulty'='{}'::jsonb
    and input->>'source_question_id'~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    and jsonb_typeof(input->'source_version')='number' and input->>'source_version'~'^[0-9]{1,9}$'
    and jsonb_typeof(input->'knowledge_point')='string' and length(input->>'knowledge_point')<=120
    and input->>'difficulty' in ('easy','medium','hard','unknown') end is true;
$$;
revoke all on function public.valid_ai_input(jsonb) from public,anon,authenticated,service_role;

create table public.similar_question_adoptions (
  request_id uuid primary key, child_id uuid not null references public.children(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  question_id uuid references public.wrong_questions(id) on delete set null,
  config_hash text not null, created_at timestamptz not null default now()
);
create table public.question_ai_origins (
  question_id uuid primary key references public.wrong_questions(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  source_question_id uuid references public.wrong_questions(id) on delete set null, source_version integer,
  request_id uuid not null, model_version text not null, prompt_version text not null,
  confidence numeric not null, generated_hash text not null, answer_check jsonb not null,
  approved_at timestamptz not null default now(), last_reviewed_version integer not null default 0
);
create table public.ai_result_feedback (
  request_id uuid primary key references public.ai_analysis_requests(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  reason text not null check(reason in ('wrong_answer','not_similar','unclear','unsafe','other')),
  created_at timestamptz not null default now()
);
alter table public.similar_question_adoptions enable row level security;
alter table public.question_ai_origins enable row level security;
alter table public.ai_result_feedback enable row level security;
revoke all on public.similar_question_adoptions,public.question_ai_origins,public.ai_result_feedback from anon,authenticated;

create function public.similar_question_context(source_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare w public.wrong_questions; family uuid;
begin
  select * into w from public.wrong_questions where id=source_id and not deleting;
  select family_id into family from public.children where id=w.child_id;
  perform public.require_parent_authorization(family);
  if w.id is null or w.review_kind<>'question' then raise exception '请从普通错题选择相似题'; end if;
  return jsonb_build_object('child_id',w.child_id,'family_id',family,'input',jsonb_build_object('kind','similar','source_question_id',w.id,
    'source_version',w.content_version,'subject',w.subject,'text',w.final_text,'knowledge_point',coalesce(w.knowledge_point,''),'difficulty',w.difficulty));
end $$;
create function public.find_similar_questions(source_id uuid,query text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare context jsonb:=public.similar_question_context(source_id); result jsonb;
begin
  if query is null or length(query)>80 then raise exception '搜索内容过长'; end if;
  select coalesce(jsonb_agg(to_jsonb(candidate)),'[]'::jsonb) into result from (
    select w.id,w.final_text,w.subject,w.knowledge_point,w.difficulty,w.ai_generated,
      case when nullif(btrim(w.knowledge_point),'')=nullif(btrim(context#>>'{input,knowledge_point}'),'') then 'knowledge' else 'subject' end match_reason
    from public.wrong_questions w where w.child_id=(context->>'child_id')::uuid and w.id<>source_id
      and not w.deleting and not w.archived and w.review_kind='question' and w.subject=context#>>'{input,subject}'
      and (btrim(query)='' or strpos(lower(w.final_text),lower(btrim(query)))>0 or strpos(lower(coalesce(w.knowledge_point,'')),lower(btrim(query)))>0)
    order by case when nullif(btrim(w.knowledge_point),'')=nullif(btrim(context#>>'{input,knowledge_point}'),'') then 0 else 1 end,w.updated_at desc,w.id limit 20
  ) candidate;
  return jsonb_build_object('items',result,'limit',20);
end $$;
revoke all on function public.similar_question_context(uuid),public.find_similar_questions(uuid,text) from public,anon;
grant execute on function public.similar_question_context(uuid),public.find_similar_questions(uuid,text) to authenticated;
create function public.valid_similar_question(q jsonb) returns boolean language plpgsql immutable set search_path='' as $$
declare answer jsonb;
begin
  if jsonb_typeof(q) is distinct from 'object' or jsonb_typeof(q->'prompt') is distinct from 'string' or length(btrim(q->>'prompt')) not between 1 and 2000
    or q->>'subject' is null or q->>'subject' not in ('math','chinese','english')
    or jsonb_typeof(q->'explanation') is distinct from 'string' or length(q->>'explanation')>2000
    or jsonb_typeof(q->'knowledge_point') is distinct from 'string' or length(q->>'knowledge_point')>120
    or q->>'difficulty' is null or q->>'difficulty' not in ('easy','medium','hard','unknown')
    or jsonb_typeof(q->'answers') is distinct from 'array' or jsonb_array_length(q->'answers') not between 1 and 5 then return false; end if;
  for answer in select jsonb_array_elements(q->'answers') loop
    if jsonb_typeof(answer)<>'string' or length(btrim(answer#>>'{}')) not between 1 and 500 then return false; end if;
  end loop;return true;
end $$;
revoke all on function public.valid_similar_question(jsonb) from public,anon,authenticated,service_role;

create function public.inspect_similar_adoption(target_child_id uuid,request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.similar_question_adoptions; family uuid;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  select * into a from public.similar_question_adoptions where similar_question_adoptions.request_id=inspect_similar_adoption.request_id;
  if a.request_id is null then return jsonb_build_object('request_id',request_id,'status','unknown'); end if;
  if a.child_id<>target_child_id or a.owner_id<>auth.uid() then raise exception '无权核对此保存请求' using errcode='42501'; end if;
  return jsonb_build_object('request_id',request_id,'status',case when a.question_id is null then 'deleted' else 'saved' end,'question_id',a.question_id);
end $$;
create function public.preview_practice_answer(target_child_id uuid,config jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare family uuid;
begin
  select family_id into family from public.children where id=target_child_id;perform public.require_parent_authorization(family);
  if not public.valid_similar_question(config) then raise exception '请补全题目、答案、解析及分类'; end if;
  return public.check_practice_answer(config->>'subject',config->>'prompt',config->'answers');
end $$;
create function public.adopt_similar_question(target_child_id uuid,request_id uuid,config jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare family uuid; generation integer; r public.ai_analysis_requests; a public.similar_question_adoptions;
  qid uuid; checked jsonb; fingerprint text:=encode(sha256(convert_to(config::text,'UTF8')),'hex'); s public.family_ai_settings;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  select family_id,ai_generation into family,generation from public.children where id=target_child_id for share;
  perform public.require_parent_authorization(family);
  select * into s from public.family_ai_settings where family_id=family for update;
  perform pg_advisory_xact_lock(hashtextextended('ai-request:'||request_id::text,0));
  select * into a from public.similar_question_adoptions where similar_question_adoptions.request_id=adopt_similar_question.request_id;
  if found then
    if a.owner_id<>auth.uid() or a.child_id<>target_child_id then raise exception '无权保存此请求' using errcode='42501';end if;
    if a.config_hash is distinct from fingerprint then raise exception '保存请求已绑定原审核内容'; end if;
    return public.inspect_similar_adoption(target_child_id,request_id);
  end if;
  select * into r from public.ai_analysis_requests where id=request_id for update;
  if r.owner_id is distinct from auth.uid() or r.child_id is distinct from target_child_id or r.purpose<>'similar' then
    raise exception '无权保存此生成题' using errcode='42501'; end if;
  if not s.enabled or r.policy_version<>s.version or r.generation<>generation or r.state<>'completed' or r.expires_at<=now() or r.result is null
    or jsonb_array_length(r.result->'safety_flags')<>0 then raise exception '生成结果已结束、过期或不可采纳'; end if;
  if not public.valid_similar_question(config) or config->>'subject' is distinct from r.subject
    or config->>'reviewed' is distinct from 'true' or config-'prompt'-'answers'-'subject'-'knowledge_point'-'difficulty'-'explanation'-'reviewed'<>'{}'::jsonb then
    raise exception '请家长逐项核对题目、全部答案和解析'; end if;
  checked:=public.check_practice_answer(config->>'subject',config->>'prompt',config->'answers');
  if checked->>'status'='failed' then raise exception '答案复算未通过，请修正后保存'; end if;
  qid:=public.save_review_question(target_child_id,(config-'reviewed')||jsonb_build_object('kind','question'));
  update public.wrong_questions set ai_generated=true,difficulty=config->>'difficulty' where id=qid;
  insert into public.question_ai_origins(question_id,child_id,source_question_id,source_version,request_id,model_version,prompt_version,confidence,generated_hash,answer_check)
    values(qid,target_child_id,r.source_question_id,r.source_version,r.id,r.model,r.prompt_version,(r.result->>'confidence')::numeric,
      encode(sha256(convert_to((r.result->'structured_output')::text,'UTF8')),'hex'),checked);
  insert into public.similar_question_adoptions(request_id,child_id,owner_id,question_id,config_hash)
    values(request_id,target_child_id,auth.uid(),qid,fingerprint);
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'ai.question_adopt','wrong_question',qid::text,jsonb_build_object('request_id',request_id,'rule_status',checked->>'status'));
  return public.inspect_similar_adoption(target_child_id,request_id);
end $$;
create function public.feedback_ai_result(target_child_id uuid,request_id uuid,reason text) returns void
language plpgsql security definer set search_path='' as $$
declare r public.ai_analysis_requests; family uuid;
begin
  select family_id into family from public.children where id=target_child_id;perform public.require_parent_authorization(family);
  select * into r from public.ai_analysis_requests where id=request_id;
  if r.child_id is distinct from target_child_id or r.owner_id is distinct from auth.uid() then raise exception '无权反馈此请求' using errcode='42501';end if;
  if reason is null or reason not in ('wrong_answer','not_similar','unclear','unsafe','other') then raise exception '请选择反馈类型';end if;
  insert into public.ai_result_feedback(request_id,child_id,reason) values(request_id,target_child_id,reason)
    on conflict on constraint ai_result_feedback_pkey do update set reason=excluded.reason;
end $$;
revoke all on function public.inspect_similar_adoption(uuid,uuid),public.adopt_similar_question(uuid,uuid,jsonb),
  public.preview_practice_answer(uuid,jsonb),public.feedback_ai_result(uuid,uuid,text) from public,anon;
grant execute on function public.inspect_similar_adoption(uuid,uuid),public.adopt_similar_question(uuid,uuid,jsonb),
  public.preview_practice_answer(uuid,jsonb),public.feedback_ai_result(uuid,uuid,text) to authenticated;

alter function public.save_review_question(uuid,jsonb,uuid) rename to save_review_question_before_similar;
create function public.save_review_question(target_child_id uuid,config jsonb,target_question_id uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare qid uuid; checked jsonb; generated boolean; family uuid;
begin
  select family_id into family from public.children where id=target_child_id;perform public.require_parent_authorization(family);
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id::text,0));
  select ai_generated into generated from public.wrong_questions where id=target_question_id and child_id=target_child_id for update;
  if generated then
    checked:=public.check_practice_answer(config->>'subject',config->>'prompt',config->'answers');
    if checked->>'status'='failed' then raise exception '答案复算未通过，请修正后保存'; end if;
  end if;
  if config ? 'difficulty' and (config->>'difficulty' is null or config->>'difficulty' not in ('easy','medium','hard','unknown')) then raise exception '难度不正确'; end if;
  qid:=public.save_review_question_before_similar(target_child_id,config,target_question_id);
  if config ? 'difficulty' then update public.wrong_questions set difficulty=config->>'difficulty' where id=qid; end if;
  if generated then update public.question_ai_origins set answer_check=checked,last_reviewed_version=(select content_version from public.wrong_questions where id=qid) where question_id=qid; end if;
  return qid;
end $$;
revoke all on function public.save_review_question_before_similar(uuid,jsonb,uuid),public.save_review_question(uuid,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.save_review_question(uuid,jsonb,uuid) to authenticated;

alter function public.review_question_editor(uuid) rename to review_question_editor_before_similar;
create function public.review_question_editor(target_question_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb:=public.review_question_editor_before_similar(target_question_id);
begin
  return result||jsonb_build_object('ai_origin',(select to_jsonb(o) from public.question_ai_origins o where question_id=target_question_id));
end $$;
revoke all on function public.review_question_editor_before_similar(uuid),public.review_question_editor(uuid) from public,anon,authenticated;
grant execute on function public.review_question_editor(uuid) to authenticated;

-- Carry the label into immutable review/PDF snapshots and existing renderers.
create function public.label_ai_question_snapshot() returns trigger
language plpgsql security definer set search_path='' as $$
declare source_id uuid;
begin
  source_id:=case when TG_TABLE_NAME='task_review_items' then (to_jsonb(new)->>'wrong_question_id')::uuid else (to_jsonb(new)->>'question_id')::uuid end;
  if exists(select 1 from public.wrong_questions where id=source_id and ai_generated) then
    new.prompt:='【AI生成·家长已审核】'||new.prompt;
  end if;return new;
end $$;
create trigger label_ai_review before insert on public.task_review_items for each row execute function public.label_ai_question_snapshot();
create trigger label_ai_worksheet before insert on public.worksheet_items for each row execute function public.label_ai_question_snapshot();
revoke all on function public.label_ai_question_snapshot() from public,anon,authenticated,service_role;

alter function public.child_export_source(uuid) rename to child_export_source_before_similar;
create function public.child_export_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select public.child_export_source_before_similar(target_child_id)||jsonb_build_array(
    jsonb_build_object('name','ai_question_origins','columns',jsonb_build_array('question_id','child_id','source_question_id','source_version','request_id','model_version','prompt_version','confidence','generated_hash','answer_check','approved_at','last_reviewed_version'),
      'rows',coalesce((select jsonb_agg(to_jsonb(o) order by question_id) from public.question_ai_origins o where child_id=target_child_id),'[]'::jsonb)),
    jsonb_build_object('name','ai_question_adoptions','columns',jsonb_build_array('request_id','child_id','question_id','created_at'),
      'rows',coalesce((select jsonb_agg(to_jsonb(a)-'owner_id'-'config_hash' order by request_id) from public.similar_question_adoptions a where child_id=target_child_id),'[]'::jsonb)),
    jsonb_build_object('name','ai_feedback','columns',jsonb_build_array('request_id','child_id','reason','created_at','model_version','prompt_version'),
      'rows',coalesce((select jsonb_agg(to_jsonb(f)||jsonb_build_object('model_version',r.model,'prompt_version',r.prompt_version) order by f.request_id)
        from public.ai_result_feedback f join public.ai_analysis_requests r on r.id=f.request_id where f.child_id=target_child_id),'[]'::jsonb)));
$$;
revoke all on function public.child_export_source(uuid),public.child_export_source_before_similar(uuid) from public,anon,authenticated,service_role;
alter function public.child_deletion_source(uuid) rename to child_deletion_source_before_similar;
create function public.child_deletion_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_set(public.child_deletion_source_before_similar(target_child_id),'{counts}',
    (public.child_deletion_source_before_similar(target_child_id)->'counts')||jsonb_build_object(
      'ai_question_origins',(select count(*) from public.question_ai_origins where child_id=target_child_id),
      'ai_adoptions',(select count(*) from public.similar_question_adoptions where child_id=target_child_id),
      'ai_feedback',(select count(*) from public.ai_result_feedback where child_id=target_child_id)));
$$;
revoke all on function public.child_deletion_source(uuid),public.child_deletion_source_before_similar(uuid) from public,anon,authenticated,service_role;
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
    or jsonb_typeof(input->'text') is distinct from 'string' or length(btrim(input->>'text')) not between 1 and 2000
    or input->>'subject' is null or input->>'subject' not in ('math','chinese','english')
    or not public.valid_ai_input(input) then raise exception 'AI请求格式不正确' using errcode='22023'; end if;
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
      values(request_id,family,target_child_id,auth.uid(),fingerprint,s.version,generation,'cancelled',now(),case when input->>'kind'='similar' then 'similar' else 'classification' end) returning * into r;
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
      'running',gen_random_uuid(),c.model,c.reserve_cents,now()+make_interval(days=>s.retention_days),case when input->>'kind'='similar' then 'similar' else 'classification' end,
      source.id,source.content_version,input->>'subject',case when input->>'kind'='similar' then 'similar-question-v1' else 'question-structure-v1' end) returning * into r;
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
