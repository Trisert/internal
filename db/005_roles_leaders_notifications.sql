-- =====================================================================
-- J2050 internal tools - migration 005
-- Scope:
--   * role "teamleader" (same rights as "user"; assignable as task leader)
--   * sub-team leaders (set by admins) and task leader override
--   * effective task leader: override > first sub-team of the task (in the
--     order SYSTEMS, ELECTRONICS, ...) with a leader > parent task leader
--   * shift supervisor (one active admin per shift, outside the capacity)
--   * hours statistics for admins (booked hours of ended shifts,
--     participants and supervisors)
--   * list of registrations awaiting approval (e-mail to the admins)
--   * notification support: calendar synchronisation queue, sent log,
--     processing lease (used by the "notify" Edge Function)
-- Prerequisite: migrations 001-004 applied.
-- Run once in Supabase > SQL Editor. Runs as one transaction.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Role "teamleader"
-- ---------------------------------------------------------------------
alter table public.profiles drop constraint profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('admin', 'teamleader', 'user'));

-- A leader shall be an active teamleader or admin
create function public.is_valid_leader(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles
                 where id = p_user and status = 'active' and role in ('teamleader', 'admin'));
$$;

-- ---------------------------------------------------------------------
-- 2. Sub-team leaders (one leader per sub-team)
-- ---------------------------------------------------------------------
create table public.team_leaders (
  team       text primary key check (team in ('SYSTEMS', 'ELECTRONICS', 'SOFTWARE', 'AOCS',
                                              'TERMOMECH', 'TELECOM', 'OUTREACH', 'BOARD-PM')),
  leader_id  uuid not null references public.profiles(id) on delete cascade
);

alter table public.team_leaders enable row level security;
create policy read_team_leaders  on public.team_leaders for select to authenticated using (public.is_active());
create policy admin_team_leaders on public.team_leaders for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------
-- 3. Task leader override and notification bookkeeping
-- ---------------------------------------------------------------------
alter table public.tasks
  add column leader_id          uuid references public.profiles(id) on delete set null,
  add column notified_leader_id uuid references public.profiles(id) on delete set null;

create function public.check_leader() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.leader_id is not null and not public.is_valid_leader(new.leader_id) then
    raise exception 'Leader shall be an active teamleader or admin';
  end if;
  return new;
end $$;

create trigger tasks_leader_check before insert or update of leader_id on public.tasks
  for each row execute function public.check_leader();
create trigger team_leaders_check before insert or update of leader_id on public.team_leaders
  for each row execute function public.check_leader();

-- Effective leader of every task
create view public.task_leaders with (security_invoker = true) as
with base as (
  select t.id, t.parent_id,
         (select p.id from public.profiles p
           where p.id = t.leader_id and p.status = 'active' and p.role in ('teamleader', 'admin')) as override_leader,
         (select tl.leader_id
            from unnest(t.teams) as u(team)
            join public.team_leaders tl on tl.team = u.team
            join public.profiles p on p.id = tl.leader_id
                                  and p.status = 'active' and p.role in ('teamleader', 'admin')
           order by array_position(array['SYSTEMS', 'ELECTRONICS', 'SOFTWARE', 'AOCS', 'TERMOMECH',
                                         'TELECOM', 'OUTREACH', 'BOARD-PM'], u.team)
           limit 1) as team_leader
  from public.tasks t
)
select b.id as task_id,
       coalesce(b.override_leader, b.team_leader, pb.override_leader, pb.team_leader) as leader_id,
       case when b.override_leader is not null then 'override'
            when b.team_leader     is not null then 'team'
            when coalesce(pb.override_leader, pb.team_leader) is not null then 'parent'
       end as source
from base b
left join base pb on pb.id = b.parent_id;

-- ---------------------------------------------------------------------
-- 4. Shift supervisor: one active admin per shift, not counted in the
--    capacity. Default: the admin who creates the shift or approves the
--    request; it can be changed.
-- ---------------------------------------------------------------------
alter table public.shifts
  add column supervisor_id uuid references public.profiles(id) on delete set null default auth.uid();

create function public.check_supervisor() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.supervisor_id is null then
    if tg_op = 'INSERT' then raise exception 'Supervisor required'; end if;
    return new;
  end if;
  if not exists (select 1 from profiles where id = new.supervisor_id and role = 'admin' and status = 'active') then
    raise exception 'Supervisor shall be an active admin';
  end if;
  if tg_op = 'UPDATE' and exists (select 1 from assignments
                                  where shift_id = new.id and user_id = new.supervisor_id) then
    raise exception 'Supervisor is booked as participant';
  end if;
  return new;
end $$;

create trigger shifts_supervisor_check before insert or update of supervisor_id on public.shifts
  for each row execute function public.check_supervisor();

