-- ============================================================================
-- Verification for migration 060 (Benjamin production rush) — RUN AFTER 060.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL RUSH TESTS PASSED".
--
-- A guild member with Benjamins rushes an active craft. Rate = 600s/Benjamin.
-- We set finish_at to a known offset so the arithmetic is deterministic.
-- ============================================================================

begin;

do $$
declare
    v_hash   text := 'test_rush_hash';
    v_hash2  text := 'test_rush_outsider';
    v_acct   uuid;
    v_out    uuid;
    v_guild  uuid;
    v_guild2 uuid;
    v_qid    uuid;
    r        json;
    v_bal    bigint;
    v_rem    numeric;
begin
    -- ── Setup: member with 50 Benjamins; an outsider in another guild ────────
    insert into public.accounts (device_hash, username, recovery_hash, benjamin_balance)
    values (v_hash, 'rush_user', 'x', 50) returning id into v_acct;
    insert into public.accounts (device_hash, username, recovery_hash, benjamin_balance)
    values (v_hash2, 'rush_outsider', 'x', 50) returning id into v_out;

    insert into public.guilds (name, specialization, leader_id)
    values ('test_rush_guild', 'mining', v_acct) returning id into v_guild;
    insert into public.guilds (name, specialization, leader_id)
    values ('test_rush_guild2', 'mining', v_out) returning id into v_guild2;

    insert into public.guild_members (guild_id, account_id, role)
    values (v_guild, v_acct, 'leader'),
           (v_guild2, v_out, 'leader');

    -- ── Rate helper ──────────────────────────────────────────────────────────
    if public._rush_seconds_per_benjamin() <> 600 then
        raise exception 'FAIL rate: expected 600, got %', public._rush_seconds_per_benjamin();
    end if;

    -- ── Insert an active craft finishing in 3000s (50 min) ───────────────────
    insert into public.guild_production_queue
        (guild_id, recipe_id, output_item_key, finish_at, status, enqueued_by)
    values (v_guild, 'gold_ring', 'item:gold_ring', now() + interval '3000 seconds', 'active', v_acct)
    returning id into v_qid;

    -- ── Guard: invalid amount ────────────────────────────────────────────────
    r := public.rush_production(v_hash, v_guild, v_qid, 0);
    if (r->>'error') is distinct from 'invalid_amount' then
        raise exception 'FAIL invalid_amount guard: %', r;
    end if;

    -- ── Guard: outsider (not in this guild) cannot rush ──────────────────────
    r := public.rush_production(v_hash2, v_guild, v_qid, 1);
    if (r->>'error') is distinct from 'not_in_guild' then
        raise exception 'FAIL not_in_guild guard: %', r;
    end if;

    -- ── Guard: wrong guild id for an existing craft ──────────────────────────
    r := public.rush_production(v_hash2, v_guild2, v_qid, 1);
    if (r->>'error') is distinct from 'wrong_guild' then
        raise exception 'FAIL wrong_guild guard: %', r;
    end if;

    -- ── Partial rush: 2 Benjamins -> removes 1200s, finish ~1800s out ────────
    r := public.rush_production(v_hash, v_guild, v_qid, 2);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL partial rush: %', r;
    end if;
    if (r->>'spent')::int <> 2 then
        raise exception 'FAIL partial spent: expected 2, got %', r;
    end if;
    if (r->>'seconds_removed')::bigint <> 1200 then
        raise exception 'FAIL seconds_removed: expected 1200, got %', r;
    end if;
    if (r->>'ready')::boolean <> false then
        raise exception 'FAIL craft should not be ready yet: %', r;
    end if;
    -- Balance 50 - 2 = 48.
    select benjamin_balance into v_bal from public.accounts where id = v_acct;
    if v_bal <> 48 then raise exception 'FAIL balance after partial: expected 48, got %', v_bal; end if;
    -- Remaining time is now ~1800s (allow a small clock slack).
    select extract(epoch from (finish_at - now())) into v_rem
    from public.guild_production_queue where id = v_qid;
    if v_rem < 1700 or v_rem > 1801 then
        raise exception 'FAIL remaining after partial: expected ~1800, got %', v_rem;
    end if;

    -- ── Overshoot: request 10 but only 3 needed to reach now() ───────────────
    -- 1800s left -> ceil(1800/600)=3 Benjamins needed; request 10, charge 3.
    r := public.rush_production(v_hash, v_guild, v_qid, 10);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL overshoot rush: %', r;
    end if;
    if (r->>'spent')::int <> 3 then
        raise exception 'FAIL overshoot spent: expected 3 (only what is needed), got %', r;
    end if;
    if (r->>'ready')::boolean <> true then
        raise exception 'FAIL craft should be ready after overshoot: %', r;
    end if;
    -- Balance 48 - 3 = 45 (NOT 48 - 10).
    select benjamin_balance into v_bal from public.accounts where id = v_acct;
    if v_bal <> 45 then raise exception 'FAIL balance after overshoot: expected 45, got %', v_bal; end if;
    -- finish_at floored at now() -> remaining <= 0.
    select extract(epoch from (finish_at - now())) into v_rem
    from public.guild_production_queue where id = v_qid;
    if v_rem > 1 then raise exception 'FAIL craft not floored to now: remaining %', v_rem; end if;

    -- ── Guard: rushing an already-ready craft is rejected ────────────────────
    r := public.rush_production(v_hash, v_guild, v_qid, 1);
    if (r->>'error') is distinct from 'already_ready' then
        raise exception 'FAIL already_ready guard: %', r;
    end if;

    -- ── Ledger: two 'rush' debits (-2 and -3) referencing the craft ──────────
    if (select coalesce(sum(delta), 0) from public.benjamin_ledger
        where ref_id = v_qid and reason = 'rush') <> -5 then
        raise exception 'FAIL rush ledger sum: expected -5';
    end if;

    -- ── Insufficient benjamins on a fresh craft ──────────────────────────────
    insert into public.guild_production_queue
        (guild_id, recipe_id, output_item_key, finish_at, status, enqueued_by)
    values (v_guild, 'ruby_ring', 'item:ruby_ring', now() + interval '7200 seconds', 'active', v_acct)
    returning id into v_qid;
    -- Drain the wallet to 1 Benjamin, then try to spend 2.
    update public.accounts set benjamin_balance = 1 where id = v_acct;
    r := public.rush_production(v_hash, v_guild, v_qid, 2);
    if (r->>'error') is distinct from 'insufficient_benjamins' then
        raise exception 'FAIL insufficient_benjamins guard: %', r;
    end if;

    -- ── Guard: nonexistent craft ─────────────────────────────────────────────
    r := public.rush_production(v_hash, v_guild, gen_random_uuid(), 1);
    if (r->>'error') is distinct from 'craft_not_found' then
        raise exception 'FAIL craft_not_found guard: %', r;
    end if;

    raise notice 'ALL RUSH TESTS PASSED';
end;
$$;

rollback;
