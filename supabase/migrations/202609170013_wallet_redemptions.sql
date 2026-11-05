-- One append-only ledger drives both available/frozen coins and non-decreasing XP.
alter table public.ledger_entries add column frozen_delta integer not null default 0;
alter table public.ledger_entries add constraint frozen_is_coin check(asset_type='coin' or frozen_delta=0);
create table public.wallet_settings(child_id uuid primary key references public.children(id) on delete cascade,
  daily_soft_limit integer not null default 150 check(daily_soft_limit between 0 and 10000));
create table public.pending_coin_awards(id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id) on delete cascade,
  amount integer not null check(amount>0), source_type text not null, source_id uuid,
  source_key text not null unique, status text not null default 'pending' check(status in ('pending','approved','rejected')),
  reason text, actor_id uuid references auth.users(id), created_at timestamptz not null default now(), decided_at timestamptz);
alter table public.wallet_settings enable row level security;
alter table public.pending_coin_awards enable row level security;
create policy wallet_settings_read on public.wallet_settings for select to authenticated using(public.child_is_visible(child_id));
create policy pending_coins_read on public.pending_coin_awards for select to authenticated using(public.child_is_visible(child_id));
revoke all on public.wallet_settings,public.pending_coin_awards from public,anon,authenticated;
grant select on public.wallet_settings,public.pending_coin_awards to authenticated;

-- Remove legacy wallet additions; the ledger trigger below is now the sole writer.
-- Assert the exact known block exists instead of silently accepting an unknown function.
do $$
declare signature text; definition text; changed text;
begin
  foreach signature in array array['public.complete_task_internal(uuid,text,text)',
    'public.award_plan_stages(uuid)','public.settle_long_plan(uuid)'] loop
    definition:=pg_get_functiondef(signature::regprocedure);
    changed:=regexp_replace(definition,'update public\.wallets set[\s\S]*?where child_id\s*=\s*(task_record\.child_id|child|t\.child_id);','','i');
    if changed=definition then raise exception 'Legacy wallet block missing in %',signature; end if;
    execute changed;
  end loop;
end $$;

create function public.prepare_ledger_entry() returns trigger language plpgsql security definer set search_path='' as $$
declare zone text; used bigint; ceiling integer; allowed integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('wallet:'||new.child_id::text,0));
  perform 1 from public.wallets where child_id=new.child_id for update;
  if not found then raise exception 'Wallet missing'; end if;
  if new.asset_type='xp' and new.amount<0 then raise exception 'XP never decreases'; end if;
  if exists(select 1 from public.ledger_entries where idempotency_key=new.idempotency_key) then return new; end if;
  if new.asset_type='coin' and new.amount>0 and new.source_type in ('task_completion','plan_stage','plan_completion','streak','learning_event') then
    select f.timezone into zone from public.children c join public.families f on f.id=c.family_id where c.id=new.child_id;
    select daily_soft_limit into ceiling from public.wallet_settings where child_id=new.child_id;
    ceiling:=coalesce(ceiling,150);
    select coalesce(sum(amount),0) into used from public.ledger_entries where child_id=new.child_id and asset_type='coin'
      and source_type in ('task_completion','plan_stage','plan_completion','streak','learning_event') and amount>0
      and (created_at at time zone zone)::date=(now() at time zone zone)::date;
    allowed:=least(new.amount,greatest(ceiling-used,0)::integer);
    if allowed<new.amount then
      insert into public.pending_coin_awards(child_id,amount,source_type,source_id,source_key)
      values(new.child_id,new.amount-allowed,new.source_type,new.source_id,new.idempotency_key);
      new.amount:=allowed;
    end if;
  end if;
  return new;
end $$;
create trigger ledger_prepare before insert on public.ledger_entries for each row execute function public.prepare_ledger_entry();
create function public.project_ledger_entry() returns trigger language plpgsql security definer set search_path='' as $$
begin
  update public.wallets set coin_balance=coin_balance+case when new.asset_type='coin' then new.amount else 0 end,
    frozen_balance=frozen_balance+new.frozen_delta,
    xp=xp+case when new.asset_type='xp' then new.amount else 0 end,updated_at=now() where child_id=new.child_id;
  return new;
