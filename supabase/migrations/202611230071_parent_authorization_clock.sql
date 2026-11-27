-- Keep verify_parent_pin's public result shape for already installed clients.
create function public.verify_parent_pin_timed(target_family_id uuid, candidate_pin text)
returns table(verified boolean, remaining_attempts integer, retry_at timestamptz,
  authorized_until timestamptz, server_now timestamptz)
language sql volatile security invoker set search_path='' as $$
  select p.*, statement_timestamp()
    from public.verify_parent_pin(target_family_id,candidate_pin) p;
$$;
revoke all on function public.verify_parent_pin_timed(uuid,text) from public,anon;
grant execute on function public.verify_parent_pin_timed(uuid,text) to authenticated;

create or replace function public.account_deletion_context() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if not public.account_is_active(auth.uid()) then raise exception '账号不可用' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',f.id,'name',f.name,
    'owned',f.owner_user_id=auth.uid(),'authorized',public.has_parent_authorization(f.id),
    'server_now',statement_timestamp(),
    'authorized_until',(select expires_at from public.parent_authorizations where family_id=f.id and user_id=auth.uid() and session_id=auth.jwt()->>'session_id')) order by f.id)
    from public.families f join public.family_members m on m.family_id=f.id where m.user_id=auth.uid()),'[]');
end $$;
