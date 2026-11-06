-- Self-account deletion: durable file work, then family cleanup, then Auth Admin API.
-- Auth and Storage records are never deleted directly by these functions.
create table public.account_deletion_jobs (
  id uuid primary key, user_id uuid not null unique, owned_family_ids uuid[] not null,
  child_ids uuid[] not null, manifest jsonb not null,
  status text not null default 'queued' check(status in ('queued','running','failed','completed')),
  phase text not null default 'files' check(phase in ('files','auth','done')),
  lease_token uuid, lease_until timestamptz, attempts integer not null default 0,
  next_attempt_at timestamptz not null, error_code text,
  created_at timestamptz not null default now(), target_at timestamptz not null default now()+interval '24 hours',
  completed_at timestamptz
);
alter table public.account_deletion_jobs enable row level security;
revoke all on public.account_deletion_jobs from public,anon,authenticated,service_role;

-- These UUID-only notices survive family dissolution so other devices can purge
-- caches. No account can read another account's notices, including family admins.
create table public.family_access_revocations (
  user_id uuid not null references auth.users(id) on delete cascade,
  family_id uuid not null, child_ids uuid[] not null, created_at timestamptz not null default now(),
  primary key(user_id,family_id)
);
alter table public.family_access_revocations enable row level security;
revoke all on public.family_access_revocations from public,anon,authenticated;
grant select on public.family_access_revocations to authenticated;
create policy own_family_revocations on public.family_access_revocations for select to authenticated using(user_id=auth.uid());

-- Reserve erased source UUID paths while a surviving shared family exists. An
-- old request ID cannot recreate a file after the account worker verified it.
create table public.deleted_account_media (
  family_id uuid references public.families(id) on delete cascade,
  bucket text not null, path text not null, primary key(bucket,path)
);
alter table public.deleted_account_media enable row level security;
revoke all on public.deleted_account_media from public,anon,authenticated,service_role;
create function public.guard_deleted_account_media() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_table_name='question_ocr_drafts' then
    if exists(select 1 from public.deleted_account_media where bucket='wrong-question-images' and path in(new.original_path,new.processed_path)) then
      raise exception '图片标识已永久删除，请使用新标识'; end if;
  elsif exists(select 1 from public.deleted_account_media where bucket='worksheets' and path=new.pdf_path) then
    raise exception '组卷标识已永久删除，请使用新标识';
  end if;
  return new;
end $$;
revoke all on function public.guard_deleted_account_media() from public,anon,authenticated,service_role;
create trigger erased_account_image before insert or update of original_path,processed_path on public.question_ocr_drafts
  for each row execute function public.guard_deleted_account_media();
create trigger erased_account_pdf before insert or update of pdf_path on public.worksheet_jobs
  for each row execute function public.guard_deleted_account_media();

create function public.account_is_active(target_user uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from auth.users where id=target_user)
    and not exists(select 1 from public.account_deletion_jobs where user_id=target_user);
$$;
revoke all on function public.account_is_active(uuid) from public,anon,authenticated,service_role;

