alter table public.children
  add column textbook_labels jsonb not null default '{}',
  add column avatar_key text not null default 'star' check(avatar_key in ('star','moon','sun','rocket','planet','leaf')),
  add column profile_version bigint not null default 0,
  add column guide_step smallint not null default 0 check(guide_step between 0 and 3),
  add column starter_task_preset text not null default 'study20' check(starter_task_preset in ('study10','study20','reading20','habit')),
  add column starter_rules_at timestamptz,
  add column onboarding_completed_at timestamptz;
-- All writes use checked RPCs, including guide progress. Parent UI flags cannot
-- fabricate completion, reset progress or write a profile version directly.
revoke insert,update,delete on public.children from anon,authenticated;
alter table public.rewards add column starter_key text check(starter_key in ('cartoon','game','book','movie','restaurant','toy','park'));
create unique index family_starter_reward on public.rewards(family_id,starter_key) where starter_key is not null;

create function public.validate_child_preferences(preferences jsonb) returns void
language plpgsql immutable set search_path='' as $$
declare labels jsonb:=preferences->'textbook_labels'; entry record;
begin
  if jsonb_typeof(preferences) is distinct from 'object' or preferences->>'avatar_key' is null
    or preferences->>'avatar_key' not in ('star','moon','sun','rocket','planet','leaf')
    or jsonb_typeof(labels) is distinct from 'object' then raise exception '请选择头像并填写有效的教材标签'; end if;
  for entry in select * from jsonb_each(labels) loop
    if entry.key not in ('chinese','math','english') or jsonb_typeof(entry.value)<>'string'
      or length(btrim(entry.value#>>'{}')) not between 1 and 60 then raise exception '教材标签支持语文、数学、英语，每项1至60字'; end if;
  end loop;
end $$;
create function public.version_child_profile() returns trigger language plpgsql set search_path='' as $$
begin
  if (new.nickname,new.grade,new.textbook_labels,new.avatar_key) is distinct from (old.nickname,old.grade,old.textbook_labels,old.avatar_key) then
    new.profile_version:=old.profile_version+1;
  else new.profile_version:=old.profile_version; end if;
  return new;
end $$;
create trigger child_profile_version before update on public.children for each row execute function public.version_child_profile();
revoke all on function public.validate_child_preferences(jsonb),public.version_child_profile() from public,anon,authenticated,service_role;

create function public.onboard_family_profile(family_name text,family_timezone text,child_nickname text,child_grade smallint,preferences jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare family uuid;
begin
  perform public.validate_child_preferences(preferences);
  if length(btrim(child_nickname)) not between 1 and 40 then raise exception '昵称需为1至40字'; end if;
  family:=public.onboard_family(family_name,family_timezone,child_nickname,child_grade);
  update public.children set textbook_labels=preferences->'textbook_labels',avatar_key=preferences->>'avatar_key' where family_id=family;
  return family;
end $$;
create function public.create_child_profile(target_family_id uuid,child_nickname text,child_grade smallint,preferences jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare child uuid;
begin
  perform public.validate_child_preferences(preferences);
  if length(btrim(child_nickname)) not between 1 and 40 then raise exception '昵称需为1至40字'; end if;
  child:=public.create_child(target_family_id,child_nickname,child_grade);
  update public.children set textbook_labels=preferences->'textbook_labels',avatar_key=preferences->>'avatar_key' where id=child;
  return child;
end $$;
create function public.update_child_profile(target_child_id uuid,child_nickname text,child_grade smallint,preferences jsonb,expected_version bigint) returns void
language plpgsql security definer set search_path='' as $$
declare child public.children;
begin
  select * into child from public.children where id=target_child_id;
  perform public.require_parent_authorization(child.family_id);
  if not public.is_family_admin(child.family_id) then raise exception 'Family administrator required' using errcode='42501'; end if;
  perform 1 from public.families where id=child.family_id for key share;
  select * into child from public.children where id=target_child_id for update;
  if not found then raise exception 'Child access required' using errcode='42501'; end if;
  if expected_version is distinct from child.profile_version then raise exception '孩子档案已在另一处修改，请刷新后重新编辑' using errcode='40001'; end if;
  perform public.validate_child_preferences(preferences);
  if child_nickname is null or length(btrim(child_nickname)) not between 1 and 40 or child_grade is null or child_grade not between 1 and 6 then raise exception '昵称需为1至40字，年级需为1至6'; end if;
  update public.children set nickname=btrim(child_nickname),grade=child_grade,textbook_labels=preferences->'textbook_labels',avatar_key=preferences->>'avatar_key' where id=target_child_id;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(child.family_id,auth.uid(),'child.profile','child',target_child_id::text,jsonb_build_object('previous_version',expected_version));
end $$;

create function public.configure_starter_rules(target_child_id uuid,preset text,daily_limit integer,reward_keys text[]) returns void
language plpgsql security definer set search_path='' as $$
declare family uuid; key text; title text; cost integer; saved uuid;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if preset is null or preset not in ('study10','study20','reading20','habit') or daily_limit is null or daily_limit not between 0 and 10000
    or reward_keys is null or cardinality(reward_keys)>7 or array_position(reward_keys,null) is not null
    or exists(select 1 from unnest(reward_keys) k where k not in ('cartoon','game','book','movie','restaurant','toy','park')) then raise exception '请检查积分模板、每日上限和奖励选择'; end if;
  perform 1 from public.families where id=family for key share;
  perform pg_advisory_xact_lock(hashtextextended('reward-family:'||family::text,0));
  perform 1 from public.children where id=target_child_id for update;
  if not found then raise exception 'Child access required' using errcode='42501'; end if;
  if cardinality(reward_keys)=0 and not exists(select 1 from public.rewards where family_id=family and active) then raise exception '请至少选择一项奖励，或先在商城创建奖励'; end if;
  foreach key in array reward_keys loop
    if exists(select 1 from public.rewards where family_id=family and starter_key=key) then continue; end if;
    title:=case key when 'cartoon' then '动画片30分钟' when 'game' then '周末游戏30分钟' when 'book' then '选择一本书'
      when 'movie' then '家庭电影' when 'restaurant' then '喜欢的餐厅' when 'toy' then '普通玩具' else '主题乐园或短途旅行' end;
    cost:=case key when 'cartoon' then 120 when 'game' then 220 when 'book' then 500 when 'movie' then 1200 when 'restaurant' then 1800 when 'toy' then 3000 else 8000 end;
    saved:=public.save_reward(family,jsonb_build_object('title',title,'cost',cost,'rules','需家长审批并约定兑现时间','minimum_level',1));
    update public.rewards set starter_key=key where id=saved;
  end loop;
  if not exists(select 1 from public.rewards where family_id=family and active) then raise exception '所选初始奖励已下架，请先在商城上架奖励或选择其他奖励'; end if;
  perform public.set_daily_coin_limit(target_child_id,daily_limit);
  update public.children set starter_task_preset=preset,starter_rules_at=coalesce(starter_rules_at,now()) where id=target_child_id;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'onboarding.rules','child',target_child_id::text,jsonb_build_object('preset',preset,'daily_limit',daily_limit,'reward_keys',reward_keys));
end $$;

create function public.advance_child_guide(target_child_id uuid,expected_step integer,selection text default null) returns integer
language plpgsql security definer set search_path='' as $$
declare child public.children;
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required' using errcode='42501'; end if;
  select * into child from public.children where id=target_child_id for update;
  if not found then raise exception 'Child access required' using errcode='42501'; end if;
  if expected_step is null or expected_step not between 0 and 2 or expected_step>child.guide_step then raise exception '请按顺序完成引导' using errcode='40001'; end if;
  if expected_step<child.guide_step then return child.guide_step; end if;
  if expected_step=0 then perform public.set_growth_slot(target_child_id,'avatar',selection);
  elsif expected_step=1 then
    if selection is null then raise exception '请选择一位伙伴'; end if;
    perform public.set_growth_slot(target_child_id,'pet',selection);
  end if;
  update public.children set guide_step=guide_step+1 where id=target_child_id returning * into child;
  return child.guide_step;
end $$;

create function public.create_starter_task(target_child_id uuid,config jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare family uuid; existing uuid; today date;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  perform 1 from public.families where id=family for key share;
  perform 1 from public.children where id=target_child_id for key share;
  if not found then raise exception 'Child access required' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('starter-task:'||target_child_id::text,0));
  select id into existing from public.task_templates where child_id=target_child_id order by created_at,id limit 1;
  if found then return existing; end if;
  today:=public.family_today(target_child_id);
  if (config->>'starts_on')::date is distinct from today then raise exception '首个任务请从家庭今天开始'; end if;
  -- The first task must actually be due today, including a weekly/custom rule.
  existing:=public.save_task_schedule(target_child_id,config);
  if not exists(select 1 from public.task_instances where template_id=existing and due_date=today) then raise exception '首个任务需要包含今天，请检查重复日期'; end if;
  return existing;
end $$;

create function public.onboarding_overview(target_child_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare child public.children; appearance jsonb; assets jsonb;
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required' using errcode='42501'; end if;
  select * into child from public.children where id=target_child_id;
  if not found then raise exception 'Child access required' using errcode='42501'; end if;
  appearance:=public.growth_overview(target_child_id);
  select coalesce(jsonb_agg(value),'[]') into assets from jsonb_array_elements(appearance->'assets') where value->>'kind'='pet' and (value->>'unlocked')::boolean;
  return jsonb_build_object('child',to_jsonb(child),'today',public.family_today(target_child_id),'appearance',appearance->'appearance','pets',assets,
    'daily_limit',coalesce((select daily_soft_limit from public.wallet_settings where child_id=target_child_id),150),
    'has_task',exists(select 1 from public.task_templates where child_id=target_child_id),
    'active_rewards',(select count(*) from public.rewards where family_id=child.family_id and active),
    'starter_rewards',coalesce((select jsonb_agg(starter_key) from public.rewards where family_id=child.family_id and starter_key is not null),'[]'));
end $$;
create function public.finish_onboarding(target_child_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare child public.children;
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required' using errcode='42501'; end if;
  select * into child from public.children where id=target_child_id for update;
  if not found then raise exception 'Child access required' using errcode='42501'; end if;
  if child.guide_step<>3 or child.starter_rules_at is null or not exists(select 1 from public.task_templates where child_id=target_child_id) then raise exception '请先完成家长规则、三步引导和首个任务'; end if;
  update public.children set onboarding_completed_at=coalesce(onboarding_completed_at,now()) where id=target_child_id;
end $$;
revoke all on function public.onboard_family_profile(text,text,text,smallint,jsonb),public.create_child_profile(uuid,text,smallint,jsonb),
  public.update_child_profile(uuid,text,smallint,jsonb,bigint),public.configure_starter_rules(uuid,text,integer,text[]),
  public.advance_child_guide(uuid,integer,text),public.create_starter_task(uuid,jsonb),public.onboarding_overview(uuid),public.finish_onboarding(uuid) from public,anon;
grant execute on function public.onboard_family_profile(text,text,text,smallint,jsonb),public.create_child_profile(uuid,text,smallint,jsonb),
  public.update_child_profile(uuid,text,smallint,jsonb,bigint),public.configure_starter_rules(uuid,text,integer,text[]),
  public.advance_child_guide(uuid,integer,text),public.create_starter_task(uuid,jsonb),public.onboarding_overview(uuid),public.finish_onboarding(uuid) to authenticated;
