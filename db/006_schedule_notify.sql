-- =====================================================================
-- J2050 internal tools - migration 006
-- Scope: run the "notify" Edge Function every minute (pg_cron + pg_net).
-- Prerequisites:
--   * migration 005 applied;
--   * Edge Function "notify" deployed, with "Verify JWT" disabled;
--   * Edge Function secrets set: SMTP_USER, SMTP_PASS, NOTIFY_SECRET, SITE_URL.
-- BEFORE RUNNING: replace the two placeholders below
--   <PROJECT-ID>     the project id (as in https://<PROJECT-ID>.supabase.co)
--   <NOTIFY-SECRET>  the same value as the NOTIFY_SECRET Edge Function secret
-- The values are stored in Supabase Vault, not in this file: do NOT commit
-- this file with the real values to the repository.
-- =====================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

select vault.create_secret('https://<PROJECT-ID>.supabase.co/functions/v1/notify', 'notify_url');
select vault.create_secret('<NOTIFY-SECRET>', 'notify_secret');

select cron.schedule(
  'notify-every-minute',
  '* * * * *',
  $$
  select net.http_post(
    url     := (select decrypted_secret from vault.decrypted_secrets where name = 'notify_url'),
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-notify-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'notify_secret')),
    body    := '{"action": "run"}'::jsonb,
    timeout_milliseconds := 30000
  );
  $$
);

-- ---------------------------------------------------------------------
-- Useful commands (run separately when needed)
-- ---------------------------------------------------------------------
-- Test e-mail (replace the address), then read the answer:
--   select net.http_post(
--     url := (select decrypted_secret from vault.decrypted_secrets where name = 'notify_url'),
--     headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret',
--                (select decrypted_secret from vault.decrypted_secrets where name = 'notify_secret')),
--     body := '{"action": "test", "to": "name.surname@studenti.unipd.it"}'::jsonb);
--   select status_code, content from net._http_response order by created desc limit 5;
--
-- Pause / resume the schedule:
--   select cron.alter_job((select jobid from cron.job where jobname = 'notify-every-minute'), active := false);
--   select cron.alter_job((select jobid from cron.job where jobname = 'notify-every-minute'), active := true);
--
-- Last runs:
--   select start_time, status, return_message from cron.job_run_details order by start_time desc limit 10;
