-- A stable upload UUID binds one immutable, parent-approved payload.
-- Keep the fingerprint private: its input contains the parent's answer key.
create table public.question_media_upload_bindings (
  draft_id uuid primary key references public.question_ocr_drafts(id) on delete cascade,
  payload_hash text not null check(payload_hash ~ '^[0-9a-f]{64}$')
);
alter table public.question_media_upload_bindings enable row level security;
revoke all on public.question_media_upload_bindings from public,anon,authenticated,service_role;
create table public.deleted_ocr_drafts (
  draft_id uuid primary key,
  family_id uuid not null references public.families(id) on delete cascade
);
alter table public.deleted_ocr_drafts enable row level security;
revoke all on public.deleted_ocr_drafts from public,anon,authenticated,service_role;

create function public.preserve_deleted_ocr_draft() returns trigger
language plpgsql security definer set search_path='' as $$
declare family uuid := split_part(old.original_path,'/',1)::uuid;
begin
  if exists(select 1 from public.families where id=family) then
    insert into public.deleted_ocr_drafts values(old.id,family) on conflict do nothing;
  end if;
  return old;
end $$;
create trigger remember_deleted_ocr after delete on public.question_ocr_drafts
  for each row execute function public.preserve_deleted_ocr_draft();
create function public.reject_deleted_ocr_draft() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.deleted_ocr_drafts where draft_id=new.id) then
    raise exception '图片草稿已经永久清理，不能重新上传';
  end if;
  return new;
end $$;
create trigger reject_deleted_ocr before insert on public.question_ocr_drafts
  for each row execute function public.reject_deleted_ocr_draft();
revoke all on function public.preserve_deleted_ocr_draft(),public.reject_deleted_ocr_draft() from public,anon,authenticated,service_role;

create function public.begin_question_media_upload(target_child_id uuid,draft_id uuid,payload_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d public.question_ocr_drafts; existing_hash text;
begin
  if payload_hash is null or payload_hash !~ '^[0-9a-f]{64}$' then raise exception 'Invalid image payload hash'; end if;
  perform public.begin_question_ocr(target_child_id,draft_id);
  select * into d from public.question_ocr_drafts where id=draft_id for update;
  if d.deleting or d.original_deleted_at is not null then raise exception '图片草稿已清理或正在清理'; end if;
  select b.payload_hash into existing_hash from public.question_media_upload_bindings b where b.draft_id=d.id;
  if existing_hash is not null and existing_hash<>payload_hash then
    raise exception '同一草稿不能上传不同图片或校对内容'; end if;
  if existing_hash is null then
    insert into public.question_media_upload_bindings values(d.id,begin_question_media_upload.payload_hash);
  end if;
  return to_jsonb(d)||jsonb_build_object('client_payload_hash',payload_hash);
end $$;
revoke all on function public.begin_question_media_upload(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.begin_question_media_upload(uuid,uuid,text) to authenticated;
