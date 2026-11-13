-- =====================================================================
-- J2050 internal tools - migration 007
-- Scope: bookings by half-hour slots.
--   * shifts start and end on :00 or :30; each half hour is a slot
--     (laboratory hours 08:30-18:30, checked by the site)
--   * a booking covers one or more consecutive slots of a shift, with its
--     own start and end, and has a role:
--       participant (members): counted in the capacity, per slot
--       supervisor  (admins) : not counted, no limit of number
--   * a participant can book only slots covered by at least one supervisor
--   * a supervisor booking cannot be removed or shortened if participants
--     would remain without supervisor in a slot not yet ended
--   * the admin who creates the shift (or approves the request) is booked
--     by default as supervisor of the whole shift; another admin can be chosen
-- Replaces the single supervisor column of migration 005.
-- Prerequisite: migrations 001-005 applied.
-- Run once in Supabase > SQL Editor. Runs as one transaction.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Bookings with own time range and role
-- ---------------------------------------------------------------------
alter table public.assignments
  add column role      text not null default 'participant' check (role in ('participant', 'supervisor')),
  add column starts_at timestamptz,
  add column ends_at   timestamptz;

-- Existing bookings: whole shift; admins become supervisors
update public.assignments a
set starts_at = s.starts_at,
    ends_at   = s.ends_at,
    role      = case when p.role = 'admin' then 'supervisor' else 'participant' end
from public.shifts s, public.profiles p
where s.id = a.shift_id and p.id = a.user_id;

-- Supervisors of migration 005 become supervisor bookings of the whole shift
insert into public.assignments (shift_id, user_id, role, starts_at, ends_at)
select s.id, s.supervisor_id, 'supervisor', s.starts_at, s.ends_at
from public.shifts s
where s.supervisor_id is not null
on conflict (shift_id, user_id) do update set role = 'supervisor';

alter table public.assignments
  alter column starts_at set not null,
  alter column ends_at   set not null,
  add constraint assignments_range_check check (ends_at > starts_at);

-- ---------------------------------------------------------------------
-- 2. Remove the single supervisor of migration 005 and the objects using it
-- ---------------------------------------------------------------------
drop view public.shifts_with_count;
drop trigger shifts_supervisor_check on public.shifts;
drop function public.check_supervisor();
drop function public.approve_request(bigint, bigint, timestamptz, timestamptz, integer, text, text, text, uuid);
drop function public.admin_hours(date, date);
drop function public.book_shift(bigint);
drop function private.book_user(bigint, uuid);
alter table public.shifts drop column supervisor_id;

-- ---------------------------------------------------------------------
-- 3. Half-hour boundaries (checked on new and modified rows; existing rows
--    not on half hours are accepted until they are modified).
--    Europe/Rome differs from UTC by whole hours: :00/:30 are the same in both.
-- ---------------------------------------------------------------------
create function private.on_half_hour(p_ts timestamptz) returns boolean
language sql immutable as $$
  select extract(second from p_ts at time zone 'UTC') = 0
     and extract(minute from p_ts at time zone 'UTC')::integer % 30 = 0;
$$;
grant usage on schema private to authenticated;
grant execute on function private.on_half_hour(timestamptz) to authenticated;

alter table public.shifts add constraint shifts_half_hours
  check (private.on_half_hour(starts_at) and private.on_half_hour(ends_at)) not valid;
alter table public.shift_requests add constraint shift_requests_half_hours
  check (private.on_half_hour(starts_at) and private.on_half_hour(ends_at)) not valid;
alter table public.assignments add constraint assignments_half_hours
  check (private.on_half_hour(starts_at) and private.on_half_hour(ends_at)) not valid;

-- ---------------------------------------------------------------------
-- 4. Slot helpers
-- ---------------------------------------------------------------------
-- Highest number of participants in any half-hour slot of [p_start, p_end), excluding one user
create function private.max_participants(p_shift bigint, p_start timestamptz, p_end timestamptz, p_exclude uuid)
returns integer language sql stable set search_path = public as $$
  select coalesce(max(n), 0)::integer from (
    select (select count(*) from assignments a
             where a.shift_id = p_shift and a.role = 'participant'
               and (p_exclude is null or a.user_id <> p_exclude)
               and a.starts_at <= h and a.ends_at > h) as n
    from generate_series(p_start, p_end - interval '30 minutes', interval '30 minutes') as h
  ) x;
$$;

