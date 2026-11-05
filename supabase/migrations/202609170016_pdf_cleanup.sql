-- PDF deletion uses the existing durable Storage API worker, never SQL object deletion.
alter table public.cleanup_jobs drop constraint cleanup_jobs_scope_check;
alter table public.cleanup_jobs add constraint cleanup_jobs_scope_check
  check(scope in ('questions','originals','abandoned_ocr','worksheets'));
alter table public.cleanup_jobs add column worksheet_ids uuid[] not null default '{}';

create function public.attach_cleanup_worksheets() returns trigger
language plpgsql security definer set search_path='' as $$
declare pdfs jsonb; deadline timestamptz;
begin
  if new.scope='questions' then
    -- Hide historical source content at authorization time, not only after the
    -- asynchronous physical delete. Results, task IDs and ledger remain intact.
    update public.task_review_items set prompt=null,subject=null,knowledge_point=null,
      pronunciation_context=null,answer_text=null,source_deleted=true
      where wrong_question_id=any(new.question_ids);
    delete from public.task_review_answer_keys where question_id=any(new.question_ids);
    select coalesce(array_agg(id order by id),'{}') into new.worksheet_ids
      from public.worksheet_jobs where child_id=new.child_id and question_ids && new.question_ids
      and status<>'deleted';
  end if;
  if cardinality(new.worksheet_ids)=0 then return new; end if;
  perform 1 from public.worksheet_jobs where id=any(new.worksheet_ids) order by id for update;
  -- A previously authorized upload can outlive its SQL lease check. Wait beyond
  -- the old generation lease plus the maximum hosted worker lifetime (400s).
  select max(lease_until+interval '10 minutes') into deadline from public.worksheet_jobs
    where id=any(new.worksheet_ids) and status='running';
  new.next_attempt_at:=greatest(new.next_attempt_at,coalesce(deadline,now()));
  select coalesce(jsonb_agg(jsonb_build_object('bucket','worksheets','path',pdf_path) order by id),'[]')
    into pdfs from public.worksheet_jobs where id=any(new.worksheet_ids);
  -- Source cleanup previews already include PDF paths. De-duplicate the final
  -- trusted manifest (explicit PDF deletion starts with an empty manifest).
  select coalesce(jsonb_agg(value),'[]') into new.manifest
    from (select distinct value from jsonb_array_elements(new.manifest||pdfs)) files;
  update public.worksheet_jobs set status='deleting',lease_token=null,lease_until=null
    where id=any(new.worksheet_ids);
  return new;
end $$;
create trigger attach_cleanup_worksheets before insert on public.cleanup_jobs
  for each row execute function public.attach_cleanup_worksheets();
revoke all on function public.attach_cleanup_worksheets() from public,anon,authenticated;

create function public.request_worksheet_cleanup(target_worksheet_id uuid, request_id uuid, confirmation text)
returns uuid language plpgsql security definer set search_path='' as $$
declare job public.worksheet_jobs; existing public.cleanup_jobs;
begin
  select * into job from public.worksheet_jobs where id=target_worksheet_id;
  if not found then raise exception '组卷不存在'; end if;
  perform public.require_parent_authorization(job.family_id);
  if request_id is null or confirmation is distinct from '永久删除' then raise exception '请明确确认永久删除'; end if;
  perform pg_advisory_xact_lock(hashtextextended('cleanup:'||job.child_id::text,0));
  select * into job from public.worksheet_jobs where id=target_worksheet_id for update;
  select * into existing from public.cleanup_jobs where id=request_id;
  if found then
    if existing.scope<>'worksheets' or existing.owner_id<>auth.uid()
      or existing.worksheet_ids<>array[target_worksheet_id] then raise exception '清理标识已用于其他请求'; end if;
    return existing.id;
  end if;
  if job.status in ('deleting','deleted') then
    select * into existing from public.cleanup_jobs where target_worksheet_id=any(worksheet_ids)
      order by created_at desc limit 1;
    if found then return existing.id; end if;
    raise exception '组卷已删除';
  end if;
  insert into public.cleanup_jobs(id,family_id,child_id,owner_id,scope,question_ids,draft_ids,manifest,worksheet_ids)
    values(request_id,job.family_id,job.child_id,auth.uid(),'worksheets','{}','{}','[]',array[job.id]);
  return request_id;
end $$;
revoke all on function public.request_worksheet_cleanup(uuid,uuid,text) from public,anon;
grant execute on function public.request_worksheet_cleanup(uuid,uuid,text) to authenticated;

