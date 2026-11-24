-- ============================================================================
-- Marketplace Task 3 (UI): get_listings / get_my_listings — browse listings
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Read-only listing browse endpoints returning JSON arrays. Buying is a later
-- task; these just surface what's for sale.
-- ============================================================================

-- get_listings(exclude_device_hash) -> active listings from OTHER sellers,
-- newest first. Excludes the caller's own listings so the Browse tab shows what
-- they can actually buy. Pass an empty string to include everything.
--
-- Each row: { id, item_key, unit_price, quantity_remaining, per_buyer_daily_limit,
--             seller, created_at }
create or replace function public.get_listings(p_exclude_device_hash text default '')
returns json
language sql
security definer
set search_path = public
as $$
    select coalesce(json_agg(row_to_json(t) order by t.created_at desc), '[]'::json)
    from (
        select l.id, l.item_key, l.unit_price, l.quantity_remaining,
               l.per_buyer_daily_limit, a.username as seller, l.created_at
        from public.listings l
        join public.accounts a on a.id = l.seller_id
        where l.status = 'active'
          and l.quantity_remaining > 0
          and (p_exclude_device_hash = '' or a.device_hash <> p_exclude_device_hash)
    ) t;
$$;

grant execute on function public.get_listings(text) to anon, authenticated;

-- get_my_listings(device_hash) -> the caller's own active listings, newest first.
-- Used by the "My Listings" tab (Task 4).
create or replace function public.get_my_listings(p_device_hash text)
returns json
language sql
security definer
set search_path = public
as $$
    select coalesce(json_agg(row_to_json(t) order by t.created_at desc), '[]'::json)
    from (
        select l.id, l.item_key, l.unit_price, l.quantity_remaining,
               l.per_buyer_daily_limit, l.status, l.created_at
        from public.listings l
        join public.accounts a on a.id = l.seller_id
        where a.device_hash = p_device_hash
          and l.status = 'active'
    ) t;
$$;

grant execute on function public.get_my_listings(text) to anon, authenticated;