end $$;
create trigger ledger_project after insert on public.ledger_entries for each row execute function public.project_ledger_entry();
create function public.protect_ledger_entry() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='DELETE' and not exists(select 1 from public.children where id=old.child_id) then return old; end if;
  raise exception 'Ledger is append-only';
end $$;
create trigger ledger_immutable before update or delete on public.ledger_entries for each row execute function public.protect_ledger_entry();
revoke all on function public.prepare_ledger_entry(),public.project_ledger_entry(),public.protect_ledger_entry() from public,anon,authenticated;
revoke insert,update,delete on public.wallets,public.ledger_entries from anon,authenticated;

create function public.set_daily_coin_limit(target_child_id uuid, daily_limit integer) returns void
language plpgsql security definer set search_path='' as $$
declare family uuid;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  insert into public.wallet_settings values(target_child_id,daily_limit) on conflict(child_id) do update set daily_soft_limit=excluded.daily_soft_limit;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
  values(family,auth.uid(),'wallet.limit','child',target_child_id::text,jsonb_build_object('daily_limit',daily_limit));
end $$;
create function public.adjust_wallet(target_child_id uuid, coins integer, xp_amount integer, reason text,
  command_id uuid, large_amount_confirmed boolean default false) returns void
language plpgsql security definer set search_path='' as $$
declare family uuid;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if command_id is null or coins is null or xp_amount is null or xp_amount<0 or abs(coins::bigint)>10000 or xp_amount>10000
    or nullif(btrim(reason),'') is null or length(reason)>500 or (coins=0 and xp_amount=0) then raise exception 'Invalid adjustment'; end if;
  if abs(coins::bigint)>500 and large_amount_confirmed is distinct from true then raise exception '超过500金币须再次确认'; end if;
  perform pg_advisory_xact_lock(hashtextextended('wallet:'||target_child_id::text,0));
  if exists(select 1 from public.ledger_entries where idempotency_key='adjust:'||command_id||':coin') then
    if not exists(select 1 from public.ledger_entries where idempotency_key='adjust:'||command_id||':coin' and child_id=target_child_id and amount=coins)
      or not exists(select 1 from public.ledger_entries where idempotency_key='adjust:'||command_id||':xp' and amount=xp_amount) then raise exception 'Command payload changed'; end if;
    return;
  end if;
  insert into public.ledger_entries(child_id,asset_type,amount,source_type,source_id,idempotency_key) values
    (target_child_id,'coin',coins,'parent_adjustment',command_id,'adjust:'||command_id||':coin'),
    (target_child_id,'xp',xp_amount,'parent_adjustment',command_id,'adjust:'||command_id||':xp');
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
  values(family,auth.uid(),'wallet.adjust','child',target_child_id::text,jsonb_build_object('coins',coins,'xp',xp_amount,'reason',reason,'command_id',command_id));
end $$;
create function public.decide_pending_coins(target_award_id uuid, approve boolean, reason text) returns void
language plpgsql security definer set search_path='' as $$
declare a public.pending_coin_awards; family uuid;
begin
  select * into a from public.pending_coin_awards where id=target_award_id for update;
  select family_id into family from public.children where id=a.child_id;
  perform public.require_parent_authorization(family);
  if approve is null or nullif(btrim(reason),'') is null or length(reason)>500 then raise exception '请填写确认原因'; end if;
  if a.status<>'pending' then
    if (a.status='approved') is distinct from approve then raise exception 'Already decided'; end if;
    return;
  end if;
  if approve then insert into public.ledger_entries(child_id,asset_type,amount,source_type,source_id,idempotency_key)
    values(a.child_id,'coin',a.amount,'coin_approval',a.id,'coin-approval:'||a.id); end if;
  update public.pending_coin_awards set status=case when approve then 'approved' else 'rejected' end,
    reason=decide_pending_coins.reason,actor_id=auth.uid(),decided_at=now() where id=a.id;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'wallet.coin_decision','pending_coin',a.id::text,jsonb_build_object('approved',approve,'reason',reason));
end $$;

