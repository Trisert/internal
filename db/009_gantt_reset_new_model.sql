-- =====================================================================
-- J2050 internal tools - migration 009
-- Scope: reset of the Gantt and new planning model.
--   * Gantt reset: all tasks, dependencies and task history are deleted.
--     Users, sub-team leaders, timeline events, lab shifts and bookings are
--     kept; lab shifts lose their task (task becomes optional for existing
--     shifts and is reassigned by an admin when editing the shift).
--   * Departments: SYS, ELE, SFW, AOCS, THM, TTC, OUT, MGT (sub-team leaders
--     are renamed accordingly).
--   * Task code generated on creation: <department>-<nn> (e.g. ELE-01);
--     subtask: <parent code>.<n> (e.g. ELE-01.2). Numbers are never reused.
--     Code, parent and department of a top-level task cannot be changed.
--   * Dates: planned start, planned end, optional deadline; actual start and
--     completion dates; "blocked" flag with reason. The status is derived.
--   * A task with subtasks: planned dates and actual dates are calculated
--     from its subtasks (roll-up); its own deadline gives the margin.
--   * Default leader: leader of the task department, then parent task leader.
--   * Editing reserved to admins (unchanged).
-- Prerequisite: migrations 001-008 applied.
-- Run once in Supabase > SQL Editor. Runs as one transaction.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Lab shifts keep existing, their task becomes optional
-- ---------------------------------------------------------------------
alter table public.shifts alter column task_id drop not null;
update public.shifts set task_id = null;

-- ---------------------------------------------------------------------
-- 2. Gantt reset
-- ---------------------------------------------------------------------
delete from public.task_dependencies;
delete from public.tasks;
delete from public.task_history;
delete from public.notification_log where key like 'deadline:%';

-- ---------------------------------------------------------------------
-- 3. Departments
-- ---------------------------------------------------------------------
create function private.departments() returns text[]
language sql immutable as $$
  select array['SYS', 'ELE', 'SFW', 'AOCS', 'THM', 'TTC', 'OUT', 'MGT'];
$$;
grant execute on function private.departments() to authenticated, service_role;

alter table public.team_leaders drop constraint team_leaders_team_check;
update public.team_leaders set team = case team
  when 'SYSTEMS' then 'SYS' when 'ELECTRONICS' then 'ELE' when 'SOFTWARE' then 'SFW'
  when 'TERMOMECH' then 'THM' when 'TELECOM' then 'TTC' when 'OUTREACH' then 'OUT'
  when 'BOARD-PM' then 'MGT' else team end;
alter table public.team_leaders add constraint team_leaders_team_check
  check (team = any (private.departments()));

-- ---------------------------------------------------------------------
-- 4. Task fields of the new model (table empty after the reset)
-- ---------------------------------------------------------------------
alter table public.tasks drop column status;
alter table public.tasks drop column duration_days;
alter table public.tasks rename column responsible to people;
comment on column public.tasks.start_date is 'Planned start';
comment on column public.tasks.end_date   is 'Planned end';

alter table public.tasks
  add column department     text not null check (department = any (private.departments())),
  add column deadline       date,
  add column started_on     date,
  add column completed_on   date,
  add column blocked        boolean not null default false,
  add column blocked_reason text,
  add column last_sub       integer not null default 0,
  add constraint tasks_teams_check     check (teams <@ private.departments()),
  add constraint tasks_completed_check check (completed_on is null or (started_on is not null and completed_on >= started_on)),
  add constraint tasks_blocked_check   check (not blocked or nullif(trim(blocked_reason), '') is not null);

-- Code counters per department (numbers never reused)
create table public.task_code_counters (
  department text primary key check (department = any (private.departments())),
  last       integer not null default 0
);
insert into public.task_code_counters (department) select unnest(private.departments());
alter table public.task_code_counters enable row level security;   -- no policy: not accessible from the site

-- ---------------------------------------------------------------------
-- 5. Code generation, immutable fields
-- ---------------------------------------------------------------------
create function public.assign_task_code() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  n integer;
  p tasks%rowtype;
