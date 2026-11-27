-- Business data is erased atomically with a durable, trusted file-deletion manifest.
-- A completed job means Storage API deletion AND absence verification succeeded.
alter table public.cleanup_jobs drop constraint cleanup_jobs_scope_check;
alter table public.cleanup_jobs add constraint cleanup_jobs_scope_check
  check(scope in ('questions','originals','abandoned_ocr','worksheets','child'));
alter table public.cleanup_jobs drop constraint cleanup_jobs_status_check;
alter table public.cleanup_jobs add constraint cleanup_jobs_status_check
  check(status in ('queued','running','failed','completed','superseded'));
alter table public.cleanup_jobs add column superseded_by uuid references public.cleanup_jobs(id) on delete set null;
drop policy cleanup_parent_read on public.cleanup_jobs;
create policy cleanup_parent_read on public.cleanup_jobs for select to authenticated
  using(public.can_manage_family(family_id) and (scope<>'child' or public.is_family_admin(family_id)));

-- No nickname, answer, file path or account identity is retained here. Members use
-- these IDs to erase stale device caches after reconnecting, including child mode.
create table public.child_deletion_tombstones(
  child_id uuid primary key, family_id uuid not null references public.families(id) on delete cascade,
  deleted_at timestamptz not null default now());
alter table public.child_deletion_tombstones enable row level security;
revoke all on public.child_deletion_tombstones from public,anon,authenticated;
grant select on public.child_deletion_tombstones to authenticated;
create policy deleted_children_member_read on public.child_deletion_tombstones for select to authenticated
  using(public.is_family_member(family_id));

