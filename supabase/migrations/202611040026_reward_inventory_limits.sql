-- Inventory is shared by a family. Requested/approved claims reserve one unit;
-- fulfilled units stay consumed even when a child's personal data is erased.
alter table public.rewards
  add column stock_total integer check(stock_total between 0 and 1000000),
  add column stock_fulfilled bigint not null default 0 check(stock_fulfilled>=0),
  add column quota_period text not null default 'none' check(quota_period in ('none','day','week','month','lifetime')),
  add column quota_limit integer check(quota_limit between 1 and 1000000),
  add constraint reward_quota_pair check((quota_period='none')=(quota_limit is null));
update public.rewards r set stock_fulfilled=(select count(*) from public.redemptions d where d.reward_id=r.id and d.status='fulfilled');
alter table public.redemptions add column requested_on date,
  add column reward_limits jsonb not null default '{}';
update public.redemptions d set requested_on=(d.created_at at time zone f.timezone)::date
  from public.children c join public.families f on f.id=c.family_id where d.child_id=c.id;
alter table public.redemptions alter column requested_on set not null;
create index reward_active_claims on public.redemptions(reward_id,child_id,requested_on)
  where status in ('requested','approved','fulfilled');

create function public.record_reward_consumption() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.status='fulfilled' and (tg_op='INSERT' or old.status<>'fulfilled') then
    update public.rewards set stock_fulfilled=stock_fulfilled+1 where id=new.reward_id;
  end if;
  return new;
end $$;
create trigger reward_consumption after insert or update of status on public.redemptions
  for each row execute function public.record_reward_consumption();
-- Preserve legacy insert paths while recording the authoritative family day.
create function public.stamp_redemption_day() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  new.requested_on:=(new.created_at at time zone (select f.timezone from public.children c
    join public.families f on f.id=c.family_id where c.id=new.child_id))::date;
  return new;
end $$;
create trigger redemption_day before insert on public.redemptions for each row execute function public.stamp_redemption_day();
revoke all on function public.record_reward_consumption(),public.stamp_redemption_day() from public,anon,authenticated,service_role;

create function public.reward_capacity(target_reward_id uuid,target_child_id uuid,day date) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.rewards; reserved bigint; used bigint; first_day date; next_day date;
begin
  select * into strict r from public.rewards where id=target_reward_id;
  first_day:=case r.quota_period when 'day' then day when 'week' then day-extract(isodow from day)::int+1
    when 'month' then date_trunc('month',day::timestamp)::date else '-infinity'::date end;
  next_day:=case r.quota_period when 'day' then day+1 when 'week' then first_day+7
    when 'month' then (first_day+interval '1 month')::date else 'infinity'::date end;
  select count(*) into reserved from public.redemptions where reward_id=r.id and status in ('requested','approved');
  select count(*) into used from public.redemptions where reward_id=r.id and child_id=target_child_id
    and status in ('requested','approved','fulfilled') and requested_on>=first_day and requested_on<next_day;
  return jsonb_build_object('stock_reserved',reserved,
    'stock_available',case when r.stock_total is null then null else greatest(r.stock_total-r.stock_fulfilled-reserved,0) end,
    'quota_used',used,'quota_remaining',case when r.quota_limit is null then null else greatest(r.quota_limit-used,0) end,
    'quota_resets_on',case when r.quota_period in ('none','lifetime') then null else next_day end);
end $$;
revoke all on function public.reward_capacity(uuid,uuid,date) from public,anon,authenticated,service_role;

