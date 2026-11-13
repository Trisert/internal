-- =====================================================================
-- J2050 internal tools - migration 003
-- Scope:
--   * task fields of the project Gantt (code, responsible, status,
--     estimated duration, note, sub-teams, milestone label)
--   * one-level hierarchy: task > subtask
--   * dependencies without cycles
--   * import of the 59 tasks of the previous Gantt (tasks.json, 09.11.2026)
-- Prerequisite: migrations 001 and 002 applied.
-- Run once in Supabase > SQL Editor. Runs as one transaction.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Remove the test task created during the permission checks
--    (only if no shift refers to it)
-- ---------------------------------------------------------------------
delete from public.tasks t
where t.name = 'Test'
  and not exists (select 1 from public.shifts s where s.task_id = t.id)
  and not exists (select 1 from public.shift_requests r where r.task_id = t.id);

-- ---------------------------------------------------------------------
-- 2. Task fields
-- ---------------------------------------------------------------------
alter table public.tasks drop column progress;

alter table public.tasks
  add column code            text check (char_length(code) between 1 and 20),
  add column responsible     text,
  add column status          text not null default 'todo'
                             check (status in ('todo', 'working', 'done', 'late', 'qm_risk', 'long_term')),
  add column duration_days   integer not null default 1 check (duration_days >= 1),
  add column note            text,
  add column teams           text[] not null default '{}',
  add column milestone_label text,
  add column created_at      timestamptz not null default now();

-- ---------------------------------------------------------------------
-- 3. Hierarchy limited to one level (task > subtask)
-- ---------------------------------------------------------------------
create function public.check_task_parent() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.parent_id is not null then
    if new.parent_id = new.id then
      raise exception 'A task cannot be its own parent';
    end if;
    if exists (select 1 from tasks where id = new.parent_id and parent_id is not null) then
      raise exception 'Subtasks cannot have subtasks';
    end if;
    if exists (select 1 from tasks where parent_id = new.id) then
      raise exception 'A task with subtasks cannot become a subtask';
    end if;
  end if;
  return new;
end $$;

create trigger tasks_parent_check
  before insert or update of parent_id on public.tasks
  for each row execute function public.check_task_parent();

-- ---------------------------------------------------------------------
-- 4. Dependencies without cycles
--    Row (task_id, depends_on): task_id cannot start before depends_on ends.
-- ---------------------------------------------------------------------
create function public.check_task_dependency() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (
    with recursive chain(id) as (
      select d.depends_on from task_dependencies d where d.task_id = new.depends_on
      union
      select d.depends_on from task_dependencies d join chain c on d.task_id = c.id
    )
    select 1 from chain where id = new.task_id
  ) then
    raise exception 'Dependency would create a cycle';
  end if;
  return new;
end $$;

create trigger task_dependencies_cycle_check
  before insert or update on public.task_dependencies
  for each row execute function public.check_task_dependency();

