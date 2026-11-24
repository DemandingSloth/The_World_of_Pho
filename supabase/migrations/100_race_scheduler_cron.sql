-- ============================================================================
-- Migration 100: Run horse races on schedule (server-side cron)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- PROBLEM: races only advanced (open -> betting -> resolved) when a player
-- called a racetrack RPC (get_races, register_horse, place_bet, get_my_bets...),
-- because each of those starts with `perform public._horse_advance_races()`.
-- If nobody opened the racetrack screen, races never locked, never ran, and the
-- entered horses stayed stuck "in a race" indefinitely.
--
-- FIX: a pg_cron job calls _horse_advance_races() every minute, so races lock,
-- run, pay out bets/prizes and deduct life on time with no visitors. The RPCs
-- still call it too, which is harmless (it only acts on races that are due).
--
-- PREREQUISITE: the pg_cron extension. If the CREATE EXTENSION line below
-- errors with a permissions message, enable it instead from the dashboard:
-- Database -> Extensions -> search "pg_cron" -> Enable, then re-run this file.
-- ============================================================================

create extension if not exists pg_cron;


-- Wrapper the cron job calls. Kept separate so the job's command never needs to
-- change if _horse_advance_races is redefined later. Errors are logged by
-- pg_cron (cron.job_run_details) and do not stop future runs.
create or replace function public._cron_advance_races()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    perform public._horse_advance_races();
end;
$$;
revoke all on function public._cron_advance_races() from anon, authenticated;


-- (Re)schedule idempotently: drop any previous job with this name first.
do $$
begin
    if exists (select 1 from cron.job where jobname = 'advance_horse_races') then
        perform cron.unschedule('advance_horse_races');
    end if;
end;
$$;

select cron.schedule(
    'advance_horse_races',
    '* * * * *',                                  -- every minute
    $$ select public._cron_advance_races(); $$
);


-- Catch up right now: resolves any races that were stuck waiting for a visitor
-- (e.g. a horse left "in a race" for weeks).
select public._cron_advance_races();


-- ── Verify (optional) ────────────────────────────────────────────────────────
-- select jobid, jobname, schedule, active from cron.job where jobname = 'advance_horse_races';
-- select status, return_message, start_time from cron.job_run_details
--   where jobid = (select jobid from cron.job where jobname = 'advance_horse_races')
--   order by start_time desc limit 10;
