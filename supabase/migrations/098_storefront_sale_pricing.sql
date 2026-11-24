-- ============================================================================
-- Migration 098: Storefront sale pricing (10% steps down to a 50% floor)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Supersedes the pricing rules in migration 094. Previously a guild could list
-- an item at its recommended price with a hard floor of (recommended − 1) —
-- effectively "recommended or above". Now guilds may run SALES: they can list
-- at any price from the full recommended value DOWN TO 50% of it (the client
-- offers 10% steps: 100/90/80/70/60/50%). The server enforces only the 50%
-- floor so the client is free to pick any legal value in that band.
--
-- Changes:
--   1. _item_recommended_price(item_key) — NEW. Returns the FULL recommended
--      listing price for any guild item key (jewelry sell_price, stockpile
--      suggested_price, or recipe token_value). Also knows WonderStone and
--      WonderVessel tiers for completeness.
--
--   2. _item_min_price(item_key) — REWRITTEN. Now returns ceil(recommended ×
--      0.5): the lowest price a guild may list at (a 50% sale). list_guild_item
--      already compares p_unit_price against this floor, so no change needed
--      there — a 0 price still snaps to the floor, which is now the 50% value.
--
--   NOTE: Recipes use 'item:<id>' keys, so _is_jewelry_key already routes them
--   through guild_jewelry_inventory (where collect_production deposits them).
--   No change to list_guild_item / cancel_guild_listing is required.
-- ============================================================================


-- ── _item_recommended_price ───────────────────────────────────────────────────
-- Full recommended (100%) listing price for any guild item key.
--   Jewelry ('item:<id>'):   sell_price            (from ITEM_DEFS)
--   Recipes ('item:<id>'):   token_value           (Σ ingredient token × 10)
--   Stockpile items:         suggested_price       (from SUGGESTED_LIST_PRICE)
--   WonderStone / Vessels:   token value (for completeness; crafted locally)
--   Unknown:                 1
create or replace function public._item_recommended_price(p_item_key text)
returns bigint
language plpgsql
immutable
security definer
set search_path = public
as $$
begin
    return case p_item_key
        -- Jewelry: full sell_price
        when 'item:diamond_ring'        then 500000
        when 'item:gold_ring'           then 250000
        when 'item:blue_stone_necklace' then 400000
        when 'item:pink_stone_necklace' then 400000
        when 'item:violet_stone_ring'   then 600000
        when 'item:black_pearl_necklace'then 900000
        when 'item:emerald_necklace'    then 1400000
        when 'item:ruby_ring'           then 2500000
        when 'item:copper_horseshoe'    then 300000
        when 'item:iron_horseshoe'      then 300000
        -- Food recipes: recommended token value (Σ ingredient token × 10)
        when 'item:sparkling_grape_juice'              then 1150
        when 'item:sun_dried_trail_mix'                then 2190
        when 'item:summer_melon_salad'                 then 1340
        when 'item:stuffed_roasted_peppers'            then 180
        when 'item:spicy_plum_jam'                     then 560
        when 'item:roasted_cauliflower_and_squash_soup' then 340
        when 'item:smoked_apple_glaze'                 then 2500
        when 'item:tropical_oat_and_fruit_mash'        then 4760
        when 'item:coconut_water_hydration'            then 2500
        when 'item:sweet_banana_crisp'                 then 2190
        when 'item:citrus_melon_lemonade'              then 1300
        when 'item:curried_veggie_bowl'                then 410
        when 'item:spiced_pho_noodle_bowl'             then 1300
        -- Uncut gems
        when 'gem:gold'          then 6
        when 'gem:blue_stone'    then 8
        when 'gem:pink_stone'    then 8
        when 'gem:violet_stone'  then 11
        when 'gem:black_pearl'   then 16
        when 'gem:emerald'       then 21
        when 'gem:ruby'          then 31
        when 'gem:diamond'       then 51
        -- Polished gems
        when 'polished:blue_stone'    then 76
        when 'polished:pink_stone'    then 76
        when 'polished:violet_stone'  then 101
        when 'polished:black_pearl'   then 151
        when 'polished:emerald'       then 201
        when 'polished:ruby'          then 301
        when 'polished:diamond'       then 501
        -- Garden crops
        when 'crop:beans'        then 2
        when 'crop:cucumbers'    then 5
        when 'crop:peppers'      then 7
        when 'crop:squash'       then 12
        when 'crop:grapes'       then 16
        when 'crop:sunflower'    then 20
        when 'crop:cauliflower'  then 24
        when 'crop:pineapple'    then 27
        when 'crop:watermelon'   then 31
        -- Orchard fruit
        when 'fruit:plum'        then 51
        when 'fruit:lemon'       then 101
        when 'fruit:apple'       then 151
        when 'fruit:banana'      then 201
        when 'fruit:coconut'     then 251
        -- Resources
        when 'resource:wood'         then 51
        when 'resource:stick'        then 26
        when 'resource:iron_ore'     then 76
        when 'resource:iron_bar'     then 751
        when 'resource:copper_ore'   then 101
        when 'resource:copper_ingot' then 1001
        when 'resource:gold_ingot'   then 2501
        -- Rare material / duplicators (crafted locally; here for completeness)
        when 'material:wonderstone'  then 250000
        when 'vessel:1'  then 2500000
        when 'vessel:2'  then 5000000
        when 'vessel:3'  then 7500000
        when 'vessel:4'  then 10000000
        when 'vessel:5'  then 12500000
        when 'vessel:6'  then 15000000
        when 'vessel:7'  then 17500000
        when 'vessel:8'  then 20000000
        when 'vessel:9'  then 22500000
        when 'vessel:10' then 25000000
        -- Fallback
        else 1
    end;
