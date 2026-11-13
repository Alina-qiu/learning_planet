-- Immutable OCR provenance; private media and PIN-protected management.
alter table public.wrong_questions add column error_reason text not null default '';
create table public.question_ocr_drafts (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id) on delete cascade,
  owner_id uuid not null references auth.users(id),
  status text not null default 'pending' check(status in ('pending','recognized','failed','manual','saved')),
  original_path text not null unique,
  processed_path text not null unique,
  raw_text text not null default '',
  raw_result jsonb not null default '{}',
  failure_code text,
  question_id uuid unique references public.wrong_questions(id),
  created_at timestamptz not null default now()
);
alter table public.question_ocr_drafts enable row level security;
revoke all on public.question_ocr_drafts from public,anon,authenticated;
grant select on public.question_ocr_drafts to authenticated;
create policy ocr_read on public.question_ocr_drafts for select to authenticated
  using(public.child_is_visible(child_id) and (question_id is not null or
    (owner_id=auth.uid() and exists(select 1 from public.children c where c.id=child_id and public.can_manage_family(c.family_id)))));
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('wrong-question-images','wrong-question-images',false,10485760,array['image/jpeg','image/png'])
on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=array['image/jpeg','image/png'];
create policy question_image_read on storage.objects for select to authenticated using (
  bucket_id='wrong-question-images' and exists(select 1 from public.question_ocr_drafts d
  where (name=d.original_path or name=d.processed_path) and public.child_is_visible(d.child_id)
    and (d.question_id is not null or d.owner_id=auth.uid())));
create policy question_image_insert on storage.objects for insert to authenticated with check (
  bucket_id='wrong-question-images' and exists(select 1 from public.question_ocr_drafts d
  join public.children c on c.id=d.child_id where (name=d.original_path or name=d.processed_path)
  and d.owner_id=auth.uid() and d.status='pending' and public.can_manage_family(c.family_id)));
