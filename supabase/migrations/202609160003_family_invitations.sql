create table public.family_invitations (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  email text not null,
  invited_by uuid not null references auth.users(id),
  accepted_at timestamptz,
  expires_at timestamptz not null default (now() + interval '7 days'),
  created_at timestamptz not null default now(),
  check (email = lower(btrim(email)))
);

create unique index family_invitations_pending_email_idx
  on public.family_invitations (family_id, email)
  where accepted_at is null;

alter table public.family_invitations enable row level security;

create policy family_invitations_admin_select
  on public.family_invitations for select
  using (public.is_family_admin(family_id));

create or replace function public.invite_family_parent(
  target_family_id uuid,
  parent_email text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_email text := lower(btrim(parent_email));
  invitation_id uuid;
begin
  if not public.is_family_admin(target_family_id) then
    raise exception 'Family administrator required';
  end if;
  if normalized_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
    raise exception 'A valid email address is required';
  end if;

  insert into public.family_invitations (family_id, email, invited_by)
  values (target_family_id, normalized_email, auth.uid())
  on conflict (family_id, email) where accepted_at is null
  do update set
    invited_by = excluded.invited_by,
    expires_at = now() + interval '7 days',
    created_at = now()
  returning id into invitation_id;

  return invitation_id;
end;
$$;

revoke all on function public.invite_family_parent(uuid, text) from public;
grant execute on function public.invite_family_parent(uuid, text) to authenticated;

create or replace function public.accept_family_invitations()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  current_email text := lower(auth.jwt() ->> 'email');
  accepted_count integer;
begin
  if auth.uid() is null or nullif(current_email, '') is null then
    return 0;
  end if;

  with accepted as (
    update public.family_invitations
    set accepted_at = now()
    where email = current_email
      and accepted_at is null
      and expires_at > now()
    returning family_id
  ), inserted as (
    insert into public.family_members (family_id, user_id, role)
    select family_id, auth.uid(), 'parent' from accepted
    on conflict (family_id, user_id) do nothing
    returning family_id
  )
  select count(*) into accepted_count from accepted;

  return accepted_count;
end;
$$;

revoke all on function public.accept_family_invitations() from public;
grant execute on function public.accept_family_invitations() to authenticated;
