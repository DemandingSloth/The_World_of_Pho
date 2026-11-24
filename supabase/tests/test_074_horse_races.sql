-- ============================================================================
-- Verification for migration 074 (horse races) — RUN AFTER 065 + 074.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL RACE TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_hash  text := 'test_race_owner';
    v_hash2 text := 'test_race_other';
    v_acct  uuid;
    v_acct2 uuid;
    r       json;
    v_race  uuid;
    v_h1    uuid;
    v_h2    uuid;
    v_h3    uuid;
    v_cnt   int;
    v_npc   int;
    i       int;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash, 'race_owner', 'x') returning id into v_acct;
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash2, 'race_other', 'x') returning id into v_acct2;

    -- Three active horses for the owner.
    r := public.buy_horse(v_hash, 'thoroughbred', 'Alpha'); v_h1 := (r->'horse'->>'id')::uuid;
    r := public.buy_horse(v_hash, 'arabian',      'Beta');  v_h2 := (r->'horse'->>'id')::uuid;
    r := public.buy_horse(v_hash, 'standardbred', 'Gamma'); v_h3 := (r->'horse'->>'id')::uuid;

    -- ── get_races lazily creates an open race ────────────────────────────────
    r := public.get_races(v_hash);
    if json_array_length(r->'races') < 1 then
        raise exception 'FAIL get_races should auto-create an open race: %', r;
    end if;
    v_race := ((r->'races')->0->>'id')::uuid;
    if ((r->'races')->0->>'status') is distinct from 'open' then
        raise exception 'FAIL first race not open: %', r;
    end if;

    -- ── Register a horse -> lane 0, snapshot, mine=true ──────────────────────
    r := public.register_horse(v_hash, v_race, v_h1);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL register: %', r; end if;
    if (r->>'lane')::int <> 0 then raise exception 'FAIL first lane should be 0: %', r; end if;

    -- ── Can't enter the same horse twice in the same race ────────────────────
    r := public.register_horse(v_hash, v_race, v_h1);
    if (r->>'error') is distinct from 'already_entered' then
        raise exception 'FAIL double-enter same race: %', r;
    end if;

    -- ── A horse already in a non-resolved race can't enter a DIFFERENT one ───
    -- (make a second open race by expiring none; just reuse logic: register h1
    --  into the same race already blocked; now test horse_in_race via a 2nd race)
    insert into public.races (name, field_size, opens_at, closes_at)
    values ('Second', 8, now(), now() + interval '30 min')
    returning id into v_race;  -- v_race now = the second race
    r := public.register_horse(v_hash, v_race, v_h1);
    if (r->>'error') is distinct from 'horse_in_race' then
        raise exception 'FAIL horse already in another race: %', r;
    end if;

    -- A different horse CAN enter the second race.
    r := public.register_horse(v_hash, v_race, v_h2);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL register h2 in 2nd race: %', r; end if;

    -- ── Not your horse ───────────────────────────────────────────────────────
    r := public.register_horse(v_hash2, v_race, v_h3);
    if (r->>'error') is distinct from 'not_your_horse' then
        raise exception 'FAIL register not-your-horse: %', r;
    end if;

    -- ── Retired horse can't register ─────────────────────────────────────────
    update public.horses set status = 'retired' where id = v_h3;
    r := public.register_horse(v_hash, v_race, v_h3);
    if (r->>'error') is distinct from 'horse_retired' then
        raise exception 'FAIL register retired horse: %', r;
    end if;

    -- ── Close + NPC backfill: expire the second race, advance, check field=8 ─
    update public.races set closes_at = now() - interval '1 min' where id = v_race;
    perform public._horse_advance_races();
    if (select status from public.races where id = v_race) <> 'closed' then
        raise exception 'FAIL race should be closed after advance';
    end if;
    select count(*) into v_cnt from public.race_entries where race_id = v_race;
    if v_cnt <> 8 then raise exception 'FAIL field should be 8 after backfill, got %', v_cnt; end if;
    select count(*) into v_npc from public.race_entries where race_id = v_race and is_npc;
    if v_npc <> 7 then raise exception 'FAIL expected 7 NPCs (1 real horse), got %', v_npc; end if;
    -- Seed assigned at close.
    if (select seed from public.races where id = v_race) is null then
        raise exception 'FAIL closed race should have a seed';
    end if;
    -- Lanes are unique 0..7.
    select count(distinct lane) into v_cnt from public.race_entries where race_id = v_race;
    if v_cnt <> 8 then raise exception 'FAIL lanes not unique 0..7: distinct=%', v_cnt; end if;

    -- ── Can't register into a closed race ────────────────────────────────────
    r := public.buy_horse(v_hash, 'thoroughbred', 'Delta');
    r := public.register_horse(v_hash, v_race, (r->'horse'->>'id')::uuid);
    if (r->>'error') is distinct from 'race_closed' then
        raise exception 'FAIL register into closed race: %', r;
    end if;

    -- ── Advance keeps >=1 open race available ────────────────────────────────
    perform public._horse_advance_races();
    select count(*) into v_cnt from public.races where status = 'open';
    if v_cnt < 1 then raise exception 'FAIL no open race after advance'; end if;

    -- ── race_full: fill an open race's 8 lanes, 9th real reg -> race_full ────
    -- Use a FRESH empty open race (an auto-created one may already have entries).
    insert into public.races (name, field_size, status, closes_at)
    values ('FullTest', 8, 'open', now() + interval '30 min')
    returning id into v_race;
    for i in 1..8 loop
        r := public.buy_horse(v_hash, 'thoroughbred', 'Fill' || i);
        -- force into lane via direct insert (bypass one-race rule for the test)
        insert into public.race_entries (race_id, lane, is_npc, horse_id, owner_id,
            display_name, breed, speed, endurance, life)
        values (v_race, i - 1, false, (r->'horse'->>'id')::uuid, v_acct,
            'Fill' || i, 'thoroughbred', 10, 6, 80);
    end loop;
    -- The 9th entrant: insert a fresh active horse directly (the owner is well
    -- past the 5-horse stable cap by now, so buy_horse would return stable_full).
    declare
        v_overflow uuid;
    begin
        insert into public.horses (owner_id, name, breed, life, life_cap, speed, endurance)
        values (v_acct, 'Overflow', 'arabian', 100, 100, 8, 10)
        returning id into v_overflow;
        r := public.register_horse(v_hash, v_race, v_overflow);
    end;
    if (r->>'error') is distinct from 'race_full' then
        raise exception 'FAIL 9th registration should be race_full: %', r;
    end if;

    raise notice 'ALL RACE TESTS PASSED';
end;
$$;

rollback;
