-- Static character slots, daily challenge tasks and parent-confirmed awards.
alter table public.growth_assets add column starter boolean not null default false;
insert into public.growth_assets(key,title,kind,starter) values
  ('starter_star','小星伙伴','pet',true),('starter_rabbit','小兔伙伴','pet',true);
alter table public.child_growth_profiles
  add column avatar_key text not null default 'astronaut' check(avatar_key in ('astronaut','explorer')),
  add column badge_key text references public.growth_assets(key),
  add column outfit_key text references public.growth_assets(key),
  add column pet_key text references public.growth_assets(key) default 'starter_star';
update public.child_growth_profiles p set
  badge_key=case when a.kind='badge' then a.key end,
  outfit_key=case when a.kind='outfit' then a.key end,
  pet_key=case when a.kind='pet' then a.key else 'starter_star' end
  from public.growth_assets a where a.key=p.equipped_asset;

create function public.set_growth_slot(target_child_id uuid, slot text, selection text) returns void
language plpgsql security definer set search_path='' as $$
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required' using errcode='42501'; end if;
  if slot is null or slot not in ('avatar','badge','outfit','pet') then raise exception 'Invalid appearance slot'; end if;
  if slot='avatar' then
    if selection is null or selection not in ('astronaut','explorer') then raise exception 'Invalid character'; end if;
  elsif selection is not null and not exists(select 1 from public.growth_assets a
    where a.key=selection and a.kind=slot and (a.starter or exists(
      select 1 from public.child_growth_assets u where u.child_id=target_child_id and u.asset_key=a.key))) then
    raise exception '请先解锁对应类型的奖励';
  end if;
  -- One slot per operation; concurrent devices cannot replace unrelated slots.
  insert into public.child_growth_profiles(child_id) values(target_child_id) on conflict do nothing;
  update public.child_growth_profiles set
    avatar_key=case when slot='avatar' then selection else avatar_key end,
    badge_key=case when slot='badge' then selection else badge_key end,
    outfit_key=case when slot='outfit' then selection else outfit_key end,
    pet_key=case when slot='pet' then selection else pet_key end
    where child_id=target_child_id;
end $$;
revoke all on function public.set_growth_slot(uuid,text,text) from public,anon;
grant execute on function public.set_growth_slot(uuid,text,text) to authenticated;

-- Keep the original API coherent for older clients.
create or replace function public.equip_growth_asset(target_child_id uuid, asset_key text) returns void
language plpgsql security definer set search_path='' as $$
declare kind text;
begin
  if asset_key is null then
    perform public.set_growth_slot(target_child_id,'badge',null);
    perform public.set_growth_slot(target_child_id,'outfit',null);
    perform public.set_growth_slot(target_child_id,'pet',null);
  else
    select a.kind into kind from public.growth_assets a where a.key=asset_key;
    perform public.set_growth_slot(target_child_id,kind,asset_key);
  end if;
  update public.child_growth_profiles set equipped_asset=asset_key where child_id=target_child_id;
end $$;

alter function public.growth_overview(uuid) rename to growth_overview_before_slots;
revoke all on function public.growth_overview_before_slots(uuid) from public,anon,authenticated;
create function public.growth_overview(target_child_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; profile public.child_growth_profiles; assets jsonb;
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required' using errcode='42501'; end if;
  result:=public.growth_overview_before_slots(target_child_id);
  select * into profile from public.child_growth_profiles where child_id=target_child_id;
  if not found then profile.avatar_key:='astronaut'; profile.pet_key:='starter_star'; end if;
  select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('unlocked',a.starter or u.asset_key is not null)
    order by a.starter desc,a.minimum_level nulls first,a.key),'[]') into assets from public.growth_assets a
    left join public.child_growth_assets u on u.asset_key=a.key and u.child_id=target_child_id;
  return result||jsonb_build_object('assets',assets,'appearance',jsonb_build_object(
    'avatar',profile.avatar_key,'badge',profile.badge_key,'outfit',profile.outfit_key,'pet',profile.pet_key),
    'xp',coalesce((select xp from public.wallets where child_id=target_child_id),0),
    'today',public.family_today(target_child_id));
end $$;
revoke all on function public.growth_overview(uuid) from public,anon;
grant execute on function public.growth_overview(uuid) to authenticated;

alter table public.task_instances add column task_kind text not null default 'standard' check(task_kind in ('standard','challenge'));
create unique index one_daily_challenge on public.task_instances(child_id,due_date) where task_kind='challenge';
create function public.create_daily_challenge(target_child_id uuid, command_id uuid, title text, minimum_seconds integer default 0)
returns uuid language plpgsql security definer set search_path='' as $$
declare family uuid; day date; task public.task_instances;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if command_id is null or nullif(btrim(title),'') is null or length(title)>120 or minimum_seconds is null
    or minimum_seconds not between 0 and 7200 then raise exception '请填写挑战名称，最低时长为0至120分钟'; end if;
  perform pg_advisory_xact_lock(hashtextextended('challenge-request:'||command_id::text,0));
  select * into task from public.task_instances where idempotency_key='challenge-request:'||command_id;
  if found then
    if task.child_id<>target_child_id or task.title<>btrim(title) or task.minimum_seconds<>minimum_seconds then raise exception 'Command payload changed'; end if;
    return task.id;
  end if;
  day:=public.family_today(target_child_id);
  perform pg_advisory_xact_lock(hashtextextended('challenge:'||target_child_id::text||':'||day::text,0));
  select * into task from public.task_instances where child_id=target_child_id and due_date=day and task_kind='challenge';
  if found then
    raise exception '今天已有挑战，请在任务中心查看';
  end if;
  insert into public.task_instances(child_id,title,due_date,source_type,task_kind,minimum_seconds,
    coin_reward,xp_reward,idempotency_key) values(target_child_id,btrim(title),day,'parent_template','challenge',minimum_seconds,
    30,25,'challenge-request:'||command_id) returning * into task;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id)
    values(family,auth.uid(),'challenge.create','task_instance',task.id::text);
  return task.id;