create or replace function public.is_family_member(target_family_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select public.account_is_active(auth.uid())
    and exists(select 1 from public.family_members where family_id=target_family_id and user_id=auth.uid())
    and not exists(select 1 from public.account_deletion_jobs where target_family_id=any(owned_family_ids));
$$;
create or replace function public.is_family_admin(target_family_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select public.is_family_member(target_family_id)
    and exists(select 1 from public.family_members where family_id=target_family_id and user_id=auth.uid() and role='admin');
$$;
drop policy families_select on public.families;
create policy families_select on public.families for select to authenticated using(public.is_family_member(id));

-- Serialize account-owned inserts with the self-deletion transaction. This also
-- blocks an unexpired JWT from recreating a family or accepting new invitations.
create function public.guard_active_account_write() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if auth.role()='authenticated' then
    perform 1 from auth.users where id=auth.uid() for share;
    if not public.account_is_active(auth.uid()) then raise exception '账号已申请注销' using errcode='42501'; end if;
  end if;
  return new;
end $$;
revoke all on function public.guard_active_account_write() from public,anon,authenticated,service_role;
do $$ declare t text; begin
  foreach t in array array['families','family_members','family_invitations','parent_authorizations','question_ocr_drafts','worksheet_jobs','cleanup_jobs'] loop
    execute format('create trigger active_account_write before insert or update on public.%I for each row execute function public.guard_active_account_write()',t);
  end loop;
end $$;

create function public.guard_deleting_family_child() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  perform 1 from public.families where id=new.family_id for key share;
  if exists(select 1 from public.account_deletion_jobs where new.family_id=any(owned_family_ids)) then
    raise exception '家庭正在注销，不能新增或修改孩子' using errcode='42501'; end if;
  return new;
end $$;
revoke all on function public.guard_deleting_family_child() from public,anon,authenticated,service_role;
create trigger deleting_family_child before insert or update on public.children for each row execute function public.guard_deleting_family_child();

-- Shared-family history remains useful without retaining a deleted Auth identity.
alter table public.cleanup_jobs alter column owner_id drop not null;
alter table public.cleanup_jobs drop constraint cleanup_jobs_owner_id_fkey;
alter table public.cleanup_jobs add foreign key(owner_id) references auth.users(id) on delete set null;
alter table public.audit_logs drop constraint audit_logs_actor_user_id_fkey;
alter table public.audit_logs add foreign key(actor_user_id) references auth.users(id) on delete set null;
alter table public.pending_coin_awards drop constraint pending_coin_awards_actor_id_fkey;
alter table public.pending_coin_awards add foreign key(actor_id) references auth.users(id) on delete set null;
alter table public.redemptions drop constraint redemptions_actor_id_fkey;
alter table public.redemptions add foreign key(actor_id) references auth.users(id) on delete set null;

create function public.account_deletion_context() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if not public.account_is_active(auth.uid()) then raise exception '账号不可用' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',f.id,'name',f.name,
    'owned',f.owner_user_id=auth.uid(),'authorized',public.has_parent_authorization(f.id),
    'authorized_until',(select expires_at from public.parent_authorizations where family_id=f.id and user_id=auth.uid() and session_id=auth.jwt()->>'session_id')) order by f.id)
    from public.families f join public.family_members m on m.family_id=f.id where m.user_id=auth.uid()),'[]');
end $$;
revoke all on function public.account_deletion_context() from public,anon;
grant execute on function public.account_deletion_context() to authenticated;

create function public.account_deletion_source(target_user uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare families uuid[]; children uuid[]; files jsonb; scope jsonb;
begin
  select coalesce(array_agg(id order by id),'{}') into families from public.families where owner_user_id=target_user;
  select coalesce(array_agg(id order by id),'{}') into children from public.children where family_id=any(families);
  with paths as (
    select p->>'bucket' bucket,p->>'path' path from unnest(children) child
      cross join lateral jsonb_array_elements(public.child_deletion_source(child)->'manifest') p
    union select 'wrong-question-images',original_path from public.question_ocr_drafts where owner_id=target_user
    union select 'wrong-question-images',processed_path from public.question_ocr_drafts where owner_id=target_user
    union select 'worksheets',pdf_path from public.worksheet_jobs where owner_id=target_user
    union select bucket_id,name from storage.objects where owner_id=target_user::text or owner=target_user
    union select bucket_id,name from storage.objects where bucket_id in ('worksheets','wrong-question-images')
      and split_part(name,'/',1)=any(families::text[])
  ) select coalesce(jsonb_agg(jsonb_build_object('bucket',bucket,'path',path) order by bucket,path),'[]') into files from paths;
  scope:=jsonb_build_object('owned_family_ids',families,'child_ids',children,
    'memberships',(select coalesce(jsonb_agg(family_id order by family_id),'[]') from public.family_members where user_id=target_user),
    'children',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'nickname',c.nickname,'counts',public.child_deletion_source(c.id)->'counts') order by c.id),'[]') from public.children c where c.id=any(children)),
    'shared_uploads',(select count(*) from public.question_ocr_drafts where owner_id=target_user and not(child_id=any(children))),
    'shared_worksheets',(select count(*) from public.worksheet_jobs where owner_id=target_user and not(family_id=any(families))),
    'files',jsonb_array_length(files),'file_revision',md5(files::text));
  return jsonb_build_object('scope',scope,'manifest',files);
