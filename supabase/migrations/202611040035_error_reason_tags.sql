-- PRD ERR-04: explicit reviewed labels; never infer labels from legacy prose.
alter table public.wrong_questions add column error_reason_tags text[] not null default '{}'
  check (error_reason_tags <@ array['reading','concept','calculation','handwriting','memory','other']::text[]
    and array_position(error_reason_tags,null) is null and cardinality(error_reason_tags)<=6);

alter function public.save_review_question(uuid,jsonb,uuid) rename to save_review_question_before_reason_tags;
create function public.save_review_question(target_child_id uuid,config jsonb,target_question_id uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare family uuid; question uuid; tags text[]; saved_ocr boolean:=false;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id::text,0));
  if config ? 'error_reason_tags' then
    if jsonb_typeof(config->'error_reason_tags') is distinct from 'array' then
      raise exception '错误原因标签必须为列表';
    end if;
    if jsonb_array_length(config->'error_reason_tags')>6 or exists (
      select 1 from jsonb_array_elements(config->'error_reason_tags') t(value)
      where jsonb_typeof(value)<>'string' or (value#>>'{}') not in ('reading','concept','calculation','handwriting','memory','other')
    ) then raise exception '错误原因标签不正确'; end if;
    select coalesce(array_agg(value order by array_position(array['reading','concept','calculation','handwriting','memory','other']::text[],value)),'{}'::text[])
      into tags from jsonb_array_elements_text(config->'error_reason_tags') t(value);
    if cardinality(tags)<>(select count(distinct value) from unnest(tags) t(value)) then
      raise exception '错误原因标签不能重复';
    end if;
  end if;
  -- An OCR retry returns the original question; it must not replace its labels.
  -- The existing inner RPC still verifies draft owner, child and lifecycle.
  if config ? 'ocr_draft_id' then
    select status='saved' into saved_ocr from public.question_ocr_drafts
      where id=(config->>'ocr_draft_id')::uuid;
  end if;
  question:=public.save_review_question_before_reason_tags(target_child_id,config,target_question_id);
  if config ? 'error_reason_tags' and not coalesce(saved_ocr,false) then
    update public.wrong_questions set error_reason_tags=tags where id=question;
  end if;
  return question;
end $$;
revoke all on function public.save_review_question_before_reason_tags(uuid,jsonb,uuid),public.save_review_question(uuid,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.save_review_question(uuid,jsonb,uuid) to authenticated;
