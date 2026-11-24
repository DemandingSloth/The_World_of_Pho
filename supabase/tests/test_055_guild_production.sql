-- ============================================================================
-- Verification for migration 055 (Guild Production) — RUN AFTER 055.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL PRODUCTION TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_hash   text := 'test_prod_hash';
    v_acct   uuid;
    v_guild  uuid;
    r        json;
    v_qid    uuid;
    v_cnt    int;
    v_gold   bigint;
    v_ingot  bigint;
begin
    -- ── Setup: account + guild + membership ─────────────────────────────────
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash, 'test_prod_user', 'x') returning id into v_acct;
    insert into public.guilds (name, specialization, leader_id)
    values ('test_prod_guild', 'mining', v_acct) returning id into v_guild;
    insert into public.guild_members (guild_id, account_id, role)
    values (v_guild, v_acct, 'leader');

    -- Stockpile: enough for a gold_ring (20 gem:gold + 5 resource:gold_ingot).
    insert into public.guild_stockpile (guild_id, item_key, amount) values
        (v_guild, 'gem:gold', 100),
        (v_guild, 'resource:gold_ingot', 50);

    -- ── Capacity / parallel helpers at level 0 ──────────────────────────────
    if public._guild_production_capacity(v_guild) <> 3 then
        raise exception 'FAIL capacity@0: expected 3, got %', public._guild_production_capacity(v_guild);
    end if;
    if public._guild_production_parallel(v_guild) <> 1 then
        raise exception 'FAIL parallel@0: expected 1, got %', public._guild_production_parallel(v_guild);
    end if;

    -- ── Invalid recipe rejected ─────────────────────────────────────────────
    r := public.enqueue_production(v_hash, v_guild, 'not_a_recipe');
    if (r->>'error') is distinct from 'invalid_recipe' then
        raise exception 'FAIL invalid_recipe guard: %', r;
    end if;

    -- ── Locked stockpile blocks production ──────────────────────────────────
    update public.guilds set stockpile_locked = true where id = v_guild;
    r := public.enqueue_production(v_hash, v_guild, 'gold_ring');
    if (r->>'error') is distinct from 'stockpile_locked' then
        raise exception 'FAIL locked guard: %', r;
    end if;
    update public.guilds set stockpile_locked = false where id = v_guild;

    -- ── Reserved stock is protected (reserve all gold -> insufficient) ──────
    update public.guild_stockpile set reserved = 100 where guild_id = v_guild and item_key = 'gem:gold';
    r := public.enqueue_production(v_hash, v_guild, 'gold_ring');
    if (r->>'error') is distinct from 'insufficient_stock' then
        raise exception 'FAIL reserved-protection: %', r;
    end if;
    update public.guild_stockpile set reserved = 0 where guild_id = v_guild and item_key = 'gem:gold';

    -- ── Successful enqueue deducts stockpile + schedules ────────────────────
    r := public.enqueue_production(v_hash, v_guild, 'gold_ring');
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL enqueue gold_ring: %', r;
    end if;
    v_qid := (r->>'queue_id')::uuid;

    select amount into v_gold  from public.guild_stockpile where guild_id = v_guild and item_key = 'gem:gold';
    select amount into v_ingot from public.guild_stockpile where guild_id = v_guild and item_key = 'resource:gold_ingot';
    if v_gold <> 80 then raise exception 'FAIL gold deduct: expected 80, got %', v_gold; end if;
    if v_ingot <> 45 then raise exception 'FAIL ingot deduct: expected 45, got %', v_ingot; end if;

    -- Queue shows 1 active item.
    r := public.get_guild_production(v_hash, v_guild);
    if json_array_length(r->'items') <> 1 then
        raise exception 'FAIL queue length after enqueue: %', r;
    end if;

    -- ── Insufficient stock when inputs run out ──────────────────────────────
    -- Drain gold_ingot below 5 so the next gold_ring can't be made.
    update public.guild_stockpile set amount = 2 where guild_id = v_guild and item_key = 'resource:gold_ingot';
    r := public.enqueue_production(v_hash, v_guild, 'gold_ring');
    if (r->>'error') is distinct from 'insufficient_stock' then
        raise exception 'FAIL insufficient_stock guard: %', r;
    end if;
    -- restore
    update public.guild_stockpile set amount = 45 where guild_id = v_guild and item_key = 'resource:gold_ingot';

    -- ── Parallel scheduling: with parallel=1, a 2nd craft starts after the 1st ─
    -- Enqueue a second gold_ring; its finish should be ~2x craft (1200s) out.
    r := public.enqueue_production(v_hash, v_guild, 'gold_ring');
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL 2nd enqueue: %', r;
    end if;
    -- 2nd finish_at should be strictly later than 1st (serialized on 1 lane).
    if (select count(*) from (
            select finish_at from public.guild_production_queue
            where guild_id = v_guild and status = 'active'
            order by finish_at) q) <> 2 then
        raise exception 'FAIL expected 2 active crafts';
    end if;
    -- The later craft finishes roughly 1200s after the earlier one.
    if (select max(finish_at) - min(finish_at)
        from public.guild_production_queue
        where guild_id = v_guild and status = 'active') < interval '1000 seconds' then
        raise exception 'FAIL parallel=1 did not serialize the 2nd craft';
    end if;

    -- ── Capacity limit: cap=3, already 2 active; add 1 more -> ok, 4th -> full ─
    r := public.enqueue_production(v_hash, v_guild, 'gold_ring');  -- 3rd
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL 3rd enqueue (within cap): %', r;
    end if;
    r := public.enqueue_production(v_hash, v_guild, 'gold_ring');  -- 4th -> full
    if (r->>'error') is distinct from 'facility_full' then
        raise exception 'FAIL facility_full guard: %', r;
    end if;

    -- ── Collect: back-date all active to the past, then collect into escrow ──
    update public.guild_production_queue set finish_at = now() - interval '1 second'
    where guild_id = v_guild and status = 'active';
    r := public.collect_production(v_hash, v_guild);
    if (r->>'total')::int <> 3 then
        raise exception 'FAIL collect total: expected 3, got %', r;
    end if;
    -- 3 gold_rings escrowed to the collector.
    select quantity into v_cnt from public.escrow
    where account_id = v_acct and item_key = 'item:gold_ring';
    if coalesce(v_cnt, 0) <> 3 then
        raise exception 'FAIL escrow gold_ring: expected 3, got %', coalesce(v_cnt, 0);
    end if;
    -- No active crafts remain.
    if (select count(*) from public.guild_production_queue
        where guild_id = v_guild and status = 'active') <> 0 then
        raise exception 'FAIL active crafts remain after collect';
    end if;

    raise notice 'ALL PRODUCTION TESTS PASSED';
end;
$$;

rollback;