end $$;
revoke all on function public.account_deletion_source(uuid) from public,anon,authenticated,service_role;

create function public.preview_account_deletion() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare family uuid;
begin
  if not public.account_is_active(auth.uid()) then raise exception '账号不可用' using errcode='42501'; end if;
  for family in select family_id from public.family_members where user_id=auth.uid() loop
    perform public.require_parent_authorization(family);
  end loop;
  if exists(select 1 from public.families where owner_user_id=auth.uid() and not public.is_family_admin(id)) then
    raise exception '家庭所有者权限不一致，请先修复管理员归属' using errcode='42501'; end if;
  return jsonb_build_object('scope',public.account_deletion_source(auth.uid())->'scope',
    'file_wait_minutes',10,'target_hours',24,'job_retention_days',30,'irreversible',true);
end $$;
revoke all on function public.preview_account_deletion() from public,anon;
grant execute on function public.preview_account_deletion() to authenticated;

create function public.request_account_deletion(request_id uuid,expected_scope jsonb,confirmation text) returns uuid
language plpgsql security definer set search_path='' as $$
declare source jsonb; scope jsonb; previous public.account_deletion_jobs; family uuid; child uuid; file jsonb;
  families uuid[]; children uuid[]; deadline timestamptz;
begin
  if auth.uid() is null or nullif(auth.jwt()->>'session_id','') is null then raise exception '请重新登录' using errcode='42501'; end if;
  if request_id is null or confirmation is distinct from '永久注销我的账号' then raise exception '请输入永久注销我的账号确认'; end if;
  perform pg_advisory_xact_lock(hashtextextended('account-delete:'||auth.uid()::text,0));
  select * into previous from public.account_deletion_jobs where id=request_id or user_id=auth.uid();
  if found then
    if previous.user_id<>auth.uid() or previous.id<>request_id then raise exception '已有注销申请，请查看原申请' using errcode='42501'; end if;
    return previous.id;
  end if;
  perform 1 from auth.users where id=auth.uid() for update;
  perform 1 from public.families where owner_user_id=auth.uid() order by id for update;
  perform 1 from public.family_members where user_id=auth.uid() order by family_id for update;
  perform 1 from public.question_ocr_drafts where owner_id=auth.uid() order by id for update;
  perform 1 from public.worksheet_jobs where owner_id=auth.uid() order by id for update;
  scope:=public.preview_account_deletion()->'scope';
  source:=public.account_deletion_source(auth.uid());
  if expected_scope is distinct from scope then raise exception '注销范围已变化，请刷新并重新确认' using errcode='40001'; end if;
  select coalesce(array_agg(value::uuid),'{}') into families from jsonb_array_elements_text(scope->'owned_family_ids');
  select coalesce(array_agg(value::uuid),'{}') into children from jsonb_array_elements_text(scope->'child_ids');
  for file in select value from jsonb_array_elements(source->'manifest') loop
    if not (file->>'bucket'='wrong-question-images' and file->>'path' ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/(original|processed)\.jpg$'
      or file->>'bucket'='worksheets' and file->>'path' ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/worksheet\.pdf$') then
      raise exception '发现未知文件，注销未受理，请先处理不受支持的上传文件'; end if;
  end loop;
  select greatest(now()+interval '10 minutes',coalesce(max(lease_until+interval '10 minutes'),now())) into deadline
    from public.worksheet_jobs where owner_id=auth.uid() and status='running';
  -- Preserve remote cache invalidations before the family and its tombstones go away.
  insert into public.family_access_revocations(user_id,family_id,child_ids)
    select m.user_id,m.family_id,array(select c.id from public.children c where c.family_id=m.family_id
      union select t.child_id from public.child_deletion_tombstones t where t.family_id=m.family_id)
    from public.family_members m where m.family_id=any(families)
    on conflict(user_id,family_id) do update set child_ids=excluded.child_ids;
  insert into public.deleted_account_media(family_id,bucket,path)
    select coalesce((select family_id from public.children where id::text=split_part(p->>'path','/',1)),
      (select id from public.families where id::text=split_part(p->>'path','/',1))),p->>'bucket',p->>'path'
    from jsonb_array_elements(source->'manifest') p on conflict do nothing;
  foreach child in array children loop
    perform public.request_child_deletion(child,gen_random_uuid(),
      (select value->'counts' from jsonb_array_elements(scope->'children') where value->>'id'=child::text),'永久删除孩子');
  end loop;
  -- Remove this user's sources in joined families, retaining the family's edited
  -- questions, task results and ledger. Other users' uploads are untouched.
  delete from public.child_export_jobs where owner_id=auth.uid() or child_id in
    (select child_id from public.question_ocr_drafts where owner_id=auth.uid()
     union select child_id from public.worksheet_jobs where owner_id=auth.uid());
  delete from public.question_ocr_drafts where owner_id=auth.uid();
  delete from public.worksheet_jobs where owner_id=auth.uid();
  delete from public.child_export_jobs where owner_id=auth.uid();
  delete from public.family_invitations where invited_by=auth.uid() or email=(select lower(email) from auth.users where id=auth.uid());
  update public.audit_logs set actor_user_id=null,details='{}' where actor_user_id=auth.uid();
  insert into public.account_deletion_jobs(id,user_id,owned_family_ids,child_ids,manifest,next_attempt_at)
    values(request_id,auth.uid(),families,children,source->'manifest',deadline);
  delete from public.parent_authorizations where user_id=auth.uid();
  return request_id;
end $$;
revoke all on function public.request_account_deletion(uuid,jsonb,text) from public,anon;
grant execute on function public.request_account_deletion(uuid,jsonb,text) to authenticated;

-- No file paths, names, emails, tokens, PINs or counts after acceptance.
create function public.account_deletion_status() returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',id,'status',status,'phase',phase,'created_at',created_at,
    'target_at',target_at,'next_attempt_at',next_attempt_at,'error_code',error_code,'completed_at',completed_at)
  from public.account_deletion_jobs where user_id=auth.uid();
