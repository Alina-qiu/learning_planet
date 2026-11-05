-- Reviewed answers are private; clients cannot mark mastery or self-award.
alter table public.wrong_questions
  add column review_kind text not null default 'question' check(review_kind in ('question','pinyin')),
  add column review_step smallint not null default 0 check(review_step between 0 and 4),
  add column content_version bigint not null default 0,
  add column review_attempts integer not null default 0,
  add column last_reviewed_at timestamptz,
  add column archived boolean not null default false,
  add column pronunciation_context text not null default '';
create table public.wrong_question_answers (
  question_id uuid primary key references public.wrong_questions(id) on delete cascade,
  accepted_answers text[] not null check(cardinality(accepted_answers) between 1 and 5),
  explanation text not null default ''
);
create table public.task_review_answer_keys (
  task_id uuid not null references public.task_instances(id) on delete cascade,
  question_id uuid not null references public.wrong_questions(id),
  accepted_answers text[] not null,
  explanation text not null,
  primary key(task_id,question_id)
);
alter table public.wrong_question_answers enable row level security;
alter table public.task_review_answer_keys enable row level security;
revoke all on public.wrong_question_answers,public.task_review_answer_keys from public,anon,authenticated;
drop policy wrong_questions_parent_write on public.wrong_questions;
revoke insert,update,delete on public.wrong_questions from anon,authenticated;
revoke insert,update,delete on public.task_review_items from anon,authenticated;
create policy review_items_read on public.task_review_items for select using(exists(
  select 1 from public.task_instances t where t.id=task_instance_id and public.child_is_visible(t.child_id)));

alter table public.task_review_items
  add column prompt text,
  add column subject text,
  add column knowledge_point text,
  add column review_kind text,
  add column pronunciation_context text,
  add column question_version bigint,
  add column answer_text text,
  add column answer_command_id uuid unique;

-- Legacy unfinished generated tasks have no answer keys. Preserve them as skipped
-- instead of allowing unchecked completion or inventing historical answers.
insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
  select c.family_id,null,'review.legacy_task_skip','task_instance',t.id::text,
    jsonb_build_object('reason','Legacy generated task has no immutable answer key')
  from public.task_instances t join public.children c on c.id=t.child_id
  where t.source_type='automatic_wrong_review' and t.status not in ('completed','skipped','expired');
update public.task_instances set status='skipped',active_started_at=null
  where source_type='automatic_wrong_review' and status not in ('completed','skipped','expired');

create function public.normalize_pinyin(value text) returns text
language plpgsql immutable set search_path='' as $$
declare raw text; token text; base text; tone integer; marked integer; letter text; output text[] := '{}';
begin
  raw := lower(translate(normalize(coalesce(value,''),NFC),
    'ĀÁǍÀĒÉĚÈĪÍǏÌŌÓǑÒŪÚǓÙÜǕǗǙǛ','āáǎàēéěèīíǐìōóǒòūúǔùüǖǘǚǜ'));
  raw := replace(replace(raw,'u:','ü'),'v','ü');
  raw := regexp_replace(raw,'[''’·-]',' ','g');
  raw := regexp_replace(raw,'([0-5])','\1 ','g');
  for token in select regexp_split_to_table(btrim(raw),'\s+') loop
    if token='' then continue; end if;
    tone := null; marked := null;
    foreach letter in array regexp_split_to_array(token,'') loop
      if position(letter in 'āēīōūǖ')>0 then marked:=1;
      elsif position(letter in 'áéíóúǘ')>0 then marked:=2;
      elsif position(letter in 'ǎěǐǒǔǚ')>0 then marked:=3;
      elsif position(letter in 'àèìòùǜ')>0 then marked:=4;
      else continue; end if;
      if tone is not null then raise exception '每个音节只允许一个声调，请用空格分开'; end if;
      tone:=marked;
    end loop;
    if token~'[0-5]$' then
      marked := right(token,1)::integer;
      if marked=0 then marked:=5; end if;
      if tone is not null and tone<>marked then raise exception '数字与符号声调不一致'; end if;
      tone:=marked; token:=left(token,length(token)-1);
    end if;
    base := translate(token,'āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ','aaaaeeeeiiiioooouuuuüüüü');
    if base !~ '^[a-zü]+$' then raise exception '拼音只允许字母、ü及声调，请按音节空格分隔'; end if;
    output := array_append(output,base||coalesce(tone,5));
  end loop;
  if cardinality(output)=0 then raise exception '拼音不能为空'; end if;
  return array_to_string(output,' ');