-- ---------------------------------------------------------------------
-- 5. Import of the previous Gantt
--    Status mapping: Da fare -> todo, Working -> working, DONE -> done.
--    Sub-teams derived from the "responsible" field with the keyword rules
--    of the previous Gantt; afterwards they are edited explicitly.
-- ---------------------------------------------------------------------
insert into public.tasks (code, name, responsible, status, start_date, end_date, duration_days, note, teams, milestone_label) values
  ('A0', 'Passare i blocchi della sliding plate a Federico', 'Giacomo', 'done', '2026-11-04', '2026-11-07', 2, null, array['ELECTRONICS']::text[], null),
  ('A1', 'Istituire il board con riunione settimanale', 'Giacomo, Marco', 'done', '2026-11-04', '2026-11-08', 3, null, array['ELECTRONICS','BOARD-PM']::text[], null),
  ('A2', 'Nominare la persona SYSTEMS per il coordinamento frequenze', 'SYSTEMS', 'done', '2026-11-04', '2026-11-08', 2, null, array['SYSTEMS']::text[], null),
  ('A3', 'Individuare le reclute per i compiti aperti', 'Marco Segato', 'working', '2026-11-04', '2026-11-08', 4, null, array['BOARD-PM']::text[], null),
  ('A4', 'Verificare stato dell''architettura FreeRTOS e del GitHub', 'Nicola Destro', 'done', '2026-11-03', '2026-11-08', 3, null, array['SOFTWARE']::text[], null),
  ('A5', 'Avviare il CAD post-descoping', 'Enrico', 'done', '2026-11-03', '2026-11-08', 2, 'START I0', array['TERMOMECH']::text[], null),
  ('B0', 'Banco di sviluppo con gli EM per SOFTWARE', 'Giacomo', 'working', '2026-11-06', '2026-11-15', 7, null, array['ELECTRONICS']::text[], null),
  ('B1', 'Stack-up meccanico (ordine e distanze delle schede)', 'Enrico', 'working', '2026-11-06', '2026-11-18', 8, 'BETTER BEFORE', array['TERMOMECH']::text[], null),
  ('C0', 'Layout EPS per l''iterazione', 'Giacomo', 'todo', '2026-11-12', '2026-11-20', 10, null, array['ELECTRONICS']::text[], null),
  ('C1', 'Layout sliding plate per l''iterazione', 'Federico Di Bella', 'working', '2026-11-10', '2026-11-20', 10, null, array['ELECTRONICS']::text[], null),
  ('C2', 'Correzione footprint radio della Board-Telecomm', 'Recluta KiCad, Federico', 'working', '2026-11-11', '2026-11-20', 7, null, array['ELECTRONICS']::text[], null),
  ('C3', 'Correzione routing OBC', 'Giacomo', 'done', '2026-11-12', '2026-11-20', 3, null, array['ELECTRONICS']::text[], null),
  ('C4', 'Disegno scheda di test LED', 'Recluta ELECTRONICS', 'todo', '2026-11-09', '2026-11-20', 9, null, array['ELECTRONICS']::text[], null),
  ('C5', 'Modello, frequenza e disponibilità su JLC della radio', 'Alessandro Vignato', 'working', '2026-11-09', '2026-11-20', 5, 'ASAP', array['TELECOM']::text[], null),
  ('C6', 'Ordine iterazione a JLC (EPS, sliding, Board-Telecomm, OBC, test LED)', 'Giacomo', 'todo', '2026-11-16', '2026-11-20', 3, 'IMPORTANT DEADLINE', array['ELECTRONICS']::text[], null),
  ('C7', 'Stima costi del batch con margine del 30%', 'Giacomo', 'todo', '2026-11-11', '2026-11-20', 8, null, array['ELECTRONICS']::text[], null),
  ('C8', 'Lista spacer con lunghezze di riserva', 'Enrico', 'todo', '2026-11-18', '2026-11-20', 2, null, array['TERMOMECH']::text[], null),
  ('C9', 'Scelta della resina a basso outgassing', 'TERMOMECH, AOCS', 'done', '2026-11-09', '2026-11-20', 7, null, array['AOCS','TERMOMECH']::text[], null),
  ('C10', 'Materiali di montaggio dei pannelli', 'Giacomo', 'working', '2026-11-10', '2026-11-20', 10, null, array['ELECTRONICS']::text[], null),
  ('C11', 'Procedura di montaggio dei pannelli', 'Recluta TERMOMECH, Enrico', 'todo', '2026-11-15', '2026-11-20', 5, null, array['TERMOMECH']::text[], null),
  ('D0', 'Requisiti di livello 1 congelati', 'SYSTEMS', 'working', '2026-11-03', '2026-11-22', 18, 'HIGHER PRIORITY', array['SYSTEMS']::text[], null),
  ('D1', 'Avviare la stesura della checklist di review', 'Recluta ELECTRONICS', 'todo', '2026-11-20', '2026-11-23', 3, null, array['ELECTRONICS']::text[], null),
  ('E0', 'Top-up del credito JLC tramite università', 'Giacomo', 'todo', '2026-11-09', '2026-11-27', 7, null, array['ELECTRONICS']::text[], null),
  ('E1', 'Ordini Mouser: spacer, materiali pannelli, resina, pulizia, stagno', 'Giacomo', 'todo', '2026-11-23', '2026-11-27', 4, null, array['ELECTRONICS']::text[], null),
  ('F0', 'Pinout del backplane sulla sliding plate', 'Giacomo, Federico', 'todo', '2026-11-09', '2026-11-30', 5, null, array['ELECTRONICS']::text[], null),
  ('F1', 'Decidere se la conversione Z+ porta i segnali delle facce', 'Giacomo', 'todo', '2026-11-09', '2026-11-30', 3, 'BETTER BEFORE', array['ELECTRONICS']::text[], null),
  ('F2', 'Driver I2C MCP23017 (CS payload SPI)', 'SOFTWARE', 'todo', '2026-11-25', '2026-11-30', 5, null, array['SOFTWARE']::text[], null),
  ('F3', 'Chiusura formato frame EPS-OBC + driver telemetria(DA DECIDERE)', 'SOFTWARE', 'todo', '2026-11-25', '2026-11-30', 5, null, array['SOFTWARE']::text[], null),
  ('G0', 'BOM freeze e ordini JLC Global Sourcing', 'ELECTRONICS', 'todo', '2026-11-23', '2026-12-05', 10, null, array['ELECTRONICS']::text[], null),
  ('G1', 'Interfacce meccaniche delle facce', 'TERMOMECH', 'todo', '2026-11-19', '2026-12-07', 14, null, array['TERMOMECH']::text[], null),
  ('K2', 'Sleep/Stop nel firmware', 'SOFTWARE', 'todo', '2026-12-05', '2026-12-10', 5, null, array['SOFTWARE']::text[], null),
  ('H0', 'Test EPS: charger-MPPT, termica charger, protezione batteria', 'Giacomo', 'todo', '2026-11-25', '2026-12-14', 10, null, array['ELECTRONICS']::text[], null),
  ('H1', 'Test watchdog hardware sull''EM OBC', 'Reclute ELECTRONICS e SOFTWARE', 'todo', '2026-11-23', '2026-12-14', 8, null, array['ELECTRONICS','SOFTWARE']::text[], null),
  ('H2', 'Tuning H-bridge AOCS e valori aggiornati in BOM', 'ELECTRONICS', 'todo', '2026-11-23', '2026-12-14', 10, null, array['ELECTRONICS']::text[], null),
  ('H3', 'Test fotodiodi rifatto e documentato', 'Reclute SYS e ELECTRONICS', 'todo', '2026-11-23', '2026-12-14', 10, null, array['SYSTEMS','ELECTRONICS']::text[], null),
  ('H4', 'Domanda di coordinamento IARU', 'SYSTEMS, Alessandro', 'todo', '2026-11-16', '2026-12-15', 21, null, array['SYSTEMS','TELECOM']::text[], null),
  ('H5', 'Checklist di review', 'Recluta ELECTRONICS', 'todo', '2026-11-23', '2026-12-15', 7, null, array['ELECTRONICS']::text[], null),
  ('H6', 'FreeRTOS con driver sull''EM OBC', 'SOFTWARE', 'todo', '2026-11-15', '2026-12-15', 21, null, array['SOFTWARE']::text[], null),
  ('H7', 'Driver camera ArduCam SPI', 'SOFTWARE', 'todo', '2026-11-10', '2026-12-15', 5, null, array['SOFTWARE']::text[], null),
  ('H8', 'Verifica GPIO radio in HIL', 'SOFTWARE', 'todo', '2026-12-13', '2026-12-18', 5, null, array['SOFTWARE']::text[], null),
  ('I0', 'CAD post-descoping completo', 'TERMOMECH', 'working', '2026-11-08', '2026-12-20', 42, 'STOP A5', array['TERMOMECH']::text[], null),
  ('I1', 'Design freeze: schede, meccanica, requisiti L2, budget, ICD', 'Tutti i reparti', 'todo', '2026-12-15', '2026-12-29', 14, null, array['SYSTEMS','ELECTRONICS','SOFTWARE','AOCS','TERMOMECH','TELECOM','OUTREACH']::text[], 'Design freeze'),
  ('I2', 'Inizio stesura procedura QM', 'SYSTEMS', 'todo', '2026-12-30', '2027-01-04', 5, null, array['SYSTEMS']::text[], null),
  ('J0', 'Review del design', 'ELECTRONICS, SYSTEMS', 'todo', '2026-12-29', '2027-01-05', 7, null, array['SYSTEMS','ELECTRONICS']::text[], null),
  ('K0', 'Ordine batch JLC (QM + FM + spare)', 'Giacomo', 'todo', '2027-01-05', '2027-01-10', 5, null, array['ELECTRONICS']::text[], null),
  ('K1', 'Verification matrix', 'SYSTEMS', 'todo', '2026-12-01', '2027-01-10', 14, 'START in dec', array['SYSTEMS']::text[], null),
  ('L0', 'Test plan', 'SYSTEMS', 'todo', '2026-12-14', '2027-01-15', 14, null, array['SYSTEMS']::text[], null),
  ('L1', 'Moduli di test EPS, AOCS e Telecomm', 'SOFTWARE', 'todo', '2026-12-16', '2027-01-15', 30, null, array['SOFTWARE']::text[], null),
  ('M0', 'Firmware di test e procedure funzionali (AOCS: Niccolò, TELECOM: Alessandro)', 'SOFTWARE, SYSTEMS', 'todo', '2027-01-04', '2027-01-31', 16, null, array['SYSTEMS','SOFTWARE','AOCS','TELECOM']::text[], null),
  ('M1', 'Aggiornamento analisi FEM e termica', 'TERMOMECH', 'todo', '2026-12-21', '2027-01-31', 21, null, array['TERMOMECH']::text[], null),
  ('M2', 'DML', 'SYSTEMS', 'todo', '2026-12-07', '2027-01-31', 14, null, array['SYSTEMS']::text[], null),
  ('M3', 'Magnetorquer in 3 set e procedura di winding', 'Reclute SYSTEMS e AOCS', 'todo', '2026-11-30', '2027-01-31', 21, null, array['SYSTEMS','AOCS']::text[], null),
  ('M4', 'Fine stesura procedura QM', 'SYSTEMS', 'todo', '2027-01-26', '2027-01-31', 5, null, array['SYSTEMS']::text[], null),
  ('N0', 'Inizio integrazione QM', 'Giacomo, Federico', 'todo', '2027-01-18', '2027-02-01', 7, null, array['ELECTRONICS']::text[], 'QM integration'),
  ('N1', 'Procedure ambientali (vibrazione, TVAC)', 'SYSTEMS', 'todo', '2027-01-18', '2027-02-15', 14, null, array['SYSTEMS']::text[], null),
  ('N2', 'VCD', 'SYSTEMS', 'todo', '2027-01-04', '2027-02-20', 20, null, array['SYSTEMS']::text[], null),
  ('N3', 'Test funzionali di base sul QM', 'SOFTWARE, SYSTEMS', 'todo', '2027-02-08', '2027-02-20', 10, null, array['SYSTEMS','SOFTWARE']::text[], null),
  ('N4', 'Greenlight ESA (data da confermare)', 'Board', 'todo', '2027-02-15', '2027-02-26', 7, null, array['BOARD-PM']::text[], null),
  ('N5', 'Campagna di test QM alla CubeSat Support Facility', 'Board', 'todo', '2027-02-01', '2027-03-26', 28, null, array['BOARD-PM']::text[], null);

