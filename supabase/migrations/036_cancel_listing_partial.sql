-- ============================================================================
-- Marketplace: partial cancel — return only what the player can hold, keep the
-- rest as an ACTIVE listing (never hidden in escrow)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- WHY: the full cancel_listing (004) moved the entire unsold remainder into
-- escrow. When the player's local store was full, the overflow sat invisibly in
-- escrow until space freed up — the player couldn't see what they had. Design
-- rule: a player can always see everything they own. So a cancel should only
-- pull back as much as fits locally and leave the remainder as a visible active
-- listing (still sellable, still shown in "My Listings").
--
-- Example: 1700 seeds listed, 500 free local slots -> cancel returns 500 (into
-- escrow, claimed immediately by the client) and the listing stays ACTIVE with
-- quantity_remaining = 1200.
--
-- p_max_return: max units to pull back this call (= the player's free local
-- space for that item). NULL = pull back everything (full cancel), matching the
-- old behavior for uncapped items.
--
-- Returns json:
--   { ok, returned_qty, remaining_qty, item_key, cancelled }
--     returned_qty  = units moved to escrow for the client to claim now
--     remaining_qty = units left on the still-active listing (0 if fully cancelled)
--     cancelled     = true if the listing was fully cancelled (nothing left)
-- ============================================================================

create or replace function public.cancel_listing_partial(
    p_device_hash text,
    p_listing_id  uuid,
    p_max_return  bigint default null
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_seller   uuid;
    v_listing  public.listings%rowtype;
    v_return   bigint;
    v_remaining bigint;
begin
    select id into v_seller from public.accounts where device_hash = p_device_hash;
    if v_seller is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select * into v_listing from public.listings
    where id = p_listing_id for update;
    if not found then
        return json_build_object('error', 'listing_not_found');
    end if;
    if v_listing.seller_id <> v_seller then
        return json_build_object('error', 'not_your_listing');
    end if;
    if v_listing.status <> 'active' then
        return json_build_object('error', 'listing_not_active');
    end if;

    -- How much to pull back this call. NULL p_max_return = everything (uncapped).
    if p_max_return is null then
        v_return := v_listing.quantity_remaining;
    else
        v_return := least(v_listing.quantity_remaining, greatest(p_max_return, 0));
    end if;

    v_remaining := v_listing.quantity_remaining - v_return;

    -- Return the claimable portion to escrow (client claims it immediately).
    if v_return > 0 then
        perform public._escrow_add(v_seller, v_listing.item_key, v_return);
    end if;

    if v_remaining <= 0 then
        -- Nothing left: fully cancel the listing.
        update public.listings
        set status = 'cancelled', quantity_remaining = 0
        where id = p_listing_id;
    else
        -- Keep the listing ACTIVE with the leftover so it stays visible/sellable.
        update public.listings
        set quantity_remaining = v_remaining
        where id = p_listing_id;
    end if;

    return json_build_object('ok', true,
        'returned_qty', v_return,
        'remaining_qty', v_remaining,
        'item_key', v_listing.item_key,
        'cancelled', (v_remaining <= 0));
end;
$$;

grant execute on function public.cancel_listing_partial(text, uuid, bigint) to anon, authenticated;
