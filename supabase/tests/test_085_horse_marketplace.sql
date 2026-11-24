-- ============================================================================
-- Verification for migration 085 (horse marketplace — player-to-player sales)
-- ============================================================================
-- AFTER 065 + 077 + 079 + 082 + 083 + 085. Transactional; ROLLS BACK.
-- Success -> notice "ALL HORSE MARKET TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_seller text := 'test_hm_seller';
    v_buyer  text := 'test_hm_buyer';
    v_as     uuid;
    v_ab     uuid;
    r        json;
    v_h1     uuid;
    v_listing uuid;
    v_race   uuid;
    v_sugg   bigint;
    v_bal_s0 bigint;
    v_bal_b0 bigint;
begin
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_seller, 'hm_seller', 'x', 0) returning id into v_as;
    insert into public.accounts (device_hash, username, recovery_hash, token_balance)
    values (v_buyer, 'hm_buyer', 'x', 1000000) returning id into v_ab;

    -- Seller buys a horse to sell. standardbred base 90/9/8.
    r := public.buy_horse(v_seller, 'standardbred', 'ForSale'); v_h1 := (r->'horse'->>'id')::uuid;

    -- ── Suggested price = round(stat_total)*5000 = (90+9+8)*5000 = 535000 ─────
    v_sugg := public._horse_listing_suggested_price(v_h1);
    if v_sugg <> 535000 then raise exception 'FAIL suggested price (want 535000): %', v_sugg; end if;

    -- ── Bad price rejected ────────────────────────────────────────────────────
    r := public.list_horse(v_seller, v_h1, 0);
    if (r->>'error') is distinct from 'bad_price' then raise exception 'FAIL bad_price: %', r; end if;

    -- ── List it (seller sets any price) ──────────────────────────────────────
    r := public.list_horse(v_seller, v_h1, 250000);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL list: %', r; end if;
    v_listing := (r->>'listing_id')::uuid;

    -- Double-list rejected.
    r := public.list_horse(v_seller, v_h1, 250000);
    if (r->>'error') is distinct from 'already_listed' then raise exception 'FAIL already_listed: %', r; end if;

    -- ── A LISTED horse can't be raced (mutual exclusion) ─────────────────────
    insert into public.races (name, field_size, status, opens_at, closes_at)
    values ('MktRace', 8, 'open', now(), now() + interval '5 hours')
    returning id into v_race;
    r := public.register_horse(v_seller, v_race, v_h1);
    if (r->>'error') is distinct from 'horse_listed' then
        raise exception 'FAIL listed horse should not race: %', r;
    end if;

    -- ── get_horse_market surfaces the listing + buyer sees not-mine ──────────
    r := public.get_horse_market(v_buyer);
    if not exists (
        select 1 from json_array_elements(r->'listings') l
        where (l->>'listing_id') = v_listing::text and (l->>'mine')::boolean = false
          and (l->>'name') = 'ForSale'
    ) then
        raise exception 'FAIL market listing not visible to buyer';
    end if;

    -- ── Can't buy your own ────────────────────────────────────────────────────
    r := public.buy_horse_listing(v_seller, v_listing);
    if (r->>'error') is distinct from 'cannot_buy_own' then raise exception 'FAIL cannot_buy_own: %', r; end if;

    -- ── Buyer purchases: tokens move, ownership transfers, shoe cleared ──────
    select token_balance into v_bal_s0 from public.accounts where id = v_as;
    select token_balance into v_bal_b0 from public.accounts where id = v_ab;
    update public.horses set horseshoe = 'copper' where id = v_h1;  -- had a shoe

    r := public.buy_horse_listing(v_buyer, v_listing);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL buy: %', r; end if;

    if (select owner_id from public.horses where id = v_h1) <> v_ab then
        raise exception 'FAIL ownership not transferred';
    end if;
    if (select horseshoe from public.horses where id = v_h1) is not null then
        raise exception 'FAIL horseshoe not cleared on sale';
    end if;
    if (select token_balance from public.accounts where id = v_ab) <> v_bal_b0 - 250000 then
        raise exception 'FAIL buyer tokens not debited';
    end if;
    if (select token_balance from public.accounts where id = v_as) <> v_bal_s0 + 250000 then
        raise exception 'FAIL seller tokens not credited';
    end if;
    if (select status from public.horse_listings where id = v_listing) <> 'sold' then
        raise exception 'FAIL listing not marked sold';
    end if;

    -- ── Can't buy a sold listing ─────────────────────────────────────────────
    r := public.buy_horse_listing(v_buyer, v_listing);
    if (r->>'error') is distinct from 'listing_not_active' then
        raise exception 'FAIL buy sold listing: %', r;
    end if;

    -- ── Retired horse can't be listed ────────────────────────────────────────
    r := public.buy_horse(v_seller, 'arabian', 'OldTimer'); v_h1 := (r->'horse'->>'id')::uuid;
    update public.horses set status = 'retired' where id = v_h1;
    r := public.list_horse(v_seller, v_h1, 100000);
    if (r->>'error') is distinct from 'horse_retired' then
        raise exception 'FAIL retired horse listable: %', r;
    end if;

    -- ── Insufficient tokens ──────────────────────────────────────────────────
    r := public.buy_horse(v_seller, 'arabian', 'Pricey'); v_h1 := (r->'horse'->>'id')::uuid;
    r := public.list_horse(v_seller, v_h1, 999999999); v_listing := (r->>'listing_id')::uuid;
    r := public.buy_horse_listing(v_buyer, v_listing);
    if (r->>'error') is distinct from 'insufficient_tokens' then
        raise exception 'FAIL insufficient_tokens: %', r;
    end if;

    -- ── Cancel returns the horse to normal (re-listable, raceable) ───────────
    r := public.cancel_horse_listing(v_seller, v_listing);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL cancel: %', r; end if;
    r := public.list_horse(v_seller, v_h1, 100000);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL relist after cancel: %', r; end if;

    raise notice 'ALL HORSE MARKET TESTS PASSED';
end;
$$;

rollback;
