-- =====================================================================
-- J2050 internal tools - migration 008
-- Scope: editing of the Gantt from the site.
--   * optimistic locking: tasks.updated_at / updated_by; a save based on an
--     out-of-date copy is refused ("Task modified by someone else")
--   * atomic save of a task with its dependencies (admin_save_task)
--   * change history of tasks and dependencies (task_history), readable by
--     active members, written only by triggers
-- Prerequisite: migrations 001-007 applied.
-- Run once in Supabase > SQL Editor. Runs as one transaction.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Last change of each task
-- ---------------------------------------------------------------------
alter table public.tasks
  add column updated_at timestamptz not null default now(),
  add column updated_by uuid references public.profiles(id) on delete set null;

-- Updated on every change of the task content; the notification bookkeeping
-- (notified_leader_id, written by the notification service) does not count.
create function public.touch_task() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.updated_at := now();
    new.updated_by := auth.uid();
  elsif (to_jsonb(new) - 'notified_leader_id' - 'updated_at' - 'updated_by')
        is distinct from (to_jsonb(old) - 'notified_leader_id' - 'updated_at' - 'updated_by') then
    new.updated_at := now();
    new.updated_by := auth.uid();
  else
    new.updated_at := old.updated_at;
    new.updated_by := old.updated_by;
  end if;
  return new;
end $$;

create trigger tasks_touch before insert or update on public.tasks
  for each row execute function public.touch_task();

-- ---------------------------------------------------------------------
-- 2. Change history
-- ---------------------------------------------------------------------
create table public.task_history (
  id          bigint generated always as identity primary key,
  task_id     bigint not null,          -- no foreign key: the history survives the task
  task_code   text,
  action      text not null check (action in ('created', 'updated', 'deleted',
                                              'dependency added', 'dependency removed')),
  changes     jsonb,                    -- { field: [old, new] } or { depends_on: code }
  changed_by  uuid references public.profiles(id) on delete set null,
  changed_at  timestamptz not null default now()
);
create index task_history_task_idx on public.task_history (task_id, changed_at desc);

alter table public.task_history enable row level security;
create policy read_task_history on public.task_history for select to authenticated
  using (public.is_active());

create function public.log_task_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_diff jsonb := '{}';
  k text;
begin
  if tg_op = 'INSERT' then
    insert into task_history (task_id, task_code, action, changes, changed_by)
    values (new.id, new.code, 'created',
            to_jsonb(new) - 'notified_leader_id' - 'updated_at' - 'updated_by' - 'created_at', auth.uid());
    return null;
  elsif tg_op = 'DELETE' then
    insert into task_history (task_id, task_code, action, changes, changed_by)
    values (old.id, old.code, 'deleted', jsonb_build_object('name', old.name), auth.uid());
    return null;
  end if;
  v_old := to_jsonb(old) - 'notified_leader_id' - 'updated_at' - 'updated_by';
  v_new := to_jsonb(new) - 'notified_leader_id' - 'updated_at' - 'updated_by';
  for k in select jsonb_object_keys(v_new) loop
    if v_new -> k is distinct from v_old -> k then
      v_diff := v_diff || jsonb_build_object(k, jsonb_build_array(v_old -> k, v_new -> k));
    end if;
  end loop;
  if v_diff <> '{}' then
    insert into task_history (task_id, task_code, action, changes, changed_by)
    values (new.id, new.code, 'updated', v_diff, auth.uid());
  end if;
  return null;
end $$;

create trigger tasks_history after insert or update or delete on public.tasks
  for each row execute function public.log_task_change();

create function public.log_dependency_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_task text;
  v_dep  text;
begin
  r := coalesce(new, old);
  select code into v_task from tasks where id = r.task_id;
  select code into v_dep  from tasks where id = r.depends_on;
  -- Dependencies removed together with a deleted task: the deletion is already logged
  if v_task is null or v_dep is null then return null; end if;
  insert into task_history (task_id, task_code, action, changes, changed_by)
  values (r.task_id, v_task,
          case when tg_op = 'INSERT' then 'dependency added' else 'dependency removed' end,
          jsonb_build_object('depends_on', v_dep), auth.uid());
  return null;