alter table public.rewards add column description text not null default '',
  add column rules text not null default '', add column available_from timestamptz,
  add column available_until timestamptz, add column minimum_level integer not null default 1 check(minimum_level between 1 and 50),
  add column request_days integer not null default 7 check(request_days between 1 and 30),
  add column fulfillment_days integer not null default 30 check(fulfillment_days between 1 and 90),
  add column version bigint not null default 0;
alter table public.redemptions add column request_key uuid unique,
  add column reward_title text, add column reward_rules text,
  add column expires_at timestamptz not null default (now()+interval '7 days'),
  add column fulfillment_days integer not null default 30,
  add column decision_reason text, add column actor_id uuid references auth.users(id), add column fulfilled_at timestamptz;
revoke insert,update,delete on public.rewards,public.redemptions from anon,authenticated;
create function public.xp_level(value bigint) returns integer language sql immutable set search_path='' as $$
  select least(50,1+floor((sqrt(1+8*greatest(value,0)::numeric/100)-1)/2)::integer)
$$;
create function public.save_reward(target_family_id uuid, config jsonb, target_reward_id uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare saved_id uuid;
begin
  perform public.require_parent_authorization(target_family_id);
  if nullif(btrim(config->>'title'),'') is null or length(config->>'title')>100 or (config->>'cost')::integer not between 1 and 1000000
    or coalesce(config->>'cost','')='' or length(coalesce(config->>'rules',''))>1000 or length(coalesce(config->>'description',''))>1000
    or (config->>'available_from')::timestamptz>(config->>'available_until')::timestamptz then raise exception 'Invalid reward'; end if;
  if target_reward_id is null then
    insert into public.rewards(family_id,title,cost) values(target_family_id,btrim(config->>'title'),(config->>'cost')::integer) returning rewards.id into saved_id;
  else
    select rewards.id into saved_id from public.rewards where rewards.id=target_reward_id and family_id=target_family_id for update;
    if not found then raise exception 'Reward access required'; end if;
    if config ? 'expected_version' and not exists(select 1 from public.rewards where rewards.id=saved_id and version=(config->>'expected_version')::bigint) then raise exception '奖励已修改，请重新打开'; end if;
  end if;
  update public.rewards set title=btrim(config->>'title'),cost=(config->>'cost')::integer,
    description=coalesce(config->>'description',''),rules=coalesce(config->>'rules',''),active=coalesce((config->>'active')::boolean,true),
    available_from=(config->>'available_from')::timestamptz,available_until=(config->>'available_until')::timestamptz,
    minimum_level=coalesce((config->>'minimum_level')::integer,1),request_days=coalesce((config->>'request_days')::integer,7),
    fulfillment_days=coalesce((config->>'fulfillment_days')::integer,30),version=version+1 where rewards.id=saved_id;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id) values(target_family_id,auth.uid(),'reward.save','reward',saved_id::text);
  return saved_id;
end $$;
create function public.request_reward(target_child_id uuid, target_reward_id uuid, command_id uuid, expected_version bigint) returns uuid
language plpgsql security definer set search_path='' as $$
declare r public.rewards; redemption public.redemptions; family uuid; balance public.wallets; new_redemption_id uuid;
begin
  if not public.child_is_visible(target_child_id) or command_id is null then raise exception 'Child access required'; end if;
  select family_id into family from public.children where id=target_child_id;
  perform pg_advisory_xact_lock(hashtextextended('redeem:'||command_id::text,0));
  select * into redemption from public.redemptions where request_key=command_id;
  if found then
    if redemption.child_id<>target_child_id or redemption.reward_id<>target_reward_id then raise exception 'Command payload changed'; end if;
    return redemption.id;
  end if;
  select * into r from public.rewards where rewards.id=target_reward_id for share;
  if expected_version is null or r.version is distinct from expected_version then raise exception '奖励价格或规则已变化，请刷新后重新确认'; end if;
  if r.family_id is distinct from family or not r.active or r.available_from>now() or r.available_until<=now() then raise exception '奖励不可用'; end if;
  perform pg_advisory_xact_lock(hashtextextended('wallet:'||target_child_id::text,0));
  select * into balance from public.wallets where child_id=target_child_id for update;
  if balance.coin_balance<r.cost then raise exception '可用金币不足'; end if;
  if public.xp_level(balance.xp)<r.minimum_level then raise exception '尚未达到解锁等级'; end if;
  insert into public.redemptions(reward_id,child_id,frozen_amount,request_key,reward_title,reward_rules,expires_at,fulfillment_days)
  values(r.id,target_child_id,r.cost,command_id,r.title,r.rules,now()+make_interval(days=>r.request_days),r.fulfillment_days) returning redemptions.id into new_redemption_id;
  insert into public.ledger_entries(child_id,asset_type,amount,frozen_delta,source_type,source_id,idempotency_key)
  values(target_child_id,'coin',-r.cost,r.cost,'redemption_freeze',new_redemption_id,'redeem:'||new_redemption_id||':freeze');
  return new_redemption_id;