alter function public.claim_cleanup_job(uuid) rename to claim_cleanup_job_base;
revoke all on function public.claim_cleanup_job_base(uuid) from public,anon,authenticated,service_role;
create function public.claim_cleanup_job(target_job_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job public.cleanup_jobs;
begin
  select * into job from public.cleanup_jobs where id=target_job_id for update;
  if not found then raise exception '清理任务不存在'; end if;
  if coalesce(auth.role(),'')<>'service_role' then perform public.require_parent_authorization(job.family_id); end if;
  if cardinality(job.worksheet_ids)>0 and job.status<>'completed' and job.next_attempt_at>now() then
    return jsonb_build_object('id',job.id,'status','queued','next_attempt_at',job.next_attempt_at);
  end if;
  return public.claim_cleanup_job_base(target_job_id);
end $$;
revoke all on function public.claim_cleanup_job(uuid) from public,anon;
grant execute on function public.claim_cleanup_job(uuid) to authenticated,service_role;

alter function public.finish_cleanup_job(uuid,uuid,text) rename to finish_cleanup_job_base;
revoke all on function public.finish_cleanup_job_base(uuid,uuid,text) from public,anon,authenticated,service_role;
create function public.finish_cleanup_job(target_job_id uuid, token uuid, failure_code text default null)
returns void language plpgsql security definer set search_path='' as $$
declare job public.cleanup_jobs;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Trusted cleanup worker required' using errcode='42501'; end if;
  select * into job from public.cleanup_jobs where id=target_job_id for update;
  if cardinality(job.worksheet_ids)>0 and job.next_attempt_at>now() then raise exception '等待旧生成进程结束'; end if;
  perform public.finish_cleanup_job_base(target_job_id,token,failure_code);
  if failure_code is null then
    delete from public.worksheet_items where worksheet_id=any(job.worksheet_ids);
    update public.worksheet_jobs set status='deleted',config='{}',question_ids='{}',sha256=null,
      byte_size=null,pages=null,progress=0,error_code=null where id=any(job.worksheet_ids);
    -- Keep stable PDF path tombstones. IDs cannot be reused for a late upload.
  end if;
end $$;
revoke all on function public.finish_cleanup_job(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.finish_cleanup_job(uuid,uuid,text) to service_role;

create function public.enqueue_expired_worksheets() returns integer
language plpgsql security definer set search_path='' as $$
declare job public.worksheet_jobs; total integer:=0;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'Trusted retention dispatcher required' using errcode='42501'; end if;
  for job in select * from public.worksheet_jobs where expires_at<=now()
    and status not in ('deleting','deleted') order by expires_at,id limit 25 for update skip locked loop
    insert into public.cleanup_jobs(id,family_id,child_id,owner_id,scope,question_ids,draft_ids,manifest,worksheet_ids)
      values(gen_random_uuid(),job.family_id,job.child_id,job.owner_id,'worksheets','{}','{}','[]',array[job.id]);
    total:=total+1;
  end loop;
  return total;
end $$;
revoke all on function public.enqueue_expired_worksheets() from public,anon,authenticated;
grant execute on function public.enqueue_expired_worksheets() to service_role;

alter function public.preview_question_cleanup(uuid,text,uuid[]) rename to preview_question_cleanup_base;
revoke all on function public.preview_question_cleanup_base(uuid,text,uuid[]) from public,anon,authenticated,service_role;
create function public.preview_question_cleanup(target_child_id uuid, operation text, ids uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; pdfs jsonb; selected uuid[]; running integer;
begin
  result:=public.preview_question_cleanup_base(target_child_id,operation,ids);
  select coalesce(array_agg(value::uuid),'{}') into selected from jsonb_array_elements_text(result->'question_ids');
  select coalesce(jsonb_agg(jsonb_build_object('bucket','worksheets','path',pdf_path) order by id),'[]'),
    count(*) filter(where status='running')::integer into pdfs,running from public.worksheet_jobs
    where operation='questions' and child_id=target_child_id and question_ids && selected and status<>'deleted';
  return result||jsonb_build_object('manifest',(result->'manifest')||pdfs,
    'files',(result->>'files')::integer+jsonb_array_length(pdfs),
    'worksheets',jsonb_array_length(pdfs),'running_worksheets',running);
end $$;
revoke all on function public.preview_question_cleanup(uuid,text,uuid[]) from public,anon;
grant execute on function public.preview_question_cleanup(uuid,text,uuid[]) to authenticated;
