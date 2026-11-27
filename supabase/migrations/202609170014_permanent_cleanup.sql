-- Persist trusted manifests before removing real Storage files. No SQL Storage DELETE.
alter table public.wrong_questions add column deleting boolean not null default false;
alter table public.question_ocr_drafts add column deleting boolean not null default false,
  add column original_deleted_at timestamptz;
alter table public.task_review_items drop constraint task_review_items_wrong_question_id_fkey;
alter table public.task_review_items add column source_deleted boolean not null default false;
create table public.cleanup_jobs (
  id uuid primary key,
  family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid not null,
  owner_id uuid not null references auth.users(id),
  scope text not null check(scope in ('questions','originals','abandoned_ocr')),
  question_ids uuid[] not null,
  draft_ids uuid[] not null,
  manifest jsonb not null,
  status text not null default 'queued' check(status in ('queued','running','failed','completed')),
  lease_token uuid,
  lease_until timestamptz,
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  error_code text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
alter table public.cleanup_jobs enable row level security;
revoke all on public.cleanup_jobs from public,anon,authenticated;
grant select on public.cleanup_jobs to authenticated;
grant select on public.cleanup_jobs to service_role;
create policy cleanup_parent_read on public.cleanup_jobs for select to authenticated
  using(public.can_manage_family(family_id));

create function public.preview_question_cleanup(target_child_id uuid, operation text, ids uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare family uuid; selected uuid[]; drafts uuid[]; paths jsonb; tasks integer;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if operation not in ('questions','originals','abandoned_ocr') or operation is null then raise exception '无效清理范围'; end if;
  if operation='abandoned_ocr' then
    selected:='{}';
    select coalesce(array_agg(id order by id),'{}') into drafts from public.question_ocr_drafts
      where child_id=target_child_id and owner_id=auth.uid() and question_id is null
      and created_at<now()-interval '1 day' and not deleting;
  else
    if cardinality(ids) is null or cardinality(ids) not between 1 and 100 or array_position(ids,null) is not null then raise exception '请选择1至100道题'; end if;
    select array_agg(distinct item order by item) into selected from unnest(ids) item;
    if exists(select 1 from unnest(selected) item where not exists(select 1 from public.wrong_questions
      where id=item and child_id=target_child_id and not deleting)) then raise exception '包含其他孩子或正在删除的错题'; end if;
    select coalesce(array_agg(id order by id),'{}') into drafts from public.question_ocr_drafts
      where question_id=any(selected) and (operation='questions' or original_deleted_at is null);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('bucket','wrong-question-images','path',p.path) order by p.path),'[]') into paths
    from (select original_path as path from public.question_ocr_drafts where id=any(drafts) and original_deleted_at is null
      union select processed_path from public.question_ocr_drafts where id=any(drafts) and operation<>'originals') p;
  select count(distinct t.id)::integer into tasks from public.task_instances t join public.task_review_items i on i.task_instance_id=t.id
    where i.wrong_question_id=any(selected) and t.status not in ('completed','skipped','expired');
  return jsonb_build_object('scope',operation,'question_ids',selected,'draft_ids',drafts,'manifest',paths,
    'questions',cardinality(selected),'drafts',cardinality(drafts),'files',jsonb_array_length(paths),
    'unfinished_reviews',case when operation='questions' then tasks else 0 end,
    'irreversible',true,'ledger_preserved',true);
end $$;

