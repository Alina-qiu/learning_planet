-- Elevation is scoped to one authenticated login session, not a client flag.
create table public.parent_authorizations (
  family_id uuid not null references public.families(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id text not null,
  expires_at timestamptz not null,
  primary key (family_id, user_id, session_id)
);
alter table public.parent_authorizations enable row level security;
revoke all on public.parent_authorizations from anon, authenticated;

create function public.has_parent_authorization(target_family_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select public.is_family_member(target_family_id) and exists (
    select 1 from public.parent_authorizations a
    where a.family_id = target_family_id and a.user_id = auth.uid()
      and a.session_id = auth.jwt() ->> 'session_id'
      and a.expires_at > now()
  )
$$;
revoke all on function public.has_parent_authorization(uuid) from public;
grant execute on function public.has_parent_authorization(uuid) to authenticated;

create function public.can_manage_family(target_family_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select public.is_family_member(target_family_id)
  and public.has_parent_authorization(target_family_id) $$;
revoke all on function public.can_manage_family(uuid) from public;
grant execute on function public.can_manage_family(uuid) to authenticated;

create function public.require_parent_authorization(target_family_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.has_parent_authorization(target_family_id) then
    raise exception 'Parent authorization required or expired' using errcode = '42501';
  end if;
end;
$$;
revoke all on function public.require_parent_authorization(uuid) from public, authenticated;

alter function public.verify_parent_pin(uuid, text) rename to verify_parent_pin_internal;
revoke all on function public.verify_parent_pin_internal(uuid, text) from public, authenticated;
create function public.verify_parent_pin(target_family_id uuid, candidate_pin text)
returns table(verified boolean, remaining_attempts integer, retry_at timestamptz, authorized_until timestamptz)
language plpgsql security definer set search_path = public
as $$
declare result record; current_session text := auth.jwt() ->> 'session_id';
begin
  if auth.uid() is null or nullif(current_session, '') is null then
    raise exception 'Authenticated login session required' using errcode = '42501';
  end if;
  select * into result from public.verify_parent_pin_internal(target_family_id, candidate_pin);
  if result.verified then
    authorized_until := now() + interval '10 minutes';
    insert into public.parent_authorizations(family_id, user_id, session_id, expires_at)
    values(target_family_id, auth.uid(), current_session, authorized_until)
    on conflict (family_id, user_id, session_id) do update set expires_at = excluded.expires_at;
  else
    delete from public.parent_authorizations
    where family_id = target_family_id and user_id = auth.uid() and session_id = current_session;
  end if;
  return query select result.verified, result.remaining_attempts, result.retry_at, authorized_until;
end;
$$;
revoke all on function public.verify_parent_pin(uuid, text) from public;
grant execute on function public.verify_parent_pin(uuid, text) to authenticated;

create function public.revoke_parent_authorization(target_family_id uuid default null)
returns void language sql security definer set search_path = public
as $$
  delete from public.parent_authorizations where user_id = auth.uid()
    and session_id = auth.jwt() ->> 'session_id'
    and (target_family_id is null or family_id = target_family_id)
$$;
revoke all on function public.revoke_parent_authorization(uuid) from public;
grant execute on function public.revoke_parent_authorization(uuid) to authenticated;

alter function public.set_parent_pin(uuid, text) rename to set_parent_pin_internal;
revoke all on function public.set_parent_pin_internal(uuid, text) from public, authenticated;
create function public.set_parent_pin(target_family_id uuid, new_pin text)
returns void language plpgsql security definer set search_path = public
as $$
declare was_authorized boolean; current_session text := auth.jwt() ->> 'session_id';
begin
  perform pg_advisory_xact_lock(hashtextextended(target_family_id::text, 0));
  was_authorized := public.has_parent_authorization(target_family_id);
  if exists(select 1 from public.parent_pins where family_id = target_family_id) then
    perform public.require_parent_authorization(target_family_id);
  elsif auth.uid() is null or nullif(current_session, '') is null
    or coalesce((auth.jwt() ->> 'iat')::bigint, 0) < extract(epoch from now() - interval '5 minutes') then
    raise exception 'Sign in again before first PIN setup' using errcode = '42501';
  end if;
  perform public.set_parent_pin_internal(target_family_id, new_pin);
  delete from public.parent_authorizations where family_id = target_family_id;
  if was_authorized then
    insert into public.parent_authorizations values
      (target_family_id, auth.uid(), current_session, now() + interval '10 minutes');
  end if;
end;
$$;
revoke all on function public.set_parent_pin(uuid, text) from public;
grant execute on function public.set_parent_pin(uuid, text) to authenticated;

-- Read access remains available to child mode; writes require elevated parent mode.
-- Parent-only invitation and audit details are not exposed in child mode.
drop policy family_invitations_admin_select on public.family_invitations;
create policy family_invitations_admin_select on public.family_invitations for select
  using(public.is_family_admin(family_id) and public.has_parent_authorization(family_id));
drop policy audit_logs_select on public.audit_logs;
create policy audit_logs_select on public.audit_logs for select
  using(public.can_manage_family(family_id));
drop policy children_all on public.children;
create policy children_select on public.children for select using(public.is_family_member(family_id));
-- Only RPCs may create children, ensuring every child has a wallet.
drop policy families_update_admin on public.families;
create policy families_update_admin on public.families for update
  using(public.is_family_admin(id) and public.has_parent_authorization(id))
  with check(public.is_family_admin(id) and public.has_parent_authorization(id));
revoke update on public.families from authenticated;
grant update(name, timezone) on public.families to authenticated;
drop policy family_members_insert_admin on public.family_members;
drop policy family_members_update_admin on public.family_members;
drop policy family_members_delete_admin on public.family_members;
create policy family_members_insert_admin on public.family_members for insert
  with check(public.is_family_admin(family_id) and public.has_parent_authorization(family_id));
create policy family_members_update_admin on public.family_members for update
  using(public.is_family_admin(family_id) and public.has_parent_authorization(family_id))
  with check(public.is_family_admin(family_id) and public.has_parent_authorization(family_id));
create policy family_members_delete_admin on public.family_members for delete
  using(public.is_family_admin(family_id) and public.has_parent_authorization(family_id));
drop policy rewards_member on public.rewards;
create policy rewards_select on public.rewards for select using(public.is_family_member(family_id));
create policy rewards_parent_write on public.rewards for all
  using(public.can_manage_family(family_id)) with check(public.can_manage_family(family_id));
drop policy wrong_questions_member on public.wrong_questions;
create policy wrong_questions_select on public.wrong_questions for select using(public.child_is_visible(child_id));
create policy wrong_questions_parent_write on public.wrong_questions for all using(
  exists(select 1 from public.children c where c.id = child_id and public.can_manage_family(c.family_id))
) with check(
  exists(select 1 from public.children c where c.id = child_id and public.can_manage_family(c.family_id))
);
drop policy task_templates_admin_insert on public.task_templates;
drop policy task_templates_admin_update on public.task_templates;
drop policy task_templates_admin_delete on public.task_templates;
create policy task_templates_parent_write on public.task_templates for all using(
  exists(select 1 from public.children c where c.id = child_id and public.can_manage_family(c.family_id))
) with check(
  exists(select 1 from public.children c where c.id = child_id and public.can_manage_family(c.family_id))
);
alter function public.create_child(uuid, text, smallint) rename to create_child_internal;
revoke all on function public.create_child_internal(uuid, text, smallint) from public, authenticated;
create function public.create_child(target_family_id uuid, child_nickname text, child_grade smallint) returns uuid
language plpgsql security definer set search_path = public as $$
begin

  perform public.require_parent_authorization(target_family_id);

  return public.create_child_internal(target_family_id, child_nickname, child_grade);
end;
$$;
revoke all on function public.create_child(uuid, text, smallint) from public;
grant execute on function public.create_child(uuid, text, smallint) to authenticated;

alter function public.update_child(uuid, text, smallint) rename to update_child_internal;
revoke all on function public.update_child_internal(uuid, text, smallint) from public, authenticated;
create function public.update_child(target_child_id uuid, child_nickname text, child_grade smallint) returns void
language plpgsql security definer set search_path = public as $$
begin

  perform public.require_parent_authorization((select family_id from public.children where id = target_child_id));

  perform public.update_child_internal(target_child_id, child_nickname, child_grade);
end;
$$;
revoke all on function public.update_child(uuid, text, smallint) from public;
grant execute on function public.update_child(uuid, text, smallint) to authenticated;

alter function public.delete_child(uuid) rename to delete_child_internal;
revoke all on function public.delete_child_internal(uuid) from public, authenticated;
create function public.delete_child(target_child_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin

  perform public.require_parent_authorization((select family_id from public.children where id = target_child_id));
  perform pg_advisory_xact_lock(hashtextextended('children:' ||
    (select family_id::text from public.children where id = target_child_id), 0));

  perform public.delete_child_internal(target_child_id);
end;
$$;
revoke all on function public.delete_child(uuid) from public;
grant execute on function public.delete_child(uuid) to authenticated;

alter function public.invite_family_parent(uuid, text) rename to invite_family_parent_internal;
revoke all on function public.invite_family_parent_internal(uuid, text) from public, authenticated;
create function public.invite_family_parent(target_family_id uuid, parent_email text) returns uuid
language plpgsql security definer set search_path = public as $$
begin

  perform public.require_parent_authorization(target_family_id);

  return public.invite_family_parent_internal(target_family_id, parent_email);
end;
$$;
revoke all on function public.invite_family_parent(uuid, text) from public;
grant execute on function public.invite_family_parent(uuid, text) to authenticated;

alter function public.complete_task(uuid, text, text) rename to complete_task_internal;
revoke all on function public.complete_task_internal(uuid, text, text) from public, authenticated;
create function public.complete_task(target_task_id uuid, completion_key text, parent_reason text default null) returns public.task_instances
language plpgsql security definer set search_path = public as $$
begin
  if parent_reason is not null then
  perform public.require_parent_authorization((select c.family_id from public.children c join public.task_instances t on t.child_id = c.id where t.id = target_task_id));
  end if;
  return public.complete_task_internal(target_task_id, completion_key, parent_reason);
end;
$$;
revoke all on function public.complete_task(uuid, text, text) from public;
grant execute on function public.complete_task(uuid, text, text) to authenticated;

alter function public.create_task_from_template(uuid, date, timestamptz) rename to create_task_from_template_internal;
revoke all on function public.create_task_from_template_internal(uuid, date, timestamptz) from public, authenticated;
create function public.create_task_from_template(target_template_id uuid, target_date date, target_due_at timestamptz default null) returns uuid
language plpgsql security definer set search_path = public as $$
begin

  perform public.require_parent_authorization((select c.family_id from public.children c join public.task_templates t on t.child_id = c.id where t.id = target_template_id));

  return public.create_task_from_template_internal(target_template_id, target_date, target_due_at);
end;
$$;
revoke all on function public.create_task_from_template(uuid, date, timestamptz) from public;
grant execute on function public.create_task_from_template(uuid, date, timestamptz) to authenticated;
