-- =====================================================================
-- J2050 internal tools - migration 004
-- Scope: timeline events (fixed external dates shown as vertical
-- reference lines in the Gantt; not tasks).
-- Prerequisite: migrations 001-003 applied.
-- Run once in Supabase > SQL Editor. Runs as one transaction.
-- =====================================================================
begin;

create table public.timeline_events (
  id          bigint generated always as identity primary key,
  label       text not null check (char_length(trim(label)) between 1 and 40),
  event_date  date not null,
  note        text,
  created_at  timestamptz not null default now()
);

alter table public.timeline_events enable row level security;

create policy read_events on public.timeline_events for select to authenticated
  using (public.is_active());
create policy admin_events on public.timeline_events for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

grant select, insert, update, delete on public.timeline_events to authenticated;
grant usage on all sequences in schema public to authenticated;

-- Event of the previous Gantt ("cap. cinese", 06.02.2027)
insert into public.timeline_events (label, event_date) values ('Chinese New Year', '2027-02-06');

commit;
