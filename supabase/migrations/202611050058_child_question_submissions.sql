-- Child input stays outside the graded question bank until an explicit parent
-- confirmation. Reuse private image paths and existing deletion/export scopes.
alter table public.question_ocr_drafts add column requires_parent_review boolean not null default false,
  add column child_submission jsonb,add column submitted_at timestamptz,
  add column parent_confirmed_at timestamptz,add column parent_confirmed_by uuid references auth.users(id) on delete set null;
alter table public.question_media_upload_bindings add column submission_hash text,
  add column approval_request_id uuid,add column approval_owner_id uuid references auth.users(id) on delete set null,
  add column approval_hash text;
create index child_question_submission_page_idx on public.question_ocr_drafts(child_id,submitted_at desc,id desc)
  where requires_parent_review and submitted_at is not null;

create function public.child_question_submission(target_draft_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare d public.question_ocr_drafts; family uuid;
begin
  select * into d from public.question_ocr_drafts where id=target_draft_id;
  select family_id into family from public.children where id=d.child_id;
  if not found or not d.requires_parent_review or d.deleting or not public.child_is_visible(d.child_id)
    or (d.owner_id is distinct from auth.uid() and (d.submitted_at is null or not public.can_manage_family(family))) then
    raise exception 'Submission access required' using errcode='42501'; end if;
  return jsonb_build_object('owner_id',auth.uid(),'draft_id',d.id,'child_id',d.child_id,'family_id',family,
    'created_by',d.owner_id,'submitted_at',d.submitted_at,'confirmed_at',d.parent_confirmed_at,
    'state',case when d.question_id is not null then 'approved' when d.submitted_at is not null then 'pending' else 'uploading' end,
    'question_id',d.question_id,'config',d.child_submission,'recognition',d.raw_result,
    'original_path',case when d.original_deleted_at is null then d.original_path else null end,'processed_path',d.processed_path);
end $$;

create function public.begin_child_question_upload(target_child_id uuid,draft_id uuid,payload_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare family uuid; d public.question_ocr_drafts; previous text;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  select family_id into family from public.children where id=target_child_id;
  perform 1 from public.families where id=family for key share;
  if not coalesce(public.child_is_visible(target_child_id),false) then raise exception 'Child access required' using errcode='42501'; end if;
  if draft_id is null or payload_hash is null or payload_hash !~ '^[0-9a-f]{64}$' then raise exception 'Invalid upload' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ocr:'||auth.uid()::text,0));
  select * into d from public.question_ocr_drafts where id=draft_id for update;
  if found then
    if d.child_id<>target_child_id or d.owner_id<>auth.uid() or not d.requires_parent_review or d.deleting or d.original_deleted_at is not null then
      raise exception 'Draft unavailable' using errcode='42501'; end if;
  else
    if (select count(*) from public.question_ocr_drafts where owner_id=auth.uid() and created_at>now()-interval '1 day')>=50 then
      raise exception 'Daily image limit reached' using errcode='22023'; end if;
    insert into public.question_ocr_drafts(id,child_id,owner_id,original_path,processed_path,requires_parent_review)
      values(draft_id,target_child_id,auth.uid(),family::text||'/'||draft_id::text||'/original.jpg',family::text||'/'||draft_id::text||'/processed.jpg',true) returning * into d;
  end if;
  select b.payload_hash into previous from public.question_media_upload_bindings b where b.draft_id=d.id;
  if previous is not null and previous<>payload_hash then raise exception 'Upload changed' using errcode='22023'; end if;
  if previous is null then insert into public.question_media_upload_bindings(draft_id,payload_hash) values(d.id,payload_hash); end if;
  return to_jsonb(d)||jsonb_build_object('client_payload_hash',payload_hash);
end $$;

create function public.submit_child_question(target_draft_id uuid,config jsonb,recognition jsonb default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d public.question_ocr_drafts; family uuid; fingerprint text; previous text;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  select c.family_id into family from public.children c join public.question_ocr_drafts q on q.child_id=c.id where q.id=target_draft_id;
  perform 1 from public.families where id=family for key share;
  select * into d from public.question_ocr_drafts where id=target_draft_id for update;
  if not found or not d.requires_parent_review or d.owner_id is distinct from auth.uid() or d.deleting
    or not coalesce(public.child_is_visible(d.child_id),false) then raise exception 'Submission access required' using errcode='42501'; end if;
  if jsonb_typeof(config) is distinct from 'object' or octet_length(config::text)>32768
    or config->>'kind' is distinct from 'question' or config->>'subject' is null or config->>'subject' not in ('math','chinese','english')
    or nullif(btrim(config->>'prompt'),'') is null or char_length(config->>'prompt')>2000
    or config->>'ocr_confirmed' is distinct from 'true'
    or config-array['kind','subject','prompt','answers','context','knowledge_point','explanation','error_reason','error_reason_tags','pronunciation_confirmed','ocr_confirmed','requires_parent_review']<>'{}'::jsonb then
    raise exception 'Invalid child submission' using errcode='22023'; end if;
  if recognition is not null and (jsonb_typeof(recognition)<>'object' or octet_length(recognition::text)>2097152 or jsonb_typeof(recognition->'text') is distinct from 'string' or nullif(btrim(recognition->>'text'),'') is null) then
    raise exception 'Invalid OCR result' using errcode='22023'; end if;
  if jsonb_typeof(config->'prompt') is distinct from 'string' or config->'ocr_confirmed' is distinct from 'true'::jsonb
    or jsonb_typeof(config->'answers') is distinct from 'array' then raise exception 'Invalid submission fields' using errcode='22023'; end if;
  if jsonb_array_length(config->'answers')>5 or exists(select 1 from jsonb_array_elements(config->'answers') v where jsonb_typeof(v)<>'string' or char_length(v#>>'{}')>2000)
    or exists(select 1 from jsonb_each(config) e where e.key in ('context','knowledge_point','explanation','error_reason') and (jsonb_typeof(e.value)<>'string' or char_length(e.value#>>'{}')>2000)) then
    raise exception 'Invalid submission fields' using errcode='22023'; end if;
  if config ? 'error_reason_tags' then
    if jsonb_typeof(config->'error_reason_tags')<>'array' then raise exception 'Invalid reason tags' using errcode='22023'; end if;
    if jsonb_array_length(config->'error_reason_tags')>10 or exists(select 1 from jsonb_array_elements(config->'error_reason_tags') v where jsonb_typeof(v)<>'string') then raise exception 'Invalid reason tags' using errcode='22023'; end if;
  end if;
  if recognition ? 'lines' then
    if jsonb_typeof(recognition->'lines')<>'array' then raise exception 'Invalid OCR lines' using errcode='22023'; end if;
    if jsonb_array_length(recognition->'lines')>5000 or exists(select 1 from jsonb_array_elements(recognition->'lines') v where jsonb_typeof(v)<>'object' or jsonb_typeof(v->'text') is distinct from 'string'
      or (v ? 'confidence' and jsonb_typeof(v->'confidence') not in ('number','null'))) then raise exception 'Invalid OCR lines' using errcode='22023'; end if;
  end if;
  fingerprint:=encode(sha256(convert_to(jsonb_build_object('config',config,'recognition',recognition)::text,'UTF8')),'hex');
  select b.submission_hash into previous from public.question_media_upload_bindings b where b.draft_id=d.id;
  if not found then raise exception 'Upload binding missing' using errcode='22023'; end if;
  if previous is not null then
    if previous<>fingerprint then raise exception 'Submission content changed' using errcode='22023'; end if;
    return public.child_question_submission(d.id);
  end if;
  if d.status<>'pending' or not exists(select 1 from storage.objects where bucket_id='wrong-question-images' and name=d.original_path)
    or not exists(select 1 from storage.objects where bucket_id='wrong-question-images' and name=d.processed_path) then
    raise exception 'Images are not ready' using errcode='22023'; end if;
  update public.question_ocr_drafts set child_submission=config,submitted_at=clock_timestamp(),
    status=case when recognition is null then 'manual' else 'recognized' end,raw_text=coalesce(recognition->>'text',''),
    raw_result=coalesce(recognition,'{}')||jsonb_build_object('source','on_device_client_suggestion','confirmation_required',true) where id=d.id;
  update public.question_media_upload_bindings set submission_hash=fingerprint where draft_id=d.id;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'review.child_submitted','ocr_draft',d.id::text,jsonb_build_object('requires_parent_review',true));
  return public.child_question_submission(d.id);
end $$;

create function public.approve_child_question(target_draft_id uuid,request_id uuid,config jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d public.question_ocr_drafts; family uuid; fingerprint text; binding public.question_media_upload_bindings; question uuid;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  select c.family_id into family from public.children c join public.question_ocr_drafts q on q.child_id=c.id where q.id=target_draft_id;
  perform 1 from public.families where id=family for key share;
  perform public.require_parent_authorization(family);
  -- Match normal question creation's lock order before locking the media row.
  perform pg_advisory_xact_lock(hashtextextended('review:'||(select child_id::text from public.question_ocr_drafts where id=target_draft_id),0));
  select * into d from public.question_ocr_drafts where id=target_draft_id for update;
  if not found or not d.requires_parent_review or d.submitted_at is null or d.deleting or not coalesce(public.child_is_visible(d.child_id),false) then
    raise exception 'Submission unavailable' using errcode='42501'; end if;
  perform 1 from public.parent_authorizations a where a.family_id=family and a.user_id=auth.uid()
    and a.session_id=auth.jwt()->>'session_id' and a.expires_at>clock_timestamp() for key share;
  if not found then raise exception 'Parent authorization expired' using errcode='42501'; end if;
  if request_id is null or jsonb_typeof(config) is distinct from 'object' or config->>'kind' is distinct from 'question'
    or config->>'ocr_confirmed' is distinct from 'true' or config ? 'ocr_draft_id' or config ? 'expected_version' then
    raise exception 'Parent answer confirmation required' using errcode='22023'; end if;
  fingerprint:=encode(sha256(convert_to(config::text,'UTF8')),'hex');
  select * into binding from public.question_media_upload_bindings where draft_id=d.id;
  if d.question_id is not null then
    if binding.approval_request_id is distinct from request_id or binding.approval_owner_id is distinct from auth.uid() or binding.approval_hash is distinct from fingerprint then
      raise exception 'Submission already reviewed; refresh' using errcode='40001'; end if;
    return public.child_question_submission(d.id);
  end if;
  question:=public.save_review_question(d.child_id,config-'requires_parent_review',null);
  update public.question_ocr_drafts set question_id=question,status='saved',parent_confirmed_at=clock_timestamp(),parent_confirmed_by=auth.uid() where id=d.id;
  update public.question_media_upload_bindings set approval_request_id=request_id,approval_owner_id=auth.uid(),approval_hash=fingerprint where draft_id=d.id;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'review.parent_confirmed_child_input','wrong_question',question::text,jsonb_build_object('draft_id',d.id));
  return public.child_question_submission(d.id);
end $$;

create function public.child_question_submissions(target_child_id uuid,after_created_at timestamptz default null,after_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare family uuid; rows jsonb; last_row jsonb;
begin
  select family_id into family from public.children where id=target_child_id;
  if not coalesce(public.child_is_visible(target_child_id),false) then raise exception 'Child access required' using errcode='42501'; end if;
  if (after_created_at is null)<>(after_id is null) or after_created_at is not null and not isfinite(after_created_at) then raise exception 'Invalid cursor' using errcode='22023'; end if;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.submitted_at desc,q.id desc),'[]') into rows from (
    select d.id,d.submitted_at,d.child_submission->>'prompt' title,d.question_id,
      case when d.question_id is null then 'pending' else 'approved' end state
    from public.question_ocr_drafts d where d.child_id=target_child_id and d.requires_parent_review and d.submitted_at is not null and not d.deleting
      and (d.owner_id=auth.uid() or public.can_manage_family(family))
      and (after_id is null or (d.submitted_at,d.id)<(after_created_at,after_id))
      order by d.submitted_at desc,d.id desc limit 51) q;
  last_row:=rows->49;
  return jsonb_build_object('owner_id',auth.uid(),'child_id',target_child_id,'family_id',family,
    'items',(select coalesce(jsonb_agg(value order by ordinal),'[]') from jsonb_array_elements(rows) with ordinality e(value,ordinal) where ordinal<=50),
    'next_cursor',case when jsonb_array_length(rows)>50 then jsonb_build_object('id',last_row->>'id','created_at',last_row->>'submitted_at') else null end);
end $$;

-- Child submissions never weaken existing parent-only uploads or editing.
create or replace function public.can_insert_question_image(object_path text) returns boolean
language plpgsql security definer set search_path='' as $$
declare d public.question_ocr_drafts; family uuid;
begin
  select * into d from public.question_ocr_drafts where original_path=object_path or processed_path=object_path for share;
  if not found or d.deleting or d.original_deleted_at is not null or d.status<>'pending' or d.owner_id is distinct from auth.uid() then return false; end if;
  select family_id into family from public.children where id=d.child_id;
  return public.child_is_visible(d.child_id) and (d.requires_parent_review or public.can_manage_family(family));
end $$;
drop policy ocr_read on public.question_ocr_drafts;
create policy ocr_read on public.question_ocr_drafts for select to authenticated using (
  public.child_is_visible(child_id) and (question_id is not null or
    exists(select 1 from public.children c where c.id=child_id and
      ((owner_id=auth.uid() and (requires_parent_review or public.can_manage_family(c.family_id)))
      or (requires_parent_review and submitted_at is not null and public.can_manage_family(c.family_id))))));
drop policy question_image_read on storage.objects;
create policy question_image_read on storage.objects for select to authenticated using (
  bucket_id='wrong-question-images' and exists(select 1 from public.question_ocr_drafts d join public.children c on c.id=d.child_id
    where (name=d.original_path or name=d.processed_path) and public.child_is_visible(d.child_id)
      and (d.question_id is not null or d.owner_id=auth.uid() or (d.requires_parent_review and d.submitted_at is not null and public.can_manage_family(c.family_id)))));

alter function public.save_review_question(uuid,jsonb,uuid) rename to save_review_question_before_child_submissions;
create function public.save_review_question(target_child_id uuid,config jsonb,target_question_id uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
begin
  if config ? 'ocr_draft_id' and exists(select 1 from public.question_ocr_drafts where id=(config->>'ocr_draft_id')::uuid and requires_parent_review) then
    raise exception 'Use the explicit parent confirmation flow' using errcode='22023'; end if;
  return public.save_review_question_before_child_submissions(target_child_id,config,target_question_id);
end $$;
revoke all on function public.save_review_question_before_child_submissions(uuid,jsonb,uuid) from public,anon,authenticated,service_role;
revoke all on function public.child_question_submission(uuid),public.begin_child_question_upload(uuid,uuid,text),public.submit_child_question(uuid,jsonb,jsonb),
  public.approve_child_question(uuid,uuid,jsonb),public.child_question_submissions(uuid,timestamptz,uuid),public.save_review_question(uuid,jsonb,uuid) from public,anon,service_role;
grant execute on function public.child_question_submission(uuid),public.begin_child_question_upload(uuid,uuid,text),public.submit_child_question(uuid,jsonb,jsonb),
  public.approve_child_question(uuid,uuid,jsonb),public.child_question_submissions(uuid,timestamptz,uuid),public.save_review_question(uuid,jsonb,uuid) to authenticated;

-- A child's export includes submitted family input even when another family
-- member uploaded it. Unsubmitted private drafts retain their old owner rule.
alter function public.child_export_source(uuid) rename to child_export_source_before_child_submissions;
create function public.child_export_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_agg(case
    when section->>'name'='ocr_records' then jsonb_set(section,'{rows}',coalesce((
      select jsonb_agg(to_jsonb(d) order by d.created_at,d.id) from public.question_ocr_drafts d
      where d.child_id=target_child_id and not d.deleting and
        (d.question_id is not null or d.owner_id=auth.uid() or d.requires_parent_review and d.submitted_at is not null)),'[]'))
    when section->>'name'='audit_logs' then jsonb_set(section,'{rows}',(section->'rows')||coalesce((
      select jsonb_agg(jsonb_build_object('id',a.id,'actor_user_id',a.actor_user_id,'action',a.action,'target_type',a.target_type,
        'target_id',a.target_id,'details',a.details,'created_at',a.created_at) order by a.id)
      from public.audit_logs a join public.question_ocr_drafts d on a.target_type='ocr_draft' and a.target_id=d.id::text
      where d.child_id=target_child_id and a.action='review.child_submitted' and
        not exists(select 1 from jsonb_array_elements(section->'rows') e where e->>'id'=a.id::text)),'[]'))
    else section end order by ordinal)
    from jsonb_array_elements(public.child_export_source_before_child_submissions(target_child_id)) with ordinality e(section,ordinal);
$$;
revoke all on function public.child_export_source(uuid),public.child_export_source_before_child_submissions(uuid) from public,anon,authenticated,service_role;
