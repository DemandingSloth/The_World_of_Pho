-- ============================================================================
-- Verification for migration 083 (jewelry horse effects)
-- ============================================================================
-- AFTER 065 + 070 + 073 + 078 + 082 + 083. Transactional; ROLLS BACK.
-- Success -> notice "ALL JEWELRY HORSE TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_owner  text := 'test_jh_owner';
    v_ao     uuid;
    r        json;
    v_h1     uuid;
    v_race   uuid;
    v_gain   numeric;
    v_speed  numeric;
    v_end    numeric;
    v_life   numeric;
    v_cap    numeric;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_owner, 'jh_owner', 'x') returning id into v_ao;

    -- ── Jewelry bonus curve helper ───────────────────────────────────────────
    if public._horse_jewelry_bonus_pct(0) <> 0.0 then raise exception 'FAIL pct lvl0'; end if;
    if public._horse_jewelry_bonus_pct(10) <> 0.25 then raise exception 'FAIL pct lvl10'; end if;

    -- ── Training multiplier can push a session gain ABOVE the base cap ────────
    -- Base cap is 10.00; score 90 -> gain 10.00. With mult 2.0 -> 20.00, but the
    -- speed ceiling is 100 so from a low base it should land at base+20.
    r := public.buy_horse(v_owner, 'standardbred', 'Trainee'); v_h1 := (r->'horse'->>'id')::uuid;
    update public.horses set speed = 10, endurance = 10, life = 90, life_cap = 90 where id = v_h1;

    -- Train sprint with mult 1.0 first (baseline): score 90 -> +10 -> speed 20.
    r := public.train_horse(v_owner, v_h1, 'sprint', 90, 1.0);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL baseline train: %', r; end if;
    v_gain := (r->>'gain')::numeric;
    if v_gain <> 10.00 then raise exception 'FAIL baseline gain not 10: %', v_gain; end if;

    -- Now a boosted sprint (mult 2.0): score 90 capped to 10, ×2 = 20 gain.
    -- (speed is now 20; +20 -> 40, under the 100 ceiling, so full 20 lands.)
    r := public.train_horse(v_owner, v_h1, 'sprint', 90, 2.0);
    v_gain := (r->>'gain')::numeric;
    if v_gain <> 20.00 then raise exception 'FAIL boosted gain not 20 (above cap): %', v_gain; end if;
    select speed into v_speed from public.horses where id = v_h1;
    if v_speed <> 40.00 then raise exception 'FAIL speed after boosted train not 40: %', v_speed; end if;

    -- Multiplier clamp: a silly mult is capped at 5.0 (10 × 5 = 50 gain max).
    update public.horses set speed = 0 where id = v_h1;
    r := public.train_horse(v_owner, v_h1, 'sprint', 90, 99.0);
    v_gain := (r->>'gain')::numeric;
    if v_gain <> 50.00 then raise exception 'FAIL mult clamp (want 50): %', v_gain; end if;

    -- ── Register with emerald + pink levels -> snapshot buffed ───────────────
    r := public.buy_horse(v_owner, 'standardbred', 'Decked'); v_h1 := (r->'horse'->>'id')::uuid;
    update public.horses set speed = 40, endurance = 40, life = 80, life_cap = 80 where id = v_h1;

    insert into public.races (name, field_size, status, opens_at, closes_at)
    values ('JewelRace', 8, 'open', now(), now() + interval '5 hours')
    returning id into v_race;

    -- emerald level 10 (+25% across the board), pink level 10 (+25% life_cap).
    r := public.register_horse(v_owner, v_race, v_h1, 0, 10, 10);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL register jewel: %', r; end if;

    select speed, endurance, life, life_cap into v_speed, v_end, v_life, v_cap
    from public.race_entries where race_id = v_race and horse_id = v_h1;
    -- emerald: speed 40×1.25=50, endurance 40×1.25=50, life 80×1.25=100.
    if v_speed <> 50.00 then raise exception 'FAIL emerald speed not 50: %', v_speed; end if;
    if v_end   <> 50.00 then raise exception 'FAIL emerald endurance not 50: %', v_end; end if;
    -- pink: life_cap 80×1.25=100. life clamped to the (buffed) cap: min(100,100)=100.
    if v_cap  <> 100.00 then raise exception 'FAIL pink life_cap not 100: %', v_cap; end if;
    if v_life <> 100.00 then raise exception 'FAIL life not clamped to buffed cap: %', v_life; end if;

    -- ── Ceiling clamp: huge base + emerald can't exceed 100 ──────────────────
    r := public.buy_horse(v_owner, 'standardbred', 'Maxed'); v_h1 := (r->'horse'->>'id')::uuid;
    update public.horses set speed = 95, endurance = 95, life = 150, life_cap = 190 where id = v_h1;
    insert into public.races (name, field_size, status, opens_at, closes_at)
    values ('JewelRace2', 8, 'open', now(), now() + interval '5 hours')
    returning id into v_race;
    r := public.register_horse(v_owner, v_race, v_h1, 0, 10, 10);
    select speed, endurance, life_cap into v_speed, v_end, v_cap
    from public.race_entries where race_id = v_race and horse_id = v_h1;
    if v_speed <> 100.00 then raise exception 'FAIL speed not clamped to 100: %', v_speed; end if;
    if v_end   <> 100.00 then raise exception 'FAIL endurance not clamped to 100: %', v_end; end if;
    if v_cap   <> 200.00 then raise exception 'FAIL life_cap not clamped to 200: %', v_cap; end if;

    -- ── No jewelry (levels 0) -> no buff ─────────────────────────────────────
    r := public.buy_horse(v_owner, 'standardbred', 'Plain'); v_h1 := (r->'horse'->>'id')::uuid;
    update public.horses set speed = 40, endurance = 40, life = 80, life_cap = 80 where id = v_h1;
    insert into public.races (name, field_size, status, opens_at, closes_at)
    values ('JewelRace3', 8, 'open', now(), now() + interval '5 hours')
    returning id into v_race;
    r := public.register_horse(v_owner, v_race, v_h1, 0, 0, 0);
    select speed into v_speed from public.race_entries where race_id = v_race and horse_id = v_h1;
    if v_speed <> 40.00 then raise exception 'FAIL unbuffed speed changed: %', v_speed; end if;

    raise notice 'ALL JEWELRY HORSE TESTS PASSED';
end;
$$;

rollback;
