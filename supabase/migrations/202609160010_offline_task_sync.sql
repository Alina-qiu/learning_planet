-- Offline child commands never grant parent privileges or accept wallet amounts.
alter table public.task_instances add column sync_version bigint not null default 0;

create function public.bump_task_sync_version() returns trigger
language plpgsql set search_path='' as $$
begin
  if new is distinct from old then new.sync_version := old.sync_version + 1; end if;
  return new;
end;
$$;
revoke all on function public.bump_task_sync_version() from public,anon,authenticated;
create trigger task_sync_version before update on public.task_instances
  for each row execute function public.bump_task_sync_version();

create table public.task_sync_leases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '7 days'
);
create index task_sync_leases_owner on public.task_sync_leases(user_id,child_id,issued_at desc);
create table public.task_command_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  command_id uuid not null,
  task_id uuid not null references public.task_instances(id) on delete cascade,
  request jsonb not null,
  outcome text not null check(outcome in ('applied','already_completed')),
  result_version bigint not null,
  created_at timestamptz not null default now(),
  primary key(user_id,command_id)
);
alter table public.task_sync_leases enable row level security;
alter table public.task_command_receipts enable row level security;
revoke all on public.task_sync_leases,public.task_command_receipts from public,anon,authenticated;

create function public.task_sync_snapshot(target_child_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare lease public.task_sync_leases; snapshot jsonb;
begin
  if auth.uid() is null or not public.child_is_visible(target_child_id) then
    raise exception 'Child access required' using errcode='42501';
  end if;
  perform public.generate_scheduled_tasks(target_child_id);
  delete from public.task_sync_leases where user_id=auth.uid() and expires_at<now();
  select * into lease from public.task_sync_leases where user_id=auth.uid()
    and child_id=target_child_id and issued_at>now()-interval '15 minutes'
    and expires_at>now()+interval '6 days' order by issued_at desc limit 1;
  if not found then
    insert into public.task_sync_leases(user_id,child_id) values(auth.uid(),target_child_id)
      returning * into lease;
  end if;
  -- One statement observes a consistent task/wallet snapshot after generation.
  select jsonb_build_object(
    'lease_id',lease.id,'lease_expires_at',lease.expires_at,'server_at',clock_timestamp(),
    'timezone',f.timezone,'day',(now() at time zone f.timezone)::date,
    'tasks',coalesce((select jsonb_agg(to_jsonb(t) order by t.due_date,t.created_at,t.id)
      from public.task_instances t where t.child_id=c.id),'[]'::jsonb),
    'wallet',jsonb_build_object('coin_balance',w.coin_balance,'frozen_balance',w.frozen_balance,'xp',w.xp)
  ) into snapshot from public.children c join public.families f on f.id=c.family_id
    join public.wallets w on w.child_id=c.id where c.id=target_child_id;
  return snapshot;
end;
$$;
revoke all on function public.task_sync_snapshot(uuid) from public,anon,authenticated;
grant execute on function public.task_sync_snapshot(uuid) to authenticated;

create function public.task_command_result(target_task_id uuid,outcome text,reason text default null)
returns jsonb language sql security definer set search_path='' as $$
  select jsonb_build_object('outcome',outcome,'reason',reason,'task',to_jsonb(t),
    'wallet',jsonb_build_object('coin_balance',w.coin_balance,'frozen_balance',w.frozen_balance,'xp',w.xp),
    'server_at',clock_timestamp()) from public.task_instances t
    join public.wallets w on w.child_id=t.child_id where t.id=target_task_id;
$$;
revoke all on function public.task_command_result(uuid,text,text) from public,anon,authenticated;

create function public.apply_task_command(command jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  request_command_id uuid := (command->>'command_id')::uuid;
  request_task_id uuid := (command->>'task_id')::uuid;
  predecessor_id uuid := (command->>'predecessor_id')::uuid;
  occurred_at timestamptz := (command->>'occurred_at')::timestamptz;
  kind text := command->>'kind';
  expected_version bigint;
  t public.task_instances;
  lease public.task_sync_leases;
  receipt public.task_command_receipts;
  predecessor public.task_command_receipts;
  outcome text := 'applied';
  seconds bigint;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if request_command_id is null or request_task_id is null or occurred_at is null
    or kind is null or kind not in ('start','pause','resume','complete')
    or command - array['command_id','task_id','predecessor_id','occurred_at','kind','lease_id','expected_version'] <> '{}'::jsonb then
    raise exception 'Invalid offline command';
  end if;
  -- Serialize duplicate UUIDs as well as competing updates to the task.
  perform pg_advisory_xact_lock(hashtextextended('task-command:'||auth.uid()||':'||request_command_id,0));
  select * into t from public.task_instances where id=request_task_id for update;
  if not found or not public.child_is_visible(t.child_id) then
    raise exception 'Task access required' using errcode='42501';
  end if;
  select * into receipt from public.task_command_receipts
    where user_id=auth.uid() and task_command_receipts.command_id=request_command_id;
  if found then
    if receipt.request<>command then raise exception 'Command UUID cannot be reused with different data'; end if;
    return public.task_command_result(t.id,receipt.outcome);
  end if;
  select * into lease from public.task_sync_leases where id=(command->>'lease_id')::uuid
    and user_id=auth.uid() and child_id=t.child_id;
  if not found or lease.expires_at<clock_timestamp() then
    return public.task_command_result(t.id,'conflict','离线缓存授权已过期，请联网刷新后处理');
  end if;
  -- Client activity is not an attendance proof. Only bounded elapsed wall time
  -- since a server-issued lease is accepted; future/backdated clocks cannot mint time.
  if occurred_at<lease.issued_at or occurred_at<t.created_at or occurred_at>clock_timestamp() then
    return public.task_command_result(t.id,'conflict','操作时间不在服务端允许范围内，请联网校准');
  end if;
  if predecessor_id is not null then
    select * into predecessor from public.task_command_receipts where user_id=auth.uid()
      and task_command_receipts.command_id=predecessor_id and task_command_receipts.task_id=t.id;
    if not found or occurred_at<(predecessor.request->>'occurred_at')::timestamptz then
      return public.task_command_result(t.id,'conflict','前序命令缺失或操作时间顺序错误');
    end if;
    expected_version := predecessor.result_version;
  else
    expected_version := (command->>'expected_version')::bigint;
  end if;
  if t.status='completed' then
    outcome := 'already_completed';
  elsif t.status in ('skipped','expired') then
    return public.task_command_result(t.id,'conflict','任务已跳过或过期，不能重放离线打卡');
  elsif expected_version is null or expected_version<>t.sync_version then
    return public.task_command_result(t.id,'conflict','另一台设备已修改任务，请采用服务端状态');
  elsif t.source_type='automatic_wrong_review' then
    return public.task_command_result(t.id,'conflict','自动复习任务需要完成题目作答，不支持普通离线打卡');
  elsif exists(select 1 from public.long_plans p where p.template_id=t.template_id and p.settled_at is not null) then
    return public.task_command_result(t.id,'conflict','长期计划已经结算，请联系家长处理');
  else
    -- Exception subtransaction rolls back timing changes if the existing completion
    -- chain rejects minimum duration, approved leave, or another business rule.
    begin
      if kind='start' and t.status in ('ready','scheduled') then
        update public.task_instances set status='in_progress',started_at=coalesce(started_at,occurred_at),
          active_started_at=occurred_at where id=t.id;
      elsif kind='resume' and t.status='paused' then
        update public.task_instances set status='in_progress',active_started_at=occurred_at where id=t.id;
      elsif kind in ('pause','complete') and (
        (kind='pause' and t.status='in_progress') or
        (kind='complete' and t.status in ('in_progress','paused'))) then
        if t.active_started_at is not null and occurred_at<t.active_started_at then
          raise exception '操作时间早于上次开始时间';
        end if;
        seconds := t.accumulated_seconds::bigint + case when t.active_started_at is null then 0
          else greatest(floor(extract(epoch from occurred_at-t.active_started_at))::bigint,0) end;
        if kind='complete' and seconds<t.minimum_seconds then
          raise exception '尚未达到最低有效时长';
        end if;
        update public.task_instances set accumulated_seconds=least(seconds,2147483647)::integer,
          active_started_at=null,status=case when kind='pause' then 'paused'::public.task_status else status end
          where id=t.id;
        if kind='complete' then
          perform public.complete_task(t.id,'offline:'||request_command_id,null);
        end if;
      else
        raise exception '任务状态不允许此操作';
      end if;
    exception when sqlstate 'P0001' then
      return public.task_command_result(t.id,'conflict',sqlerrm);
    end;
    select * into t from public.task_instances where id=request_task_id;
  end if;
  insert into public.task_command_receipts(user_id,command_id,task_id,request,outcome,result_version)
    values(auth.uid(),request_command_id,t.id,command,outcome,t.sync_version);
  return public.task_command_result(t.id,outcome);
end;
$$;
revoke all on function public.apply_task_command(jsonb) from public,anon,authenticated;
grant execute on function public.apply_task_command(jsonb) to authenticated;