-- Booking: the supervisor of a shift cannot book it as participant; the
-- overlap check also considers the shifts the user supervises.
create or replace function private.book_user(p_shift_id bigint, p_user_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_capacity   smallint;
  v_starts     timestamptz;
  v_ends       timestamptz;
  v_supervisor uuid;
  v_count      integer;
begin
  perform pg_advisory_xact_lock(hashtext('book_user:' || p_user_id::text));

  select capacity, starts_at, ends_at, supervisor_id into v_capacity, v_starts, v_ends, v_supervisor
  from shifts where id = p_shift_id for update;

  if not found then raise exception 'Shift not found'; end if;
  if v_starts <= now() then raise exception 'Shift already started'; end if;
  if v_supervisor = p_user_id then raise exception 'Supervisor of this shift'; end if;

  if exists (select 1 from assignments
             where shift_id = p_shift_id and user_id = p_user_id) then
    raise exception 'Already booked';
  end if;

  select count(*) into v_count from assignments where shift_id = p_shift_id;
  if v_count >= v_capacity then raise exception 'Shift full'; end if;

  if exists (select 1 from shifts s
             where s.id <> p_shift_id
               and tstzrange(s.starts_at, s.ends_at) && tstzrange(v_starts, v_ends)
               and (s.supervisor_id = p_user_id
                    or exists (select 1 from assignments a where a.shift_id = s.id and a.user_id = p_user_id))) then
    raise exception 'Overlapping shift';
  end if;

  insert into assignments (shift_id, user_id) values (p_shift_id, p_user_id);
end $$;

-- Approval with supervisor (default: the approving admin)
drop function public.approve_request(bigint, bigint, timestamptz, timestamptz, integer, text, text, text);

create function public.approve_request(
  p_request_id  bigint,
  p_task_id     bigint      default null,
  p_starts_at   timestamptz default null,
  p_ends_at     timestamptz default null,
  p_capacity    integer     default null,
  p_location    text        default null,
  p_description text        default null,
  p_note        text        default null,
  p_supervisor  uuid        default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  r          shift_requests%rowtype;
  v_task_id  bigint;
  v_shift_id bigint;
begin
  if not public.is_admin() then raise exception 'Not authorized'; end if;

  select * into r from shift_requests where id = p_request_id for update;
  if not found then raise exception 'Request not found'; end if;
  if r.status <> 'pending' then raise exception 'Request not pending'; end if;

  if not exists (select 1 from profiles
                 where id = r.requested_by and status = 'active') then
    raise exception 'Requester account not active';
  end if;

  v_task_id := coalesce(p_task_id, r.task_id);
  if v_task_id is null then raise exception 'Task required'; end if;

  insert into shifts (task_id, starts_at, ends_at, capacity, location, description, supervisor_id)
  values (v_task_id,
          coalesce(p_starts_at, r.starts_at),
          coalesce(p_ends_at,   r.ends_at),
          coalesce(p_capacity,  1),
          coalesce(p_location,  r.location),
          coalesce(p_description, r.description),
          coalesce(p_supervisor, auth.uid()))
  returning id into v_shift_id;

  perform private.book_user(v_shift_id, r.requested_by);

  update shift_requests
  set status = 'approved', shift_id = v_shift_id, admin_note = p_note,
      decided_by = auth.uid(), decided_at = now()
  where id = p_request_id;

  return v_shift_id;
end $$;

-- ---------------------------------------------------------------------
-- 5. Hours statistics (admin): booked hours of shifts already ended,
--    as participant and as supervisor
-- ---------------------------------------------------------------------
create function public.admin_hours(p_from date, p_to date)
returns table (user_id uuid, person text, task_id bigint, role text, hours numeric, shifts integer)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized'; end if;
  return query
    with presence as (
      select a.user_id as uid, s.*, 'participant'::text as kind
      from public.assignments a join public.shifts s on s.id = a.shift_id
      union all
      select s.supervisor_id as uid, s.*, 'supervisor'::text as kind
      from public.shifts s where s.supervisor_id is not null
    )
    select x.uid,
           coalesce(p.full_name, p.email),
           x.task_id,
           x.kind,
           round(sum(extract(epoch from (x.ends_at - x.starts_at)) / 3600.0)::numeric, 2),
           count(*)::integer
    from presence x
    join public.profiles p on p.id = x.uid
    where x.ends_at <= now()
      and x.starts_at >= (p_from::timestamp at time zone 'Europe/Rome')
      and x.starts_at <  ((p_to + 1)::timestamp at time zone 'Europe/Rome')
    group by x.uid, p.full_name, p.email, x.task_id, x.kind;
end $$;

-- ---------------------------------------------------------------------
-- 6. Registrations awaiting approval (for the e-mail to the admins):
--    e-mail confirmed, and name entered or confirmed more than 1 h ago
-- ---------------------------------------------------------------------
create function public.pending_registrations()
returns table (id uuid, email text, full_name text, confirmed_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.id, p.email, p.full_name, u.email_confirmed_at
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.status = 'pending'
    and u.email_confirmed_at is not null
    and (p.first_name is not null or u.email_confirmed_at < now() - interval '1 hour');
$$;

-- ---------------------------------------------------------------------
-- 7. Notification support (used only by the Edge Function, service role)
-- ---------------------------------------------------------------------
-- Shifts whose calendar invitation shall be (re)sent
create table public.calendar_dirty (
  shift_id   bigint primary key,
  marked_at  timestamptz not null default now()
);

-- Invitations sent for each shift: one invitation per person (kept after
-- the shift is deleted, to send the cancellations)
create table public.calendar_state (
  shift_id   bigint primary key,
  attendees  jsonb not null default '[]',   -- [{ "id", "email", "name", "supervisor", "seq" }] invited
  cancelled  jsonb not null default '{}',   -- { person id: last sequence used for a cancellation }
  content    jsonb,                         -- summary, start, end, location, description
  hash       text,                          -- shift details at the last invitation/update
  updated_at timestamptz not null default now()
);

-- Every e-mail sent once only (reminders, deadline notices)
create table public.notification_log (
  key      text primary key,
  sent_at  timestamptz not null default now()
);

-- Lease preventing two overlapping runs of the Edge Function
create table public.notify_lease (
  id     integer primary key check (id = 1),
  until  timestamptz not null default '-infinity'
);
insert into public.notify_lease (id) values (1);

alter table public.calendar_dirty   enable row level security;
alter table public.calendar_state   enable row level security;
alter table public.notification_log enable row level security;
alter table public.notify_lease     enable row level security;
-- No policies and no grants: not accessible from the site.

create function public.claim_notify_lease(p_seconds integer) returns boolean
language sql security definer set search_path = public as $$
  update notify_lease set until = now() + make_interval(secs => p_seconds)
  where id = 1 and until < now()
  returning true;
$$;

create function public.release_notify_lease() returns void
language sql security definer set search_path = public as $$
  update notify_lease set until = '-infinity' where id = 1;
$$;

-- Mark shifts for calendar synchronisation
create function public.mark_calendar_dirty() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if tg_table_name = 'assignments' then
    v_id := coalesce(new.shift_id, old.shift_id);
  else
    v_id := coalesce(new.id, old.id);
  end if;
  insert into calendar_dirty (shift_id) values (v_id)
    on conflict (shift_id) do update set marked_at = now();
  return null;
end $$;

create trigger assignments_calendar after insert or delete on public.assignments
  for each row execute function public.mark_calendar_dirty();
create trigger shifts_calendar after insert or update or delete on public.shifts
  for each row execute function public.mark_calendar_dirty();

-- ---------------------------------------------------------------------
-- 8. Privileges
-- ---------------------------------------------------------------------
grant select on public.team_leaders to authenticated;
grant insert, update, delete on public.team_leaders to authenticated;
grant select on public.task_leaders to authenticated;

revoke execute on function public.is_valid_leader(uuid)        from public, anon;
grant  execute on function public.is_valid_leader(uuid)        to authenticated;
revoke execute on function public.approve_request(bigint, bigint, timestamptz, timestamptz, integer, text, text, text, uuid) from public, anon;
grant  execute on function public.approve_request(bigint, bigint, timestamptz, timestamptz, integer, text, text, text, uuid) to authenticated;
revoke execute on function public.admin_hours(date, date)      from public, anon;
grant  execute on function public.admin_hours(date, date)      to authenticated;

-- Edge Function only (service role). Explicit grants because
-- "Automatically expose new tables" is disabled in this project.
grant usage on schema public to service_role;
grant select on all tables in schema public to service_role;
grant update (notified_leader_id) on public.tasks to service_role;
revoke execute on function public.claim_notify_lease(integer) from public, anon, authenticated;
revoke execute on function public.release_notify_lease()      from public, anon, authenticated;
grant  execute on function public.claim_notify_lease(integer) to service_role;
grant  execute on function public.release_notify_lease()      to service_role;
revoke execute on function public.pending_registrations()     from public, anon, authenticated;
grant  execute on function public.pending_registrations()     to service_role;
grant select, insert, update, delete on public.calendar_dirty, public.calendar_state,
  public.notification_log, public.notify_lease to service_role;

-- Trigger functions: never callable directly
revoke execute on function public.check_leader()         from public, anon, authenticated;
revoke execute on function public.mark_calendar_dirty()  from public, anon, authenticated;
revoke execute on function public.check_supervisor()     from public, anon, authenticated;

commit;
