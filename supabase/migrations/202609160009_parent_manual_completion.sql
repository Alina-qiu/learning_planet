-- Authorized PIN-verified family parents may manually complete tasks.
-- Existing wrappers retain timing, leave, session, audit and reward idempotency checks.
create or replace function public.complete_task_internal(
  target_task_id uuid,
  completion_key text,
  parent_reason text default null
) returns public.task_instances
language plpgsql
security definer
set search_path = public
as $$
declare
  task_record public.task_instances%rowtype;
  task_family_id uuid;
begin
  select * into task_record from public.task_instances
  where id = target_task_id for update;
  if not public.child_is_visible(task_record.child_id) then
    raise exception 'Task access required';
  end if;
  if task_record.status = 'completed' then return task_record; end if;

  select family_id into task_family_id from public.children
  where id = task_record.child_id;
  if parent_reason is not null and not public.can_manage_family(task_family_id) then
    raise exception 'Valid parent PIN authorization required for manual completion';
  end if;
  if parent_reason is null and task_record.status not in ('in_progress', 'paused') then
    raise exception 'Task must be started before completion';
  end if;
  if parent_reason is not null and nullif(btrim(parent_reason), '') is null then
    raise exception 'Manual completion reason is required';
  end if;

  update public.task_instances
  set status = 'completed',
      accumulated_seconds = accumulated_seconds + case
        when active_started_at is null then 0
        else greatest(extract(epoch from now() - active_started_at)::integer, 0)
      end,
      active_started_at = null,
      completed_at = now(),
      completion_reason = parent_reason
  where id = target_task_id returning * into task_record;

  insert into public.ledger_entries (
    child_id, asset_type, amount, source_type, source_id, idempotency_key
  ) values
    (task_record.child_id, 'coin', task_record.coin_reward, 'task_completion',
      task_record.id, 'task-completion:' || task_record.id::text || ':coin'),
    (task_record.child_id, 'xp', task_record.xp_reward, 'task_completion',
      task_record.id, 'task-completion:' || task_record.id::text || ':xp')
  on conflict (idempotency_key) do nothing;

  update public.wallets set
    coin_balance = coin_balance + task_record.coin_reward,
    xp = xp + task_record.xp_reward,
    updated_at = now()
  where child_id = task_record.child_id;

  if parent_reason is not null then
    insert into public.audit_logs (
      family_id, actor_user_id, action, target_type, target_id, details
    ) values (
      task_family_id, auth.uid(), 'task.manual_complete', 'task_instance',
      task_record.id::text, jsonb_build_object('reason', parent_reason)
    );
  end if;
  return task_record;
end;
$$;

revoke all on function public.complete_task_internal(uuid, text, text)
  from public, anon, authenticated;
