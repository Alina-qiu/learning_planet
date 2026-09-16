create type public.task_recurrence as enum (
  'once', 'daily', 'weekly', 'custom'
);

create table public.task_templates (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id) on delete cascade,
  title text not null,
  description text not null default '',
  recurrence public.task_recurrence not null default 'once',
  recurrence_rule jsonb not null default '{}'::jsonb,
  coin_reward integer not null default 0 check (coin_reward >= 0),
  xp_reward integer not null default 0 check (xp_reward >= 0),
  expected_minutes integer check (expected_minutes > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.task_templates enable row level security;

create policy task_templates_select on public.task_templates for select
  using (public.child_is_visible(child_id));
create policy task_templates_admin_insert on public.task_templates for insert
  with check (
    exists (
      select 1 from public.children c
      where c.id = child_id and public.is_family_admin(c.family_id)
    )
  );
create policy task_templates_admin_update on public.task_templates for update
  using (
    exists (
      select 1 from public.children c
      where c.id = child_id and public.is_family_admin(c.family_id)
    )
  )
  with check (
    exists (
      select 1 from public.children c
      where c.id = child_id and public.is_family_admin(c.family_id)
    )
  );
create policy task_templates_admin_delete on public.task_templates for delete
  using (
    exists (
      select 1 from public.children c
      where c.id = child_id and public.is_family_admin(c.family_id)
    )
  );

alter table public.task_instances
  add column template_id uuid references public.task_templates(id) on delete set null,
  add column description text not null default '',
  add column scheduled_at timestamptz,
  add column due_at timestamptz,
  add column started_at timestamptz,
  add column active_started_at timestamptz,
  add column accumulated_seconds integer not null default 0
    check (accumulated_seconds >= 0),
  add column completed_at timestamptz,
  add column completion_reason text;

drop policy task_instances_member on public.task_instances;
create policy task_instances_select on public.task_instances for select
  using (public.child_is_visible(child_id));

create or replace function public.create_task_from_template(
  target_template_id uuid,
  target_date date,
  target_due_at timestamptz default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  template_record public.task_templates%rowtype;
  created_task_id uuid;
begin
  select * into template_record
  from public.task_templates
  where id = target_template_id and active;
  if not found then raise exception 'Active task template not found'; end if;
  if not public.child_is_visible(template_record.child_id) then
    raise exception 'Child access required';
  end if;

  insert into public.task_instances (
    child_id, template_id, title, description, due_date, due_at,
    source_type, coin_reward, xp_reward, idempotency_key
  ) values (
    template_record.child_id, template_record.id, template_record.title,
    template_record.description, target_date, target_due_at,
    'parent_template', template_record.coin_reward, template_record.xp_reward,
    'template:' || template_record.id::text || ':' || target_date::text
  )
  on conflict (idempotency_key) do update set title = excluded.title
  returning id into created_task_id;
  return created_task_id;
end;
$$;

revoke all on function public.create_task_from_template(uuid, date, timestamptz) from public;
grant execute on function public.create_task_from_template(uuid, date, timestamptz) to authenticated;

create or replace function public.generate_scheduled_tasks(
  target_child_id uuid,
  target_date date
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare generated_count integer;
begin
  if auth.role() <> 'service_role' and not public.child_is_visible(target_child_id) then
    raise exception 'Child access required';
  end if;

  with due_templates as (
    select t.*
    from public.task_templates t
    where t.child_id = target_child_id
      and t.active
      and (
        t.recurrence = 'daily'
        or (
          t.recurrence = 'weekly'
          and coalesce(t.recurrence_rule -> 'weekdays', '[]'::jsonb)
            @> jsonb_build_array(extract(isodow from target_date)::integer)
        )
        or (
          t.recurrence = 'custom'
          and coalesce(t.recurrence_rule -> 'dates', '[]'::jsonb)
            @> jsonb_build_array(target_date::text)
        )
        or (
          t.recurrence = 'once'
          and t.recurrence_rule ->> 'date' = target_date::text
        )
      )
  ), inserted as (
    insert into public.task_instances (
      child_id, template_id, title, description, due_date, source_type,
      coin_reward, xp_reward, idempotency_key
    )
    select
      child_id, id, title, description, target_date, 'parent_template',
      coin_reward, xp_reward,
      'template:' || id::text || ':' || target_date::text
    from due_templates
    on conflict (idempotency_key) do nothing
    returning id
  )
  select count(*) into generated_count from inserted;

  return generated_count;
end;
$$;

revoke all on function public.generate_scheduled_tasks(uuid, date) from public;
grant execute on function public.generate_scheduled_tasks(uuid, date) to authenticated;
grant execute on function public.generate_scheduled_tasks(uuid, date) to service_role;

create or replace function public.start_task(target_task_id uuid)
returns public.task_instances
language plpgsql
security definer
set search_path = public
as $$
declare task_record public.task_instances%rowtype;
begin
  select * into task_record from public.task_instances
  where id = target_task_id for update;
  if not public.child_is_visible(task_record.child_id) then
    raise exception 'Task access required';
  end if;
  if task_record.status not in ('scheduled', 'ready') then
    raise exception 'Task cannot be started from status %', task_record.status;
  end if;
  update public.task_instances
  set status = 'in_progress',
      started_at = coalesce(started_at, now()),
      active_started_at = now()
  where id = target_task_id returning * into task_record;
  return task_record;
end;
$$;

create or replace function public.pause_task(target_task_id uuid)
returns public.task_instances
language plpgsql
security definer
set search_path = public
as $$
declare task_record public.task_instances%rowtype;
begin
  select * into task_record from public.task_instances
  where id = target_task_id for update;
  if not public.child_is_visible(task_record.child_id) then
    raise exception 'Task access required';
  end if;
  if task_record.status <> 'in_progress' or task_record.active_started_at is null then
    raise exception 'Only an active task can be paused';
  end if;
  update public.task_instances
  set status = 'paused',
      accumulated_seconds = accumulated_seconds +
        greatest(extract(epoch from now() - active_started_at)::integer, 0),
      active_started_at = null
  where id = target_task_id returning * into task_record;
  return task_record;
end;
$$;

create or replace function public.resume_task(target_task_id uuid)
returns public.task_instances
language plpgsql
security definer
set search_path = public
as $$
declare task_record public.task_instances%rowtype;
begin
  select * into task_record from public.task_instances
  where id = target_task_id for update;
  if not public.child_is_visible(task_record.child_id) then
    raise exception 'Task access required';
  end if;
  if task_record.status <> 'paused' then
    raise exception 'Only a paused task can be resumed';
  end if;
  update public.task_instances
  set status = 'in_progress', active_started_at = now()
  where id = target_task_id returning * into task_record;
  return task_record;
end;
$$;

create or replace function public.complete_task(
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
  if parent_reason is not null and not public.is_family_admin(task_family_id) then
    raise exception 'Family administrator required for manual completion';
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

revoke all on function public.start_task(uuid) from public;
revoke all on function public.pause_task(uuid) from public;
revoke all on function public.resume_task(uuid) from public;
revoke all on function public.complete_task(uuid, text, text) from public;
grant execute on function public.start_task(uuid) to authenticated;
grant execute on function public.pause_task(uuid) to authenticated;
grant execute on function public.resume_task(uuid) to authenticated;
grant execute on function public.complete_task(uuid, text, text) to authenticated;