begin
  if new.parent_id is null then
    if new.department is null then raise exception 'Department required'; end if;
    update task_code_counters set last = last + 1 where department = new.department returning last into n;
    if not found then raise exception 'Department not valid'; end if;
    new.code := new.department || '-' || case when n < 100 then lpad(n::text, 2, '0') else n::text end;
  else
    select * into p from tasks where id = new.parent_id;
    if not found then raise exception 'Parent task not found'; end if;
    if p.parent_id is not null then raise exception 'Subtasks cannot have subtasks'; end if;
    update tasks set last_sub = last_sub + 1 where id = new.parent_id returning last_sub into n;
    new.code := p.code || '.' || n;
    new.department := coalesce(new.department, p.department);
  end if;
  return new;
end $$;

create trigger tasks_assign_code before insert on public.tasks
  for each row execute function public.assign_task_code();

create function public.check_task_immutable() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.code <> old.code then raise exception 'Code cannot be changed'; end if;
  if new.parent_id is distinct from old.parent_id then raise exception 'Parent cannot be changed'; end if;
  if old.parent_id is null and new.department <> old.department then
    raise exception 'Department of a task cannot be changed';
  end if;
  -- Dates of a task with subtasks are calculated (roll-up only)
  if coalesce(current_setting('app.rollup', true), '') <> 'on'
     and exists (select 1 from tasks c where c.parent_id = new.id)
     and (new.start_date, new.end_date, new.started_on, new.completed_on)
         is distinct from (old.start_date, old.end_date, old.started_on, old.completed_on) then
    raise exception 'Dates of a task with subtasks are calculated';
  end if;
  return new;
end $$;

create trigger tasks_immutable before update on public.tasks
  for each row execute function public.check_task_immutable();

-- ---------------------------------------------------------------------
-- 6. Roll-up of the subtasks into the parent task
--    planned dates = envelope of the subtasks; started = first start;
--    completed = last completion, only when all subtasks are completed
-- ---------------------------------------------------------------------
create function private.rollup_task(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.rollup', 'on', true);
  update tasks p set
    start_date   = x.s,
    end_date     = x.e,
    started_on   = x.st,
    completed_on = case when x.n = x.nc then x.co end,
    blocked      = false,
    blocked_reason = null
  from (select min(start_date) s, max(end_date) e, min(started_on) st, max(completed_on) co,
               count(*) n, count(completed_on) nc
        from tasks where parent_id = p_id) x
  where p.id = p_id and x.n > 0;
  perform set_config('app.rollup', 'off', true);
end $$;

create function public.rollup_parent() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op <> 'DELETE' and new.parent_id is not null then
    perform private.rollup_task(new.parent_id);
  elsif tg_op = 'DELETE' and old.parent_id is not null then
    perform private.rollup_task(old.parent_id);
  end if;
  return null;
end $$;

create trigger tasks_rollup after insert or update or delete on public.tasks
  for each row execute function public.rollup_parent();

-- Last change and history: roll-up and code bookkeeping are not changes of the task
create or replace function public.touch_task() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.updated_at := now();
    new.updated_by := auth.uid();
  elsif coalesce(current_setting('app.rollup', true), '') <> 'on'
        and (to_jsonb(new) - 'notified_leader_id' - 'updated_at' - 'updated_by' - 'last_sub')
            is distinct from (to_jsonb(old) - 'notified_leader_id' - 'updated_at' - 'updated_by' - 'last_sub') then
    new.updated_at := now();
    new.updated_by := auth.uid();
  else
    new.updated_at := old.updated_at;
    new.updated_by := old.updated_by;
  end if;
  return new;
end $$;

create or replace function public.log_task_change() returns trigger
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
            to_jsonb(new) - 'notified_leader_id' - 'updated_at' - 'updated_by' - 'created_at' - 'last_sub', auth.uid());
    return null;
  elsif tg_op = 'DELETE' then
    insert into task_history (task_id, task_code, action, changes, changed_by)
    values (old.id, old.code, 'deleted', jsonb_build_object('name', old.name), auth.uid());
    return null;
  end if;
  if coalesce(current_setting('app.rollup', true), '') = 'on' then return null; end if;
  v_old := to_jsonb(old) - 'notified_leader_id' - 'updated_at' - 'updated_by' - 'last_sub';
  v_new := to_jsonb(new) - 'notified_leader_id' - 'updated_at' - 'updated_by' - 'last_sub';
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

