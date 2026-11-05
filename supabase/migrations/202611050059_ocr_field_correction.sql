-- Preserve field-level source and the first confirmed correction separately
-- from grading answers. Existing unstructured provenance remains readable.
alter table public.question_ocr_drafts add column final_ocr_fields jsonb;
alter table public.question_ocr_drafts drop constraint ocr_confirmation_metrics_check;
alter table public.question_ocr_drafts add constraint ocr_confirmation_metrics_check check (
  (metrics_confirmed_at is null and metrics_ocr_fields is null and metrics_corrected_fields is null)
  or (metrics_confirmed_at is not null and metrics_ocr_fields is not null and metrics_corrected_fields is not null and metrics_ocr_fields between 0 and 4
    and metrics_corrected_fields between 0 and metrics_ocr_fields));

create function public.validate_ocr_field_correction(recognition jsonb,config jsonb) returns void
language plpgsql immutable security definer set search_path='' as $$
declare fields jsonb:=config->'ocr_corrections'; confirmations jsonb:=config->'ocr_field_confirmations';
  key text; source jsonb; expected text;
begin
  if recognition ? 'field_schema' then
    if recognition->'field_schema' is distinct from '1'::jsonb or jsonb_typeof(recognition->'fields') is distinct from 'object'
      or (recognition->'fields')-array['prompt','options','answer','annotation']<>'{}'::jsonb then
      raise exception 'Invalid OCR fields' using errcode='22023'; end if;
    foreach key in array array['prompt','options','answer','annotation'] loop
      source:=recognition->'fields'->key;
      if jsonb_typeof(source) is distinct from 'object' or jsonb_typeof(source->'text') is distinct from 'string'
        or char_length(source->>'text')>32768 then raise exception 'Invalid OCR field text' using errcode='22023'; end if;
      if source ? 'confidence' and source->'confidence'<>'null'::jsonb then
        if jsonb_typeof(source->'confidence')<>'number' then raise exception 'Invalid OCR confidence' using errcode='22023'; end if;
        if (source->>'confidence')::numeric not between 0 and 1 then raise exception 'Invalid OCR confidence' using errcode='22023'; end if;
      end if;
    end loop;
    if fields is null then raise exception 'Please confirm each OCR field' using errcode='22023'; end if;
  end if;
  if fields is null and confirmations is null then return; end if;
  if jsonb_typeof(fields) is distinct from 'object' or fields-array['prompt','options','answer','annotation']<>'{}'::jsonb
    or jsonb_typeof(confirmations) is distinct from 'array' then raise exception 'Invalid OCR correction' using errcode='22023'; end if;
  if jsonb_array_length(confirmations)>4 or exists(select 1 from jsonb_array_elements(confirmations) v where jsonb_typeof(v)<>'string' or v#>>'{}' not in ('prompt','options','answer','annotation'))
    or (select count(*) from jsonb_array_elements(confirmations))<>(select count(distinct v) from jsonb_array_elements(confirmations) v) then
    raise exception 'Invalid OCR confirmation list' using errcode='22023'; end if;
  foreach key in array array['prompt','options','answer','annotation'] loop
    if jsonb_typeof(fields->key) is distinct from 'string' or char_length(fields->>key)>2000 then raise exception 'Invalid corrected field' using errcode='22023'; end if;
    if (nullif(btrim(fields->>key),'') is not null or nullif(btrim(recognition->'fields'->key->>'text'),'') is not null)
      and not confirmations ? key then raise exception 'Confirm every nonempty OCR field' using errcode='22023'; end if;
  end loop;
  expected:=btrim(fields->>'prompt')||case when btrim(fields->>'options')<>'' then E'\n'||btrim(fields->>'options') else '' end;
  if nullif(btrim(fields->>'prompt'),'') is null or config->>'prompt' is distinct from expected then
    raise exception 'Question must contain the corrected prompt and options only' using errcode='22023'; end if;
end $$;
revoke all on function public.validate_ocr_field_correction(jsonb,jsonb) from public,anon,authenticated,service_role;

create or replace function public.capture_ocr_confirmation_metrics() returns trigger
language plpgsql security definer set search_path='' as $$
declare confirmed text; key text;
begin
  if tg_op='INSERT' then
    new.metrics_confirmed_at:=null;new.metrics_ocr_fields:=null;new.metrics_corrected_fields:=null;new.final_ocr_fields:=null;
  elsif old.status in ('recognized','manual') and new.status='saved' and old.question_id is null and new.question_id is not null then
    select final_text into confirmed from public.wrong_questions where id=new.question_id and child_id=new.child_id;
    if not found then raise exception 'OCR confirmation scope mismatch'; end if;
    new.metrics_confirmed_at:=clock_timestamp();new.metrics_ocr_fields:=0;new.metrics_corrected_fields:=0;
    if old.status='recognized' and old.raw_result->'field_schema'='1'::jsonb then
      if new.final_ocr_fields is null then raise exception 'OCR field confirmation missing' using errcode='22023'; end if;
      foreach key in array array['prompt','options','answer','annotation'] loop
        if nullif(btrim(old.raw_result->'fields'->key->>'text'),'') is not null then
          new.metrics_ocr_fields:=new.metrics_ocr_fields+1;
          if btrim(old.raw_result->'fields'->key->>'text') is distinct from btrim(new.final_ocr_fields->>key) then new.metrics_corrected_fields:=new.metrics_corrected_fields+1; end if;
        end if;
      end loop;
    elsif old.status='recognized' then
      new.metrics_ocr_fields:=1;new.metrics_corrected_fields:=case when btrim(old.raw_text) is distinct from btrim(confirmed) then 1 else 0 end;
    end if;
  else
    new.metrics_confirmed_at:=old.metrics_confirmed_at;new.metrics_ocr_fields:=old.metrics_ocr_fields;new.metrics_corrected_fields:=old.metrics_corrected_fields;
    if old.question_id is not null then new.final_ocr_fields:=old.final_ocr_fields; end if;
  end if;
  return new;
end $$;

alter function public.save_review_question(uuid,jsonb,uuid) rename to save_review_question_before_ocr_fields;
create function public.save_review_question(target_child_id uuid,config jsonb,target_question_id uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare d public.question_ocr_drafts; family uuid;
begin
  select family_id into family from public.children where id=target_child_id;
  perform 1 from auth.users where id=auth.uid() for share;
  perform 1 from public.families where id=family for key share;
  perform public.require_parent_authorization(family);
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id::text,0));
  if config ? 'ocr_draft_id' then
    select * into d from public.question_ocr_drafts where id=(config->>'ocr_draft_id')::uuid for update;
    if not found or d.child_id<>target_child_id or d.owner_id is distinct from auth.uid() or d.requires_parent_review or d.deleting then
      raise exception 'OCR draft unavailable' using errcode='42501'; end if;
    perform 1 from public.parent_authorizations a where a.family_id=family and a.user_id=auth.uid()
      and a.session_id=auth.jwt()->>'session_id' and a.expires_at>clock_timestamp() for key share;
    if not found then raise exception 'Parent authorization expired' using errcode='42501'; end if;
    perform public.validate_ocr_field_correction(d.raw_result,config);
    if d.question_id is null then update public.question_ocr_drafts set final_ocr_fields=config->'ocr_corrections' where id=d.id; end if;
  else
    perform public.validate_ocr_field_correction(null,config);
  end if;
  return public.save_review_question_before_ocr_fields(target_child_id,config-array['ocr_corrections','ocr_field_confirmations'],target_question_id);