-- Dependencies: first code depends on second code (old tasks.json: "req" = tasks that need this one)
insert into public.task_dependencies (task_id, depends_on)
select a.id, b.id from (values
  ('I0', 'A5'),
  ('H6', 'B0'),
  ('C0', 'B1'),
  ('C1', 'B1'),
  ('C6', 'C0'),
  ('C6', 'C1'),
  ('C6', 'C5'),
  ('E1', 'C8'),
  ('E1', 'C9'),
  ('E1', 'C10'),
  ('H5', 'D1'),
  ('G0', 'F0'),
  ('K2', 'F2'),
  ('K2', 'F3'),
  ('H8', 'H1')
) as d(task_code, dep_code)
join public.tasks a on a.code = d.task_code
join public.tasks b on b.code = d.dep_code;

-- ---------------------------------------------------------------------
-- 6. Code mandatory and unique (tasks without code get "T<id>")
-- ---------------------------------------------------------------------
update public.tasks set code = 'T' || id where code is null;
alter table public.tasks alter column code set not null;
alter table public.tasks add constraint tasks_code_unique unique (code);

-- ---------------------------------------------------------------------
-- 7. Privileges: trigger functions never callable directly
--    (table privileges of migration 001 already cover the new columns)
-- ---------------------------------------------------------------------
revoke execute on function public.check_task_parent()     from public, anon, authenticated;
revoke execute on function public.check_task_dependency() from public, anon, authenticated;

commit;
