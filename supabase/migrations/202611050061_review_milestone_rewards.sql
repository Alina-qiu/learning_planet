-- Existing tasks retain their published per-answer reward contract. New daily
-- tasks freeze stage snapshots and use PRD 6.4 correction / 7-day / 30-day awards.
alter table public.task_instances add column review_reward_policy smallint not null default 1
  check(review_reward_policy in (1,2) and (review_reward_policy=1 or source_type='automatic_wrong_review'));
alter table public.task_review_items
  add column review_step_snapshot smallint check(review_step_snapshot between 0 and 4),
  add column review_due_snapshot timestamptz,
  add column reward_stage smallint check(reward_stage in (0,3,4)),
  add column reward_status text not null default 'legacy' check(reward_status in ('legacy','pending','wrong','practice','already_rewarded','stale','eligible','awarded')),
  add column reward_coins integer not null default 0 check(reward_coins between 0 and 40),
  add column reward_xp integer not null default 0 check(reward_xp between 0 and 30),
  add column reward_awarded_at timestamptz;

-- Private uniqueness receipts duplicate the public per-item award fields. They
-- are not an additional wallet or mutable balance; child/question deletion cascades.
create table public.review_milestone_awards(
  child_id uuid not null references public.children(id) on delete cascade,
  question_id uuid not null references public.wrong_questions(id) on delete cascade,
  question_version bigint not null check(question_version>=0),
  stage smallint not null check(stage in (0,3,4)),
  task_id uuid not null references public.task_instances(id) on delete cascade,
  awarded_at timestamptz not null default now(),
  primary key(question_id,question_version,stage)
);
alter table public.review_milestone_awards enable row level security;
revoke all on public.review_milestone_awards from public,anon,authenticated,service_role;

create function public.snapshot_review_reward_stage() returns trigger
language plpgsql security definer set search_path='' as $$
declare w public.wrong_questions;
begin
  if (select review_reward_policy from public.task_instances where id=new.task_instance_id)=2 then
    select * into w from public.wrong_questions where id=new.wrong_question_id;
    new.review_step_snapshot:=w.review_step;new.review_due_snapshot:=w.review_due_at;
    new.reward_stage:=case when w.review_step in (0,3,4) then w.review_step end;
    new.reward_status:='pending';new.reward_coins:=0;new.reward_xp:=0;new.reward_awarded_at:=null;
  end if;
  return new;
end $$;
create trigger review_reward_snapshot before insert on public.task_review_items
  for each row execute function public.snapshot_review_reward_stage();
revoke all on function public.snapshot_review_reward_stage() from public,anon,authenticated,service_role;

