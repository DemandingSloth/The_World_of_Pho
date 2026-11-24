-- ============================================================================
-- Verification for migration 065 (horses) — RUN AFTER 065.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL HORSE TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_hash  text := 'test_horse_owner';
    v_acct  uuid;
    r       json;
    v_id    uuid;
    v_cnt   int;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash, 'horse_owner', 'x') returning id into v_acct;

    -- ── Breed stats helper ───────────────────────────────────────────────────
    if (select life from public._horse_breed_stats('thoroughbred')) <> 80 then
        raise exception 'FAIL thoroughbred life';
    end if;
    if (select purchasable from public._horse_breed_stats('unicorn')) <> false then
        raise exception 'FAIL unicorn should not be purchasable';
    end if;
    if exists (select 1 from public._horse_breed_stats('dragon')) then
        raise exception 'FAIL unknown breed should return no row';
    end if;

    -- ── Invalid breed / mythical rejected ────────────────────────────────────
    r := public.buy_horse(v_hash, 'dragon', 'Sparky');
    if (r->>'error') is distinct from 'invalid_breed' then
        raise exception 'FAIL invalid_breed: %', r;
    end if;
    r := public.buy_horse(v_hash, 'unicorn', 'Sparkle');
    if (r->>'error') is distinct from 'not_purchasable' then
        raise exception 'FAIL mythical not purchasable: %', r;
    end if;

    -- ── Invalid name ─────────────────────────────────────────────────────────
    r := public.buy_horse(v_hash, 'arabian', '');
    if (r->>'error') is distinct from 'invalid_name' then
        raise exception 'FAIL empty name: %', r;
    end if;
    r := public.buy_horse(v_hash, 'arabian', repeat('x', 25));
    if (r->>'error') is distinct from 'invalid_name' then
        raise exception 'FAIL overlong name: %', r;
    end if;

    -- ── Buy an Arabian (100/8/10 -> total 118 -> price 11,800,000) ───────────
    r := public.buy_horse(v_hash, 'arabian', 'Secretariat');
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL buy arabian: %', r;
    end if;
    if (r->>'price')::bigint <> 11800000 then
        raise exception 'FAIL arabian price: expected 11800000, got %', r->>'price';
    end if;
    if (r->'horse'->>'life')::int <> 100 or (r->'horse'->>'endurance')::int <> 10 then
        raise exception 'FAIL arabian stats: %', r;
    end if;
    if (r->'horse'->>'life_cap')::int <> 100 then
        raise exception 'FAIL arabian life_cap should equal base life: %', r;
    end if;
    v_id := (r->'horse'->>'id')::uuid;

    -- ── Stable capacity: base 5. Fill to 5, 6th rejected ─────────────────────
    perform public.buy_horse(v_hash, 'thoroughbred', 'A2');
    perform public.buy_horse(v_hash, 'thoroughbred', 'A3');
    perform public.buy_horse(v_hash, 'thoroughbred', 'A4');
    perform public.buy_horse(v_hash, 'thoroughbred', 'A5');
    select count(*) into v_cnt from public.horses where owner_id = v_acct and status = 'active';
    if v_cnt <> 5 then raise exception 'FAIL expected 5 active horses, got %', v_cnt; end if;

    r := public.buy_horse(v_hash, 'thoroughbred', 'A6');
    if (r->>'error') is distinct from 'stable_full' then
        raise exception 'FAIL 6th horse should hit stable_full: %', r;
    end if;

    -- ── get_horses reflects the 5 + capacity ─────────────────────────────────
    r := public.get_horses(v_hash);
    if (r->>'capacity')::int <> 5 then raise exception 'FAIL capacity in get_horses'; end if;
    if json_array_length(r->'horses') <> 5 then
        raise exception 'FAIL get_horses count: %', json_array_length(r->'horses');
    end if;

    -- ── Sell the Arabian: (118)^2 * 10000 = 139,240,000 ──────────────────────
    r := public.sell_horse(v_hash, v_id);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL sell arabian: %', r;
    end if;
    if (r->>'price')::bigint <> 139240000 then
        raise exception 'FAIL sell price: expected 139240000, got %', r->>'price';
    end if;
    -- Horse removed; stable back to 4.
    select count(*) into v_cnt from public.horses where owner_id = v_acct and status = 'active';
    if v_cnt <> 4 then raise exception 'FAIL active count after sell: expected 4, got %', v_cnt; end if;

    -- ── Can't sell someone else's / nonexistent horse ────────────────────────
    r := public.sell_horse(v_hash, gen_random_uuid());
    if (r->>'error') is distinct from 'horse_not_found' then
        raise exception 'FAIL sell nonexistent: %', r;
    end if;

    insert into public.accounts (device_hash, username, recovery_hash)
    values ('test_horse_other', 'horse_other', 'x');
    r := public.sell_horse('test_horse_other',
        (select id from public.horses where owner_id = v_acct limit 1));
    if (r->>'error') is distinct from 'not_your_horse' then
        raise exception 'FAIL sell not-your-horse: %', r;
    end if;

    raise notice 'ALL HORSE TESTS PASSED';
end;
$$;

rollback;