end;
$$;
revoke all on function public.normalize_pinyin(text) from public,anon,authenticated;

create function public.normalize_review_answer(value text,kind text) returns text
language sql immutable set search_path='' as $$
  select case when kind='pinyin' then public.normalize_pinyin(value)
    else lower(regexp_replace(btrim(normalize(coalesce(value,''),NFC)),'\s+',' ','g')) end;
$$;
revoke all on function public.normalize_review_answer(text,text) from public,anon,authenticated;

create function public.save_review_question(target_child_id uuid,config jsonb,target_question_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare family uuid; qid uuid; kind text:=config->>'kind'; answer text; answers text[]:='{}';
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if kind is null or kind not in ('question','pinyin') or nullif(btrim(config->>'prompt'),'') is null
    or length(config->>'prompt')>2000 or config->>'subject' is null
    or config->>'subject' not in ('chinese','math','english')
    or jsonb_typeof(config->'answers') is distinct from 'array'
    or jsonb_array_length(config->'answers') not between 1 and 5 then raise exception 'Invalid review question'; end if;
  if kind='pinyin' and (config->>'subject'<>'chinese' or nullif(btrim(config->>'context'),'') is null
    or config->>'pronunciation_confirmed' is distinct from 'true') then
    raise exception '拼音需提供语境，并由家长确认标准读音';
  end if;
  for answer in select jsonb_array_elements_text(config->'answers') loop
    if nullif(btrim(answer),'') is null or length(answer)>500 then raise exception '答案不能为空或超过500字'; end if;
    perform public.normalize_review_answer(answer,kind);
    answers:=array_append(answers,btrim(answer));
  end loop;
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id,0));
  if target_question_id is null then
    insert into public.wrong_questions(child_id,subject,final_text,knowledge_point,review_kind,
      pronunciation_context,review_due_at) values(target_child_id,config->>'subject',btrim(config->>'prompt'),
      nullif(btrim(config->>'knowledge_point'),''),kind,coalesce(config->>'context',''),now()) returning id into qid;
  else
    update public.wrong_questions set subject=config->>'subject',final_text=btrim(config->>'prompt'),
      knowledge_point=nullif(btrim(config->>'knowledge_point'),''),review_kind=kind,
      pronunciation_context=coalesce(config->>'context',''),content_version=content_version+1,
      review_step=0,mastery_status='unmastered',review_due_at=now(),updated_at=now()
      where id=target_question_id and child_id=target_child_id returning id into qid;
    if not found then raise exception 'Question access required' using errcode='42501'; end if;
  end if;
  insert into public.wrong_question_answers values(qid,answers,coalesce(config->>'explanation',''))
    on conflict(question_id) do update set accepted_answers=excluded.accepted_answers,explanation=excluded.explanation;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id)
    values(family,auth.uid(),'review.question_save','wrong_question',qid::text);
  return qid;
