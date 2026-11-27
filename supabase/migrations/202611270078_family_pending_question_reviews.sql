-- Use the same pending set for the family count and the parent's actionable page.
create index pending_child_question_reviews_idx
  on public.question_ocr_drafts(child_id, submitted_at desc, id desc)
  where requires_parent_review and submitted_at is not null and question_id is null and not deleting;

create or replace function public.family_overview(target_family_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare family public.families; today date; result jsonb;
begin
  perform public.require_parent_authorization(target_family_id);
  select * into strict family from public.families where id=target_family_id;
  today:=(now() at time zone family.timezone)::date;
  with kids as materialized (
    select id,nickname,created_at from public.children where family_id=target_family_id
  ), eligible as materialized (
    select t.child_id,t.due_date,t.status from public.task_instances t
      join kids c on c.id=t.child_id
    where not t.review_waiting_for_due and t.due_date between today-6 and today
      and not exists(select 1 from public.long_plans p join public.plan_leaves l on l.plan_id=p.id
        where p.template_id=t.template_id and l.leave_date=t.due_date)
  ), days as (
    select c.id as child_id,today-6+n as day from kids c cross join generate_series(0,6) n
  ), daily as (
    select d.child_id,d.day,count(t.child_id)::integer expected,
      count(t.child_id) filter(where t.status='completed')::integer completed
    from days d left join eligible t on t.child_id=d.child_id and t.due_date=d.day
    group by d.child_id,d.day
  ), claims as (
    select r.child_id,
      count(*) filter(where r.status='requested' and r.expires_at>now())::integer requested,
      count(*) filter(where r.status='approved' and r.expires_at>now())::integer approved,
      count(*) filter(where r.expires_at<=now())::integer awaiting_expiry
    from public.redemptions r join kids c on c.id=r.child_id
    where r.status in ('requested','approved') group by r.child_id
  ), awards as (
    select a.child_id,count(*)::integer pending_awards,sum(a.amount) pending_coins
    from public.pending_coin_awards a join kids c on c.id=a.child_id
    where a.status='pending' group by a.child_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'child_id',c.id,'nickname',c.nickname,
    'days',(select jsonb_agg(jsonb_build_object('day',d.day,'expected',d.expected,'completed',d.completed)
      order by d.day) from daily d where d.child_id=c.id),
    'requested',coalesce(r.requested,0),'approved',coalesce(r.approved,0),
    'awaiting_expiry',coalesce(r.awaiting_expiry,0),
    'pending_awards',coalesce(a.pending_awards,0),'pending_coins',coalesce(a.pending_coins,0),
    'pending_question_reviews',(select count(*) from public.question_ocr_drafts d
      where d.child_id=c.id and d.requires_parent_review and d.submitted_at is not null
        and d.question_id is null and not d.deleting)
  ) order by c.created_at,c.id),'[]'::jsonb) into result
  from kids c left join claims r on r.child_id=c.id left join awards a on a.child_id=c.id;
  return jsonb_build_object('family_id',family.id,'family_name',family.name,
    'timezone',family.timezone,'today',today,'generated_at',now(),'children',result);
end $$;

-- Keep the existing mixed-history RPC available to children and older clients.
create function public.pending_child_question_submissions(
  target_child_id uuid, after_created_at timestamptz default null, after_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare family uuid; page jsonb; cursor_row jsonb;
begin
  select family_id into family from public.children where id=target_child_id;
  perform public.require_parent_authorization(family);
  if not coalesce(public.child_is_visible(target_child_id),false) then
    raise exception 'Child access required' using errcode='42501';
  end if;
  if (after_created_at is null) <> (after_id is null) or
      (after_created_at is not null and not isfinite(after_created_at)) then
    raise exception 'Invalid cursor' using errcode='22023';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.submitted_at desc,q.id desc),'[]'::jsonb)
    into page from (
      select d.id,d.submitted_at,d.child_submission->>'prompt' as title,d.question_id,'pending'::text as state
      from public.question_ocr_drafts d
      where d.child_id=target_child_id and d.requires_parent_review and d.submitted_at is not null
        and d.question_id is null and not d.deleting
        and (after_id is null or (d.submitted_at,d.id)<(after_created_at,after_id))
      order by d.submitted_at desc,d.id desc limit 51
    ) q;
  if jsonb_array_length(page)>50 then
    cursor_row:=jsonb_build_object('id',page->49->'id','created_at',page->49->'submitted_at');
    page:=page-50;
  end if;
  return jsonb_build_object('owner_id',auth.uid(),'family_id',family,'child_id',target_child_id,
    'items',page,'next_cursor',cursor_row);
end $$;

revoke all on function public.pending_child_question_submissions(uuid,timestamptz,uuid) from public,anon,service_role;
grant execute on function public.pending_child_question_submissions(uuid,timestamptz,uuid) to authenticated;
