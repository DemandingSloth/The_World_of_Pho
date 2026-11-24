-- ============================================================================
-- Marketplace fix: "Market Stocker" (list_item) mission counts LIST ACTIONS,
-- not listing rows.
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 019 (auto-merge listings) and 008 (_mission_progress_count).
--
-- BUG: the list_item mission progress counted rows in `listings`
-- (count(*) where seller_id = me). Since 019 auto-MERGES a re-listing of the
-- same item/price into an existing row, re-stocking no longer creates a new row
-- -> the count didn't rise -> the mission never advanced on a restock.
--
-- FIX: track a per-account "list actions" counter that increments on EVERY
-- successful list_item call (new row OR merge), and point the mission's
-- list_item progress at that counter instead of row count.
-- ============================================================================

-- 1. Per-account counter of listing actions (monotonic; never decreases).
alter table public.accounts
    add column if not exists listings_created bigint not null default 0;

-- 2. Backfill: seed the counter to each account's current active+historical
--    listing row count, so existing progress isn't lost. (Best-effort baseline;
--    rows merged away pre-fix can't be recovered, but this is >= what count(*)
--    would have shown.)
update public.accounts a
set listings_created = greatest(a.listings_created,
    (select count(*) from public.listings l where l.seller_id = a.id));

-- 3. list_item: increment the counter on every successful listing (new or merge).
--    (CREATE OR REPLACE the 019 version, keeping merge behavior intact.)
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
    v_merged boolean := false;
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

    -- MERGE into an existing identical active listing, else insert a new row.
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
        v_merged := true;
    else
        insert into public.listings (seller_id, item_key, unit_price, quantity_remaining, per_buyer_daily_limit)
        values (v_seller, p_item_key, p_unit_price, p_quantity, v_limit)
        returning id into v_id;
    end if;

    -- Count the listing ACTION (new or merge) toward the Market Stocker mission.
    update public.accounts set listings_created = listings_created + 1 where id = v_seller;

    return json_build_object('ok', true, 'listing_id', v_id, 'merged', v_merged);
end;
$$;

grant execute on function public.list_item(text, text, int, bigint, int) to anon, authenticated;

-- 4. Point the list_item mission progress at the action counter.
create or replace function public._mission_progress_count(p_account uuid, p_objective text)
returns int
language sql
security definer
set search_path = public
as $$
    select case p_objective
        when 'make_sale' then (select count(*)::int from public.purchases where seller_id = p_account)
        when 'purchase'  then (select count(*)::int from public.purchases where buyer_id  = p_account)
        when 'list_item' then coalesce((select listings_created::int from public.accounts where id = p_account), 0)
        else 0
    end;
$$;

revoke all on function public._mission_progress_count(uuid, text) from anon, authenticated;
