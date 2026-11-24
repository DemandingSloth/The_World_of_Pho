-- ============================================================================
-- Verification for migration 059 (Public Guild Fronts) — RUN AFTER 059.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL GUILD FRONTS TESTS PASSED".
--
-- A guild (seller + member) lists jewelry; an OUTSIDE player (no guild) browses
-- and buys. Proceeds route to the guild bank and disperse evenly to the guild's
-- members; the outside buyer never receives a member share. cannot_buy_own and
-- the stock/token guards are checked.
-- ============================================================================

begin;

do $$
declare
    v_seller_hash  text := 'test_front_seller';
    v_member_hash  text := 'test_front_member';
    v_outsider_hash text := 'test_front_outsider';
    v_seller   uuid;
    v_member   uuid;
    v_outsider uuid;
    v_guild    uuid;
    r          json;
    v_lid      uuid;
    v_bank     bigint;
    v_sel      bigint;
    v_mem      bigint;
    v_out      bigint;
    v_esc      bigint;
begin
    -- ── Setup: guild (seller leader + member), outsider with NO guild ────────
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_seller_hash, 'front_seller', 'x', 0) returning id into v_seller;
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_member_hash, 'front_member', 'x', 0) returning id into v_member;
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_outsider_hash, 'front_outsider', 'x', 10000) returning id into v_outsider;

    insert into public.guilds (name, specialization, leader_id, bank_balance)
    values ('test_front_guild', 'mining', v_seller, 0) returning id into v_guild;

    insert into public.guild_members (guild_id, account_id, role)
    values (v_guild, v_seller, 'leader'),
           (v_guild, v_member, 'member');

    -- ── Member lists ruby_ring (057 path), price 101, qty 5 ──────────────────
    r := public.list_guild_item(v_seller_hash, v_guild, 'item:ruby_ring', 5, 101);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL list ruby_ring: %', r;
    end if;
    v_lid := (r->>'listing_id')::uuid;

    -- ── Public browse: outsider (no guild) can see the listing ───────────────
    r := public.get_guild_fronts(v_outsider_hash, 50, 0);
    if json_array_length(r->'items') < 1 then
        raise exception 'FAIL outsider browse should see listing: %', r;
    end if;
    -- The row carries guild_name + seller_name and mine=false for the outsider.
    if (r->'items'->0->>'guild_name') is distinct from 'test_front_guild' then
        raise exception 'FAIL front guild_name: %', r;
    end if;
    if (r->'items'->0->>'seller_name') is distinct from 'front_seller' then
        raise exception 'FAIL front seller_name: %', r;
    end if;
    if (r->'items'->0->>'mine') is distinct from 'false' then
        raise exception 'FAIL outsider mine flag should be false: %', r;
    end if;

    -- Browsing with an unknown device hash still works (public window).
    r := public.get_guild_fronts('nobody_at_all', 50, 0);
    if json_array_length(r->'items') < 1 then
        raise exception 'FAIL anonymous browse should still see listings: %', r;
    end if;

    -- ── Lister cannot buy their own listing ──────────────────────────────────
    r := public.buy_guild_front_item(v_seller_hash, v_lid, 1);
    if (r->>'error') is distinct from 'cannot_buy_own' then
        raise exception 'FAIL cannot_buy_own guard: %', r;
    end if;

    -- ── Insufficient stock ───────────────────────────────────────────────────
    r := public.buy_guild_front_item(v_outsider_hash, v_lid, 99);
    if (r->>'error') is distinct from 'insufficient_stock' then
        raise exception 'FAIL insufficient_stock guard: %', r;
    end if;

    -- ── Outsider buys 1 @101. pot=101 over 2 members -> each 50, bank 1 ───────
    r := public.buy_guild_front_item(v_outsider_hash, v_lid, 1);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL outsider buy: %', r;
    end if;
    if (r->>'spent')::bigint <> 101 then
        raise exception 'FAIL spent: expected 101, got %', r;
    end if;
    if (r->>'guild_id') is distinct from v_guild::text then
        raise exception 'FAIL guild_id in buy result: %', r;
    end if;

    -- Outsider paid 101: 10000 - 101 = 9899; got NO member share.
    select token_balance into v_out from public.accounts where id = v_outsider;
    if v_out <> 9899 then raise exception 'FAIL outsider balance: expected 9899, got %', v_out; end if;

    -- Members each got 50 (even split of the 101 pot; remainder 1 banked).
    select token_balance into v_sel from public.accounts where id = v_seller;
    select token_balance into v_mem from public.accounts where id = v_member;
    if v_sel <> 50 then raise exception 'FAIL seller share: expected 50, got %', v_sel; end if;
    if v_mem <> 50 then raise exception 'FAIL member share: expected 50, got %', v_mem; end if;

    -- Guild bank holds the remainder (1).
    select bank_balance into v_bank from public.guilds where id = v_guild;
    if v_bank <> 1 then raise exception 'FAIL guild bank: expected 1, got %', v_bank; end if;

    -- Item escrowed to the BUYER (outsider), not a guild member.
    select quantity into v_esc from public.escrow where account_id = v_outsider and item_key = 'item:ruby_ring';
    if coalesce(v_esc, 0) <> 1 then raise exception 'FAIL outsider escrow: expected 1, got %', coalesce(v_esc, 0); end if;

    -- Ledger: buyer spend line (guild_front_buy) + member share lines (guild_store_share).
    if (select count(*) from public.token_ledger
        where ref_id = v_lid and reason = 'guild_front_buy') <> 1 then
        raise exception 'FAIL missing guild_front_buy ledger line';
    end if;
    if (select count(*) from public.token_ledger
        where ref_id = v_lid and reason = 'guild_store_share') <> 2 then
        raise exception 'FAIL expected 2 guild_store_share ledger lines (one per member)';
    end if;

    -- ── Second buy folds the bank: pot = bank(1) + 101 = 102 -> each 51, bank 0
    r := public.buy_guild_front_item(v_outsider_hash, v_lid, 1);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL outsider buy 2: %', r;
    end if;
    select bank_balance into v_bank from public.guilds where id = v_guild;
    if v_bank <> 0 then raise exception 'FAIL bank after sweep: expected 0, got %', v_bank; end if;
    -- Members now 50 + 51 = 101 each.
    select token_balance into v_sel from public.accounts where id = v_seller;
    if v_sel <> 101 then raise exception 'FAIL seller after 2nd sale: expected 101, got %', v_sel; end if;

    -- ── Insufficient tokens (a poor buyer) ───────────────────────────────────
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values ('test_front_broke', 'front_broke', 'x', 10);
    r := public.buy_guild_front_item('test_front_broke', v_lid, 1);
    if (r->>'error') is distinct from 'insufficient_tokens' then
        raise exception 'FAIL insufficient_tokens guard: %', r;
    end if;

    -- ── Buy out the rest -> sold_out, then rejected ──────────────────────────
    r := public.buy_guild_front_item(v_outsider_hash, v_lid, 3);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL buy remaining 3: %', r;
    end if;
    if (select status from public.guild_store_listings where id = v_lid) <> 'sold_out' then
        raise exception 'FAIL listing should be sold_out';
    end if;
    r := public.buy_guild_front_item(v_outsider_hash, v_lid, 1);
    if (r->>'error') is distinct from 'listing_not_active' then
        raise exception 'FAIL sold_out buy guard: %', r;
    end if;

    raise notice 'ALL GUILD FRONTS TESTS PASSED';
end;
$$;

rollback;
