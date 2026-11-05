-- Match worksheet_pdf.mjs. Existing ready PDFs retain their original renderer;
-- an active lease also keeps its version until it finishes or is reclaimed.
alter table public.worksheet_jobs alter column renderer_version set default 'a4-v2';

create or replace function public.claim_worksheet(target_worksheet_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare job public.worksheet_jobs; token uuid; items jsonb;
begin
  select * into job from public.worksheet_jobs where id=target_worksheet_id for update;
  if not found then raise exception '组卷不存在'; end if;
  if coalesce(auth.role(),'')<>'service_role' then perform public.require_parent_authorization(job.family_id); end if;
  if job.status='ready' and job.expires_at>now() then return jsonb_build_object('id',job.id,'status','ready'); end if;
  if job.status in ('deleting','deleted') or job.expires_at<=now() then raise exception '组卷已删除或过期'; end if;
  if job.status='running' and job.lease_until>now() then return jsonb_build_object('id',job.id,'status','running'); end if;
  if exists(select 1 from public.worksheet_items i left join public.wrong_questions w on w.id=i.question_id
    where i.worksheet_id=job.id and (w.id is null or w.deleting)) then raise exception '源题正在或已经永久删除，禁止生成'; end if;
  token:=gen_random_uuid();
  update public.worksheet_jobs set status='running',lease_token=token,lease_until=now()+interval '5 minutes',
    attempts=attempts+1,progress=5,error_code=null,renderer_version='a4-v2' where id=job.id;
  select jsonb_agg(to_jsonb(i) order by sequence) into items from public.worksheet_items i where worksheet_id=job.id;
  return jsonb_build_object('id',job.id,'status','claimed','lease_token',token,'pdf_path',job.pdf_path,
    'snapshot',jsonb_build_object('id',job.id,'created_at',job.created_at,'config',job.config,'items',items));
end $$;

revoke all on function public.claim_worksheet(uuid) from public,anon,authenticated;
grant execute on function public.claim_worksheet(uuid) to authenticated,service_role;
