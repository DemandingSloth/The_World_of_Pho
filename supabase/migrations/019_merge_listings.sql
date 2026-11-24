-- ============================================================================
-- Marketplace: auto-merge identical listings + consolidate existing ones
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Supersedes list_item from 013.
--
-- Listing the same item at the same price repeatedly used to create separate
-- rows, cluttering Browse. Now list_item MERGES into the seller's existing
-- active listing when the item_key, unit_price AND per_buyer_daily_limit all
-- match — just bumping quantity_remaining. Different price or different daily
-- limit stays a separate listing (they're materially different offers).
--
-- Also runs a ONE-TIME cleanup that merges any already-fragmented active
-- listings (e.g. a seller's multiple polished-emerald listings at the same
-- price+limit) into a single row per (seller, item_key, price, limit).
-- ============================================================================

-- ── list_item with auto-merge ────────────────────────────────────────────────
create or replace function public.list_item(
    p_device_hash text,
    p_item_key    text,
    p_quantity    int,
    p_unit_price  bigint,
    p_daily_limit int default 0
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_seller uuid;
    v_id     uuid;
    v_limit  int := coalesce(p_daily_limit, 0);
begin
    select id into v_seller from public.accounts where device_hash = p_device_hash;
    if v_seller is null then
        return json_build_object('error', 'account_not_found');
    end if;

    if p_item_key is null or length(p_item_key) < 3 then
        return json_build_object('error', 'invalid_item_key');
    end if;
    if exists (select 1 from public.untradeable_items where item_key = p_item_key) then
        return json_build_object('error', 'item_not_tradeable');
    end if;
    if p_quantity is null or p_quantity < 1 then
        return json_build_object('error', 'invalid_quantity');
    end if;
    if p_unit_price is null or p_unit_price < 1 then
        return json_build_object('error', 'invalid_price');
    end if;
    if p_daily_limit is null or p_daily_limit < 0 then
        return json_build_object('error', 'invalid_daily_limit');
    end if;

    -- MERGE: if the seller already has an active listing for the same item at
    -- the same price AND same per-buyer daily limit, add to it instead of
    -- creating a new row. Lock the row to serialize concurrent lists.
    select id into v_id
    from public.listings
    where seller_id = v_seller
      and item_key = p_item_key
      and unit_price = p_unit_price
      and per_buyer_daily_limit = v_limit
      and status = 'active'
    order by created_at asc
    limit 1
    for update;

    if v_id is not null then
        update public.listings
        set quantity_remaining = quantity_remaining + p_quantity
        where id = v_id;
        return json_build_object('ok', true, 'listing_id', v_id, 'merged', true);
    end if;

    insert into public.listings (seller_id, item_key, unit_price, quantity_remaining, per_buyer_daily_limit)
    values (v_seller, p_item_key, p_unit_price, p_quantity, v_limit)
    returning id into v_id;

    return json_build_object('ok', true, 'listing_id', v_id, 'merged', false);
end;
$$;

grant execute on function public.list_item(text, text, int, bigint, int) to anon, authenticated;

-- ── One-time cleanup: merge existing fragmented active listings ──────────────
-- For each (seller, item_key, unit_price, per_buyer_daily_limit) group with more
-- than one active listing, keep the oldest row (sum all quantities into it) and
-- mark the rest 'cancelled' with quantity 0. Uses cancelled (not delete) so any
-- foreign-key refs (purchases.listing_id) stay valid.
do $$
declare
    g record;
    keep_id uuid;
    total   int;
begin
    for g in
        select seller_id, item_key, unit_price, per_buyer_daily_limit
        from public.listings
        where status = 'active'
        group by seller_id, item_key, unit_price, per_buyer_daily_limit
        having count(*) > 1
    loop
        -- Oldest listing in the group is the survivor.
        select id into keep_id
        from public.listings
        where status = 'active'
          and seller_id = g.seller_id and item_key = g.item_key
          and unit_price = g.unit_price and per_buyer_daily_limit = g.per_buyer_daily_limit
        order by created_at asc
        limit 1;

        select coalesce(sum(quantity_remaining), 0) into total
        from public.listings
        where status = 'active'
          and seller_id = g.seller_id and item_key = g.item_key
          and unit_price = g.unit_price and per_buyer_daily_limit = g.per_buyer_daily_limit;

        update public.listings set quantity_remaining = total where id = keep_id;

        update public.listings
        set status = 'cancelled', quantity_remaining = 0
        where status = 'active'
          and seller_id = g.seller_id and item_key = g.item_key
          and unit_price = g.unit_price and per_buyer_daily_limit = g.per_buyer_daily_limit
          and id <> keep_id;
    end loop;
end $$;
