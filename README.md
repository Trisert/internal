# J2050 Team Management

Internal web tool of the J2050 team (University of Padova): project Gantt and laboratory shift booking.

Site: <https://j2050space.github.io/internal/> (login required).

## Architecture

| Component | Service | Content |
|---|---|---|
| Web pages (HTML, CSS, JavaScript) | GitHub Pages, repository `J2050space/internal` | Static files of this repository; no build step |
| Database, authentication | Supabase project "J2050 Team Management" (EU region) | PostgreSQL with Row Level Security; e-mail and password login |
| Notification service | Supabase Edge Function `notify`, run every minute by `pg_cron` | Calendar invitations, reminders, task and registration notices |
| E-mail sending | Gmail account `j2050space@gmail.com` (SMTP, app password) | Authentication e-mails and notifications |

All rules (permissions, capacity, overlaps, supervision, codes, dates) are enforced in the database.
The pages only check inputs to give clear messages before sending.

## Pages

| Page | Users | Content |
|---|---|---|
| `index.html`, `register.html`, `welcome.html`, `forgot.html`, `reset.html` | everyone | Login, registration (only `@studenti.unipd.it` and `@unipd.it`), first access, password reset |
| `shifts.html` | active members | Lab shifts: two weekly grids, half-hour slots 08:30-18:30, booking, shift requests |
| `gantt.html` | active members (editing: admins) | Project Gantt, task editor, timeline events |
| `account.html` | active members | Name and password |
| `stats.html` | admins | Booked hours of ended shifts, by person and by task |
| `members.html` | admins | Approval of registrations, roles, department leaders |

## Roles

| Role | Rights |
|---|---|
| `user` | Books lab slots as participant, requests shifts, reads the Gantt |
| `teamleader` | As `user`; can be leader of a department or of a task |
| `admin` | Everything: Gantt editing, shifts, approvals, members. Always supervisor in the lab (not counted in the capacity) |

A new account is `pending` until an admin approves it in `members.html`.

## Planning model (Gantt)

- Task code generated on creation: `<department>-<nn>` (e.g. `ELE-01`); subtask `<parent>.<n>` (e.g. `ELE-01.2`).
  Numbers are never reused. Code, parent and department of a top-level task cannot be changed.
- Departments: SYS, ELE, SFW, AOCS, THM, TTC, OUT, MGT.
- Dates: planned start and end (the bar), optional deadline (the gap is the margin), actual start and completion dates.
- Status derived from the dates: Planned, Not started (late), In progress, Overdue, Done; plus Blocked (manual, with reason) and At risk (planned end after the deadline, or deadline passed).
- A task with subtasks takes dates and progress from its subtasks.
- Default leader: leader of the task department, then leader of the parent task; an admin can set a different leader on the task.

## Database migrations

The database is built by running the scripts of `db/` **in order**, once each, in Supabase > SQL Editor.
Each script runs as a single transaction.

| Script | Content |
|---|---|
| `schema.sql` | Base tables, Row Level Security, atomic booking |
| `002_registration_and_requests.sql` | Self-registration, approval, shift requests |
| `003_gantt_tasks.sql` | Gantt fields, import of the first Gantt (removed by 009) |
| `004_timeline_events.sql` | Timeline events |
| `005_roles_leaders_notifications.sql` | Teamleader role, leaders, statistics, notification support |
| `006_schedule_notify.sql` | Schedule of the notification service (**contains placeholders: never commit real values**) |
| `007_half_hour_slots.sql` | Bookings by half-hour slots, supervisors |
| `008_gantt_editing.sql` | Atomic task save, concurrent-change check, change history |
| `009_gantt_reset_new_model.sql` | Gantt reset, task codes, new date and status model |

Project settings assumed: "Automatically expose new tables" disabled, "Enable automatic RLS" enabled.
New tables therefore need explicit `grant` statements and Row Level Security policies.

Rule for changes: never modify an applied script; write a new numbered script.
Test it first on a separate test project when possible.

## Configuration

`js/config.js` contains the Supabase project URL and the **publishable (anon) key**, which is public by design.
The **secret / service_role key must never appear in this repository.**

Secrets are stored in the team password manager (entry names, not values):

- Supabase organisation owners and database password;
- Gmail `j2050space@gmail.com` and its app password for SMTP;
- `NOTIFY_SECRET` of the notification service.

Edge Function secrets (Supabase > Edge Functions > Secrets): `SMTP_USER`, `SMTP_PASS`, `NOTIFY_SECRET`, `SITE_URL`.

## Notification service

Code: `supabase/functions/notify/index.ts`. Deployed manually in Supabase > Edge Functions, with JWT verification disabled
(access protected by `NOTIFY_SECRET`). Activation steps and useful commands are in `db/006_schedule_notify.sql`.

## Operations

- **Backup**: the free Supabase plan gives no restore guarantee. Export the Gantt (Export CSV) and the main tables regularly to SharePoint.
- **Inactivity**: free projects are paused after a period without activity; resume from the Supabase dashboard.
- **Ownership**: Supabase organisation, GitHub organisation and Gmail account shall each have at least two owners.
- **Personal data**: names, e-mail addresses and lab hours of the members are stored; the team is informed of it.