-- Every inventory mutation takes the same family advisory lock before wallet or
-- redemption row locks. This also serializes sibling requests and expiry sweeps.
alter function public.save_reward(uuid,jsonb,uuid) rename to save_reward_base;
revoke all on function public.save_reward_base(uuid,jsonb,uuid) from public,anon,authenticated,service_role;
create function public.save_reward(target_family_id uuid,config jsonb,target_reward_id uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare saved uuid; r public.rewards; total integer; period text; quota integer; reserved bigint;
begin
  perform public.require_parent_authorization(target_family_id);
  perform pg_advisory_xact_lock(hashtextextended('reward-family:'||target_family_id::text,0));
  if target_reward_id is not null then
    select * into r from public.rewards where id=target_reward_id and family_id=target_family_id for update;
    if not found then raise exception 'Reward access required' using errcode='42501'; end if;
    if (config ? 'stock_total' or config ? 'quota_period' or config ? 'quota_limit')
      and (config->>'expected_version')::bigint is distinct from r.version then raise exception '奖励已修改，请重新打开'; end if;
  end if;
  total:=case when config ? 'stock_total' then (config->>'stock_total')::integer else r.stock_total end;
  period:=case when config ? 'quota_period' then config->>'quota_period' else coalesce(r.quota_period,'none') end;
  quota:=case when config ? 'quota_limit' then (config->>'quota_limit')::integer else r.quota_limit end;
  if total not between 0 and 1000000 or period is null or period not in ('none','day','week','month','lifetime')
    or (period='none') is distinct from (quota is null) or quota not between 1 and 1000000 then
    raise exception '库存需为0至1000000或不限；限次需选择周期和1至1000000次'; end if;
  select count(*) into reserved from public.redemptions where reward_id=target_reward_id and status in ('requested','approved');
  if total is not null and total<coalesce(r.stock_fulfilled,0)+reserved then
    raise exception '总库存不能少于已兑现与已预留数量（%）',coalesce(r.stock_fulfilled,0)+reserved; end if;
  saved:=public.save_reward_base(target_family_id,config,target_reward_id);
  update public.rewards set stock_total=total,quota_period=period,quota_limit=quota where id=saved;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(target_family_id,auth.uid(),'reward.limits','reward',saved::text,jsonb_build_object(
      'before',jsonb_build_object('stock_total',r.stock_total,'quota_period',r.quota_period,'quota_limit',r.quota_limit),
      'after',jsonb_build_object('stock_total',total,'quota_period',period,'quota_limit',quota)));
  return saved;
end $$;

alter function public.transition_redemption(uuid,text,text) rename to transition_redemption_base;
revoke all on function public.transition_redemption_base(uuid,text,text) from public,anon,authenticated,service_role;
create function public.transition_redemption(target_redemption_id uuid,operation text,reason text default '') returns void
language plpgsql security definer set search_path='' as $$
declare family uuid; child uuid;
begin
  select c.family_id,c.id into family,child from public.redemptions d join public.children c on c.id=d.child_id where d.id=target_redemption_id;
  if family is null then raise exception 'Redemption access required' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('reward-family:'||family::text,0));
  perform 1 from public.children where id=child for key share;
  if not found then raise exception 'Child access required' using errcode='42501'; end if;
  perform public.transition_redemption_base(target_redemption_id,operation,reason);
end $$;

