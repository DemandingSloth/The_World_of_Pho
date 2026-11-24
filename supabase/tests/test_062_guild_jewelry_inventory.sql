-- ============================================================================
-- Verification for migration 062 (guild jewelry inventory) — RUN AFTER 062.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL GUILD JEWELRY TESTS PASSED".
--
-- Flow: a finished craft is collected into the GUILD pool (not personal escrow);
-- a member lists out of the pool (drawing it down); over-listing is rejected;
-- cancelling returns stock to the pool; a buyer still receives the item in their
-- own personal escrow.
-- ============================================================================

begin;

do $$
declare
    v_hash   text := 'test_jw_member';
    v_bhash  text := 'test_jw_buyer';
    v_acct   uuid;
    v_buyer  uuid;
    v_guild  uuid;
    r        json;
    v_qid    uuid;
    v_lid    uuid;
    v_pool   bigint;
    v_esc    bigint;
begin
    -- ── Setup: guild with a member (leader) + a second buyer member ──────────
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_hash, 'jw_member', 'x', 0) returning id into v_acct;
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_bhash, 'jw_buyer', 'x', 100000) returning id into v_buyer;

    insert into public.guilds (name, specialization, leader_id)
    values ('test_jw_guild', 'mining', v_acct) returning id into v_guild;
    insert into public.guild_members (guild_id, account_id, role)
    values (v_guild, v_acct, 'leader'),
           (v_guild, v_buyer, 'member');

    -- ── A finished craft in the queue (ruby_ring, already past finish) ───────
    insert into public.guild_production_queue
        (guild_id, recipe_id, output_item_key, finish_at, status, enqueued_by)
    values (v_guild, 'ruby_ring', 'item:ruby_ring', now() - interval '1 second', 'active', v_acct)
    returning id into v_qid;

    -- ── Collect: goes to the GUILD pool, NOT the collector's escrow ──────────
    r := public.collect_production(v_hash, v_guild);
    if (r->>'total')::int <> 1 then
        raise exception 'FAIL collect total: expected 1, got %', r;
    end if;

    select quantity into v_pool from public.guild_jewelry_inventory
    where guild_id = v_guild and item_key = 'item:ruby_ring';
    if coalesce(v_pool, 0) <> 1 then
        raise exception 'FAIL guild pool after collect: expected 1, got %', coalesce(v_pool, 0);
    end if;
    -- Collector personal escrow must be EMPTY (the whole point of this change).
    select quantity into v_esc from public.escrow
    where account_id = v_acct and item_key = 'item:ruby_ring';
    if coalesce(v_esc, 0) <> 0 then
        raise exception 'FAIL collector escrow should be 0, got %', coalesce(v_esc, 0);
    end if;

    -- ── get_guild_jewelry shows the pool ─────────────────────────────────────
    r := public.get_guild_jewelry(v_hash, v_guild);
    if json_array_length(r->'items') <> 1 then
        raise exception 'FAIL get_guild_jewelry length: %', r;
    end if;
    if (r->'items'->0->>'item_key') is distinct from 'item:ruby_ring' then
        raise exception 'FAIL get_guild_jewelry item_key: %', r;
    end if;

    -- ── Over-list is rejected (pool has 1, try to list 5) ────────────────────
    r := public.list_guild_item(v_hash, v_guild, 'item:ruby_ring', 5, 1000);
    if (r->>'error') is distinct from 'insufficient_jewelry' then
        raise exception 'FAIL over-list guard: %', r;
    end if;

    -- ── Non-jewelry rejected ─────────────────────────────────────────────────
    r := public.list_guild_item(v_hash, v_guild, 'resource:iron_bar', 1, 1000);
    if (r->>'error') is distinct from 'not_jewelry' then
        raise exception 'FAIL not_jewelry guard: %', r;
    end if;

    -- ── Valid list: draws the pool down to 0 ─────────────────────────────────
    r := public.list_guild_item(v_hash, v_guild, 'item:ruby_ring', 1, 1000);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL list ruby_ring: %', r;
    end if;
    v_lid := (r->>'listing_id')::uuid;
    select coalesce(quantity, 0) into v_pool from public.guild_jewelry_inventory
    where guild_id = v_guild and item_key = 'item:ruby_ring';
    if coalesce(v_pool, 0) <> 0 then
        raise exception 'FAIL pool after list: expected 0, got %', coalesce(v_pool, 0);
    end if;

    -- ── Cancel returns the unsold unit to the GUILD pool (not escrow) ────────
    r := public.cancel_guild_listing(v_hash, v_lid);
    if (r->>'returned_qty')::int <> 1 then
        raise exception 'FAIL cancel returned_qty: %', r;
    end if;
    select quantity into v_pool from public.guild_jewelry_inventory
    where guild_id = v_guild and item_key = 'item:ruby_ring';
    if coalesce(v_pool, 0) <> 1 then
        raise exception 'FAIL pool after cancel: expected 1, got %', coalesce(v_pool, 0);
    end if;

    -- ── Re-list, then a buyer purchases -> buyer gets PERSONAL escrow ────────
    r := public.list_guild_item(v_hash, v_guild, 'item:ruby_ring', 1, 1000);
    v_lid := (r->>'listing_id')::uuid;

    -- Internal guild buy (same-guild member). Buyer gets the item personally.
    r := public.buy_guild_item(v_bhash, v_guild, v_lid, 1);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL buyer purchase: %', r;
    end if;
    select quantity into v_esc from public.escrow
    where account_id = v_buyer and item_key = 'item:ruby_ring';
    if coalesce(v_esc, 0) <> 1 then
        raise exception 'FAIL buyer personal escrow: expected 1, got %', coalesce(v_esc, 0);
    end if;
    -- Pool stays at 0 (the listed unit was already drawn out at list time).
    select coalesce(quantity, 0) into v_pool from public.guild_jewelry_inventory
    where guild_id = v_guild and item_key = 'item:ruby_ring';
    if coalesce(v_pool, 0) <> 0 then
        raise exception 'FAIL pool after sale: expected 0, got %', coalesce(v_pool, 0);
    end if;

    -- ── Leader can cancel another member's listing (returns to pool) ─────────
    -- Give the pool a unit, let the buyer-member list it, leader cancels it.
    perform public._guild_jewelry_add(v_guild, 'item:gold_ring', 2);
    r := public.list_guild_item(v_bhash, v_guild, 'item:gold_ring', 2, 500);
    v_lid := (r->>'listing_id')::uuid;
    -- Leader (v_hash) cancels the member's (v_bhash) listing.
    r := public.cancel_guild_listing(v_hash, v_lid);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL leader cancel of member listing: %', r;
    end if;
    select quantity into v_pool from public.guild_jewelry_inventory
    where guild_id = v_guild and item_key = 'item:gold_ring';
    if coalesce(v_pool, 0) <> 2 then
        raise exception 'FAIL gold_ring pool after leader cancel: expected 2, got %', coalesce(v_pool, 0);
    end if;

    raise notice 'ALL GUILD JEWELRY TESTS PASSED';
end;
$$;

rollback;