-- ---------------------------------------------------------------------
-- 7. Effective leader: override > department leader > parent task leader
-- ---------------------------------------------------------------------
create or replace view public.task_leaders with (security_invoker = true) as
with base as (
  select t.id, t.parent_id,
         (select p.id from public.profiles p
           where p.id = t.leader_id and p.status = 'active' and p.role in ('teamleader', 'admin')) as override_leader,
         (select tl.leader_id from public.team_leaders tl
            join public.profiles p on p.id = tl.leader_id
                                  and p.status = 'active' and p.role in ('teamleader', 'admin')
           where tl.team = t.department) as dept_leader
  from public.tasks t
)
select b.id as task_id,
       coalesce(b.override_leader, b.dept_leader, pb.override_leader, pb.dept_leader) as leader_id,
       case when b.override_leader is not null then 'override'
            when b.dept_leader     is not null then 'department'
            when coalesce(pb.override_leader, pb.dept_leader) is not null then 'parent'
       end as source
from base b
left join base pb on pb.id = b.parent_id;

-- ---------------------------------------------------------------------
-- 8. Editing functions (admin)
-- ---------------------------------------------------------------------
-- Save a task (new or existing) with its dependencies.
--   p_fields: department, name, parent_id (new tasks only), start_date, end_date,
--             deadline, started_on, completed_on, blocked, blocked_reason,
--             leader_id, people, note, teams, milestone_label
--   The code is generated; for a task with subtasks the dates are ignored.
create or replace function public.admin_save_task(
  p_id          bigint,
  p_fields      jsonb,
  p_depends_on  bigint[]    default null,
  p_required_by bigint[]    default null,
  p_expected    timestamptz default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_id        bigint := p_id;
  v_current   timestamptz;
  v_children  boolean;
  v_today     date := (now() at time zone 'Europe/Rome')::date;
  v_started   date := nullif(p_fields ->> 'started_on', '')::date;
  v_completed date := nullif(p_fields ->> 'completed_on', '')::date;
  v_blocked   boolean := coalesce((p_fields ->> 'blocked')::boolean, false);
  v_teams     text[];
begin
  if not public.is_admin() then raise exception 'Not authorized'; end if;
  if v_started > v_today or v_completed > v_today then raise exception 'Actual dates cannot be in the future'; end if;
  v_teams := coalesce(array(select jsonb_array_elements_text(p_fields -> 'teams')), '{}');

  if v_id is null then
    insert into tasks (code, department, name, parent_id, start_date, end_date, deadline,
                       started_on, completed_on, blocked, blocked_reason,
                       leader_id, people, note, teams, milestone_label)
    values ('-', nullif(p_fields ->> 'department', ''), trim(p_fields ->> 'name'),
            nullif(p_fields ->> 'parent_id', '')::bigint,
            (p_fields ->> 'start_date')::date, (p_fields ->> 'end_date')::date,
            nullif(p_fields ->> 'deadline', '')::date,
            v_started, v_completed, v_blocked,
            case when v_blocked then nullif(trim(p_fields ->> 'blocked_reason'), '') end,
            nullif(p_fields ->> 'leader_id', '')::uuid,
            nullif(trim(p_fields ->> 'people'), ''),
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
    v_children := exists (select 1 from tasks where parent_id = v_id);
    update tasks set
      department      = coalesce(nullif(p_fields ->> 'department', ''), department),
      name            = trim(p_fields ->> 'name'),
      start_date      = case when v_children then start_date   else (p_fields ->> 'start_date')::date end,
      end_date        = case when v_children then end_date     else (p_fields ->> 'end_date')::date end,
      started_on      = case when v_children then started_on   else v_started end,
      completed_on    = case when v_children then completed_on else v_completed end,
      blocked         = case when v_children then false else v_blocked end,
      blocked_reason  = case when v_children or not v_blocked then null
                             else nullif(trim(p_fields ->> 'blocked_reason'), '') end,
      deadline        = nullif(p_fields ->> 'deadline', '')::date,
      leader_id       = nullif(p_fields ->> 'leader_id', '')::uuid,
      people          = nullif(trim(p_fields ->> 'people'), ''),
      note            = nullif(trim(p_fields ->> 'note'), ''),
      teams           = v_teams,
      milestone_label = nullif(trim(p_fields ->> 'milestone_label'), '')
    where id = v_id;
  end if;

  if p_depends_on is not null then
    delete from task_dependencies where task_id = v_id and depends_on <> all (p_depends_on);
    insert into task_dependencies (task_id, depends_on)
    select v_id, d from unnest(p_depends_on) as d on conflict do nothing;
  end if;
  if p_required_by is not null then
    delete from task_dependencies where depends_on = v_id and task_id <> all (p_required_by);
    insert into task_dependencies (task_id, depends_on)
    select r, v_id from unnest(p_required_by) as r on conflict do nothing;
  end if;
  return v_id;
end $$;

-- Move a task by a number of days (a task with subtasks moves all of them).
-- Actual dates and deadline are facts and commitments: they do not move.
create function public.admin_move_task(p_id bigint, p_days integer, p_expected timestamptz default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_current timestamptz;
begin
  if not public.is_admin() then raise exception 'Not authorized'; end if;
  select updated_at into v_current from tasks where id = p_id for update;
  if not found then raise exception 'Task not found'; end if;
  if p_expected is not null and v_current <> p_expected then raise exception 'Task modified by someone else'; end if;
  if exists (select 1 from tasks where parent_id = p_id) then
    update tasks set start_date = start_date + p_days, end_date = end_date + p_days where parent_id = p_id;
  else
    update tasks set start_date = start_date + p_days, end_date = end_date + p_days where id = p_id;
  end if;
end $$;

-- Change planned start and end of a task without subtasks
create function public.admin_set_dates(p_id bigint, p_start date, p_end date, p_expected timestamptz default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_current timestamptz;
begin
  if not public.is_admin() then raise exception 'Not authorized'; end if;
  select updated_at into v_current from tasks where id = p_id for update;
  if not found then raise exception 'Task not found'; end if;
  if p_expected is not null and v_current <> p_expected then raise exception 'Task modified by someone else'; end if;
  update tasks set start_date = p_start, end_date = p_end where id = p_id;
end $$;

-- New shifts and approved requests always need a task
create or replace function public.check_shift_task() returns trigger
language plpgsql as $$
begin
  if new.task_id is null and (tg_op = 'INSERT' or old.task_id is not null) then
    raise exception 'Task required';
  end if;
  return new;
end $$;

create trigger shifts_task_required before insert or update of task_id on public.shifts
  for each row execute function public.check_shift_task();

-- ---------------------------------------------------------------------
-- 9. Privileges
-- ---------------------------------------------------------------------
grant select on public.task_leaders to authenticated, service_role;
revoke all on function private.rollup_task(bigint) from public;

revoke execute on function public.admin_move_task(bigint, integer, timestamptz)    from public, anon;
grant  execute on function public.admin_move_task(bigint, integer, timestamptz)    to authenticated;
revoke execute on function public.admin_set_dates(bigint, date, date, timestamptz) from public, anon;
grant  execute on function public.admin_set_dates(bigint, date, date, timestamptz) to authenticated;

revoke execute on function public.assign_task_code()     from public, anon, authenticated;
revoke execute on function public.check_task_immutable() from public, anon, authenticated;
revoke execute on function public.rollup_parent()        from public, anon, authenticated;
revoke execute on function public.check_shift_task()     from public, anon, authenticated;

commit;
