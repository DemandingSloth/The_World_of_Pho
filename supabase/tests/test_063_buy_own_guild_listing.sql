-- ============================================================================
-- Verification for migration 063 (buy your own guild listing) — RUN AFTER 063.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL BUY-OWN TESTS PASSED".
--
-- The member who listed a guild item (e.g. the leader) can now BUY it — the old
-- cannot_buy_own guard is gone since the stock is guild-owned (migration 062).
-- Proceeds still route to the guild bank + even split.
-- ============================================================================

begin;

do $$
declare
    v_hash   text := 'test_bo_leader';
    v_hash2  text := 'test_bo_member';
    v_acct   uuid;
    v_m2     uuid;
    v_guild  uuid;
    r        json;
    v_lid    uuid;
    v_esc    bigint;
    v_bal    bigint;
begin
    -- ── Setup: 2-member guild, leader has tokens to buy with ─────────────────
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_hash, 'bo_leader', 'x', 10000) returning id into v_acct;
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_hash2, 'bo_member', 'x', 0) returning id into v_m2;

    insert into public.guilds (name, specialization, leader_id)
    values ('test_bo_guild', 'mining', v_acct) returning id into v_guild;
    insert into public.guild_members (guild_id, account_id, role)
    values (v_guild, v_acct, 'leader'),
           (v_guild, v_m2, 'member');

    -- Guild jewelry pool has 2 ruby rings; leader lists both.
    perform public._guild_jewelry_add(v_guild, 'item:ruby_ring', 2);

    -- ── INTERNAL buy_guild_item: leader buys their own listing ───────────────
    r := public.list_guild_item(v_hash, v_guild, 'item:ruby_ring', 1, 1000);
    v_lid := (r->>'listing_id')::uuid;
    r := public.buy_guild_item(v_hash, v_guild, v_lid, 1);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL leader internal self-buy: %', r;
    end if;
    -- Leader got the ring in personal escrow.
    select quantity into v_esc from public.escrow
    where account_id = v_acct and item_key = 'item:ruby_ring';
    if coalesce(v_esc, 0) <> 1 then
        raise exception 'FAIL leader escrow after internal buy: expected 1, got %', coalesce(v_esc, 0);
    end if;
    -- Proceeds routed to the bank/even-split: leader paid 1000, got back an even
    -- share (500 of the 1000 pot in a 2-member guild), member got 500.
    select token_balance into v_bal from public.accounts where id = v_m2;
    if v_bal <> 500 then raise exception 'FAIL member share after self-buy: expected 500, got %', v_bal; end if;

    -- ── PUBLIC buy_guild_front_item: leader buys their own listing ───────────
    r := public.list_guild_item(v_hash, v_guild, 'item:ruby_ring', 1, 1000);
    v_lid := (r->>'listing_id')::uuid;
    r := public.buy_guild_front_item(v_hash, v_lid, 1);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL leader public self-buy: %', r;
    end if;
    -- Leader now has 2 rings escrowed total.
    select quantity into v_esc from public.escrow
    where account_id = v_acct and item_key = 'item:ruby_ring';
    if coalesce(v_esc, 0) <> 2 then
        raise exception 'FAIL leader escrow after public buy: expected 2, got %', coalesce(v_esc, 0);
    end if;

    raise notice 'ALL BUY-OWN TESTS PASSED';
end;
$$;

rollback;
