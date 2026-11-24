-- ============================================================================
-- Verification for migration 058 (Guild Bank + even split) — RUN AFTER 058.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL GUILD BANK TESTS PASSED".
--
-- Guild has 3 members (seller + 2 buyers). Sales are split 3 ways; sub-member
-- remainders bank and later sweep. token_balance deltas are checked exactly.
-- ============================================================================

begin;

do $$
declare
    v_seller_hash text := 'test_bank_seller';
    v_b1_hash     text := 'test_bank_buyer1';
    v_b2_hash     text := 'test_bank_buyer2';
    v_seller uuid;
    v_b1     uuid;
    v_b2     uuid;
    v_guild  uuid;
    r        json;
    v_lid    uuid;
    v_bank   bigint;
    v_sel    bigint;
    v_bal1   bigint;
    v_bal2   bigint;
begin
    -- ── Setup: 3 members, all starting at 0 tokens for clean arithmetic ──────
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_seller_hash, 'bank_seller', 'x', 0) returning id into v_seller;
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_b1_hash, 'bank_buyer1', 'x', 10000) returning id into v_b1;
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_b2_hash, 'bank_buyer2', 'x', 10000) returning id into v_b2;

    insert into public.guilds (name, specialization, leader_id, bank_balance)
    values ('test_bank_guild', 'mining', v_seller, 0) returning id into v_guild;

    insert into public.guild_members (guild_id, account_id, role)
    values (v_guild, v_seller, 'leader'),
           (v_guild, v_b1,     'member'),
           (v_guild, v_b2,     'member');

    -- ── Listing (seller lists ruby_ring, lots of stock, price 100) ───────────
    r := public.list_guild_item(v_seller_hash, v_guild, 'item:ruby_ring', 100, 100);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL list ruby_ring: %', r;
    end if;
    v_lid := (r->>'listing_id')::uuid;

    -- ── Sale 1: buyer1 buys 1 @100. pot=100, 3 members -> each 33, bank 1 ─────
    r := public.buy_guild_item(v_b1_hash, v_guild, v_lid, 1);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL sale1: %', r; end if;
    if (r->>'shared')::bigint <> 99 then raise exception 'FAIL sale1 shared: expected 99, got %', r; end if;
    if (r->>'banked')::bigint <> 1  then raise exception 'FAIL sale1 banked: expected 1, got %', r; end if;

    -- Everyone (incl. seller) got 33; buyer1 also paid 100.
    select token_balance into v_sel  from public.accounts where id = v_seller;
    select token_balance into v_bal1 from public.accounts where id = v_b1;
    select token_balance into v_bal2 from public.accounts where id = v_b2;
    if v_sel  <> 33    then raise exception 'FAIL seller after sale1: expected 33, got %', v_sel;  end if;
    if v_bal1 <> 9933  then raise exception 'FAIL buyer1 after sale1: expected 9933 (10000-100+33), got %', v_bal1; end if;
    if v_bal2 <> 10033 then raise exception 'FAIL buyer2 after sale1: expected 10033, got %', v_bal2; end if;

    select bank_balance into v_bank from public.guilds where id = v_guild;
    if v_bank <> 1 then raise exception 'FAIL bank after sale1: expected 1, got %', v_bank; end if;

    -- ── Sale 2: buyer2 buys 1 @100. pot = bank(1)+100 = 101 -> each 33, bank 2
    r := public.buy_guild_item(v_b2_hash, v_guild, v_lid, 1);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL sale2: %', r; end if;
    if (r->>'shared')::bigint <> 99 then raise exception 'FAIL sale2 shared: expected 99, got %', r; end if;
    if (r->>'banked')::bigint <> 2  then raise exception 'FAIL sale2 banked: expected 2, got %', r; end if;
    select bank_balance into v_bank from public.guilds where id = v_guild;
    if v_bank <> 2 then raise exception 'FAIL bank after sale2: expected 2, got %', v_bank; end if;

    -- ── Sale 3: buyer1 buys 1 @100. pot = 2+100 = 102 -> each 34, bank 0 ──────
    r := public.buy_guild_item(v_b1_hash, v_guild, v_lid, 1);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL sale3: %', r; end if;
    if (r->>'shared')::bigint <> 102 then raise exception 'FAIL sale3 shared (sweep): expected 102, got %', r; end if;
    if (r->>'banked')::bigint <> 0   then raise exception 'FAIL sale3 banked: expected 0 (clean sweep), got %', r; end if;
    select bank_balance into v_bank from public.guilds where id = v_guild;
    if v_bank <> 0 then raise exception 'FAIL bank after sale3: expected 0, got %', v_bank; end if;

    -- ── Conservation check: total tokens distributed to members == total spent ─
    -- 3 sales @100 = 300 spent by buyers; 300 should have reached members total.
    -- seller got 33+33+34 = 100; each buyer got their shares (minus their spend).
    select token_balance into v_sel  from public.accounts where id = v_seller;
    if v_sel <> 100 then raise exception 'FAIL seller total shares: expected 100, got %', v_sel; end if;

    -- buyer1: start 10000, spent 200 (2 buys), shares 33+33+34 = 100 -> 9900
    select token_balance into v_bal1 from public.accounts where id = v_b1;
    if v_bal1 <> 9900 then raise exception 'FAIL buyer1 final: expected 9900, got %', v_bal1; end if;
    -- buyer2: start 10000, spent 100 (1 buy), shares 33+33+34 = 100 -> 10000
    select token_balance into v_bal2 from public.accounts where id = v_b2;
    if v_bal2 <> 10000 then raise exception 'FAIL buyer2 final: expected 10000, got %', v_bal2; end if;

    -- ── cannot_buy_own still enforced (seller is a member but owns listing) ──
    r := public.buy_guild_item(v_seller_hash, v_guild, v_lid, 1);
    if (r->>'error') is distinct from 'cannot_buy_own' then
        raise exception 'FAIL cannot_buy_own still holds: %', r;
    end if;

    -- ── get_guild_bank read ──────────────────────────────────────────────────
    r := public.get_guild_bank(v_seller_hash, v_guild);
    if (r->>'member_count')::int <> 3 then raise exception 'FAIL get_guild_bank member_count: %', r; end if;
    if (r->>'bank_balance')::bigint <> 0 then raise exception 'FAIL get_guild_bank balance: %', r; end if;

    -- ── Manual distribute: seed a bank of 2, distribute -> stays 2 (< members) ─
    update public.guilds set bank_balance = 2 where id = v_guild;
    r := public.distribute_guild_bank(v_seller_hash, v_guild);
    if (r->>'distributed')::bigint <> 0 then raise exception 'FAIL distribute (2<3) distributed: %', r; end if;
    if (r->>'bank_balance')::bigint <> 2 then raise exception 'FAIL distribute (2<3) bank: %', r; end if;

    -- Seed a bank of 7, distribute -> each 2 (6 out), bank 1.
    update public.guilds set bank_balance = 7 where id = v_guild;
    r := public.distribute_guild_bank(v_seller_hash, v_guild);
    if (r->>'distributed')::bigint <> 6 then raise exception 'FAIL distribute (7) distributed: expected 6, got %', r; end if;
    if (r->>'bank_balance')::bigint <> 1 then raise exception 'FAIL distribute (7) bank: expected 1, got %', r; end if;

    -- ── Non-leader cannot distribute ─────────────────────────────────────────
    r := public.distribute_guild_bank(v_b1_hash, v_guild);
    if (r->>'error') is distinct from 'not_leader' then
        raise exception 'FAIL not_leader distribute guard: %', r;
    end if;

    raise notice 'ALL GUILD BANK TESTS PASSED';
end;
$$;

rollback;