create function public.child_deletion_source(target_child_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  with files as (
    select 'wrong-question-images'::text bucket,original_path path from public.question_ocr_drafts where child_id=target_child_id
    union select 'wrong-question-images',processed_path from public.question_ocr_drafts where child_id=target_child_id
    union select 'worksheets',pdf_path from public.worksheet_jobs where child_id=target_child_id
    union select p->>'bucket',p->>'path' from public.cleanup_jobs j cross join lateral jsonb_array_elements(j.manifest) p where j.child_id=target_child_id
    union select bucket_id,name from storage.objects where bucket_id in ('wrong-question-images','worksheets') and name like target_child_id::text||'/%'
  ), manifest as (select coalesce(jsonb_agg(jsonb_build_object('bucket',bucket,'path',path) order by bucket,path),'[]') value from files where path is not null)
  select jsonb_build_object('manifest',manifest.value,'counts',jsonb_build_object(
    'tasks',(select count(*) from public.task_instances where child_id=target_child_id),
    'templates',(select count(*) from public.task_templates where child_id=target_child_id),
    'questions',(select count(*) from public.wrong_questions where child_id=target_child_id),
    'ocr_drafts',(select count(*) from public.question_ocr_drafts where child_id=target_child_id),
    'worksheets',(select count(*) from public.worksheet_jobs where child_id=target_child_id),
    'redemptions',(select count(*) from public.redemptions where child_id=target_child_id),
    'ledger_entries',(select count(*) from public.ledger_entries where child_id=target_child_id),
    'coins',coalesce((select coin_balance from public.wallets where child_id=target_child_id),0),
    'frozen_coins',coalesce((select frozen_balance from public.wallets where child_id=target_child_id),0),
    'xp',coalesce((select xp from public.wallets where child_id=target_child_id),0),
    'files',jsonb_array_length(manifest.value))) from manifest;
$$;
revoke all on function public.child_deletion_source(uuid) from public,anon,authenticated,service_role;

create function public.preview_child_deletion(target_child_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare family uuid; source jsonb;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if not public.is_family_admin(family) then raise exception '仅家庭管理员可以删除孩子' using errcode='42501'; end if;
  source:=public.child_deletion_source(target_child_id);
  return jsonb_build_object('child_id',target_child_id,'family_id',family,'counts',source->'counts',
    'irreversible',true,'business_retention_days',0,'file_wait_minutes',10,'job_retention_days',30,
    'identity_tombstone_until_family_deletion',true);
end $$;
revoke all on function public.preview_child_deletion(uuid) from public,anon;
grant execute on function public.preview_child_deletion(uuid) to authenticated;

-- The legacy direct endpoint must not bypass the preview/confirmation contract.
create or replace function public.delete_child(target_child_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin raise exception '请通过永久删除入口预览范围并确认'; end $$;
revoke all on function public.delete_child(uuid),public.delete_child_internal(uuid) from public,anon,authenticated,service_role;

create or replace function public.guard_child_media_delete() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.cleanup_jobs j where j.child_id=old.id and j.scope='child' and j.status='queued'
    and j.owner_id=auth.uid() and public.is_family_admin(old.family_id) and public.has_parent_authorization(old.family_id)) then
    return old;
  end if;
  if exists(select 1 from public.cleanup_jobs where child_id=old.id and status not in ('completed','superseded'))
    or exists(select 1 from public.question_ocr_drafts d join storage.objects o
      on o.bucket_id='wrong-question-images' and o.name in (d.original_path,d.processed_path) where d.child_id=old.id)
    or exists(select 1 from public.worksheet_jobs j where j.child_id=old.id and
      (j.status<>'deleted' or exists(select 1 from storage.objects o where o.bucket_id='worksheets' and o.name=j.pdf_path))) then
    raise exception '请通过持久化删除任务清理该孩子的文件';
  end if;
  return old;
end $$;

create function public.request_child_deletion(target_child_id uuid,request_id uuid,expected_counts jsonb,confirmation text) returns uuid
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
  -- Child row lock blocks new foreign-key inserts before the final manifest is captured.
  perform 1 from public.children where id=target_child_id for update;
  perform pg_advisory_xact_lock(hashtextextended('review:'||target_child_id::text,0));
  perform 1 from public.cleanup_jobs where child_id=target_child_id order by id for update;
  perform 1 from public.task_instances where child_id=target_child_id order by id for update;
  perform 1 from public.worksheet_jobs where child_id=target_child_id order by id for update;
  perform 1 from public.question_ocr_drafts where child_id=target_child_id order by id for update;
  source:=public.child_deletion_source(target_child_id);
  if expected_counts is distinct from source->'counts' then raise exception '删除范围已变化，请刷新并重新确认' using errcode='40001'; end if;
  for file in select value from jsonb_array_elements(source->'manifest') loop
    if not (
      file->>'bucket'='wrong-question-images' and split_part(file->>'path','/',1)=target_child_id::text
        and file->>'path' ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/(original|processed)\.jpg$'
      or file->>'bucket'='worksheets' and split_part(file->>'path','/',1) in (target_child_id::text,family::text)
        and file->>'path' ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/worksheet\.pdf$') then
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
  -- The insert triggers revoke exports, revoke PDF leases and extend the wait past old workers.
  update public.cleanup_jobs set status='superseded',superseded_by=request_id,manifest='[]',question_ids='{}',draft_ids='{}',worksheet_ids='{}',
    lease_token=null,lease_until=null,error_code=null where child_id=target_child_id and id<>request_id;
  delete from public.audit_logs where family_id=family and target_id=any(audit_targets);
  insert into public.child_deletion_tombstones(child_id,family_id) values(target_child_id,family);
  -- The question FK uses RESTRICT and is checked before the child's task cascade.
  delete from public.task_review_answer_keys where question_id=any(questions)
    or task_id in(select id from public.task_instances where child_id=target_child_id);
  delete from public.children where id=target_child_id;
  return request_id;
end $$;
revoke all on function public.request_child_deletion(uuid,uuid,jsonb,text) from public,anon;
grant execute on function public.request_child_deletion(uuid,uuid,jsonb,text) to authenticated;

alter function public.claim_cleanup_job(uuid) rename to claim_cleanup_job_before_child;
revoke all on function public.claim_cleanup_job_before_child(uuid) from public,anon,authenticated,service_role;
create function public.claim_cleanup_job(target_job_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job public.cleanup_jobs;
begin
  select * into job from public.cleanup_jobs where id=target_job_id for update;
  if not found then raise exception '清理任务不存在'; end if;
  if auth.role() is distinct from 'service_role' then
    perform public.require_parent_authorization(job.family_id);
    if job.scope='child' and not public.is_family_admin(job.family_id) then raise exception '仅管理员可以操作孩子删除' using errcode='42501'; end if;
  end if;
  if job.status='superseded' then return jsonb_build_object('id',job.id,'status','superseded','superseded_by',job.superseded_by); end if;
  if job.scope='child' and job.status<>'completed' and job.next_attempt_at>now() then
    return jsonb_build_object('id',job.id,'status','queued','next_attempt_at',job.next_attempt_at); end if;
  return public.claim_cleanup_job_before_child(target_job_id);
end $$;
revoke all on function public.claim_cleanup_job(uuid) from public,anon;
grant execute on function public.claim_cleanup_job(uuid) to authenticated,service_role;

alter function public.finish_cleanup_job(uuid,uuid,text) rename to finish_cleanup_job_before_child;
revoke all on function public.finish_cleanup_job_before_child(uuid,uuid,text) from public,anon,authenticated,service_role;
create function public.finish_cleanup_job(target_job_id uuid,token uuid,failure_code text default null) returns void
language plpgsql security definer set search_path='' as $$
declare job public.cleanup_jobs;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Trusted cleanup worker required' using errcode='42501'; end if;
  select * into job from public.cleanup_jobs where id=target_job_id for update;
  if job.scope is distinct from 'child' then perform public.finish_cleanup_job_before_child(target_job_id,token,failure_code); return; end if;
  if job.status='completed' and failure_code is null then return; end if;
  if job.status<>'running' or job.lease_token is distinct from token or job.lease_until<=now() or job.next_attempt_at>now() then
    raise exception '删除执行租约已失效'; end if;
  if failure_code is not null then
    update public.cleanup_jobs set status='failed',error_code=case when failure_code in ('INVALID_MANIFEST','STORAGE_REMOVE_FAILED','STORAGE_VERIFY_FAILED','CLEANUP_FINISH_FAILED')
      then failure_code else 'CLEANUP_FINISH_FAILED' end,lease_token=null,lease_until=null,
      next_attempt_at=now()+make_interval(secs=>least(21600,30*power(2,least(attempts,10)))::integer) where id=job.id;
    return;
  end if;
  if exists(select 1 from jsonb_array_elements(job.manifest) p join storage.objects o on o.bucket_id=p->>'bucket' and o.name=p->>'path')
    or exists(select 1 from storage.objects where bucket_id in ('wrong-question-images','worksheets') and name like job.child_id::text||'/%') then
    raise exception '文件尚未确认删除'; end if;
  if exists(select 1 from public.children where id=job.child_id) then raise exception '孩子业务数据尚未删除'; end if;
  delete from public.cleanup_jobs where superseded_by=job.id;
  update public.cleanup_jobs set status='completed',completed_at=now(),manifest='[]',question_ids='{}',draft_ids='{}',worksheet_ids='{}',
    lease_token=null,lease_until=null,error_code=null where id=job.id;
end $$;
revoke all on function public.finish_cleanup_job(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.finish_cleanup_job(uuid,uuid,text) to service_role;

create function public.child_deletion_history(target_family_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  perform public.require_parent_authorization(target_family_id);
  if not public.is_family_admin(target_family_id) then raise exception '仅家庭管理员可以查看孩子删除记录' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'child_id',child_id,'status',status,'attempts',attempts,
    'error_code',error_code,'created_at',created_at,'completed_at',completed_at,'next_attempt_at',next_attempt_at) order by created_at desc,id)
    from public.cleanup_jobs where family_id=target_family_id and scope='child'),'[]');
end $$;
revoke all on function public.child_deletion_history(uuid) from public,anon;
grant execute on function public.child_deletion_history(uuid) to authenticated;

-- Called by the existing trusted drain before dispatch, so no new service is needed.
alter function public.enqueue_expired_worksheets() rename to enqueue_expired_worksheets_before_child;
revoke all on function public.enqueue_expired_worksheets_before_child() from public,anon,authenticated,service_role;
create function public.enqueue_expired_worksheets() returns integer
language plpgsql security definer set search_path='' as $$
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Trusted maintenance required' using errcode='42501'; end if;
  delete from public.cleanup_jobs where scope='child' and status='completed' and completed_at<now()-interval '30 days';
  return public.enqueue_expired_worksheets_before_child();
end $$;
revoke all on function public.enqueue_expired_worksheets() from public,anon,authenticated;
grant execute on function public.enqueue_expired_worksheets() to service_role;

create function public.guard_family_pending_files() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.cleanup_jobs where family_id=old.id and status in ('queued','running','failed')) then
    raise exception '家庭仍有未完成的文件清理，请等待完成后再删除家庭'; end if;
  return old;
end $$;
create trigger family_pending_files before delete on public.families for each row execute function public.guard_family_pending_files();
revoke all on function public.guard_family_pending_files() from public,anon,authenticated,service_role;