end $$;
create function public.transition_redemption(target_redemption_id uuid, operation text, reason text default '') returns void
language plpgsql security definer set search_path='' as $$
declare r public.redemptions; family uuid; next_status public.redemption_status;
begin
  select * into r from public.redemptions where id=target_redemption_id for update;
  if not public.child_is_visible(r.child_id) and not (auth.role()='service_role' and operation='expire') then raise exception 'Redemption access required'; end if;
  select family_id into family from public.children where id=r.child_id;
  if operation not in ('approve','reject','cancel','fulfill','expire') or operation is null then raise exception 'Invalid transition'; end if;
  if operation in ('approve','reject','fulfill') then
    perform public.require_parent_authorization(family);
    if nullif(btrim(reason),'') is null or length(reason)>500 then raise exception '请填写操作原因或履约说明'; end if;
  end if;
  next_status:=case operation when 'approve' then 'approved' when 'reject' then 'rejected' when 'cancel' then 'cancelled' when 'fulfill' then 'fulfilled' else 'expired' end;
  if r.status=next_status then return; end if;
  if r.status not in ('requested','approved') then raise exception '兑换已结束'; end if;
  if operation='expire' and r.expires_at>now() then raise exception '兑换尚未过期'; end if;
  if operation<>'expire' and r.expires_at<=now() then raise exception '兑换已过期，请刷新'; end if;
  if operation in ('approve','reject','cancel') and r.status<>'requested' then raise exception 'Only a request can be approved/rejected/cancelled'; end if;
  if operation='fulfill' and r.status<>'approved' then raise exception '请先批准再确认履约'; end if;
  if operation in ('reject','cancel','expire','fulfill') then
    insert into public.ledger_entries(child_id,asset_type,amount,frozen_delta,source_type,source_id,idempotency_key)
    values(r.child_id,'coin',case when operation='fulfill' then 0 else r.frozen_amount end,-r.frozen_amount,
      case when operation='fulfill' then 'redemption_spend' else 'redemption_refund' end,r.id,'redeem:'||r.id||':settle');
  end if;
  update public.redemptions set status=next_status,decision_reason=reason,actor_id=auth.uid(),updated_at=now(),
    fulfilled_at=case when operation='fulfill' then now() else fulfilled_at end,
    expires_at=case when operation='approve' then now()+make_interval(days=>r.fulfillment_days) else expires_at end where id=r.id;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
  values(family,auth.uid(),'redemption.'||operation,'redemption',r.id::text,jsonb_build_object('reason',reason));
