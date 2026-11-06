-- OCR uploads use family/draft paths. Child deletion must validate their actual
-- provenance, while also supporting older child/draft paths and cleanup jobs.
create or replace function public.request_child_deletion(target_child_id uuid,request_id uuid,expected_counts jsonb,confirmation text) returns uuid
language plpgsql security definer set search_path='' as $$
declare family uuid; previous public.cleanup_jobs; source jsonb; questions uuid[]; drafts uuid[]; worksheets uuid[];
  audit_targets text[]; deadline timestamptz; file jsonb;
begin
  if request_id is null or confirmation is distinct from '永久删除孩子' then raise exception '请输入永久删除孩子确认，无法恢复'; end if;
  perform pg_advisory_xact_lock(hashtextextended('cleanup:'||target_child_id::text,0));
  select * into previous from public.cleanup_jobs where id=request_id;
  if found then
    perform public.require_parent_authorization(previous.family_id);
    if previous.scope<>'child' or previous.child_id<>target_child_id or previous.owner_id is distinct from auth.uid()
      or not public.is_family_admin(previous.family_id) then raise exception '请求标识已用于其他操作' using errcode='42501'; end if;
    return previous.id;
  end if;
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if not public.is_family_admin(family) then raise exception '仅家庭管理员可以删除孩子' using errcode='42501'; end if;
  perform 1 from public.children where id=target_child_id for update;
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id::text,0));
  perform 1 from public.cleanup_jobs where child_id=target_child_id order by id for update;
  perform 1 from public.task_instances where child_id=target_child_id order by id for update;
  perform 1 from public.worksheet_jobs where child_id=target_child_id order by id for update;
  perform 1 from public.question_ocr_drafts where child_id=target_child_id order by id for update;
  source:=public.child_deletion_source(target_child_id);
  if expected_counts is distinct from source->'counts' then raise exception '删除范围已变化，请刷新并重新确认' using errcode='40001'; end if;
  for file in select value from jsonb_array_elements(source->'manifest') loop
    if not coalesce((
      file->>'bucket'='wrong-question-images'
      and file->>'path' ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/(original|processed)\.jpg$'
      and not exists(select 1 from public.question_ocr_drafts d where d.child_id<>target_child_id
        and file->>'path' in (d.original_path,d.processed_path))
      and (split_part(file->>'path','/',1)=target_child_id::text
        or (split_part(file->>'path','/',1)=family::text and (
          exists(select 1 from public.question_ocr_drafts d where d.child_id=target_child_id
            and file->>'path' in (d.original_path,d.processed_path))
          or exists(select 1 from public.cleanup_jobs j where j.child_id=target_child_id and j.family_id=family
            and split_part(file->>'path','/',2)=any(select d::text from unnest(j.draft_ids) d)
            and j.manifest @> jsonb_build_array(file)))))
      or file->>'bucket'='worksheets' and split_part(file->>'path','/',1) in (target_child_id::text,family::text)
        and file->>'path' ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/worksheet\.pdf$'),false) then
      raise exception '发现不属于支持范围的文件路径，删除未执行';
    end if;
  end loop;
  select coalesce(array_agg(id),'{}') into questions from public.wrong_questions where child_id=target_child_id;
  select coalesce(array_agg(id),'{}') into drafts from public.question_ocr_drafts where child_id=target_child_id;
  select coalesce(array_agg(id),'{}') into worksheets from public.worksheet_jobs where child_id=target_child_id;
  select greatest(now()+interval '10 minutes',coalesce(max(next_attempt_at),now())) into deadline
    from public.cleanup_jobs where child_id=target_child_id and status not in ('completed','superseded');
  select array_agg(id) into audit_targets from (
    select target_child_id::text id
    union select id::text from public.task_instances where child_id=target_child_id
    union select id::text from public.task_templates where child_id=target_child_id
    union select p.id::text from public.long_plans p join public.task_templates t on t.id=p.template_id where t.child_id=target_child_id
    union select id::text from public.wrong_questions where child_id=target_child_id
    union select id::text from public.question_ocr_drafts where child_id=target_child_id
    union select id::text from public.pending_coin_awards where child_id=target_child_id
    union select id::text from public.redemptions where child_id=target_child_id
    union select id::text from public.learning_events where child_id=target_child_id
    union select id::text from public.worksheet_jobs where child_id=target_child_id
    union select id::text from public.cleanup_jobs where child_id=target_child_id
  ) targets;
  insert into public.cleanup_jobs(id,family_id,child_id,owner_id,scope,question_ids,draft_ids,worksheet_ids,manifest,next_attempt_at)
    values(request_id,family,target_child_id,auth.uid(),'child',questions,drafts,worksheets,source->'manifest',deadline);
  update public.cleanup_jobs set status='superseded',superseded_by=request_id,manifest='[]',question_ids='{}',draft_ids='{}',worksheet_ids='{}',
    lease_token=null,lease_until=null,error_code=null where child_id=target_child_id and id<>request_id;
  delete from public.audit_logs where family_id=family and target_id=any(audit_targets);
  insert into public.child_deletion_tombstones(child_id,family_id) values(target_child_id,family);
  delete from public.task_review_answer_keys where question_id=any(questions)
    or task_id in(select id from public.task_instances where child_id=target_child_id);
  delete from public.children where id=target_child_id;
  return request_id;
end $$;
revoke all on function public.request_child_deletion(uuid,uuid,jsonb,text) from public,anon,authenticated,service_role;
grant execute on function public.request_child_deletion(uuid,uuid,jsonb,text) to authenticated;

-- Legacy child/draft paths also need the durable no-resurrection fence.
create or replace function public.preserve_deleted_ocr_draft() returns trigger
language plpgsql security definer set search_path='' as $$
declare family uuid;
begin
  family:=coalesce((select family_id from public.children where id=old.child_id),
    (select family_id from public.child_deletion_tombstones where child_id=old.child_id),
    (select id from public.families where id::text=split_part(old.original_path,'/',1)));
  if family is not null and exists(select 1 from public.families where id=family) then
    insert into public.deleted_ocr_drafts values(old.id,family) on conflict do nothing;
  end if;
  return old;
end $$;
revoke all on function public.preserve_deleted_ocr_draft() from public,anon,authenticated,service_role;
