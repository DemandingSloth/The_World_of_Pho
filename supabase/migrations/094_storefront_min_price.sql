-- ============================================================================
-- Migration 094: Storefront accepts stockpile items + min price floor
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- The guild storefront previously accepted JEWELRY ONLY (item:* keys from the
-- guild_jewelry_inventory pool). Now it also accepts raw-material stockpile
-- items (resource/gem/polished/crop/fruit keys) drawn from guild_stockpile.
-- This replaces the withdraw feature: excess stock is sold on the storefront
-- instead of withdrawn to the leader's escrow.
--
-- Changes:
--   1. _item_min_price(item_key) — replaces _jewelry_min_price. Returns the
--      floor price for ANY item: sell_price-1 for jewelry, suggested_price-1
--      for stockpile items, 1 as a safe fallback.
--
--   2. list_guild_item REWRITTEN to accept any valid guild item key:
--      • item:* (jewelry)  → deducts from guild_jewelry_inventory (existing)
--      • stockpile keys    → deducts from guild_stockpile (available = amount -
--        reserved; reserved stock is never touched)
--      • p_unit_price = 0  → use recommended floor price
--      • p_unit_price > 0  → must be >= floor (else price_below_minimum)
--
--   3. cancel_guild_listing REWRITTEN to route returns to the right pool:
--      • item:* → guild_jewelry_inventory (existing)
--      • stockpile keys → guild_stockpile (added back to amount)
--
--   NOTE: withdraw_from_stockpile / set_stockpile_lock remain in the DB as
--   harmless dead functions; the client no longer calls them.
-- ============================================================================


-- ── _item_min_price ──────────────────────────────────────────────────────────
-- Returns the minimum allowed listing price for ANY guild item key.
--   Jewelry ('item:<id>'):  sell_price − 1  (from ITEM_DEFS sell_price)
--   Stockpile items:        suggested_price − 1  (from SUGGESTED_LIST_PRICE)
--   Unknown:                1
create or replace function public._item_min_price(p_item_key text)
returns bigint
language plpgsql
immutable
security definer
set search_path = public
as $$
begin
    return case p_item_key
        -- Jewelry: sell_price − 1
        when 'item:diamond_ring'        then 499999
        when 'item:gold_ring'           then 249999
        when 'item:blue_stone_necklace' then 399999
        when 'item:pink_stone_necklace' then 399999
        when 'item:violet_stone_ring'   then 599999
        when 'item:black_pearl_necklace'then 899999
        when 'item:emerald_necklace'    then 1399999
        when 'item:ruby_ring'           then 2499999
        when 'item:copper_horseshoe'    then 299999
        when 'item:iron_horseshoe'      then 299999
        -- Uncut gems
        when 'gem:gold'          then 5
        when 'gem:blue_stone'    then 7
        when 'gem:pink_stone'    then 7
        when 'gem:violet_stone'  then 10
        when 'gem:black_pearl'   then 15
        when 'gem:emerald'       then 20
        when 'gem:ruby'          then 30
        when 'gem:diamond'       then 50
        -- Polished gems
        when 'polished:blue_stone'    then 75
        when 'polished:pink_stone'    then 75
        when 'polished:violet_stone'  then 100
        when 'polished:black_pearl'   then 150
        when 'polished:emerald'       then 200
        when 'polished:ruby'          then 300
        when 'polished:diamond'       then 500
        -- Garden crops
        when 'crop:beans'        then 1
        when 'crop:cucumbers'    then 4
        when 'crop:peppers'      then 6
        when 'crop:squash'       then 11
        when 'crop:grapes'       then 15
        when 'crop:sunflower'    then 19
        when 'crop:cauliflower'  then 23
        when 'crop:pineapple'    then 26
        when 'crop:watermelon'   then 30
        -- Orchard fruit
        when 'fruit:plum'        then 50
        when 'fruit:lemon'       then 100
        when 'fruit:apple'       then 150
        when 'fruit:banana'      then 200
        when 'fruit:coconut'     then 250
        -- Resources
        when 'resource:wood'         then 50
        when 'resource:stick'        then 25
        when 'resource:iron_ore'     then 75
        when 'resource:iron_bar'     then 750
        when 'resource:copper_ore'   then 100
        when 'resource:copper_ingot' then 1000
        when 'resource:gold_ingot'   then 2500
        -- Fallback
        else 1
    end;
end;
$$;
revoke all on function public._item_min_price(text) from anon, authenticated;


-- ── list_guild_item (REWRITTEN: accepts jewelry + stockpile items) ────────────
-- Any active member lists guild-owned items on the storefront.
--   item:* keys       → drawn from guild_jewelry_inventory
--   stockpile keys    → drawn from guild_stockpile (available = amount − reserved)
-- p_unit_price = 0  → use the recommended floor price.
-- p_unit_price > 0  → must be >= floor (else price_below_minimum).
-- Returns { ok, listing_id, unit_price } | { error }.
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
    v_account   uuid;
    v_member    public.guild_members%rowtype;
    v_have      bigint;
    v_id        uuid;
    v_min_price bigint;
    v_price     bigint;
    v_is_jewelry boolean;
    v_amount    bigint;
    v_reserved  bigint;
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

    v_is_jewelry := public._is_jewelry_key(p_item_key);
    if not v_is_jewelry and not public._guild_stockpile_key_ok(p_item_key) then
        return json_build_object('error', 'not_jewelry');
    end if;

    -- Resolve price: 0 → recommended floor; anything else must be >= floor.
    v_min_price := public._item_min_price(p_item_key);
    if coalesce(p_unit_price, 0) <= 0 then
        v_price := v_min_price;
    elsif p_unit_price < v_min_price then
        return json_build_object(
            'error', 'price_below_minimum',
            'min_price', v_min_price
        );
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


-- ── cancel_guild_listing (REWRITTEN: routes returns to the right pool) ────────
-- Cancels an active listing; unsold remainder returns to the source pool:
--   item:*       → guild_jewelry_inventory
--   stockpile    → guild_stockpile (added back to amount)
-- The caller must be the lister OR the guild leader.
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
    v_account uuid;
    v_listing public.guild_store_listings%rowtype;
    v_leader  uuid;
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

    -- Return unsold remainder to the correct pool.
    if v_listing.quantity_remaining > 0 then
        if v_is_jewelry then
            perform public._guild_jewelry_add(v_listing.guild_id, v_listing.item_key, v_listing.quantity_remaining);
        else
            -- Return to guild_stockpile (add back to amount).
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
