-- ============================================================================
-- Verification for migration 073 (groom raises life, cap follows) — AFTER 073.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL GROOM-FILL TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_hash text := 'test_groomfill_owner';
    v_acct uuid;
    r      json;
    v_id   uuid;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash, 'groomfill_owner', 'x') returning id into v_acct;

    r := public.buy_horse(v_hash, 'arabian', 'Shiny');
    v_id := (r->'horse'->>'id')::uuid;

    -- ── 80/100, groom +5 -> 85/100 (cap unchanged, room to spare) ────────────
    update public.horses set life = 80, life_cap = 100 where id = v_id;
    r := public.train_horse(v_hash, v_id, 'groom', 90);  -- raw gain 10, halved -> +5
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL groom A: %', r; end if;
    if (r->>'gain')::numeric <> 5.00 then raise exception 'FAIL groom A gain: %', r; end if;
    if (r->'horse'->>'life')::numeric <> 85.00 then raise exception 'FAIL groom A life: %', r; end if;
    if (r->'horse'->>'life_cap')::numeric <> 100.00 then raise exception 'FAIL groom A cap moved: %', r; end if;
    if (r->>'life_cost')::int <> 0 then raise exception 'FAIL groom A no life cost: %', r; end if;

    -- ── 96/100, groom +5 -> 101/101 (life overflows, cap bumps to 101) ───────
    delete from public.horse_training where horse_id = v_id and kind = 'groom';  -- clear cooldown
    update public.horses set life = 96, life_cap = 100 where id = v_id;
    r := public.train_horse(v_hash, v_id, 'groom', 90);  -- +5
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL groom B: %', r; end if;
    if (r->'horse'->>'life')::numeric <> 101.00 then raise exception 'FAIL groom B life: %', r; end if;
    if (r->'horse'->>'life_cap')::numeric <> 101.00 then raise exception 'FAIL groom B cap: %', r; end if;

    -- ── Partial overflow: 99/100, groom +5 -> 104/104 ───────────────────────
    delete from public.horse_training where horse_id = v_id and kind = 'groom';
    update public.horses set life = 99, life_cap = 100 where id = v_id;
    r := public.train_horse(v_hash, v_id, 'groom', 90);
    if (r->'horse'->>'life')::numeric <> 104.00 then raise exception 'FAIL groom C life: %', r; end if;
    if (r->'horse'->>'life_cap')::numeric <> 104.00 then raise exception 'FAIL groom C cap: %', r; end if;

    -- ── Hard ceiling 200: life 199 cap 199 groom +5 clamps to 200/200 ────────
    delete from public.horse_training where horse_id = v_id and kind = 'groom';
    update public.horses set life = 199, life_cap = 199 where id = v_id;
    r := public.train_horse(v_hash, v_id, 'groom', 90);
    if (r->'horse'->>'life')::numeric <> 200.00 then raise exception 'FAIL groom ceiling life: %', r; end if;
    if (r->'horse'->>'life_cap')::numeric <> 200.00 then raise exception 'FAIL groom ceiling cap: %', r; end if;
    if (r->>'gain')::numeric <> 1.00 then raise exception 'FAIL groom ceiling gain clamp (expected +1.00): %', r; end if;

    -- ── Cap already at 200 -> at_ceiling ─────────────────────────────────────
    delete from public.horse_training where horse_id = v_id and kind = 'groom';
    update public.horses set life = 150, life_cap = 200 where id = v_id;
    r := public.train_horse(v_hash, v_id, 'groom', 90);
    if (r->>'error') is distinct from 'at_ceiling' then raise exception 'FAIL groom at_ceiling: %', r; end if;

    raise notice 'ALL GROOM-FILL TESTS PASSED';
end;
$$;

rollback;
