-- Before 00:05 there is no task yet. Count only the overflow beyond today's
-- normal allowance. Once generated, use the questions actually assigned.
create or replace function public.review_overview_before_snooze(target_child_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  task_id uuid;
  day_end timestamptz;
  due integer;
  selected integer;
begin
  if not public.child_is_visible(target_child_id) then
    raise exception 'Child access required' using errcode='42501';
  end if;
  task_id := public.generate_daily_wrong_review_task(target_child_id);
  select (((now() at time zone f.timezone)::date + 1)::timestamp at time zone f.timezone)
    into day_end from public.children c join public.families f on f.id=c.family_id
    where c.id=target_child_id;

  select count(*)::integer, count(i.wrong_question_id)::integer into due, selected
    from public.wrong_questions w join public.wrong_question_answers a on a.question_id=w.id
    left join public.task_review_items i on i.task_instance_id=task_id
      and i.wrong_question_id=w.id and i.question_version=w.content_version
    where w.child_id=target_child_id and w.review_due_at<day_end
      and w.mastery_status<>'mastered' and not w.archived and not w.deleting;
  return jsonb_build_object('task_id',task_id,'due',due,
    'backlog',greatest(0,due-case when task_id is null then 10 else selected end));
end $$;
revoke all on function public.review_overview_before_snooze(uuid) from public,anon,authenticated,service_role;