end;
$$;
revoke all on function public.save_review_question(uuid,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.save_review_question(uuid,jsonb,uuid) to authenticated;

create function public.review_question_editor(target_question_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare family uuid; result jsonb;
begin
  select c.family_id into family from public.wrong_questions w join public.children c on c.id=w.child_id where w.id=target_question_id;
  perform public.require_parent_authorization(family);
  select to_jsonb(w)||jsonb_build_object('answers',a.accepted_answers,'explanation',a.explanation) into result
    from public.wrong_questions w left join public.wrong_question_answers a on a.question_id=w.id where w.id=target_question_id;
  return result;
end;
$$;
revoke all on function public.review_question_editor(uuid) from public,anon,authenticated;
grant execute on function public.review_question_editor(uuid) to authenticated;

create function public.archive_review_question(target_question_id uuid,enabled boolean) returns void
language plpgsql security definer set search_path='' as $$
declare family uuid;
begin
  select c.family_id into family from public.wrong_questions w join public.children c on c.id=w.child_id where w.id=target_question_id;
  perform public.require_parent_authorization(family);
  update public.wrong_questions set archived=enabled,updated_at=now() where id=target_question_id;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'review.question_archive','wrong_question',target_question_id::text,jsonb_build_object('archived',enabled));
end;
$$;
revoke all on function public.archive_review_question(uuid,boolean) from public,anon,authenticated;
grant execute on function public.archive_review_question(uuid,boolean) to authenticated;

create or replace function public.generate_daily_wrong_review_task(
  target_child_id uuid,target_date date default null,max_questions integer default 10
) returns uuid language plpgsql security definer set search_path='' as $$
declare task_id uuid; zone text; today date;
begin
  if auth.role() is distinct from 'service_role' and not public.child_is_visible(target_child_id) then
    raise exception 'Child access required' using errcode='42501'; end if;
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  if zone is null then raise exception 'Child not found'; end if;
  today := (now() at time zone zone)::date;
  if auth.role() is distinct from 'service_role' and target_date is not null and target_date<>today then
    raise exception 'Only family today can be generated'; end if;
  target_date:=coalesce(target_date,today);
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id,0));
  select id into task_id from public.task_instances where child_id=target_child_id
    and due_date=target_date and source_type='automatic_wrong_review' for update;
  if found then return task_id; end if;
  if not exists(select 1 from public.wrong_questions w join public.wrong_question_answers a on a.question_id=w.id
    where w.child_id=target_child_id and not w.archived and w.mastery_status<>'mastered'
      and w.review_due_at<((target_date+1)::timestamp at time zone zone)) then return null; end if;
  insert into public.task_instances(child_id,title,due_date,source_type,coin_reward,xp_reward,idempotency_key)
    values(target_child_id,'今日错题与拼音复习',target_date,'automatic_wrong_review',0,0,
      'auto-review:'||target_child_id||':'||target_date) returning id into task_id;
  with candidates as (
    select w.* from public.wrong_questions w join public.wrong_question_answers a on a.question_id=w.id
    where w.child_id=target_child_id and not w.archived and w.mastery_status<>'mastered'
      and w.review_due_at<((target_date+1)::timestamp at time zone zone)
    order by w.review_due_at,w.wrong_count desc,w.id limit greatest(1,least(coalesce(max_questions,10),10))
    for share of w,a
  ) insert into public.task_review_items(task_instance_id,wrong_question_id,sequence,prompt,subject,
    knowledge_point,review_kind,pronunciation_context,question_version)
    select task_id,id,row_number() over(order by review_due_at,wrong_count desc,id)::smallint,
      final_text,subject,knowledge_point,review_kind,pronunciation_context,content_version from candidates;
  insert into public.task_review_answer_keys(task_id,question_id,accepted_answers,explanation)
    select task_id,w.id,a.accepted_answers,a.explanation from public.task_review_items i
    join public.wrong_questions w on w.id=i.wrong_question_id
    join public.wrong_question_answers a on a.question_id=w.id where i.task_instance_id=task_id;
  update public.task_instances set coin_reward=(select count(*)::integer*5 from public.task_review_items where task_instance_id=task_id),
    xp_reward=(select count(*)::integer*5 from public.task_review_items where task_instance_id=task_id) where id=task_id;
  return task_id;
