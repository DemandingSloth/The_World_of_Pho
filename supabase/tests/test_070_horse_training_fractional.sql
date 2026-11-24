-- ============================================================================
-- Verification for migration 070 (fractional training) — RUN AFTER 065+067+070.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL FRACTIONAL TRAINING TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_hash   text := 'test_frac_owner';
    v_acct   uuid;
    r        json;
    v_id     uuid;
    v_sp0    numeric;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash, 'frac_owner', 'x') returning id into v_acct;

    -- ── Session cap is 10.00 by default ──────────────────────────────────────
    if public._horse_training_session_cap(v_acct) <> 10.00 then
        raise exception 'FAIL session cap default';
    end if;

    -- ── Gain formula = round(score/10 + 1, 2), floored 1, capped ─────────────
    if public._horse_training_gain(0, 10.00)  <> 1.00 then raise exception 'FAIL gain(0)'; end if;
    if public._horse_training_gain(10, 10.00) <> 2.00 then raise exception 'FAIL gain(10)'; end if;
    if public._horse_training_gain(5, 10.00)  <> 1.50 then raise exception 'FAIL gain(5)'; end if;
    if public._horse_training_gain(23, 10.00) <> 3.30 then raise exception 'FAIL gain(23) expected 3.30'; end if;
    if public._horse_training_gain(90, 10.00) <> 10.00 then raise exception 'FAIL gain(90)'; end if;
    -- cap applies: score 200 -> would be 21.00, capped to 10.00
    if public._horse_training_gain(200, 10.00) <> 10.00 then raise exception 'FAIL gain cap'; end if;
    -- negative score floors to 1.00
    if public._horse_training_gain(-5, 10.00) <> 1.00 then raise exception 'FAIL gain negative'; end if;
    -- a smaller cap clamps lower
    if public._horse_training_gain(90, 3.00) <> 3.00 then raise exception 'FAIL gain small cap'; end if;

    -- ── Stats are now fractional: buy, then train sprint with score 5 (+1.50) ─
    r := public.buy_horse(v_hash, 'thoroughbred', 'Frac');   -- speed base 10
    v_id := (r->'horse'->>'id')::uuid;
    v_sp0 := (r->'horse'->>'speed')::numeric;                -- 10

    r := public.train_horse(v_hash, v_id, 'sprint', 5);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL sprint: %', r; end if;
    if (r->>'gain')::numeric <> 1.50 then raise exception 'FAIL sprint gain: %', r; end if;
    if (r->'horse'->>'speed')::numeric <> v_sp0 + 1.50 then
        raise exception 'FAIL speed after sprint: %', r;
    end if;

    -- ── Cooldown still once-per-day-per-kind ─────────────────────────────────
    r := public.train_horse(v_hash, v_id, 'sprint', 50);
    if (r->>'error') is distinct from 'already_trained' then
        raise exception 'FAIL sprint cooldown: %', r;
    end if;

    -- ── Session cap: hurdle score 90 -> +10.00 (endurance 6 -> 16.00) ────────
    r := public.train_horse(v_hash, v_id, 'hurdle', 90);
    if (r->>'gain')::numeric <> 10.00 then raise exception 'FAIL hurdle cap gain: %', r; end if;
    if (r->'horse'->>'endurance')::numeric <> 16.00 then
        raise exception 'FAIL endurance after hurdle: %', r;
    end if;

    -- ── Ceiling clamp: speed at 99.50, +1.50 would be 101 -> clamps to 100 ───
    update public.horses set speed = 99.50 where id = v_id;
    delete from public.horse_training where horse_id = v_id and kind = 'sprint';
    r := public.train_horse(v_hash, v_id, 'sprint', 5);   -- raw +1.50
    if (r->>'gain')::numeric <> 0.50 then raise exception 'FAIL clamp gain near ceiling: %', r; end if;
    if (r->'horse'->>'speed')::numeric <> 100.00 then raise exception 'FAIL speed clamp: %', r; end if;

    -- ── at_ceiling once maxed ────────────────────────────────────────────────
    delete from public.horse_training where horse_id = v_id and kind = 'sprint';
    r := public.train_horse(v_hash, v_id, 'sprint', 90);
    if (r->>'error') is distinct from 'at_ceiling' then
        raise exception 'FAIL at_ceiling: %', r;
    end if;

    -- ── groom raises life_cap fractionally + keeps life <= cap ───────────────
    update public.horses set life = 40, life_cap = 80 where id = v_id;
    r := public.train_horse(v_hash, v_id, 'groom', 5);  -- +1.50 cap
    if (r->'horse'->>'life_cap')::numeric <> 81.50 then
        raise exception 'FAIL life_cap after groom: %', r;
    end if;
    if (r->'horse'->>'life')::numeric > (r->'horse'->>'life_cap')::numeric then
        raise exception 'FAIL life exceeds cap: %', r;
    end if;

    raise notice 'ALL FRACTIONAL TRAINING TESTS PASSED';
end;
$$;

rollback;