-- No UPDATE/DELETE policy: neither overwrite original evidence nor delete live snapshots.
create function public.begin_question_ocr(target_child_id uuid, draft_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare family uuid; d public.question_ocr_drafts;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if draft_id is null then raise exception '缺少草稿标识'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ocr:'||auth.uid()::text,0));
  select * into d from public.question_ocr_drafts where id=draft_id;
  if found then
    if d.child_id<>target_child_id or d.owner_id<>auth.uid() then raise exception '草稿不属于当前账号'; end if;
    return to_jsonb(d);
  end if;
  if (select count(*) from public.question_ocr_drafts where owner_id=auth.uid() and created_at>now()-interval '1 day')>=50 then
    raise exception '今日图片录入已达到50次，请明日再试';
  end if;
  insert into public.question_ocr_drafts(id,child_id,owner_id,original_path,processed_path)
  values(draft_id,target_child_id,auth.uid(),family::text||'/'||draft_id::text||'/original.jpg',
    family::text||'/'||draft_id::text||'/processed.jpg') returning * into d;
  return to_jsonb(d);
end $$;
-- On-device OCR is a suggestion, never a trusted grading or reward source.
create function public.record_question_ocr(target_draft_id uuid, result jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare d public.question_ocr_drafts; family uuid;
begin
  select * into d from public.question_ocr_drafts where id=target_draft_id for update;
  select family_id into family from public.children where id=d.child_id;
  perform public.require_parent_authorization(family);
  if d.owner_id is distinct from auth.uid() or d.status<>'pending' then raise exception '草稿不可修改'; end if;
  if octet_length(result::text)>2097152 or btrim(coalesce(result->>'text',''))='' then raise exception '识别结果为空或过大'; end if;
  if not exists(select 1 from storage.objects where bucket_id='wrong-question-images' and name=d.original_path)
     or not exists(select 1 from storage.objects where bucket_id='wrong-question-images' and name=d.processed_path) then raise exception '图片尚未上传'; end if;
  update public.question_ocr_drafts set status='recognized',raw_text=result->>'text',
    raw_result=result||jsonb_build_object('source','on_device_client_suggestion','confirmation_required',true) where id=d.id;
end $$;
create function public.manual_question_ocr(target_draft_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare d public.question_ocr_drafts; family uuid;
begin
  select * into d from public.question_ocr_drafts where id=target_draft_id for update;
  select family_id into family from public.children where id=d.child_id;
  perform public.require_parent_authorization(family);
  if d.owner_id is distinct from auth.uid() or d.status not in ('pending','failed') then raise exception '草稿不可转手工录入'; end if;
  if not exists(select 1 from storage.objects where bucket_id='wrong-question-images' and name=d.original_path)
     or not exists(select 1 from storage.objects where bucket_id='wrong-question-images' and name=d.processed_path) then raise exception '图片尚未上传'; end if;
  update public.question_ocr_drafts set status='manual' where id=d.id;
end $$;
alter function public.save_review_question(uuid,jsonb,uuid) rename to save_review_question_before_ocr;
revoke execute on function public.save_review_question_before_ocr(uuid,jsonb,uuid) from public,anon,authenticated;
create function public.save_review_question(target_child_id uuid, config jsonb, target_question_id uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare d public.question_ocr_drafts; question uuid; family uuid; v bigint;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id::text,0));
  if target_question_id is not null and config ? 'expected_version' then
    select content_version into v from public.wrong_questions where id=target_question_id for update;
    if v is distinct from (config->>'expected_version')::bigint then raise exception '错题已被修改，请重新打开编辑'; end if;
  end if;
  if config ? 'ocr_draft_id' then
    select * into d from public.question_ocr_drafts where id=(config->>'ocr_draft_id')::uuid for update;
    if d.child_id is distinct from target_child_id or d.owner_id is distinct from auth.uid() then raise exception '图片草稿不属于当前账号或孩子'; end if;
    if d.status='saved' then return d.question_id; end if;
    if d.status not in ('recognized','manual') or target_question_id is not null then raise exception '草稿尚未完成识别或校对'; end if;
    if config->>'ocr_confirmed' is distinct from 'true' then raise exception '请核对所有识别文字，尤其是低置信内容'; end if;
  end if;
  question:=public.save_review_question_before_ocr(target_child_id,config,target_question_id);
  if length(coalesce(config->>'error_reason',''))>500 then raise exception '错误原因不得超过500字'; end if;
  update public.wrong_questions set error_reason=coalesce(config->>'error_reason','') where id=question;
  if d.id is not null then
    update public.question_ocr_drafts set status='saved',question_id=question where id=d.id;
    insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'review.ocr_confirm','wrong_question',question::text,jsonb_build_object('draft_id',d.id));
  end if;
  return question;
end $$;
create function public.archive_review_questions(target_child_id uuid, question_ids uuid[], enabled boolean) returns void
language plpgsql security definer set search_path='' as $$
declare family uuid; item uuid;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if cardinality(question_ids) is null or cardinality(question_ids) not between 1 and 100 or enabled is null then raise exception '请选择1至100道题'; end if;
  if exists(select 1 from unnest(question_ids) q(id) where not exists(select 1 from public.wrong_questions w where w.id=q.id and w.child_id=target_child_id)) then raise exception '包含其他孩子的错题或无效记录'; end if;
  foreach item in array question_ids loop perform public.archive_review_question(item,enabled); end loop;
end $$;
revoke all on function public.begin_question_ocr(uuid,uuid),public.record_question_ocr(uuid,jsonb),public.manual_question_ocr(uuid),public.save_review_question(uuid,jsonb,uuid),public.archive_review_questions(uuid,uuid[],boolean) from public,anon;
grant execute on function public.begin_question_ocr(uuid,uuid),public.record_question_ocr(uuid,jsonb),public.manual_question_ocr(uuid),public.save_review_question(uuid,jsonb,uuid),public.archive_review_questions(uuid,uuid[],boolean) to authenticated;
