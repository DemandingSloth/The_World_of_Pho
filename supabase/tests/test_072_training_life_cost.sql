-- ============================================================================
-- Verification for migration 072 (training life cost) — RUN AFTER 065..072.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL LIFE-COST TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_hash text := 'test_lifecost_owner';
    v_acct uuid;
    r      json;
    v_id   uuid;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash, 'lifecost_owner', 'x') returning id into v_acct;

    -- ── Life cost curve: score 0 -> 1, 90 -> 5, mid scales, clamps 1..5 ──────
    if public._horse_training_life_cost(0)   <> 1 then raise exception 'FAIL life_cost(0)'; end if;
    if public._horse_training_life_cost(90)  <> 5 then raise exception 'FAIL life_cost(90)'; end if;
    if public._horse_training_life_cost(45)  <> 3 then raise exception 'FAIL life_cost(45) expected 3'; end if;
    if public._horse_training_life_cost(-10) <> 1 then raise exception 'FAIL life_cost negative'; end if;
    if public._horse_training_life_cost(999) <> 5 then raise exception 'FAIL life_cost over'; end if;

    -- ── Sprint drains life by the cost; no cooldown (train twice) ────────────
    r := public.buy_horse(v_hash, 'thoroughbred', 'Worker');  -- life 80
    v_id := (r->'horse'->>'id')::uuid;

    r := public.train_horse(v_hash, v_id, 'sprint', 90);  -- gain capped, cost 5
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL sprint: %', r; end if;
    if (r->>'life_cost')::int <> 5 then raise exception 'FAIL sprint life_cost: %', r; end if;
    if (r->>'retired')::boolean <> false then raise exception 'FAIL sprint not retired yet: %', r; end if;
    if (r->'horse'->>'life')::numeric <> 75.00 then raise exception 'FAIL life after sprint: %', r; end if;

    -- Immediately train again (NO daily cooldown on sprint).
    r := public.train_horse(v_hash, v_id, 'sprint', 0);  -- cost 1
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL 2nd sprint (should be allowed): %', r; end if;
    if (r->>'life_cost')::int <> 1 then raise exception 'FAIL 2nd sprint cost: %', r; end if;
    if (r->'horse'->>'life')::numeric <> 74.00 then raise exception 'FAIL life after 2nd sprint: %', r; end if;

    -- ── Hurdle also drains + no cooldown ─────────────────────────────────────
    r := public.train_horse(v_hash, v_id, 'hurdle', 90);  -- cost 5
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL hurdle: %', r; end if;
    if (r->'horse'->>'life')::numeric <> 69.00 then raise exception 'FAIL life after hurdle: %', r; end if;

    -- ── Work to death: drop life low, a run that drains past 0 retires it ────
    update public.horses set life = 3 where id = v_id;
    r := public.train_horse(v_hash, v_id, 'sprint', 90);  -- cost 5 > 3 -> dies
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL fatal sprint ok: %', r; end if;
    if (r->>'retired')::boolean <> true then raise exception 'FAIL should be retired: %', r; end if;
    if (r->'horse'->>'life')::numeric <> 0 then raise exception 'FAIL dead horse life 0: %', r; end if;
    if (r->'horse'->>'status') is distinct from 'retired' then raise exception 'FAIL status retired: %', r; end if;
    -- The earned stat gain from that final run still applied (speed went up).

    -- ── A retired horse can't train ──────────────────────────────────────────
    r := public.train_horse(v_hash, v_id, 'sprint', 50);
    if (r->>'error') is distinct from 'horse_retired' then
        raise exception 'FAIL train retired horse: %', r;
    end if;

    -- ── GROOM still capped once/day + NO life cost ───────────────────────────
    r := public.buy_horse(v_hash, 'arabian', 'Pretty');  -- life 100 / cap 100
    v_id := (r->'horse'->>'id')::uuid;
    update public.horses set life = 50, life_cap = 100 where id = v_id;  -- room to groom
    r := public.train_horse(v_hash, v_id, 'groom', 90);  -- no life drain, once/day
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL groom: %', r; end if;
    if (r->>'life_cost')::int <> 0 then raise exception 'FAIL groom should cost no life: %', r; end if;
    if (r->>'retired')::boolean <> false then raise exception 'FAIL groom not retired: %', r; end if;
    -- Second groom same day blocked.
    r := public.train_horse(v_hash, v_id, 'groom', 90);
    if (r->>'error') is distinct from 'already_trained' then
        raise exception 'FAIL groom cooldown: %', r;
    end if;

    raise notice 'ALL LIFE-COST TESTS PASSED';
end;
$$;

rollback;