end $$;
revoke all on function public.save_review_question_before_ocr_fields(uuid,jsonb,uuid) from public,anon,authenticated,service_role;
revoke all on function public.save_review_question(uuid,jsonb,uuid) from public,anon,service_role;
grant execute on function public.save_review_question(uuid,jsonb,uuid) to authenticated;

alter function public.approve_child_question(uuid,uuid,jsonb) rename to approve_child_question_before_ocr_fields;
create function public.approve_child_question(target_draft_id uuid,request_id uuid,config jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d public.question_ocr_drafts; family uuid;
begin
  perform 1 from auth.users where id=auth.uid() for share;
  select c.family_id into family from public.children c join public.question_ocr_drafts q on q.child_id=c.id where q.id=target_draft_id;
  perform 1 from public.families where id=family for key share;
  perform public.require_parent_authorization(family);
  perform pg_advisory_xact_lock(hashtextextended('review:'||(select child_id::text from public.question_ocr_drafts where id=target_draft_id),0));
  select * into d from public.question_ocr_drafts where id=target_draft_id for update;
  if not found or not d.requires_parent_review or d.deleting or d.submitted_at is null then raise exception 'Submission unavailable' using errcode='42501'; end if;
  perform public.validate_ocr_field_correction(d.raw_result,config);
  if d.question_id is null then update public.question_ocr_drafts set final_ocr_fields=config->'ocr_corrections' where id=d.id; end if;
  return public.approve_child_question_before_ocr_fields(target_draft_id,request_id,config);
end $$;
revoke all on function public.approve_child_question_before_ocr_fields(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.approve_child_question(uuid,uuid,jsonb) from public,anon,service_role;
grant execute on function public.approve_child_question(uuid,uuid,jsonb) to authenticated;

create or replace function public.submit_child_question(target_draft_id uuid,config jsonb,recognition jsonb default null) returns jsonb
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
    or config-array['kind','subject','prompt','answers','context','knowledge_point','explanation','error_reason','error_reason_tags','pronunciation_confirmed','ocr_confirmed','requires_parent_review','ocr_corrections','ocr_field_confirmations']<>'{}'::jsonb then
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
  perform public.validate_ocr_field_correction(recognition,config);
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
