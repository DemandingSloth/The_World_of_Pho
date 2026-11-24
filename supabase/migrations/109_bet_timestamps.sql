-- ============================================================================
-- Migration 109: My Bets — include when the bet was placed + the race name
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 076 (get_my_bets).
--
-- Bet result rows all looked identical (same stake/lane/odds text). get_my_bets
-- now also returns, per bet:
--   placed_at   — when the bet was placed (epoch seconds)
--   race_name   — the race it was on
--   resolved_at — when the race finished (epoch seconds, null until resolved)
-- Same shape otherwise, so older clients keep working.
-- ============================================================================

create or replace function public.get_my_bets(
    p_device_hash text,
    p_race_id     uuid default null
)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_bets    json;
begin
    perform public._horse_advance_races();
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select coalesce(json_agg(json_build_object(
        'id', b.id, 'race_id', b.race_id, 'lane', b.lane, 'currency', b.currency,
        'stake', b.stake, 'odds', b.odds, 'settled', b.settled, 'won', b.won,
        'payout', b.payout, 'race_status', r.status,
        'race_name',   r.name,
        'placed_at',   extract(epoch from b.created_at),
        'resolved_at', extract(epoch from r.resolved_at)
    ) order by b.created_at desc), '[]'::json)
    into v_bets
    from public.bets b
    join public.races r on r.id = b.race_id
    where b.account_id = v_account
      and (p_race_id is null or b.race_id = p_race_id);

    return json_build_object('ok', true, 'bets', v_bets);
end;
$$;
grant execute on function public.get_my_bets(text, uuid) to anon, authenticated;