create or replace function public.generate_daily_wrong_review_task(
  target_child_id uuid,target_date date default null,max_questions integer default 10
) returns uuid language plpgsql security definer set search_path='' as $$
declare task_id uuid; zone text; today date;
begin
  if auth.role() is distinct from 'service_role' and not public.child_is_visible(target_child_id) then
    raise exception 'Child access required' using errcode='42501'; end if;
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  if zone is null then raise exception 'Child not found'; end if;
  today:=(now() at time zone zone)::date;
  if auth.role() is distinct from 'service_role' and target_date is not null and target_date<>today then
    raise exception 'Only family today can be generated'; end if;
  target_date:=coalesce(target_date,today);
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id,0));
  select id into task_id from public.task_instances where child_id=target_child_id
    and due_date=target_date and source_type='automatic_wrong_review' for update;
  if found then return task_id; end if;
  if not exists(select 1 from public.wrong_questions w join public.wrong_question_answers a on a.question_id=w.id
    where w.child_id=target_child_id and not w.archived and not w.deleting and w.mastery_status<>'mastered'
      and w.review_due_at<((target_date+1)::timestamp at time zone zone)) then return null; end if;
  insert into public.task_instances(child_id,title,due_date,source_type,coin_reward,xp_reward,idempotency_key,review_reward_policy)
    values(target_child_id,'今日错题与拼音复习',target_date,'automatic_wrong_review',0,0,
      'auto-review:'||target_child_id||':'||target_date,2) returning id into task_id;
  with candidates as (
    select w.* from public.wrong_questions w join public.wrong_question_answers a on a.question_id=w.id
    where w.child_id=target_child_id and not w.archived and not w.deleting and w.mastery_status<>'mastered'
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
  update public.task_instances set
    coin_reward=(select coalesce(sum(case i.reward_stage when 0 then 15 when 3 then 25 when 4 then 40 else 0 end),0)::integer
      from public.task_review_items i where i.task_instance_id=task_id and not exists(select 1 from public.review_milestone_awards r where r.question_id=i.wrong_question_id and r.question_version=i.question_version and r.stage=i.reward_stage)),
    xp_reward=(select coalesce(sum(case i.reward_stage when 0 then 15 when 3 then 20 when 4 then 30 else 0 end),0)::integer
      from public.task_review_items i where i.task_instance_id=task_id and not exists(select 1 from public.review_milestone_awards r where r.question_id=i.wrong_question_id and r.question_version=i.question_version and r.stage=i.reward_stage)),
    expected_minutes=(select greatest(1,count(*)::integer*2) from public.task_review_items where task_instance_id=task_id)
    where id=task_id;
  return task_id;
end $$;

-- Keep the existing public wrapper's task sync-version bump and offline replay.
create or replace function public.submit_review_answer_before_offline(target_task_id uuid,target_question_id uuid,answer text,command_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.task_instances; item public.task_review_items; key public.task_review_answer_keys;
  correct boolean; zone text; days integer; current_question public.wrong_questions; current_snapshot boolean; reason text;
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
  select * into current_question from public.wrong_questions where id=target_question_id for update;
  select f.timezone into zone from public.children c join public.families f on f.id=c.family_id where c.id=t.child_id;
  current_snapshot:=current_question.content_version=item.question_version;
  reason:='legacy';
  if t.review_reward_policy=2 then
    current_snapshot:=coalesce(current_snapshot and current_question.review_step=item.review_step_snapshot
      and current_question.review_due_at is not distinct from item.review_due_snapshot
      and current_question.review_due_at<(((now() at time zone zone)::date+1)::timestamp at time zone zone)
      and current_question.mastery_status<>'mastered' and not current_question.archived and not current_question.deleting,false);
    reason:=case when not current_snapshot then 'stale' when not correct then 'wrong'
      when item.reward_stage is null then 'practice'
      when exists(select 1 from public.review_milestone_awards r where r.question_id=target_question_id and r.question_version=item.question_version and r.stage=item.reward_stage) then 'already_rewarded'
      else 'eligible' end;
  end if;
  update public.task_review_items set result=correct,answer_text=answer,answer_command_id=command_id,
    answered_at=now(),reward_status=reason where task_instance_id=t.id and wrong_question_id=target_question_id;
  if current_snapshot then
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
end $$;
revoke all on function public.submit_review_answer_before_offline(uuid,uuid,text,uuid) from public,anon,authenticated,service_role;

alter function public.complete_task(uuid,text,text) rename to complete_task_before_milestones;
revoke all on function public.complete_task_before_milestones(uuid,text,text) from public,anon,authenticated,service_role;
create function public.complete_task(target_task_id uuid,completion_key text,parent_reason text default null)
returns public.task_instances language plpgsql security definer set search_path='' as $$
declare t public.task_instances; item public.task_review_items; inserted boolean;
begin
  select * into t from public.task_instances where id=target_task_id for update;
  if not found or not public.child_is_visible(t.child_id) then raise exception 'Task access required' using errcode='42501'; end if;
  if t.review_reward_policy=1 or t.status='completed' then
    return public.complete_task_before_milestones(t.id,completion_key,parent_reason);
  end if;
  if parent_reason is not null then raise exception '自动复习必须逐题作答，不能用普通补签跳过'; end if;
  if not exists(select 1 from public.task_review_items where task_instance_id=t.id)
    or exists(select 1 from public.task_review_items where task_instance_id=t.id and result is null) then
    raise exception '请完成全部题目后再结算'; end if;
  -- Sorted private claims prevent competing multi-question completions from
  -- taking uniqueness locks in opposite orders. Everything rolls back if the
  -- existing completion/authorization/timing/ledger transaction rejects.
  for item in select * from public.task_review_items where task_instance_id=t.id and reward_status='eligible' order by wrong_question_id loop
    inserted:=false;
    insert into public.review_milestone_awards(child_id,question_id,question_version,stage,task_id)
      values(t.child_id,item.wrong_question_id,item.question_version,item.reward_stage,t.id)
      on conflict(question_id,question_version,stage) do nothing returning true into inserted;
    update public.task_review_items set reward_status=case when coalesce(inserted,false) then 'awarded' else 'already_rewarded' end,
      reward_coins=case when coalesce(inserted,false) then case item.reward_stage when 0 then 15 when 3 then 25 when 4 then 40 end else 0 end,
      reward_xp=case when coalesce(inserted,false) then case item.reward_stage when 0 then 15 when 3 then 20 when 4 then 30 end else 0 end,
      reward_awarded_at=case when coalesce(inserted,false) then now() end
      where task_instance_id=t.id and wrong_question_id=item.wrong_question_id;
  end loop;
  update public.task_instances set
    coin_reward=(select coalesce(sum(reward_coins),0)::integer from public.task_review_items where task_instance_id=t.id),
    xp_reward=(select coalesce(sum(reward_xp),0)::integer from public.task_review_items where task_instance_id=t.id)
    where id=t.id;
  return public.complete_task_before_review(t.id,completion_key,parent_reason);
end $$;
revoke all on function public.complete_task(uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function public.complete_task(uuid,text,text) to authenticated;