-- Number of half-hour slots of [p_start, p_end) without any supervisor
create function private.uncovered_slots(p_shift bigint, p_start timestamptz, p_end timestamptz)
returns integer language sql stable set search_path = public as $$
  select count(*)::integer
  from generate_series(p_start, p_end - interval '30 minutes', interval '30 minutes') as h
  where not exists (select 1 from assignments a
                     where a.shift_id = p_shift and a.role = 'supervisor'
                       and a.starts_at <= h and a.ends_at > h);
$$;

-- ---------------------------------------------------------------------
-- 5. Booking routine (creation or change of the own interval)
--    The role follows the member: admins are supervisors, others participants.
-- ---------------------------------------------------------------------
create function private.book(p_shift_id bigint, p_user_id uuid, p_starts_at timestamptz, p_ends_at timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_role  text;
  s       shifts%rowtype;
  v_old   assignments%rowtype;
begin
  select case when p.role = 'admin' then 'supervisor' else 'participant' end into v_role
  from profiles p where p.id = p_user_id and p.status = 'active';
  if not found then raise exception 'Member not found or not active'; end if;

  -- Serialize bookings of the same user (overlap) and of the same shift (capacity)
  perform pg_advisory_xact_lock(hashtext('book_user:' || p_user_id::text));
  select * into s from shifts where id = p_shift_id for update;
  if not found then raise exception 'Shift not found'; end if;

  if p_starts_at is null or p_ends_at is null
     or not private.on_half_hour(p_starts_at) or not private.on_half_hour(p_ends_at) then
    raise exception 'Half-hour slots only';
  end if;
  if p_ends_at <= p_starts_at then raise exception 'Invalid time range'; end if;
  if p_starts_at < s.starts_at or p_ends_at > s.ends_at then raise exception 'Outside the shift'; end if;
  if p_starts_at <= now() then raise exception 'Shift already started'; end if;

  select * into v_old from assignments where shift_id = p_shift_id and user_id = p_user_id;
  if found and v_old.starts_at <= now() then raise exception 'Booking already started'; end if;

  if v_role = 'participant' then
    if private.uncovered_slots(p_shift_id, p_starts_at, p_ends_at) > 0 then
      raise exception 'Slot without supervisor';
    end if;
    if private.max_participants(p_shift_id, p_starts_at, p_ends_at, p_user_id) >= s.capacity then
      raise exception 'Shift full';
    end if;
  end if;

  if exists (select 1 from assignments a
             where a.user_id = p_user_id and a.shift_id <> p_shift_id
               and tstzrange(a.starts_at, a.ends_at) && tstzrange(p_starts_at, p_ends_at)) then
    raise exception 'Overlapping shift';
  end if;

  -- Change of an existing supervisor booking: checked by trigger check_supervision
  insert into assignments (shift_id, user_id, role, starts_at, ends_at)
  values (p_shift_id, p_user_id, v_role, p_starts_at, p_ends_at)
  on conflict (shift_id, user_id) do update
    set starts_at = excluded.starts_at, ends_at = excluded.ends_at, role = excluded.role;
end $$;

revoke all on function private.book(bigint, uuid, timestamptz, timestamptz) from public;

-- Book or change the own interval; an admin can also book another admin as supervisor
create function public.book_shift(
  p_shift_id  bigint,
  p_starts_at timestamptz,
  p_ends_at   timestamptz,
  p_user_id   uuid default null
) returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid := coalesce(p_user_id, auth.uid());
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not public.is_active() then raise exception 'Account not active'; end if;
  if v_user <> auth.uid() then
    if not public.is_admin() then raise exception 'Not authorized'; end if;
    if not exists (select 1 from profiles where id = v_user and role = 'admin' and status = 'active') then
      raise exception 'Only admins can be added as supervisors';
    end if;
  end if;
  perform private.book(p_shift_id, v_user, p_starts_at, p_ends_at);
end $$;

-- ---------------------------------------------------------------------
-- 6. Supervision kept on removal or shortening of a supervisor booking
--    (only slots not yet ended: no-shows of past shifts can be removed)
-- ---------------------------------------------------------------------
create function public.check_supervision() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.role <> 'supervisor' then return coalesce(new, old); end if;
  -- Shift being deleted (cascade): nothing to keep
  if not exists (select 1 from shifts where id = old.shift_id) then return coalesce(new, old); end if;
  if exists (
    select 1
    from generate_series(old.starts_at, old.ends_at - interval '30 minutes', interval '30 minutes') as h
    where h + interval '30 minutes' > now()
      and (tg_op = 'DELETE' or new.role <> 'supervisor' or not (new.starts_at <= h and new.ends_at > h))
      and exists (select 1 from assignments p
                   where p.shift_id = old.shift_id and p.role = 'participant'
                     and p.starts_at <= h and p.ends_at > h)
      and not exists (select 1 from assignments o
                       where o.shift_id = old.shift_id and o.role = 'supervisor'
                         and o.user_id <> old.user_id and o.starts_at <= h and o.ends_at > h)
  ) then
    raise exception 'Participants would remain without supervisor';
  end if;
  return coalesce(new, old);
end $$;

create trigger assignments_supervision_check
  before update or delete on public.assignments
  for each row execute function public.check_supervision();

-- ---------------------------------------------------------------------
-- 7. Capacity per slot, and bookings kept inside the shift when its
--    times change (supervisors of the whole shift follow the new times)
-- ---------------------------------------------------------------------
create or replace function public.check_shift_capacity() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.capacity < private.max_participants(new.id, new.starts_at, new.ends_at, null) then
    raise exception 'Capacity lower than current bookings';
  end if;
  return new;
end $$;

create function public.fit_bookings_to_shift() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.starts_at = old.starts_at and new.ends_at = old.ends_at then return null; end if;
  -- Supervisors booked on the whole old shift: whole new shift
  update assignments set starts_at = new.starts_at, ends_at = new.ends_at
  where shift_id = new.id and role = 'supervisor'
    and starts_at = old.starts_at and ends_at = old.ends_at;
  -- Participants first, then supervisors: remove or shorten what falls outside
  delete from assignments where shift_id = new.id and role = 'participant'
    and (ends_at <= new.starts_at or starts_at >= new.ends_at);
  update assignments set starts_at = greatest(starts_at, new.starts_at), ends_at = least(ends_at, new.ends_at)
  where shift_id = new.id and role = 'participant'
    and (starts_at < new.starts_at or ends_at > new.ends_at);
  delete from assignments where shift_id = new.id and role = 'supervisor'
    and (ends_at <= new.starts_at or starts_at >= new.ends_at);
  update assignments set starts_at = greatest(starts_at, new.starts_at), ends_at = least(ends_at, new.ends_at)
  where shift_id = new.id and role = 'supervisor'
    and (starts_at < new.starts_at or ends_at > new.ends_at);
  return null;
end $$;

create trigger shifts_fit_bookings
  after update of starts_at, ends_at on public.shifts
  for each row execute function public.fit_bookings_to_shift();

-- Capacity change: removes the selected participants, then sets the capacity
create or replace function public.admin_set_capacity(
  p_shift_id bigint,
  p_capacity integer,
  p_remove_user_ids uuid[] default '{}'
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized'; end if;
  perform 1 from shifts where id = p_shift_id for update;
  if not found then raise exception 'Shift not found'; end if;
  delete from assignments
  where shift_id = p_shift_id and role = 'participant' and user_id = any(p_remove_user_ids);
  update shifts set capacity = p_capacity where id = p_shift_id;  -- trigger checks per slot
end $$;

-- ---------------------------------------------------------------------
-- 8. Shift creation and request approval with default supervisor
-- ---------------------------------------------------------------------
create function public.admin_create_shift(
  p_task_id     bigint,
  p_starts_at   timestamptz,
  p_ends_at     timestamptz,
  p_capacity    integer,
  p_location    text default null,
  p_description text default null,
  p_notes       text default null,
  p_supervisor  uuid default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.is_admin() then raise exception 'Not authorized'; end if;
  insert into shifts (task_id, starts_at, ends_at, capacity, location, description, notes)
  values (p_task_id, p_starts_at, p_ends_at, p_capacity, p_location, p_description, p_notes)
  returning id into v_id;
  perform private.book(v_id, coalesce(p_supervisor, auth.uid()), p_starts_at, p_ends_at);
  if not exists (select 1 from assignments where shift_id = v_id and role = 'supervisor') then
    raise exception 'Supervisor shall be an active admin';
  end if;
  return v_id;
end $$;

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
  v_start    timestamptz;
  v_end      timestamptz;
begin
  if not public.is_admin() then raise exception 'Not authorized'; end if;

  select * into r from shift_requests where id = p_request_id for update;
  if not found then raise exception 'Request not found'; end if;
  if r.status <> 'pending' then raise exception 'Request not pending'; end if;
  if not exists (select 1 from profiles where id = r.requested_by and status = 'active') then
    raise exception 'Requester account not active';
  end if;

  v_task_id := coalesce(p_task_id, r.task_id);
  if v_task_id is null then raise exception 'Task required'; end if;
  v_start := coalesce(p_starts_at, r.starts_at);
  v_end   := coalesce(p_ends_at, r.ends_at);

  insert into shifts (task_id, starts_at, ends_at, capacity, location, description)
  values (v_task_id, v_start, v_end, coalesce(p_capacity, 1),
          coalesce(p_location, r.location), coalesce(p_description, r.description))
  returning id into v_shift_id;

  -- Supervisor first (participants need a supervisor), then the requester
  perform private.book(v_shift_id, coalesce(p_supervisor, auth.uid()), v_start, v_end);
  if not exists (select 1 from assignments where shift_id = v_shift_id and role = 'supervisor') then
    raise exception 'Supervisor shall be an active admin';
  end if;
  if not exists (select 1 from assignments where shift_id = v_shift_id and user_id = r.requested_by) then
    perform private.book(v_shift_id, r.requested_by, v_start, v_end);
  end if;

  update shift_requests
  set status = 'approved', shift_id = v_shift_id, admin_note = p_note,
      decided_by = auth.uid(), decided_at = now()
  where id = p_request_id;

  return v_shift_id;
end $$;

-- ---------------------------------------------------------------------
-- 9. Cancellation: own booking before its start (participants and
--    supervisors); admins any booking, also past (no-shows)
-- ---------------------------------------------------------------------
drop policy delete_assign on public.assignments;
create policy delete_assign on public.assignments for delete to authenticated
  using (
    public.is_admin()
    or (user_id = auth.uid() and public.is_active() and starts_at > now())
  );

-- Calendar synchronisation also on changes of a booking interval
drop trigger assignments_calendar on public.assignments;
create trigger assignments_calendar after insert or update or delete on public.assignments
  for each row execute function public.mark_calendar_dirty();

-- ---------------------------------------------------------------------
-- 10. Hours statistics from the booked intervals
-- ---------------------------------------------------------------------
create function public.admin_hours(p_from date, p_to date)
returns table (user_id uuid, person text, task_id bigint, role text, hours numeric, shifts integer)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorized'; end if;
  return query
    select a.user_id,
           coalesce(p.full_name, p.email),
           s.task_id,
           a.role,
           round(sum(extract(epoch from (a.ends_at - a.starts_at)) / 3600.0)::numeric, 2),
           count(*)::integer
    from public.assignments a
    join public.shifts s   on s.id = a.shift_id
    join public.profiles p on p.id = a.user_id
    where a.ends_at <= now()
      and a.starts_at >= (p_from::timestamp at time zone 'Europe/Rome')
      and a.starts_at <  ((p_to + 1)::timestamp at time zone 'Europe/Rome')
    group by a.user_id, p.full_name, p.email, s.task_id, a.role;
end $$;

-- ---------------------------------------------------------------------
-- 11. Privileges
-- ---------------------------------------------------------------------
revoke all on function private.max_participants(bigint, timestamptz, timestamptz, uuid) from public;
revoke all on function private.uncovered_slots(bigint, timestamptz, timestamptz)       from public;
revoke all on function private.on_half_hour(timestamptz) from public;
grant execute on function private.on_half_hour(timestamptz) to authenticated, service_role;

revoke execute on function public.book_shift(bigint, timestamptz, timestamptz, uuid) from public, anon;
grant  execute on function public.book_shift(bigint, timestamptz, timestamptz, uuid) to authenticated;
revoke execute on function public.admin_create_shift(bigint, timestamptz, timestamptz, integer, text, text, text, uuid) from public, anon;
grant  execute on function public.admin_create_shift(bigint, timestamptz, timestamptz, integer, text, text, text, uuid) to authenticated;
revoke execute on function public.approve_request(bigint, bigint, timestamptz, timestamptz, integer, text, text, text, uuid) from public, anon;
grant  execute on function public.approve_request(bigint, bigint, timestamptz, timestamptz, integer, text, text, text, uuid) to authenticated;
revoke execute on function public.admin_hours(date, date) from public, anon;
grant  execute on function public.admin_hours(date, date) to authenticated;

revoke execute on function public.check_supervision()      from public, anon, authenticated;
revoke execute on function public.fit_bookings_to_shift()  from public, anon, authenticated;

commit;
