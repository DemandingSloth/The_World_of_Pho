-- ============================================================================
-- Verification script for migration 053 (Benjamins + Money Gun) — RUN AFTER 053.
-- ============================================================================
-- Paste into the Supabase SQL editor and Run. Wrapped in a transaction that
-- ROLLS BACK, so it creates NO permanent data. Accrual is time-based, so the
-- test back-dates money_gun_last_claim_at to known offsets and asserts the
-- computed/claimed amounts.
--
-- Success -> single notice "ALL BENJAMIN TESTS PASSED". Any failed assertion
-- raises an exception naming the check.
-- ============================================================================

begin;

do $$
declare
    v_hash text := 'test_benj_hash';
    v_id   uuid;
    r      json;
begin
    -- ── Setup: a throwaway account ──────────────────────────────────────────
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash, 'test_benj_user', 'x') returning id into v_id;

    -- ── Tuning helpers ──────────────────────────────────────────────────────
    if public._money_gun_rate_per_hour(0) <> 1 then
        raise exception 'FAIL rate@0: expected 1, got %', public._money_gun_rate_per_hour(0);
    end if;
    if public._money_gun_rate_per_hour(5) <> 32 then
        raise exception 'FAIL rate@5: expected 32, got %', public._money_gun_rate_per_hour(5);
    end if;
    if public._money_gun_rate_per_hour(10) <> 1024 then
        raise exception 'FAIL rate@10: expected 1024, got %', public._money_gun_rate_per_hour(10);
    end if;
    if public._money_gun_cap(0) <> 48 then
        raise exception 'FAIL cap@0: expected 48, got %', public._money_gun_cap(0);
    end if;

    -- ── Claim before owning a gun is refused ────────────────────────────────
    r := public.claim_benjamins(v_hash);
    if (r->>'error') is distinct from 'no_money_gun' then
        raise exception 'FAIL claim without gun: %', r;
    end if;

    -- ── Buy the gun ─────────────────────────────────────────────────────────
    r := public.buy_money_gun(v_hash);
    if (r->>'ok') is distinct from 'true' or (r->>'level')::int <> 0 then
        raise exception 'FAIL buy_money_gun: %', r;
    end if;
    -- Second buy refused.
    r := public.buy_money_gun(v_hash);
    if (r->>'error') is distinct from 'already_owned' then
        raise exception 'FAIL double-buy guard: %', r;
    end if;

    -- ── Accrual: back-date the clock 10 hours at level 0 (rate 1/h) -> 10 ────
    update public.accounts
    set money_gun_last_claim_at = now() - interval '10 hours'
    where id = v_id;

    -- get_benjamin_balance reports accrued without claiming.
    r := public.get_benjamin_balance(v_hash);
    if (r->>'accrued')::bigint <> 10 then
        raise exception 'FAIL accrued view (10h@1/h): expected 10, got %', r;
    end if;
    if (r->>'balance')::bigint <> 0 then
        raise exception 'FAIL balance before claim: expected 0, got %', r;
    end if;

    -- Claim credits exactly 10.
    r := public.claim_benjamins(v_hash);
    if (r->>'claimed')::bigint <> 10 or (r->>'balance')::bigint <> 10 then
        raise exception 'FAIL claim (10h@1/h): %', r;
    end if;

    -- Ledger row written for the print.
    if not exists (
        select 1 from public.benjamin_ledger
        where account_id = v_id and reason = 'money_gun' and delta = 10
    ) then
        raise exception 'FAIL ledger row for 10-Benjamin print';
    end if;

    -- Immediately claiming again accrues ~0 (clock just reset) -> no-op.
    r := public.claim_benjamins(v_hash);
    if (r->>'claimed')::bigint <> 0 or (r->>'balance')::bigint <> 10 then
        raise exception 'FAIL immediate re-claim no-op: %', r;
    end if;

    -- ── Cap: back-date 100 hours at level 0 -> capped at 48 ─────────────────
    update public.accounts
    set money_gun_last_claim_at = now() - interval '100 hours'
    where id = v_id;
    r := public.claim_benjamins(v_hash);
    if (r->>'claimed')::bigint <> 48 then
        raise exception 'FAIL cap clamp (100h@1/h -> 48): %', r;
    end if;
    -- balance now 10 + 48 = 58.
    if (r->>'balance')::bigint <> 58 then
        raise exception 'FAIL balance after cap claim: expected 58, got %', r;
    end if;

    -- ── Upgrade settles at OLD rate, then raises level ──────────────────────
    -- Back-date 5 hours at level 0 (rate 1/h) -> upgrade should settle 5 first.
    update public.accounts
    set money_gun_last_claim_at = now() - interval '5 hours'
    where id = v_id;
    r := public.upgrade_money_gun(v_hash);
    if (r->>'ok') is distinct from 'true' or (r->>'level')::int <> 1 then
        raise exception 'FAIL upgrade to level 1: %', r;
    end if;
    if (r->>'claimed')::bigint <> 5 then
        raise exception 'FAIL upgrade settles old-rate accrual (expected 5): %', r;
    end if;
    -- balance now 58 + 5 = 63.
    if (r->>'balance')::bigint <> 63 then
        raise exception 'FAIL balance after upgrade settle: expected 63, got %', r;
    end if;

    -- At level 1 (rate 2/h), 3 hours -> 6.
    update public.accounts
    set money_gun_last_claim_at = now() - interval '3 hours'
    where id = v_id;
    r := public.claim_benjamins(v_hash);
    if (r->>'claimed')::bigint <> 6 then
        raise exception 'FAIL claim at level 1 (3h@2/h -> 6): %', r;
    end if;

    raise notice 'ALL BENJAMIN TESTS PASSED';
end;
$$;

rollback;