create function public.request_question_cleanup(target_child_id uuid, operation text, ids uuid[], request_id uuid, confirmation text)
returns uuid language plpgsql security definer set search_path='' as $$
declare family uuid; existing public.cleanup_jobs; preview jsonb; selected uuid[]; drafts uuid[];
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if request_id is null or confirmation is distinct from '永久删除' then raise exception '请明确确认永久删除，无法恢复'; end if;
  perform pg_advisory_xact_lock(hashtextextended('cleanup:'||target_child_id::text,0));
  select * into existing from public.cleanup_jobs where id=request_id;
  if found then
    if existing.child_id<>target_child_id or existing.owner_id<>auth.uid() or existing.scope<>operation
      or (operation<>'abandoned_ocr' and not (existing.question_ids @> ids and ids @> existing.question_ids)) then raise exception '清理标识已用于其他请求'; end if;
    return existing.id;
  end if;
  preview:=public.preview_question_cleanup(target_child_id,operation,ids);
  select coalesce(array_agg(value::uuid),'{}') into selected from jsonb_array_elements_text(preview->'question_ids');
  select coalesce(array_agg(value::uuid),'{}') into drafts from jsonb_array_elements_text(preview->'draft_ids');
  if cardinality(selected)=0 and cardinality(drafts)=0 then raise exception '没有可清理记录'; end if;
  if exists(select 1 from public.cleanup_jobs where child_id=target_child_id and status<>'completed'
    and (question_ids && selected or draft_ids && drafts)) then raise exception '已有相关清理任务，请先重试该任务'; end if;
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id::text,0));
  -- Same task-before-item/question order as grading; cancelled tasks cannot pay after the request.
  if operation='questions' then
    perform 1 from public.task_instances t where exists(select 1 from public.task_review_items i
      where i.task_instance_id=t.id and i.wrong_question_id=any(selected)) order by t.id for update;
    update public.task_instances t set status='skipped',active_started_at=null where status not in ('completed','skipped','expired')
      and exists(select 1 from public.task_review_items i where i.task_instance_id=t.id and i.wrong_question_id=any(selected));
    update public.wrong_questions set archived=true,deleting=true where id=any(selected);
  end if;
  update public.question_ocr_drafts set deleting=true where id=any(drafts);
  insert into public.cleanup_jobs(id,family_id,child_id,owner_id,scope,question_ids,draft_ids,manifest)
    values(request_id,family,target_child_id,auth.uid(),operation,selected,drafts,preview->'manifest');
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(family,auth.uid(),'cleanup.request','cleanup_job',request_id::text,
      jsonb_build_object('scope',operation,'questions',cardinality(selected),'files',preview->'files'));
  return request_id;
end $$;

create function public.guard_pending_cleanup() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.deleting and coalesce(auth.role(),'')<>'service_role' then raise exception '记录正在永久清理，禁止修改'; end if;
  return new;
end $$;
create trigger wrong_question_cleanup_guard before update on public.wrong_questions for each row execute function public.guard_pending_cleanup();
create trigger ocr_cleanup_guard before update on public.question_ocr_drafts for each row execute function public.guard_pending_cleanup();
-- Prevent new uploads to a manifest once a deletion has been authorized.
create function public.can_insert_question_image(object_path text) returns boolean
language plpgsql security definer set search_path='' as $$
declare draft public.question_ocr_drafts; family uuid;
begin
  -- The lock serializes in-flight Storage metadata insertion with cleanup marking.
  select * into draft from public.question_ocr_drafts where original_path=object_path or processed_path=object_path for share;
  if not found or draft.deleting or draft.original_deleted_at is not null or draft.status<>'pending'
    or draft.owner_id is distinct from auth.uid() then return false; end if;
  select family_id into family from public.children where id=draft.child_id;
  return public.can_manage_family(family);
end $$;
revoke all on function public.can_insert_question_image(text) from public,anon;
grant execute on function public.can_insert_question_image(text) to authenticated;
drop policy question_image_insert on storage.objects;
create policy question_image_insert on storage.objects for insert to authenticated with check (
  bucket_id='wrong-question-images' and public.can_insert_question_image(name));