end;
$$;
revoke all on function public._item_recommended_price(text) from anon, authenticated;


-- ── _item_min_price (REWRITTEN: 50% sale floor) ───────────────────────────────
-- Lowest price a guild may list an item at = ceil(recommended × 0.5).
-- list_guild_item snaps a 0 price to this floor and rejects anything lower.
create or replace function public._item_min_price(p_item_key text)
returns bigint
language plpgsql
immutable
security definer
set search_path = public
as $$
declare
    v_rec bigint;
begin
    v_rec := public._item_recommended_price(p_item_key);
    -- 50% floor, rounded up so tiny-value items never floor to 0.
    return greatest(1, ceil(v_rec::numeric * 0.5)::bigint);
end;
$$;
revoke all on function public._item_min_price(text) from anon, authenticated;


-- ============================================================================
-- Self-contained storefront listing (from migration 094, included here so that
-- running 098 ALONE enables stockpile listing even if 094 was never applied).
-- ============================================================================
-- Guilds may list BOTH produced jewelry (item:* from guild_jewelry_inventory)
-- AND excess stockpile stock / donations (resource/gem/polished/crop/fruit keys
-- from guild_stockpile, available = amount − reserved). Recipes use item:* keys
-- so they route through the jewelry pool automatically.
--
-- Price band: p_unit_price = 0 snaps to the recommended floor; any positive
-- price must be >= the 50% floor from _item_min_price above.
create or replace function public.list_guild_item(
    p_device_hash text,
    p_guild_id    uuid,
    p_item_key    text,
    p_quantity    int,
    p_unit_price  bigint
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account    uuid;
    v_member     public.guild_members%rowtype;
    v_have       bigint;
    v_id         uuid;
    v_min_price  bigint;
    v_price      bigint;
    v_is_jewelry boolean;
    v_amount     bigint;
    v_reserved   bigint;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    if p_quantity is null or p_quantity < 1 then
        return json_build_object('error', 'invalid_quantity');
    end if;

    -- Jewelry (item:*) OR a stockpile-eligible key. Everything else is rejected.
    v_is_jewelry := public._is_jewelry_key(p_item_key);
    if not v_is_jewelry and not public._guild_stockpile_key_ok(p_item_key) then
        return json_build_object('error', 'not_jewelry');
    end if;

    -- Resolve price: 0 → recommended floor; anything else must be >= floor.
    v_min_price := public._item_min_price(p_item_key);
    if coalesce(p_unit_price, 0) <= 0 then
        v_price := v_min_price;
    elsif p_unit_price < v_min_price then
        return json_build_object('error', 'price_below_minimum', 'min_price', v_min_price);
    else
        v_price := p_unit_price;
    end if;

    -- Pull stock from the right pool.
    if v_is_jewelry then
        select coalesce(quantity, 0) into v_have
        from public.guild_jewelry_inventory
        where guild_id = p_guild_id and item_key = p_item_key
        for update;
        if coalesce(v_have, 0) < p_quantity then
            return json_build_object('error', 'insufficient_jewelry',
                'have', coalesce(v_have, 0), 'need', p_quantity);
        end if;
        update public.guild_jewelry_inventory
        set quantity = quantity - p_quantity, updated_at = now()
        where guild_id = p_guild_id and item_key = p_item_key;
    else
        -- Stockpile: only the AVAILABLE portion (amount − reserved) is listable.
        select coalesce(amount, 0), coalesce(reserved, 0)
        into v_amount, v_reserved
        from public.guild_stockpile
        where guild_id = p_guild_id and item_key = p_item_key
        for update;
        v_have := greatest(coalesce(v_amount, 0) - coalesce(v_reserved, 0), 0);
        if v_have < p_quantity then
            return json_build_object('error', 'insufficient_stock',
                'have', v_have, 'need', p_quantity);
        end if;
        update public.guild_stockpile
        set amount = amount - p_quantity, updated_at = now()
        where guild_id = p_guild_id and item_key = p_item_key;
    end if;

    insert into public.guild_store_listings
        (guild_id, seller_id, item_key, unit_price, quantity_remaining)
    values (p_guild_id, v_account, p_item_key, v_price, p_quantity)
    returning id into v_id;

    return json_build_object('ok', true, 'listing_id', v_id, 'unit_price', v_price);
end;
$$;
grant execute on function public.list_guild_item(text, uuid, text, int, bigint) to anon, authenticated;


-- ── cancel_guild_listing (routes the unsold remainder back to its pool) ───────
create or replace function public.cancel_guild_listing(
    p_device_hash text,
    p_listing_id  uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account    uuid;
    v_listing    public.guild_store_listings%rowtype;
    v_leader     uuid;
    v_is_jewelry boolean;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select * into v_listing from public.guild_store_listings
    where id = p_listing_id for update;
    if not found then
        return json_build_object('error', 'listing_not_found');
    end if;
    if v_listing.status <> 'active' then
        return json_build_object('error', 'listing_not_active');
    end if;

    select leader_id into v_leader from public.guilds where id = v_listing.guild_id;
    if v_listing.seller_id <> v_account and v_leader is distinct from v_account then
        return json_build_object('error', 'not_allowed');
    end if;

    v_is_jewelry := public._is_jewelry_key(v_listing.item_key);

    if v_listing.quantity_remaining > 0 then
        if v_is_jewelry then
            perform public._guild_jewelry_add(v_listing.guild_id, v_listing.item_key, v_listing.quantity_remaining);
        else
            insert into public.guild_stockpile (guild_id, item_key, amount, reserved, updated_at)
            values (v_listing.guild_id, v_listing.item_key, v_listing.quantity_remaining, 0, now())
            on conflict (guild_id, item_key)
            do update set amount = public.guild_stockpile.amount + excluded.amount,
                           updated_at = now();
        end if;
    end if;

    update public.guild_store_listings
    set status = 'cancelled', quantity_remaining = 0
    where id = p_listing_id;

    return json_build_object('ok', true,
        'returned_qty', v_listing.quantity_remaining,
        'item_key', v_listing.item_key);
end;
$$;
grant execute on function public.cancel_guild_listing(text, uuid) to anon, authenticated;