end;
$$;
revoke all on function public.generate_daily_wrong_review_task(uuid,date,integer) from public,anon,authenticated;
grant execute on function public.generate_daily_wrong_review_task(uuid,date,integer) to authenticated,service_role;

create function public.load_review_task(target_task_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t public.task_instances; result jsonb;
begin
  select * into t from public.task_instances where id=target_task_id;
  if not found or not public.child_is_visible(t.child_id) or t.source_type<>'automatic_wrong_review' then
    raise exception 'Review task access required' using errcode='42501'; end if;
  select jsonb_build_object('task',to_jsonb(t),'items',coalesce(jsonb_agg(
    to_jsonb(i)||jsonb_build_object('accepted_answers',case when i.result is not null then k.accepted_answers end,
      'explanation',case when i.result is not null then k.explanation end) order by i.sequence),'[]'::jsonb)) into result
    from public.task_review_items i left join public.task_review_answer_keys k on k.task_id=i.task_instance_id
      and k.question_id=i.wrong_question_id where i.task_instance_id=t.id;
  return result;
end;
$$;
revoke all on function public.load_review_task(uuid) from public,anon,authenticated;
grant execute on function public.load_review_task(uuid) to authenticated;

create function public.submit_review_answer(target_task_id uuid,target_question_id uuid,answer text,command_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.task_instances; item public.task_review_items; key public.task_review_answer_keys;
  correct boolean; zone text; days integer; current_question public.wrong_questions;
begin
  select * into t from public.task_instances where id=target_task_id for update;
  if not found or not public.child_is_visible(t.child_id) or t.source_type<>'automatic_wrong_review' then
    raise exception 'Review task access required' using errcode='42501'; end if;
  select * into item from public.task_review_items where task_instance_id=t.id and wrong_question_id=target_question_id for update;
  if not found or command_id is null or nullif(btrim(answer),'') is null or length(answer)>500 then raise exception 'Invalid review answer'; end if;
  if item.result is not null then
    if item.answer_text<>answer then raise exception '此题已提交，不能修改已判定答案'; end if;
    return public.load_review_task(t.id);
  end if;
  if t.status<>'in_progress' then raise exception '请先开始或继续复习'; end if;
  select * into key from public.task_review_answer_keys where task_id=t.id and question_id=target_question_id;
  if not found then raise exception '此旧任务缺少标准答案，请联系家长更新错题'; end if;
  correct:=exists(select 1 from unnest(key.accepted_answers) a
    where public.normalize_review_answer(a,item.review_kind)=public.normalize_review_answer(answer,item.review_kind));
  update public.task_review_items set result=correct,answer_text=answer,answer_command_id=command_id,
    answered_at=now() where task_instance_id=t.id and wrong_question_id=target_question_id;
  select * into current_question from public.wrong_questions where id=target_question_id for update;
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id where c.id=t.child_id;
  -- A result for an old snapshot must not advance an edited live question.
  if current_question.content_version=item.question_version then
    days:=case when correct then (array[1,3,7,30])[least(current_question.review_step+1,4)] else 1 end;
    update public.wrong_questions set review_attempts=review_attempts+1,last_reviewed_at=now(),
      wrong_count=wrong_count+case when correct then 0 else 1 end,
      review_step=case when correct then least(review_step+1,4) else 0 end,
      mastery_status=case when correct and review_step=4 then 'mastered'::public.mastery_status else 'practicing'::public.mastery_status end,
      review_due_at=case when correct and review_step=4 then null
        else (((now() at time zone zone)::date+days)::timestamp at time zone zone) end,updated_at=now()
      where id=current_question.id;
  end if;
  return public.load_review_task(t.id);
end;
$$;
revoke all on function public.submit_review_answer(uuid,uuid,text,uuid) from public,anon,authenticated;
grant execute on function public.submit_review_answer(uuid,uuid,text,uuid) to authenticated;

alter function public.complete_task(uuid,text,text) rename to complete_task_before_review;
revoke all on function public.complete_task_before_review(uuid,text,text) from public,anon,authenticated;
create function public.complete_task(target_task_id uuid,completion_key text,parent_reason text default null)
returns public.task_instances language plpgsql security definer set search_path='' as $$
declare t public.task_instances; answered integer; correct integer;
begin
  select * into t from public.task_instances where id=target_task_id for update;
  if not found or not public.child_is_visible(t.child_id) then raise exception 'Task access required' using errcode='42501'; end if;
  if t.source_type='automatic_wrong_review' and t.status<>'completed' then
    if parent_reason is not null then raise exception '自动复习必须逐题作答，不能用普通补签跳过'; end if;
    select count(*)::integer,count(*) filter(where result)::integer into answered,correct
      from public.task_review_items where task_instance_id=t.id;
    if answered=0 or exists(select 1 from public.task_review_items where task_instance_id=t.id and result is null) then
      raise exception '请完成全部题目后再结算'; end if;
    update public.task_instances set coin_reward=correct*5,xp_reward=answered*3+correct*2 where id=t.id;
  end if;
  return public.complete_task_before_review(t.id,completion_key,parent_reason);
end;
$$;
revoke all on function public.complete_task(uuid,text,text) from public,anon,authenticated;
grant execute on function public.complete_task(uuid,text,text) to authenticated;

create function public.review_overview(target_child_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare task_id uuid; due integer; selected integer; zone text;
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required' using errcode='42501'; end if;
  task_id:=public.generate_daily_wrong_review_task(target_child_id);
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  select count(*)::integer into due from public.wrong_questions w join public.wrong_question_answers a on a.question_id=w.id
    where w.child_id=target_child_id and not w.archived and w.mastery_status<>'mastered'
      and w.review_due_at<(((now() at time zone zone)::date+1)::timestamp at time zone zone);
  select count(*)::integer into selected from public.task_review_items i join public.wrong_questions w on w.id=i.wrong_question_id
    where i.task_instance_id=task_id and i.question_version=w.content_version
      and w.review_due_at<(((now() at time zone zone)::date+1)::timestamp at time zone zone)
      and w.mastery_status<>'mastered' and not w.archived;
  return jsonb_build_object('task_id',task_id,'due',due,'backlog',greatest(0,due-selected));
end;
$$;
revoke all on function public.review_overview(uuid) from public,anon,authenticated;
grant execute on function public.review_overview(uuid) to authenticated;

-- Startup/offline recovery compensation accompanies the ordinary task snapshot.
alter function public.task_sync_snapshot(uuid) rename to task_sync_snapshot_before_review;
revoke all on function public.task_sync_snapshot_before_review(uuid) from public,anon,authenticated;
create function public.task_sync_snapshot(target_child_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  perform public.generate_daily_wrong_review_task(target_child_id);
  return public.task_sync_snapshot_before_review(target_child_id);
end;
$$;
revoke all on function public.task_sync_snapshot(uuid) from public,anon,authenticated;
grant execute on function public.task_sync_snapshot(uuid) to authenticated;

create function public.run_review_maintenance() returns integer
language plpgsql security definer set search_path='' as $$
declare child record; count integer:=0; previous_claims text:=current_setting('request.jwt.claims',true);
begin
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  for child in select c.id from public.children c join public.families f on f.id=c.family_id
    where (now() at time zone f.timezone)::time>='00:05' loop
    if public.generate_daily_wrong_review_task(child.id) is not null then count:=count+1; end if;
  end loop;
  perform set_config('request.jwt.claims',coalesce(previous_claims,''),true);
  return count;
exception when others then
  perform set_config('request.jwt.claims',coalesce(previous_claims,''),true); raise;
end;
$$;
revoke all on function public.run_review_maintenance() from public,anon,authenticated;
grant execute on function public.run_review_maintenance() to service_role;
do $$ begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    perform cron.schedule('learning-planet-review-maintenance','* * * * *','select public.run_review_maintenance();');
  end if;
end; $$;
