-- ============================================================================
-- Verification for migration 076 (betting + lifecycle) — AFTER 065+074+075+076.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL BETTING TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_owner  text := 'test_bet_owner';     -- has a horse in the race
    v_bettor text := 'test_bet_bettor';    -- bets (no horse in the race)
    v_ao     uuid;
    v_ab     uuid;
    r        json;
    v_race   uuid;
    v_h1     uuid;
    v_winlane int;
    v_odds   numeric;
    v_bet    uuid;
    v_cnt    int;
    v_payout bigint;
    v_won    boolean;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_owner, 'bet_owner', 'x') returning id into v_ao;
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_bettor, 'bet_bettor', 'x') returning id into v_ab;

    r := public.buy_horse(v_owner, 'arabian', 'Racer'); v_h1 := (r->'horse'->>'id')::uuid;

    -- ── Open race, owner registers; force the 5h cap to lock it to 'betting' ─
    insert into public.races (name, field_size, status, opens_at, closes_at)
    values ('BetTest', 8, 'open', now(), now() + interval '5 hours')
    returning id into v_race;
    r := public.register_horse(v_owner, v_race, v_h1);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL register: %', r; end if;

    -- Expire the 5h cap, advance -> should move to betting (NPC backfill + odds).
    update public.races set closes_at = now() - interval '1 min' where id = v_race;
    perform public._horse_advance_races();
    if (select status from public.races where id = v_race) <> 'betting' then
        raise exception 'FAIL race should be betting after cap elapses';
    end if;
    select count(*) into v_cnt from public.race_entries where race_id = v_race;
    if v_cnt <> 8 then raise exception 'FAIL field not backfilled to 8: %', v_cnt; end if;
    -- Odds snapshotted on every lane.
    select count(*) into v_cnt from public.race_entries where race_id = v_race and odds is not null;
    if v_cnt <> 8 then raise exception 'FAIL odds not set on all lanes: %', v_cnt; end if;
    if (select bet_closes_at from public.races where id = v_race) is null then
        raise exception 'FAIL bet_closes_at not set';
    end if;

    -- ── Owner CANNOT bet on a race they're in ────────────────────────────────
    r := public.place_bet(v_owner, v_race, 1, 'coins', 1000);
    if (r->>'error') is distinct from 'own_race' then
        raise exception 'FAIL owner betting own race: %', r;
    end if;

    -- ── Bad inputs ───────────────────────────────────────────────────────────
    r := public.place_bet(v_bettor, v_race, 99, 'coins', 1000);
    if (r->>'error') is distinct from 'bad_lane' then raise exception 'FAIL bad_lane: %', r; end if;
    r := public.place_bet(v_bettor, v_race, 0, 'gold', 1000);
    if (r->>'error') is distinct from 'bad_currency' then raise exception 'FAIL bad_currency: %', r; end if;
    r := public.place_bet(v_bettor, v_race, 0, 'coins', 0);
    if (r->>'error') is distinct from 'bad_stake' then raise exception 'FAIL bad_stake: %', r; end if;

    -- ── Bettor places a WINNING bet: pick the lane that will finish 1st ──────
    -- Peek the deterministic result (sim is pure) to know the eventual winner.
    v_winlane := ((public._race_run_sim(v_race)->'order')->>0)::int;
    select odds into v_odds from public.race_entries where race_id = v_race and lane = v_winlane;

    r := public.place_bet(v_bettor, v_race, v_winlane, 'coins', 1000);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL place winning bet: %', r; end if;
    v_bet := (r->>'bet_id')::uuid;
    if (r->>'odds')::numeric <> v_odds then raise exception 'FAIL bet odds snapshot: %', r; end if;

    -- ── A LOSING bet on a different lane ─────────────────────────────────────
    r := public.place_bet(v_bettor, v_race, (v_winlane + 1) % 8, 'coins', 500);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL place losing bet: %', r; end if;

    -- ── Resolve: expire the betting window, advance -> resolved + settle bets ─
    update public.races set bet_closes_at = now() - interval '1 min' where id = v_race;
    perform public._horse_advance_races();
    if (select status from public.races where id = v_race) <> 'resolved' then
        raise exception 'FAIL race not resolved after betting window';
    end if;

    -- Winning bet: settled, won, payout = round(1000*odds).
    select won, payout into v_won, v_payout from public.bets where id = v_bet;
    if not v_won then raise exception 'FAIL winning bet not marked won'; end if;
    if v_payout <> (1000 * v_odds)::bigint then
        raise exception 'FAIL payout != stake*odds: payout=% odds=%', v_payout, v_odds;
    end if;

    -- Losing bet: settled, not won, payout 0.
    select count(*) into v_cnt from public.bets
    where race_id = v_race and account_id = v_ab and not won and settled and payout = 0;
    if v_cnt <> 1 then raise exception 'FAIL losing bet not settled to 0'; end if;

    -- ── Can't bet on a resolved race ─────────────────────────────────────────
    r := public.place_bet(v_bettor, v_race, v_winlane, 'coins', 100);
    if (r->>'error') is distinct from 'not_betting' then
        raise exception 'FAIL bet on resolved race: %', r;
    end if;

    -- ── get_my_bets returns both bets, newest first, settled ─────────────────
    r := public.get_my_bets(v_bettor, v_race);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL get_my_bets: %', r; end if;
    if json_array_length(r->'bets') <> 2 then
        raise exception 'FAIL get_my_bets count: %', json_array_length(r->'bets');
    end if;

    -- ── Field FILLS -> auto-lock to betting (no need to wait the 5h cap) ─────
    insert into public.races (name, field_size, status, opens_at, closes_at)
    values ('FillLock', 8, 'open', now(), now() + interval '5 hours')
    returning id into v_race;
    -- Direct-insert 8 entries, then advance.
    for v_cnt in 0..7 loop
        insert into public.race_entries (race_id, lane, is_npc, display_name, breed,
            speed, endurance, life, life_cap)
        values (v_race, v_cnt, true, 'NPC' || v_cnt, 'thoroughbred', 20, 18, 60, 60);
    end loop;
    perform public._horse_advance_races();
    if (select status from public.races where id = v_race) <> 'betting' then
        raise exception 'FAIL full field should auto-lock to betting';
    end if;

    raise notice 'ALL BETTING TESTS PASSED';
end;
$$;

rollback;
