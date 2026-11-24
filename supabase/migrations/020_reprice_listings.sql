-- ============================================================================
-- Marketplace: reprice_listings — set a new price/limit on a seller's active
-- listings for one item, then merge them into a single listing.
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Used by the Sell tab's "list ALL at the new price" option: when a seller
-- lists more of an item at a price/limit that differs from their existing
-- listing(s), they can choose to re-price everything to the new terms. This
-- updates all of that seller's ACTIVE listings for the item to the new
-- price+limit and collapses them (plus keeps their combined stock) into one row.
--
-- Returns json: { ok, listing_id, quantity } | { error }
--   error codes: account_not_found, invalid_price, invalid_daily_limit
-- ============================================================================

create or replace function public.reprice_listings(
    p_device_hash text,
    p_item_key    text,
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
    v_limit  int := coalesce(p_daily_limit, 0);
    v_keep   uuid;
    v_total  int;
begin
    select id into v_seller from public.accounts where device_hash = p_device_hash for update;
    if v_seller is null then
        return json_build_object('error', 'account_not_found');
    end if;
    if p_unit_price is null or p_unit_price < 1 then
        return json_build_object('error', 'invalid_price');
    end if;
    if v_limit < 0 then
        return json_build_object('error', 'invalid_daily_limit');
    end if;

    -- Nothing to reprice -> treat as a no-op success.
    if not exists (
        select 1 from public.listings
        where seller_id = v_seller and item_key = p_item_key and status = 'active'
    ) then
        return json_build_object('ok', true, 'listing_id', null, 'quantity', 0);
    end if;

    -- Sum stock across all this seller's active listings for the item, then set
    -- the new terms on the oldest and cancel the rest (merged into one).
    select coalesce(sum(quantity_remaining), 0) into v_total
    from public.listings
    where seller_id = v_seller and item_key = p_item_key and status = 'active';

    select id into v_keep
    from public.listings
    where seller_id = v_seller and item_key = p_item_key and status = 'active'
    order by created_at asc
    limit 1;

    update public.listings
    set unit_price = p_unit_price,
        per_buyer_daily_limit = v_limit,
        quantity_remaining = v_total
    where id = v_keep;

    update public.listings
    set status = 'cancelled', quantity_remaining = 0
    where seller_id = v_seller and item_key = p_item_key and status = 'active'
      and id <> v_keep;

    return json_build_object('ok', true, 'listing_id', v_keep, 'quantity', v_total);
end;
$$;

grant execute on function public.reprice_listings(text, text, bigint, int) to anon, authenticated;
