-- ============================================================================
-- Verification for migration 084 (grant_horse — present horse drops)
-- ============================================================================
-- AFTER 065 + 084. Transactional; ROLLS BACK.
-- Success -> notice "ALL GRANT_HORSE TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_owner text := 'test_gh_owner';
    v_ao    uuid;
    r       json;
    v_cnt   int;
    v_cap   int;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_owner, 'gh_owner', 'x') returning id into v_ao;

    -- ── Grant a purchasable breed (free) ─────────────────────────────────────
    r := public.grant_horse(v_owner, 'thoroughbred', 'Freebie');
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL grant thoroughbred: %', r; end if;
    if (r->'horse'->>'breed') <> 'thoroughbred' then raise exception 'FAIL breed echo'; end if;
    if (r->'horse'->>'name') <> 'Freebie' then raise exception 'FAIL name echo'; end if;

    -- ── Grant a MYTHICAL breed (presents are the non-cup way to get these) ───
    r := public.grant_horse(v_owner, 'unicorn');
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL grant unicorn: %', r; end if;
    if (r->'horse'->>'name') <> 'Unicorn Gift' then
        raise exception 'FAIL default name: %', (r->'horse'->>'name');
    end if;
    if not exists (select 1 from public.horses where owner_id = v_ao and breed = 'unicorn') then
        raise exception 'FAIL unicorn not created';
    end if;

    -- ── Unknown breed rejected ───────────────────────────────────────────────
    r := public.grant_horse(v_owner, 'dragon');
    if (r->>'error') is distinct from 'invalid_breed' then
        raise exception 'FAIL invalid breed: %', r;
    end if;

    -- ── Room gate: fill the stable, then a grant is refused ──────────────────
    v_cap := public._horse_stable_capacity(v_ao);
    select count(*) into v_cnt from public.horses where owner_id = v_ao and status = 'active';
    while v_cnt < v_cap loop
        perform public.grant_horse(v_owner, 'arabian');
        v_cnt := v_cnt + 1;
    end loop;
    r := public.grant_horse(v_owner, 'arabian');
    if (r->>'error') is distinct from 'stable_full' then
        raise exception 'FAIL full stable should block grant: %', r;
    end if;

    raise notice 'ALL GRANT_HORSE TESTS PASSED';
end;
$$;

rollback;
