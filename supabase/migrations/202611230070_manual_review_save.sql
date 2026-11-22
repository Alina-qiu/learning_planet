-- A manual editor keeps one request ID through retries, including lost responses.
create table public.manual_review_save_receipts (
  owner_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  child_id uuid not null references public.children(id) on delete cascade,
  payload_hash text not null,
  question_id uuid references public.wrong_questions(id) on delete set null,
  primary key(owner_id, request_id)
);
alter table public.manual_review_save_receipts enable row level security;
revoke all on public.manual_review_save_receipts from public, anon, authenticated, service_role;

create function public.save_manual_review_question(
  target_child_id uuid, config jsonb, request_id uuid, target_question_id uuid default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare
  family uuid;
  question uuid;
  fingerprint text;
  receipt public.manual_review_save_receipts;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  if not public.account_is_active(auth.uid()) then
    raise exception 'Account unavailable' using errcode='42501';
  end if;
  select family_id into family from public.children where id=target_child_id;
  perform 1 from public.families where id=family for key share;
  if not coalesce(public.child_is_visible(target_child_id), false) then
    raise exception 'Child access required' using errcode='42501';
  end if;
  perform public.require_parent_authorization(family);
  if request_id is null or jsonb_typeof(config) is distinct from 'object' or config ? 'ocr_draft_id' then
    raise exception 'Invalid manual question request' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('manual-review:' || auth.uid()::text || ':' || request_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('review:' || target_child_id::text, 0));
  perform 1 from public.parent_authorizations a where a.family_id=family and a.user_id=auth.uid()
    and a.session_id=auth.jwt()->>'session_id' and a.expires_at>clock_timestamp() for key share;
  if not found then raise exception 'Parent authorization expired' using errcode='42501'; end if;

  fingerprint := encode(sha256(convert_to(jsonb_build_array(target_question_id, config)::text, 'UTF8')), 'hex');
  select * into receipt from public.manual_review_save_receipts r
    where r.owner_id=auth.uid() and r.request_id=save_manual_review_question.request_id;
  if found then
    if receipt.child_id<>target_child_id or receipt.payload_hash<>fingerprint then
      raise exception '上一次保存已完成，请从错题本打开已保存的题目继续编辑' using errcode='22023';
    end if;
    if not exists(select 1 from public.wrong_questions where id=receipt.question_id and not deleting) then
      raise exception '已保存的题目已被删除，请返回错题本' using errcode='22023';
    end if;
    return receipt.question_id;
  end if;
  question := public.save_review_question(target_child_id, config, target_question_id);
  insert into public.manual_review_save_receipts(owner_id, request_id, child_id, payload_hash, question_id)
    values(auth.uid(), request_id, target_child_id, fingerprint, question);
  return question;
end $$;
revoke all on function public.save_manual_review_question(uuid,jsonb,uuid,uuid) from public, anon, service_role;
grant execute on function public.save_manual_review_question(uuid,jsonb,uuid,uuid) to authenticated;