end $$;
revoke all on function public.create_daily_challenge(uuid,uuid,text,integer) from public,anon;
grant execute on function public.create_daily_challenge(uuid,uuid,text,integer) to authenticated;

create table public.learning_events(
  id uuid primary key, child_id uuid not null references public.children(id) on delete cascade,
  kind text not null check(kind in ('praise','exam')), event_date date not null,
  reference text not null, payload jsonb not null,
  coin_reward integer not null, xp_reward integer not null,
  actor_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(), unique(child_id,kind,event_date,reference));
alter table public.learning_events enable row level security;
create index learning_events_child_history on public.learning_events(child_id,created_at desc,id);
revoke all on public.learning_events from public,anon,authenticated;
grant select on public.learning_events to authenticated;
create policy learning_events_read on public.learning_events for select to authenticated using(public.child_is_visible(child_id));

create function public.award_learning_event(target_child_id uuid, command_id uuid, config jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare family uuid; day date; kind text; reference text; reason text;
  coins integer; xp integer; score_coins integer; score_xp integer; improvement_coins integer; improvement_xp integer;
  payload jsonb; previous public.learning_events;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  kind:=config->>'kind'; reference:=btrim(config->>'reference'); reason:=btrim(config->>'reason'); day:=(config->>'date')::date;
  if command_id is null or kind is null or kind not in ('praise','exam') or nullif(reference,'') is null or length(reference)>120
    or nullif(reason,'') is null or length(reason)>500 or day is null or not isfinite(day)
    or day<date '2000-01-01' or day>public.family_today(target_child_id)::date then raise exception '请检查事件日期、名称和确认说明'; end if;
  if kind='praise' then
    coins:=(config->>'coins')::integer; xp:=(config->>'xp')::integer;
    if coins is null or xp is null or coins not between 30 and 100 or xp not between 20 and 50 then
      raise exception '表扬奖励范围为30至100金币、20至50XP'; end if;
    payload:=jsonb_build_object('kind',kind,'reference',reference,'reason',reason,'date',day,'coins',coins,'xp',xp);
  else
    score_coins:=(config->>'score_coins')::integer; score_xp:=(config->>'score_xp')::integer;
    improvement_coins:=(config->>'improvement_coins')::integer; improvement_xp:=(config->>'improvement_xp')::integer;
    if score_coins is null or score_xp is null or improvement_coins is null or improvement_xp is null
      or not ((score_coins=0 and score_xp=0) or (score_coins between 50 and 200 and score_xp between 30 and 100))
      or not ((improvement_coins=0 and improvement_xp=0) or (improvement_coins between 50 and 200 and improvement_xp between 30 and 100))
      or greatest(score_coins,improvement_coins)=0 then raise exception '考试奖励每档为50至200金币、30至100XP；不使用的档位均填0'; end if;
    -- Select one package, never sum or combine two packages. Ties favor improvement.
    if (score_coins,score_xp)>(improvement_coins,improvement_xp) then coins:=score_coins; xp:=score_xp;
    else coins:=improvement_coins; xp:=improvement_xp; end if;
    payload:=jsonb_build_object('kind',kind,'reference',reference,'reason',reason,'date',day,
      'score_coins',score_coins,'score_xp',score_xp,'improvement_coins',improvement_coins,'improvement_xp',improvement_xp);
  end if;
  perform pg_advisory_xact_lock(hashtextextended('learning-event:'||command_id::text,0));
  select * into previous from public.learning_events where id=command_id;
  if found then
    if previous.child_id<>target_child_id or previous.payload<>payload then raise exception 'Command payload changed'; end if;
    return previous.id;
  end if;
  insert into public.learning_events(id,child_id,kind,event_date,reference,payload,coin_reward,xp_reward,actor_id)
    values(command_id,target_child_id,kind,day,reference,payload,coins,xp,auth.uid());
  insert into public.ledger_entries(child_id,asset_type,amount,source_type,source_id,idempotency_key) values
    (target_child_id,'coin',coins,'learning_event',command_id,'learning-event:'||command_id||':coin'),
    (target_child_id,'xp',xp,'learning_event',command_id,'learning-event:'||command_id||':xp');
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'learning_event.award','learning_event',command_id::text,payload||jsonb_build_object('awarded_coins',coins,'awarded_xp',xp));
  return command_id;
end $$;
revoke all on function public.award_learning_event(uuid,uuid,jsonb) from public,anon;
grant execute on function public.award_learning_event(uuid,uuid,jsonb) to authenticated;
