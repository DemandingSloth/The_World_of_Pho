-- ============================================================================
-- Migration 110: get_server_time — the game's trusted clock
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Players were moving their phone's date forward to finish every timer
-- (orchard, garden, workshop, ...) instantly, then moving it back. The game now
-- keeps its own clock (TrustedClock autoload) anchored to the SERVER's time and
-- advanced with the phone's monotonic timer, so changing the phone's date has
-- no effect while online. This is the time source it anchors to.
--
-- Returns { now: epoch seconds (float) }. No account needed.
-- ============================================================================

create or replace function public.get_server_time()
returns json
language sql
volatile
as $$
    select json_build_object('now', extract(epoch from clock_timestamp()));
$$;
grant execute on function public.get_server_time() to anon, authenticated;
