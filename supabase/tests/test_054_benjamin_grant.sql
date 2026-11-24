-- ============================================================================
-- Verification for migration 054 (grant_benjamins cheat) — RUN AFTER 054.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL GRANT TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_hash   text := 'test_grant_hash';
    v_id     uuid;
    v_secret text := public._benjamin_grant_secret();
    r        json;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash, 'test_grant_user', 'x') returning id into v_id;

    -- Wrong secret -> bad_secret, no mint.
    r := public.grant_benjamins(v_hash, 10, 'wrong-secret');
    if (r->>'error') is distinct from 'bad_secret' then
        raise exception 'FAIL bad_secret guard: %', r;
    end if;

    -- Correct secret grants 10.
    r := public.grant_benjamins(v_hash, 10, v_secret);
    if (r->>'ok') is distinct from 'true' or (r->>'granted')::bigint <> 10
       or (r->>'balance')::bigint <> 10 then
        raise exception 'FAIL grant 10: %', r;
    end if;

    -- Ledger row written with reason cheat_grant.
    if not exists (
        select 1 from public.benjamin_ledger
        where account_id = v_id and reason = 'cheat_grant' and delta = 10
    ) then
        raise exception 'FAIL cheat_grant ledger row';
    end if;

    -- Invalid amount rejected.
    r := public.grant_benjamins(v_hash, 0, v_secret);
    if (r->>'error') is distinct from 'invalid_amount' then
        raise exception 'FAIL invalid_amount guard: %', r;
    end if;

    -- Per-call cap clamps a huge request.
    r := public.grant_benjamins(v_hash, 999999999, v_secret);
    if (r->>'granted')::bigint <> public._benjamin_grant_cap() then
        raise exception 'FAIL per-call cap clamp: %', r;
    end if;

    raise notice 'ALL GRANT TESTS PASSED';
end;
$$;

rollback;
