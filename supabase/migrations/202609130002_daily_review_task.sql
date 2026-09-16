create or replace function public.generate_daily_wrong_review_task(
  target_child_id uuid,
  target_date date,
  max_questions integer default 10
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  task_id uuid;
  family_timezone text;
begin
  select f.timezone into family_timezone
  from public.children c join public.families f on f.id = c.family_id
  where c.id = target_child_id;

  if family_timezone is null then
    raise exception 'Child not found';
  end if;

  if not exists (
    select 1 from public.wrong_questions w
    where w.child_id = target_child_id
      and w.mastery_status <> 'mastered'
      and w.review_due_at < ((target_date + 1)::timestamp at time zone family_timezone)
  ) then
    return null;
  end if;

  insert into public.task_instances (
    child_id, title, due_date, source_type, coin_reward, xp_reward, idempotency_key
  ) values (
    target_child_id, '今日错题复习', target_date, 'automatic_wrong_review', 50, 45,
    'auto-review:' || target_child_id::text || ':' || target_date::text
  ) on conflict (child_id, due_date, source_type)
    where source_type = 'automatic_wrong_review'
    do update set title = excluded.title
  returning id into task_id;

  insert into public.task_review_items (task_instance_id, wrong_question_id, sequence)
  select task_id, ranked.id, ranked.sequence
  from (
    select w.id, row_number() over(order by w.review_due_at asc, w.wrong_count desc, w.id)::smallint sequence
    from public.wrong_questions w
    where w.child_id = target_child_id
      and w.mastery_status <> 'mastered'
      and w.review_due_at < ((target_date + 1)::timestamp at time zone family_timezone)
    limit greatest(1, least(max_questions, 20))
  ) ranked
  on conflict (task_instance_id, wrong_question_id) do nothing;

  return task_id;
end;
$$;

revoke all on function public.generate_daily_wrong_review_task(uuid, date, integer) from public;
grant execute on function public.generate_daily_wrong_review_task(uuid, date, integer) to service_role;