end $$;
create function public.expire_child_redemptions(target_child_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare item uuid; count integer:=0;
begin
  if auth.role() is distinct from 'service_role' and not public.child_is_visible(target_child_id) then raise exception 'Child access required'; end if;
  for item in select id from public.redemptions where child_id=target_child_id and status in ('requested','approved') and expires_at<=now() order by id loop
    perform public.transition_redemption(item,'expire'); count:=count+1;
  end loop;
  return count;
end $$;
create function public.wallet_overview(target_child_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare w public.wallets; sums record; zone text; family uuid;
begin
  if not public.child_is_visible(target_child_id) then raise exception 'Child access required'; end if;
  perform public.expire_child_redemptions(target_child_id);
  perform pg_advisory_xact_lock(hashtextextended('wallet:'||target_child_id::text,0));
  select * into w from public.wallets where child_id=target_child_id;
  select coalesce(sum(amount) filter(where asset_type='coin'),0) coins,coalesce(sum(frozen_delta),0) frozen,
    coalesce(sum(amount) filter(where asset_type='xp'),0) xp into sums from public.ledger_entries where child_id=target_child_id;
  select c.family_id,f.timezone into family,zone from public.children c join public.families f on f.id=c.family_id where c.id=target_child_id;
  return to_jsonb(w)||jsonb_build_object('level',public.xp_level(w.xp),'reconciled',w.coin_balance=sums.coins and w.frozen_balance=sums.frozen and w.xp=sums.xp,
    'ledger_totals',to_jsonb(sums),'daily_soft_limit',coalesce((select daily_soft_limit from public.wallet_settings where child_id=target_child_id),150),
    'pending_coins',coalesce((select sum(amount) from public.pending_coin_awards where child_id=target_child_id and status='pending'),0),
    'month_income',coalesce((select sum(amount) from public.ledger_entries where child_id=target_child_id and asset_type='coin' and amount>0
      and source_type not in ('redemption_refund') and date_trunc('month',created_at at time zone zone)=date_trunc('month',now() at time zone zone)),0),
    'month_spent',coalesce((select sum(-frozen_delta) from public.ledger_entries where child_id=target_child_id and source_type='redemption_spend'
      and date_trunc('month',created_at at time zone zone)=date_trunc('month',now() at time zone zone)),0));
end $$;
revoke all on function public.set_daily_coin_limit(uuid,integer),public.adjust_wallet(uuid,integer,integer,text,uuid,boolean),
  public.decide_pending_coins(uuid,boolean,text),public.save_reward(uuid,jsonb,uuid),public.request_reward(uuid,uuid,uuid,bigint),
  public.transition_redemption(uuid,text,text),public.expire_child_redemptions(uuid),public.wallet_overview(uuid) from public,anon;
grant execute on function public.set_daily_coin_limit(uuid,integer),public.adjust_wallet(uuid,integer,integer,text,uuid,boolean),
  public.decide_pending_coins(uuid,boolean,text),public.save_reward(uuid,jsonb,uuid),public.request_reward(uuid,uuid,uuid,bigint),
  public.transition_redemption(uuid,text,text),public.expire_child_redemptions(uuid),public.wallet_overview(uuid) to authenticated;
revoke all on function public.xp_level(bigint) from public,anon;
grant execute on function public.xp_level(bigint) to authenticated;

create function public.reconcile_wallet(target_child_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare family uuid; sums record;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  perform pg_advisory_xact_lock(hashtextextended('wallet:'||target_child_id::text,0));
  select coalesce(sum(amount) filter(where asset_type='coin'),0) coins,coalesce(sum(frozen_delta),0) frozen,
    coalesce(sum(amount) filter(where asset_type='xp'),0) xp into sums from public.ledger_entries where child_id=target_child_id;
  update public.wallets set coin_balance=sums.coins,frozen_balance=sums.frozen,xp=sums.xp,updated_at=now() where child_id=target_child_id;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id)
    values(family,auth.uid(),'wallet.reconcile','child',target_child_id::text);
end $$;
revoke all on function public.reconcile_wallet(uuid) from public,anon;
grant execute on function public.reconcile_wallet(uuid) to authenticated;
create function public.run_reward_maintenance() returns integer
language plpgsql security definer set search_path='' as $$
declare child uuid; count integer:=0; claims text:=current_setting('request.jwt.claims',true);
begin
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  for child in select distinct child_id from public.redemptions where status in ('requested','approved') and expires_at<=now() order by child_id loop
    count:=count+public.expire_child_redemptions(child);
  end loop;
  perform set_config('request.jwt.claims',coalesce(claims,''),true);
  return count;
end $$;
revoke all on function public.run_reward_maintenance() from public,anon,authenticated;
grant execute on function public.run_reward_maintenance() to service_role;
do $$ begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    execute $job$select cron.schedule('learning-planet-reward-maintenance','*/5 * * * *','select public.run_reward_maintenance();')$job$;
  end if;
end $$;