$$;
revoke all on function public.account_deletion_status() from public,anon;
grant execute on function public.account_deletion_status() to authenticated;

create function public.pending_account_deletions() returns setof uuid
language plpgsql security definer set search_path='' as $$
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Trusted worker required' using errcode='42501'; end if;
  delete from public.account_deletion_jobs where status='completed' and completed_at<now()-interval '30 days';
  return query select id from public.account_deletion_jobs where status<>'completed' and next_attempt_at<=now()
    and (lease_until is null or lease_until<=now()) order by next_attempt_at,id limit 10;
end $$;

create function public.claim_account_deletion(target_job_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job public.account_deletion_jobs; token uuid;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Trusted worker required' using errcode='42501'; end if;
  select * into job from public.account_deletion_jobs where id=target_job_id for update;
  if not found then raise exception 'Unknown deletion job'; end if;
  if job.status='completed' then return jsonb_build_object('id',job.id,'status','completed'); end if;
  if job.next_attempt_at>now() or (job.status='running' and job.lease_until>now()) then
    return jsonb_build_object('id',job.id,'status','waiting'); end if;
  if exists(select 1 from public.cleanup_jobs where (family_id=any(job.owned_family_ids) or owner_id=job.user_id)
    and status not in ('completed','superseded')) then
    update public.account_deletion_jobs set next_attempt_at=now()+interval '2 minutes',error_code='WAITING_FILE_JOBS' where id=job.id;
    return jsonb_build_object('id',job.id,'status','waiting'); end if;
  token:=gen_random_uuid();
  update public.account_deletion_jobs set status='running',lease_token=token,lease_until=now()+interval '5 minutes',
    attempts=attempts+1,error_code=null where id=job.id;
  return jsonb_build_object('id',job.id,'user_id',job.user_id,'status','claimed','phase',job.phase,'manifest',job.manifest,'lease_token',token);
end $$;

create function public.prepare_account_auth_deletion(target_job_id uuid,token uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare job public.account_deletion_jobs;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Trusted worker required' using errcode='42501'; end if;
  select * into job from public.account_deletion_jobs where id=target_job_id for update;
  if not found or job.status<>'running' or job.lease_token is distinct from token or job.lease_until<=now() then raise exception 'Invalid deletion lease'; end if;
  if exists(select 1 from jsonb_array_elements(job.manifest) p join storage.objects o on o.bucket_id=p->>'bucket' and o.name=p->>'path')
    or exists(select 1 from storage.objects where owner_id=job.user_id::text or owner=job.user_id)
    or exists(select 1 from storage.objects where bucket_id in ('wrong-question-images','worksheets')
      and split_part(name,'/',1)=any((job.owned_family_ids||job.child_ids)::text[]))
    or exists(select 1 from public.cleanup_jobs where (family_id=any(job.owned_family_ids) or owner_id=job.user_id) and status not in ('completed','superseded')) then
    raise exception 'File deletion not verified'; end if;
  if exists(select 1 from public.children where family_id=any(job.owned_family_ids))
    or exists(select 1 from public.question_ocr_drafts where owner_id=job.user_id)
    or exists(select 1 from public.worksheet_jobs where owner_id=job.user_id) then raise exception 'Unexpected remaining business data'; end if;
  delete from public.families where id=any(job.owned_family_ids) and owner_user_id=job.user_id;
  delete from public.family_members where user_id=job.user_id;
  delete from public.parent_authorizations where user_id=job.user_id;
  delete from public.family_invitations where invited_by=job.user_id or email=(select lower(email) from auth.users where id=job.user_id);
  update public.audit_logs set actor_user_id=null,details='{}' where actor_user_id=job.user_id;
  update public.account_deletion_jobs set phase='auth' where id=job.id;
  return job.user_id;
end $$;

create function public.finish_account_deletion(target_job_id uuid,token uuid,failure_code text default null) returns void
language plpgsql security definer set search_path='' as $$
declare job public.account_deletion_jobs;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Trusted worker required' using errcode='42501'; end if;
  select * into job from public.account_deletion_jobs where id=target_job_id for update;
  if not found then raise exception 'Unknown deletion job'; end if;
  if job.status='completed' then return; end if;
  if job.status<>'running' or job.lease_token is distinct from token or job.lease_until<=now() then raise exception 'Invalid deletion lease'; end if;
  if failure_code is not null then
    update public.account_deletion_jobs set status='failed',lease_token=null,lease_until=null,
      error_code=case when failure_code in ('INVALID_MANIFEST','STORAGE_REMOVE_FAILED','STORAGE_VERIFY_FAILED','AUTH_DELETE_FAILED','ACCOUNT_PREPARE_FAILED') then failure_code else 'ACCOUNT_FINISH_FAILED' end,
      next_attempt_at=now()+make_interval(secs=>least(21600,30*power(2,least(attempts,10)))::integer) where id=job.id;
    return;
  end if;
  if job.phase<>'auth' or exists(select 1 from auth.users where id=job.user_id) then raise exception 'Auth deletion not verified'; end if;
  update public.account_deletion_jobs set status='completed',phase='done',completed_at=now(),manifest='[]',owned_family_ids='{}',child_ids='{}',
    lease_token=null,lease_until=null,error_code=null where id=job.id;
end $$;
revoke all on function public.pending_account_deletions(),public.claim_account_deletion(uuid),
  public.prepare_account_auth_deletion(uuid,uuid),public.finish_account_deletion(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.pending_account_deletions(),public.claim_account_deletion(uuid),
  public.prepare_account_auth_deletion(uuid,uuid),public.finish_account_deletion(uuid,uuid,text) to service_role;