end $$;

create trigger task_dependencies_history after insert or delete on public.task_dependencies
  for each row execute function public.log_dependency_change();

-- ---------------------------------------------------------------------
-- 3. Atomic save of a task (new or existing) with its dependencies
--    p_fields: code, name, parent_id, start_date, end_date, duration_days,
--              status, leader_id, responsible, note, teams, milestone_label
--    p_depends_on / p_required_by: complete lists of task ids, or null to
--              leave the dependencies unchanged (e.g. drag of a bar)
--    p_expected: updated_at of the copy being edited (null for new tasks)
-- ---------------------------------------------------------------------
create function public.admin_save_task(
  p_id          bigint,
  p_fields      jsonb,
  p_depends_on  bigint[]    default null,
  p_required_by bigint[]    default null,
  p_expected    timestamptz default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_id      bigint := p_id;
  v_current timestamptz;
  v_teams   text[];
begin
  if not public.is_admin() then raise exception 'Not authorized'; end if;

  v_teams := coalesce(array(select jsonb_array_elements_text(p_fields -> 'teams')), '{}');

  if v_id is null then
    insert into tasks (code, name, parent_id, start_date, end_date, duration_days, status,
                       leader_id, responsible, note, teams, milestone_label)
    values (trim(p_fields ->> 'code'), trim(p_fields ->> 'name'),
            nullif(p_fields ->> 'parent_id', '')::bigint,
            (p_fields ->> 'start_date')::date, (p_fields ->> 'end_date')::date,
            coalesce((p_fields ->> 'duration_days')::integer, 1),
            coalesce(p_fields ->> 'status', 'todo'),
            nullif(p_fields ->> 'leader_id', '')::uuid,
            nullif(trim(p_fields ->> 'responsible'), ''),
            nullif(trim(p_fields ->> 'note'), ''),
            v_teams,
            nullif(trim(p_fields ->> 'milestone_label'), ''))
    returning id into v_id;
  else
    select updated_at into v_current from tasks where id = v_id for update;
    if not found then raise exception 'Task not found'; end if;
    if p_expected is not null and v_current <> p_expected then
      raise exception 'Task modified by someone else';
    end if;
    update tasks set
      code            = trim(p_fields ->> 'code'),
      name            = trim(p_fields ->> 'name'),
      parent_id       = nullif(p_fields ->> 'parent_id', '')::bigint,
      start_date      = (p_fields ->> 'start_date')::date,
      end_date        = (p_fields ->> 'end_date')::date,
      duration_days   = coalesce((p_fields ->> 'duration_days')::integer, 1),
      status          = coalesce(p_fields ->> 'status', 'todo'),
      leader_id       = nullif(p_fields ->> 'leader_id', '')::uuid,
      responsible     = nullif(trim(p_fields ->> 'responsible'), ''),
      note            = nullif(trim(p_fields ->> 'note'), ''),
      teams           = v_teams,
      milestone_label = nullif(trim(p_fields ->> 'milestone_label'), '')
    where id = v_id;
  end if;

  if p_depends_on is not null then
    delete from task_dependencies where task_id = v_id and depends_on <> all (p_depends_on);
    insert into task_dependencies (task_id, depends_on)
    select v_id, d from unnest(p_depends_on) as d
    on conflict do nothing;
  end if;
  if p_required_by is not null then
    delete from task_dependencies where depends_on = v_id and task_id <> all (p_required_by);
    insert into task_dependencies (task_id, depends_on)
    select r, v_id from unnest(p_required_by) as r
    on conflict do nothing;
  end if;

  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- 4. Privileges
-- ---------------------------------------------------------------------
grant select on public.task_history to authenticated;
grant select on public.task_history to service_role;

revoke execute on function public.admin_save_task(bigint, jsonb, bigint[], bigint[], timestamptz) from public, anon;
grant  execute on function public.admin_save_task(bigint, jsonb, bigint[], bigint[], timestamptz) to authenticated;

revoke execute on function public.touch_task()             from public, anon, authenticated;
revoke execute on function public.log_task_change()        from public, anon, authenticated;
revoke execute on function public.log_dependency_change()  from public, anon, authenticated;

commit;
