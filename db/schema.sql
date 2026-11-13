-- =====================================================================
-- J2050 internal tools - database schema (Supabase / PostgreSQL)
-- Scope: Gantt (tasks, dependencies) and laboratory shift booking
-- Run once in Supabase > SQL Editor, BEFORE creating any user.
-- Project settings assumed: "Automatically expose new tables" = OFF,
-- "Enable automatic RLS" = ON. Privileges are therefore granted explicitly.
-- =====================================================================

-- ============ PROFILES AND ROLES ============
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text,
  role       text not null default 'user' check (role in ('admin','user'))
);

-- Create the profile automatically when a user is created
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name) values (new.id, new.email);
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'admin');
$$;

-- ============ GANTT ============
create table public.tasks (
  id          bigint generated always as identity primary key,
  parent_id   bigint references public.tasks(id) on delete cascade,
  name        text not null,
  start_date  date not null,
  end_date    date not null,
  progress    smallint not null default 0 check (progress between 0 and 100),
  check (end_date >= start_date)
);

create table public.task_dependencies (
  task_id     bigint references public.tasks(id) on delete cascade,
  depends_on  bigint references public.tasks(id) on delete cascade,
  primary key (task_id, depends_on),
  check (task_id <> depends_on)
);

-- ============ LAB SHIFTS ============
create table public.shifts (
  id         bigint generated always as identity primary key,
  task_id    bigint not null references public.tasks(id) on delete restrict,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  capacity   smallint not null check (capacity > 0),
  location   text,
  notes      text,
  check (ends_at > starts_at)
);

create table public.assignments (
  shift_id    bigint references public.shifts(id) on delete cascade,
  user_id     uuid   references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (shift_id, user_id)          -- no double booking
);

-- ============ ROW LEVEL SECURITY ============
alter table public.profiles          enable row level security;
alter table public.tasks             enable row level security;
alter table public.task_dependencies enable row level security;
alter table public.shifts            enable row level security;
alter table public.assignments       enable row level security;

-- Read: all authenticated users
create policy read_profiles on public.profiles          for select to authenticated using (true);
create policy read_tasks    on public.tasks             for select to authenticated using (true);
create policy read_deps     on public.task_dependencies for select to authenticated using (true);
create policy read_shifts   on public.shifts            for select to authenticated using (true);
create policy read_assign   on public.assignments       for select to authenticated using (true);

-- Write Gantt and shifts: admin only
create policy admin_tasks  on public.tasks             for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_deps   on public.task_dependencies for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_shifts on public.shifts            for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Assignments: no INSERT policy (booking only through book_shift);
-- delete own booking, or any booking if admin
create policy delete_assign on public.assignments for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- Profiles: users may change their own name only, never the role
create policy update_own_profile on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- ============ ATOMIC BOOKING ============
create function public.book_shift(p_shift_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_capacity smallint;
  v_starts   timestamptz;
  v_count    integer;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- Lock the shift row: concurrent bookings of the same shift are serialized
  select capacity, starts_at into v_capacity, v_starts
  from shifts where id = p_shift_id for update;

  if not found then raise exception 'Shift not found'; end if;
  if v_starts < now() then raise exception 'Shift already started'; end if;

  select count(*) into v_count from assignments where shift_id = p_shift_id;
  if v_count >= v_capacity then raise exception 'Shift full'; end if;

  insert into assignments (shift_id, user_id) values (p_shift_id, auth.uid());
exception
  when unique_violation then raise exception 'Already booked';
end $$;

-- Shifts with number of bookings (respects RLS of underlying tables)
create view public.shifts_with_count with (security_invoker = true) as
select s.*, count(a.user_id)::int as booked
from public.shifts s
left join public.assignments a on a.shift_id = s.id
group by s.id;

-- ============ EXPLICIT PRIVILEGES (Data API) ============
-- No privilege to role anon: nothing is visible without login.
grant usage on schema public to authenticated;

grant select on public.profiles, public.tasks, public.task_dependencies,
               public.shifts, public.assignments, public.shifts_with_count
  to authenticated;

grant insert, update, delete on public.tasks, public.task_dependencies, public.shifts
  to authenticated;

grant delete on public.assignments to authenticated;

revoke update on public.profiles from authenticated;
grant  update (full_name) on public.profiles to authenticated;

grant usage on all sequences in schema public to authenticated;

revoke execute on function public.is_admin()        from public, anon;
grant  execute on function public.is_admin()        to authenticated;
revoke execute on function public.book_shift(bigint) from public, anon;
grant  execute on function public.book_shift(bigint) to authenticated;