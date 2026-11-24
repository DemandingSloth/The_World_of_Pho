-- ============================================================================
-- Migration 086: get_recent_results — resolved races you can watch (polish)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 074/075/076/077 (races + resolve + replay) + 076 (bets) applied.
--
-- The Races tab previously surfaced only OPEN + BETTING races (get_races), so a
-- player who ENTERED a horse (but didn't bet) had no way to see the result or
-- watch the replay — the only Watch button lived in My Bets. This adds a
-- recent-results feed: resolved races the caller was INVOLVED in (entered a
-- horse OR placed a bet) within the 12h replay window, newest first, each with
-- the winner + whether a replay is still available. The client renders a
-- "Recent Results" section with a Watch Replay button (get_race_result drives
-- the actual playback, unchanged).
--
--   get_recent_results(device_hash) ->
--     { ok, now, races:[{ id, name, kind, run_at, replay_expires_at,
--         has_replay, mine_entered, mine_bet,
--         winner:{ display_name, breed, is_npc, mine } }] }
-- ============================================================================

create or replace function public.get_recent_results(p_device_hash text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_races   json;
begin
    -- Advance first so a just-finished race is already 'resolved' here.
    perform public._horse_advance_races();
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select coalesce(json_agg(rj order by rj_run desc), '[]'::json) into v_races
    from (
        select
            r.run_at as rj_run,
            json_build_object(
                'id', r.id, 'name', r.name, 'kind', r.kind,
                'run_at', r.run_at, 'replay_expires_at', r.replay_expires_at,
                -- A replay is watchable until it's purged (12h) — results_json
                -- is nulled on purge, so its presence is the source of truth.
                'has_replay', (r.results_json is not null),
                'mine_entered', exists (
                    select 1 from public.race_entries e
                    where e.race_id = r.id and e.owner_id = v_account),
                'mine_bet', exists (
                    select 1 from public.bets b
                    where b.race_id = r.id and b.account_id = v_account),
                'winner', (
                    select json_build_object(
                        'display_name', e.display_name,
                        'breed', e.breed,
                        'is_npc', e.is_npc,
                        'mine', (e.owner_id is not null and e.owner_id = v_account)
                    )
                    from public.race_entries e
                    where e.race_id = r.id and e.finish_place = 1
                    limit 1
                )
            ) as rj
        from public.races r
        where r.status = 'resolved'
          and r.run_at is not null
          -- Only within the 12h replay/visibility window.
          and (r.replay_expires_at is null or r.replay_expires_at > now())
          -- Only races the caller was part of (entered a horse OR bet).
          and (
              exists (select 1 from public.race_entries e
                      where e.race_id = r.id and e.owner_id = v_account)
              or exists (select 1 from public.bets b
                         where b.race_id = r.id and b.account_id = v_account)
          )
    ) sub;

    return json_build_object('ok', true, 'now', now(), 'races', v_races);
end;
$$;
grant execute on function public.get_recent_results(text) to anon, authenticated;