create or replace function public.expire_child_redemptions(target_child_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare item uuid; count integer:=0; family uuid;
begin
  if auth.role() is distinct from 'service_role' and not public.child_is_visible(target_child_id) then raise exception 'Child access required' using errcode='42501'; end if;
  select family_id into family from public.children where id=target_child_id;
  perform pg_advisory_xact_lock(hashtextextended('reward-family:'||family::text,0));
  perform 1 from public.children where id=target_child_id for key share;
  if not found then raise exception 'Child access required' using errcode='42501'; end if;
  for item in select id from public.redemptions where child_id=target_child_id and status in ('requested','approved') and expires_at<=now() order by reward_id,id loop
    perform public.transition_redemption(item,'expire'); count:=count+1;
  end loop;
  return count;
end $$;

alter function public.request_reward(uuid,uuid,uuid,bigint) rename to request_reward_base;
revoke all on function public.request_reward_base(uuid,uuid,uuid,bigint) from public,anon,authenticated,service_role;
create function public.request_reward(target_child_id uuid,target_reward_id uuid,command_id uuid,expected_version bigint) returns uuid
language plpgsql security definer set search_path='' as $$
declare family uuid; day date; r public.rewards; capacity jsonb; saved uuid;
begin
  if not public.child_is_visible(target_child_id) or command_id is null then raise exception 'Child access required' using errcode='42501'; end if;
  select c.family_id,(now() at time zone f.timezone)::date into family,day from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  perform pg_advisory_xact_lock(hashtextextended('reward-family:'||family::text,0));
  perform pg_advisory_xact_lock(hashtextextended('redeem:'||command_id::text,0));
  if exists(select 1 from public.redemptions where request_key=command_id) then
    return public.request_reward_base(target_child_id,target_reward_id,command_id,expected_version);
  end if;
  perform public.expire_child_redemptions(target_child_id);
  select * into r from public.rewards where id=target_reward_id and family_id=family for update;
  if not found then raise exception '奖励不可用'; end if;
  if expected_version is distinct from r.version then raise exception '奖励价格或规则已变化，请刷新后重新确认'; end if;
  capacity:=public.reward_capacity(r.id,target_child_id,day);
  if (capacity->>'stock_available')::bigint=0 then raise exception '奖励库存已用完，请选择其他奖励或联系家长'; end if;
  if (capacity->>'quota_remaining')::bigint=0 then raise exception '已达到本奖励的兑换次数限制，请等待下一周期或联系家长'; end if;
  saved:=public.request_reward_base(target_child_id,target_reward_id,command_id,expected_version);
  update public.redemptions set reward_limits=jsonb_build_object('stock_total',r.stock_total,'quota_period',r.quota_period,
    'quota_limit',r.quota_limit,'requested_on',day) where id=saved;
  return saved;
end $$;

create function public.reward_catalog(target_child_id uuid,page_offset integer default 0,page_size integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare family uuid; zone text; day date; balance public.wallets; r public.rewards; capacity jsonb; blocked text; items jsonb:='[]';
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required' using errcode='42501'; end if;
  if page_offset is null or page_offset<0 or page_size is null or page_size not between 1 and 500 then raise exception 'Invalid catalog page'; end if;
  select c.family_id,f.timezone into family,zone from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  day:=(now() at time zone zone)::date;
  perform public.expire_child_redemptions(target_child_id);
  select * into balance from public.wallets where child_id=target_child_id;
  for r in select * from public.rewards where family_id=family order by created_at desc,id limit page_size offset page_offset loop
    capacity:=public.reward_capacity(r.id,target_child_id,day);
    blocked:=case when not r.active then '已下架' when r.available_from>now() then '尚未开放' when r.available_until<=now() then '已结束'
      when (capacity->>'stock_available')::bigint=0 then '库存已用完' when (capacity->>'quota_remaining')::bigint=0 then '已达兑换次数限制'
      when public.xp_level(balance.xp)<r.minimum_level then '尚未达到解锁等级' when balance.coin_balance<r.cost then '可用金币不足' else null end;
    items:=items||jsonb_build_array(to_jsonb(r)||capacity||jsonb_build_object('can_request',blocked is null,'blocked_reason',blocked,'family_timezone',zone));
  end loop;
  return jsonb_build_object('items',items,'family_today',day,'next_offset',case when jsonb_array_length(items)=page_size then page_offset+page_size else null end);
end $$;

create or replace function public.run_reward_maintenance() returns integer
language plpgsql security definer set search_path='' as $$
declare child uuid; count integer:=0; claims text:=current_setting('request.jwt.claims',true);
begin
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  for child in select c.id from public.children c where exists(select 1 from public.redemptions d
    where d.child_id=c.id and d.status in ('requested','approved') and d.expires_at<=now()) order by c.family_id,c.id loop
    count:=count+public.expire_child_redemptions(child);
  end loop;
  perform set_config('request.jwt.claims',coalesce(claims,''),true);
  return count;
end $$;
revoke all on function public.save_reward(uuid,jsonb,uuid),public.request_reward(uuid,uuid,uuid,bigint),
  public.transition_redemption(uuid,text,text),public.reward_catalog(uuid,integer,integer) from public,anon;
grant execute on function public.save_reward(uuid,jsonb,uuid),public.request_reward(uuid,uuid,uuid,bigint),
  public.transition_redemption(uuid,text,text),public.reward_catalog(uuid,integer,integer) to authenticated;
