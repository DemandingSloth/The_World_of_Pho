-- ============================================================================
-- Verification for migration 057 (Guild Store) — RUN AFTER 057.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL GUILD STORE TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_seller_hash text := 'test_store_seller';
    v_buyer_hash  text := 'test_store_buyer';
    v_other_hash  text := 'test_store_outsider';
    v_seller uuid;
    v_buyer  uuid;
    v_other  uuid;
    v_guild  uuid;
    v_guild2 uuid;
    r        json;
    v_lid    uuid;
    v_bal    bigint;
    v_esc    bigint;
    v_qty    int;
begin
    -- ── Setup: seller + buyer in guild A, outsider in guild B ────────────────
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_seller_hash, 'store_seller', 'x', 1000) returning id into v_seller;
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_buyer_hash, 'store_buyer', 'x', 5000) returning id into v_buyer;
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_other_hash, 'store_outsider', 'x', 5000) returning id into v_other;

    insert into public.guilds (name, specialization, leader_id)
    values ('test_store_guild_a', 'mining', v_seller) returning id into v_guild;
    insert into public.guilds (name, specialization, leader_id)
    values ('test_store_guild_b', 'mining', v_other) returning id into v_guild2;

    insert into public.guild_members (guild_id, account_id, role)
    values (v_guild,  v_seller, 'leader'),
           (v_guild,  v_buyer,  'member'),
           (v_guild2, v_other,  'leader');

    -- ── _is_jewelry_key helper ───────────────────────────────────────────────
    if not public._is_jewelry_key('item:gold_ring') then
        raise exception 'FAIL _is_jewelry_key(item:gold_ring) should be true';
    end if;
    if public._is_jewelry_key('gem:gold') then
        raise exception 'FAIL _is_jewelry_key(gem:gold) should be false';
    end if;
    if public._is_jewelry_key('item:') then
        raise exception 'FAIL _is_jewelry_key(item:) empty id should be false';
    end if;

    -- ── Listing a non-jewelry key is rejected ────────────────────────────────
    r := public.list_guild_item(v_seller_hash, v_guild, 'gem:gold', 5, 100);
    if (r->>'error') is distinct from 'not_jewelry' then
        raise exception 'FAIL not_jewelry guard: %', r;
    end if;

    -- ── Non-member cannot list in this guild ─────────────────────────────────
    r := public.list_guild_item(v_other_hash, v_guild, 'item:gold_ring', 1, 100);
    if (r->>'error') is distinct from 'not_in_guild' then
        raise exception 'FAIL not_in_guild list guard: %', r;
    end if;

    -- ── Invalid quantity / price guards ──────────────────────────────────────
    r := public.list_guild_item(v_seller_hash, v_guild, 'item:gold_ring', 0, 100);
    if (r->>'error') is distinct from 'invalid_quantity' then
        raise exception 'FAIL invalid_quantity guard: %', r;
    end if;
    r := public.list_guild_item(v_seller_hash, v_guild, 'item:gold_ring', 3, 0);
    if (r->>'error') is distinct from 'invalid_price' then
        raise exception 'FAIL invalid_price guard: %', r;
    end if;

    -- ── Successful listing ───────────────────────────────────────────────────
    r := public.list_guild_item(v_seller_hash, v_guild, 'item:gold_ring', 3, 200);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL list gold_ring: %', r;
    end if;
    v_lid := (r->>'listing_id')::uuid;

    -- ── Store view shows the listing (and mine flag) ─────────────────────────
    r := public.get_guild_store(v_seller_hash, v_guild);
    if json_array_length(r->'items') <> 1 then
        raise exception 'FAIL store length after list: %', r;
    end if;
    if (r->'items'->0->>'mine') is distinct from 'true' then
        raise exception 'FAIL seller mine flag: %', r;
    end if;
    if (r->'items'->0->>'seller_name') is distinct from 'store_seller' then
        raise exception 'FAIL seller_name: %', r;
    end if;

    -- Buyer sees it as not-mine.
    r := public.get_guild_store(v_buyer_hash, v_guild);
    if (r->'items'->0->>'mine') is distinct from 'false' then
        raise exception 'FAIL buyer mine flag should be false: %', r;
    end if;

    -- Outsider (guild B) sees an EMPTY guild A store (they query their own).
    r := public.get_guild_store(v_other_hash, v_guild2);
    if json_array_length(r->'items') <> 0 then
        raise exception 'FAIL guild B store should be empty: %', r;
    end if;
    -- Outsider cannot view guild A store at all.
    r := public.get_guild_store(v_other_hash, v_guild);
    if (r->>'error') is distinct from 'not_in_guild' then
        raise exception 'FAIL outsider view guard: %', r;
    end if;

    -- ── Seller cannot buy own listing ────────────────────────────────────────
    r := public.buy_guild_item(v_seller_hash, v_guild, v_lid, 1);
    if (r->>'error') is distinct from 'cannot_buy_own' then
        raise exception 'FAIL cannot_buy_own guard: %', r;
    end if;

    -- ── Outsider cannot buy (not in guild) ───────────────────────────────────
    r := public.buy_guild_item(v_other_hash, v_guild, v_lid, 1);
    if (r->>'error') is distinct from 'not_in_guild' then
        raise exception 'FAIL outsider buy guard: %', r;
    end if;

    -- ── Insufficient stock ───────────────────────────────────────────────────
    r := public.buy_guild_item(v_buyer_hash, v_guild, v_lid, 99);
    if (r->>'error') is distinct from 'insufficient_stock' then
        raise exception 'FAIL insufficient_stock guard: %', r;
    end if;

    -- ── Successful buy: 2 units @200 = 400 tokens ────────────────────────────
    r := public.buy_guild_item(v_buyer_hash, v_guild, v_lid, 2);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL buy 2 gold_ring: %', r;
    end if;
    if (r->>'spent')::bigint <> 400 then
        raise exception 'FAIL spent: expected 400, got %', r;
    end if;

    -- Buyer tokens: 5000 - 400 = 4600.
    select token_balance into v_bal from public.accounts where id = v_buyer;
    if v_bal <> 4600 then raise exception 'FAIL buyer balance: expected 4600, got %', v_bal; end if;
    -- Seller tokens: 1000 + 400 = 1400.
    select token_balance into v_bal from public.accounts where id = v_seller;
    if v_bal <> 1400 then raise exception 'FAIL seller balance: expected 1400, got %', v_bal; end if;

    -- Item into BUYER escrow (2).
    select quantity into v_esc from public.escrow where account_id = v_buyer and item_key = 'item:gold_ring';
    if coalesce(v_esc, 0) <> 2 then raise exception 'FAIL buyer escrow: expected 2, got %', coalesce(v_esc, 0); end if;

    -- Listing now has 1 remaining, still active.
    select quantity_remaining into v_qty
    from public.guild_store_listings where id = v_lid;
    if v_qty <> 1 then raise exception 'FAIL remaining after buy: expected 1, got %', v_qty; end if;
    if (select status from public.guild_store_listings where id = v_lid) <> 'active' then
        raise exception 'FAIL listing should still be active with 1 remaining';
    end if;

    -- Ledger: a guild_buy (-400) and guild_sale (+400) exist.
    if (select count(*) from public.token_ledger
        where ref_id = v_lid and reason in ('guild_buy', 'guild_sale')) <> 2 then
        raise exception 'FAIL token_ledger entries missing';
    end if;

    -- ── Buy the last unit -> listing sold_out ────────────────────────────────
    r := public.buy_guild_item(v_buyer_hash, v_guild, v_lid, 1);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL buy last unit: %', r;
    end if;
    if (select status from public.guild_store_listings where id = v_lid) <> 'sold_out' then
        raise exception 'FAIL listing should be sold_out';
    end if;
    -- Buying from a sold_out listing is rejected.
    r := public.buy_guild_item(v_buyer_hash, v_guild, v_lid, 1);
    if (r->>'error') is distinct from 'listing_not_active' then
        raise exception 'FAIL sold_out buy guard: %', r;
    end if;

    -- ── Cancel returns unsold remainder to seller escrow ─────────────────────
    r := public.list_guild_item(v_seller_hash, v_guild, 'item:ruby_ring', 4, 500);
    v_lid := (r->>'listing_id')::uuid;
    -- Non-owner cannot cancel.
    r := public.cancel_guild_listing(v_buyer_hash, v_lid);
    if (r->>'error') is distinct from 'not_your_listing' then
        raise exception 'FAIL not_your_listing cancel guard: %', r;
    end if;
    -- Owner cancels -> 4 ruby_ring back to seller escrow.
    r := public.cancel_guild_listing(v_seller_hash, v_lid);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL cancel ruby_ring: %', r;
    end if;
    if (r->>'returned_qty')::int <> 4 then
        raise exception 'FAIL returned_qty: expected 4, got %', r;
    end if;
    select quantity into v_esc from public.escrow where account_id = v_seller and item_key = 'item:ruby_ring';
    if coalesce(v_esc, 0) <> 4 then raise exception 'FAIL seller escrow after cancel: expected 4, got %', coalesce(v_esc, 0); end if;
    -- Double-cancel rejected.
    r := public.cancel_guild_listing(v_seller_hash, v_lid);
    if (r->>'error') is distinct from 'listing_not_active' then
        raise exception 'FAIL double-cancel guard: %', r;
    end if;

    raise notice 'ALL GUILD STORE TESTS PASSED';
end;
$$;

rollback;
