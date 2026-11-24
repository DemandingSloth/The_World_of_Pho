-- ============================================================================
-- Verification for migration 068 (horse feed) — RUN AFTER 065 + 068.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL FEED TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_hash    text := 'test_feed_owner';
    v_acct    uuid;
    r         json;
    v_id      uuid;
    v_id2     uuid;
    v_restore int := public._horse_feed_restore();
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash, 'feed_owner', 'x') returning id into v_acct;

    -- ── Buy an Arabian (life 100 == life_cap 100) ────────────────────────────
    r := public.buy_horse(v_hash, 'arabian', 'Hungry');
    v_id := (r->'horse'->>'id')::uuid;

    -- ── Feeding a full horse -> already_full ─────────────────────────────────
    r := public.feed_horse(v_hash, v_id);
    if (r->>'error') is distinct from 'already_full' then
        raise exception 'FAIL feed full horse: %', r;
    end if;

    -- ── Knock life down, then feed restores by the fixed amount ──────────────
    update public.horses set life = 10 where id = v_id;
    r := public.feed_horse(v_hash, v_id);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL feed: %', r; end if;
    if (r->>'restored')::int <> v_restore then
        raise exception 'FAIL restored amount: expected %, got %', v_restore, r->>'restored';
    end if;
    if (r->>'life')::int <> 10 + v_restore then
        raise exception 'FAIL life after feed: %', r;
    end if;

    -- ── Feed near the cap clamps (doesn't overshoot life_cap) ────────────────
    update public.horses set life = 100 - 5 where id = v_id;  -- life_cap is 100
    r := public.feed_horse(v_hash, v_id);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL feed near cap: %', r; end if;
    if (r->>'restored')::int <> 5 then
        raise exception 'FAIL clamp restored: expected 5, got %', r->>'restored';
    end if;
    if (r->>'life')::int <> 100 then
        raise exception 'FAIL life clamped to cap: %', r;
    end if;

    -- ── Retired horse can't be fed ───────────────────────────────────────────
    r := public.buy_horse(v_hash, 'thoroughbred', 'Retiree');
    v_id2 := (r->'horse'->>'id')::uuid;
    update public.horses set status = 'retired', life = 10 where id = v_id2;
    r := public.feed_horse(v_hash, v_id2);
    if (r->>'error') is distinct from 'horse_retired' then
        raise exception 'FAIL feed retired: %', r;
    end if;

    -- ── Not your horse / nonexistent ─────────────────────────────────────────
    r := public.feed_horse(v_hash, gen_random_uuid());
    if (r->>'error') is distinct from 'horse_not_found' then
        raise exception 'FAIL feed nonexistent: %', r;
    end if;

    insert into public.accounts (device_hash, username, recovery_hash)
    values ('test_feed_other', 'feed_other', 'x');
    update public.horses set life = 10 where id = v_id;
    r := public.feed_horse('test_feed_other', v_id);
    if (r->>'error') is distinct from 'not_your_horse' then
        raise exception 'FAIL feed not-your-horse: %', r;
    end if;

    raise notice 'ALL FEED TESTS PASSED';
end;
$$;

rollback;