create function public.claim_cleanup_job(target_job_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job public.cleanup_jobs; token uuid;
begin
  select * into job from public.cleanup_jobs where id=target_job_id for update;
  if not found then raise exception '清理任务不存在'; end if;
  if coalesce(auth.role(),'')<>'service_role' then
    perform public.require_parent_authorization(job.family_id);
  end if;
  if job.status='completed' then return jsonb_build_object('id',job.id,'status','completed'); end if;
  if job.status='running' and job.lease_until>now() then return jsonb_build_object('id',job.id,'status','running'); end if;
  token:=gen_random_uuid();
  update public.cleanup_jobs set status='running',lease_token=token,lease_until=now()+interval '5 minutes',
    attempts=attempts+1,error_code=null where id=job.id;
  return jsonb_build_object('id',job.id,'status','claimed','lease_token',token,'manifest',job.manifest);
end $$;

create function public.finish_cleanup_job(target_job_id uuid, token uuid, failure_code text default null) returns void
language plpgsql security definer set search_path='' as $$
declare job public.cleanup_jobs;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Trusted cleanup worker required' using errcode='42501'; end if;
  select * into job from public.cleanup_jobs where id=target_job_id for update;
  if not found or job.status<>'running' or job.lease_token is distinct from token or job.lease_until<now() then raise exception '清理执行租约已失效'; end if;
  if failure_code is not null then
    update public.cleanup_jobs set status='failed',error_code=left(failure_code,80),lease_token=null,lease_until=null where id=job.id;
    update public.cleanup_jobs set next_attempt_at=now()+make_interval(secs => least(21600,30*power(2,least(attempts,10)))::integer) where id=job.id;
    return;
  end if;
  -- The worker must call Storage API first. Metadata still present is independent failure evidence.
  if exists(select 1 from jsonb_array_elements(job.manifest) p join storage.objects o
    on o.bucket_id=p->>'bucket' and o.name=p->>'path') then raise exception '真实图片删除尚未完成'; end if;
  if job.scope='questions' then
    perform 1 from public.task_instances t where exists(select 1 from public.task_review_items i
      where i.task_instance_id=t.id and i.wrong_question_id=any(job.question_ids)) order by t.id for update;
    update public.task_review_items set prompt=null,subject=null,knowledge_point=null,pronunciation_context=null,
      answer_text=null,source_deleted=true where wrong_question_id=any(job.question_ids);
    delete from public.task_review_answer_keys where question_id=any(job.question_ids);
    delete from public.question_ocr_drafts where id=any(job.draft_ids);
    delete from public.wrong_questions where id=any(job.question_ids);
  elsif job.scope='originals' then
    update public.question_ocr_drafts set original_deleted_at=now(),deleting=false where id=any(job.draft_ids);
  else
    delete from public.question_ocr_drafts where id=any(job.draft_ids) and question_id is null;
  end if;
  update public.cleanup_jobs set status='completed',completed_at=now(),lease_token=null,lease_until=null,error_code=null,manifest='[]' where id=job.id;
  insert into public.audit_logs(family_id,actor_user_id,action,target_type,target_id,details)
    values(job.family_id,job.owner_id,'cleanup.completed','cleanup_job',job.id::text,jsonb_build_object('scope',job.scope));
end $$;

create function public.pending_cleanup_jobs() returns uuid[]
language plpgsql security definer set search_path='' as $$
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Trusted cleanup dispatcher required' using errcode='42501'; end if;
  return array(select id from public.cleanup_jobs where
    (status in ('queued','failed') and next_attempt_at<=now()) or (status='running' and lease_until<=now())
    order by created_at,id limit 5);
end $$;
-- Until profile deletion uses its own cleanup job, do not let the old SQL-only
-- endpoint orphan real files or remove active cleanup authorization records.
create function public.guard_child_media_delete() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.cleanup_jobs where child_id=old.id and status<>'completed')
    or exists(select 1 from public.question_ocr_drafts d join storage.objects o
      on o.bucket_id='wrong-question-images' and o.name in (d.original_path,d.processed_path) where d.child_id=old.id) then
    raise exception '请先完成该孩子的真实图片永久清理，再删除档案';
  end if;
  return old;
end $$;
create trigger child_media_delete_guard before delete on public.children for each row execute function public.guard_child_media_delete();
revoke all on function public.pending_cleanup_jobs(),public.guard_child_media_delete() from public,anon,authenticated;
grant execute on function public.pending_cleanup_jobs() to service_role;

revoke all on function public.guard_pending_cleanup(),public.preview_question_cleanup(uuid,text,uuid[]),
  public.request_question_cleanup(uuid,text,uuid[],uuid,text),public.claim_cleanup_job(uuid),public.finish_cleanup_job(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.preview_question_cleanup(uuid,text,uuid[]),public.request_question_cleanup(uuid,text,uuid[],uuid,text),public.claim_cleanup_job(uuid) to authenticated;
grant execute on function public.claim_cleanup_job(uuid),public.finish_cleanup_job(uuid,uuid,text) to service_role;
