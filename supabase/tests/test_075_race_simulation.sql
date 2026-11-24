-- ============================================================================
-- Verification for migration 075 (race sim + resolution) — AFTER 065+074+075.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL RACE SIM TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_hash  text := 'test_sim_owner';
    v_acct  uuid;
    r       json;
    v_race  uuid;
    v_h1    uuid;
    v_sim1  jsonb;
    v_sim2  jsonb;
    v_cnt   int;
    v_wins  int;
    v_runs  int;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash, 'sim_owner', 'x') returning id into v_acct;

    r := public.buy_horse(v_hash, 'arabian', 'Hero'); v_h1 := (r->'horse'->>'id')::uuid;

    -- ── Condition multiplier: >=50% full, 25-50% penalty, <25% worse ────────
    if public._race_condition_mult(100, 100) <> 1.00 then raise exception 'FAIL cond full'; end if;
    if public._race_condition_mult(60, 100)  <> 1.00 then raise exception 'FAIL cond 60%%'; end if;
    if public._race_condition_mult(40, 100)  <> 0.85 then raise exception 'FAIL cond 40%%'; end if;
    if public._race_condition_mult(10, 100)  >= 0.85 then raise exception 'FAIL cond 10%% should be worse'; end if;

    -- ── Deterministic RNG: same (seed,stream) -> same value ─────────────────
    if public._race_rng(12345, 7) <> public._race_rng(12345, 7) then
        raise exception 'FAIL rng not deterministic';
    end if;
    if public._race_rng(12345, 7) = public._race_rng(12345, 8) then
        raise exception 'FAIL rng streams collide';  -- extremely unlikely
    end if;

    -- ── Set up a closed race: 1 real horse + register, then force-close ─────
    insert into public.races (name, field_size, status, closes_at)
    values ('SimTest', 8, 'open', now() + interval '30 min')
    returning id into v_race;
    r := public.register_horse(v_hash, v_race, v_h1);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL register: %', r; end if;

    -- Close it (expire + advance). Advance also RESOLVES closed races now.
    update public.races set closes_at = now() - interval '1 min' where id = v_race;
    perform public._horse_advance_races();

    -- Should be resolved with a replay + 8 placements.
    if (select status from public.races where id = v_race) <> 'resolved' then
        raise exception 'FAIL race not resolved after advance';
    end if;
    if (select results_json from public.races where id = v_race) is null then
        raise exception 'FAIL no replay stored';
    end if;
    if (select replay_expires_at from public.races where id = v_race) is null then
        raise exception 'FAIL no replay TTL';
    end if;

    -- finish_place assigned 1..8, unique.
    select count(*) into v_cnt from public.race_entries where race_id = v_race and finish_place is not null;
    if v_cnt <> 8 then raise exception 'FAIL finish_place not set on all 8, got %', v_cnt; end if;
    select count(distinct finish_place) into v_cnt from public.race_entries where race_id = v_race;
    if v_cnt <> 8 then raise exception 'FAIL finish places not unique 1..8'; end if;
    if (select max(finish_place) from public.race_entries where race_id = v_race) <> 8
       or (select min(finish_place) from public.race_entries where race_id = v_race) <> 1 then
        raise exception 'FAIL finish places not 1..8';
    end if;

    -- Real horse got +1 race_run; +1 win iff it placed 1st.
    select races_run, wins into v_runs, v_wins from public.horses where id = v_h1;
    if v_runs <> 1 then raise exception 'FAIL races_run not bumped, got %', v_runs; end if;
    if (select finish_place from public.race_entries where race_id = v_race and horse_id = v_h1) = 1 then
        if v_wins <> 1 then raise exception 'FAIL winner wins not bumped'; end if;
    else
        if v_wins <> 0 then raise exception 'FAIL non-winner got a win'; end if;
    end if;

    -- ── Determinism: re-running the sim on the SAME race gives the SAME result
    v_sim1 := public._race_run_sim(v_race);
    v_sim2 := public._race_run_sim(v_race);
    if v_sim1::text <> v_sim2::text then
        raise exception 'FAIL sim not reproducible for same seed';
    end if;
    -- The stored replay matches a fresh sim run (same seed/entries).
    if (select results_json from public.races where id = v_race)::text <> v_sim1::text then
        raise exception 'FAIL stored replay != fresh sim';
    end if;

    -- ── get_race_result returns the replay + placements ─────────────────────
    r := public.get_race_result(v_hash, v_race);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL get_race_result: %', r; end if;
    if (r->>'has_replay')::boolean <> true then raise exception 'FAIL result has_replay false'; end if;
    if json_array_length(r->'placements') <> 8 then raise exception 'FAIL placements != 8'; end if;
    if (r->'replay'->>'segments')::int <> public._race_segments() then
        raise exception 'FAIL replay segments mismatch: %', r->'replay'->>'segments';
    end if;

    -- ── Replay purge after 12h: expire the TTL, advance, replay cleared ─────
    update public.races set replay_expires_at = now() - interval '1 min' where id = v_race;
    perform public._horse_advance_races();
    if (select results_json from public.races where id = v_race) is not null then
        raise exception 'FAIL replay not purged after TTL';
    end if;
    -- Placements survive the purge (race row + entries remain).
    select count(*) into v_cnt from public.race_entries where race_id = v_race and finish_place is not null;
    if v_cnt <> 8 then raise exception 'FAIL placements lost on purge'; end if;
    -- get_race_result after purge: ok, has_replay false.
    r := public.get_race_result(v_hash, v_race);
    if (r->>'has_replay')::boolean <> false then raise exception 'FAIL has_replay should be false post-purge'; end if;

    raise notice 'ALL RACE SIM TESTS PASSED';
end;
$$;

rollback;
