-- ============================================================================
-- Marketplace hotfix: block untradeable items (e.g. the unique Tractor) +
-- clean up / refund any bad listings & purchases that already happened.
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Some items are UNIQUE and non-stackable (permanent tools like tool:tractor).
-- They must never be listed or bought: a buyer can't receive a second one, so a
-- purchase just burns their tokens. This migration:
--   1. Adds an untradeable_items blocklist table (extensible).
--   2. Guards list_item to reject blocked keys server-side (defense in depth;
--      the client also filters now).
--   3. Cancels existing ACTIVE bad listings, returning held stock to sellers'
--      escrow (so a seller who listed a tractor gets it back).
--   4. Refunds buyers who already purchased a blocked item: credits their tokens
--      back, logs the refund, and removes the unusable item from their escrow.
-- ============================================================================

-- ── 1. Blocklist ─────────────────────────────────────────────────────────────
create table if not exists public.untradeable_items (
    item_key text primary key,
    reason   text not null default ''
);
alter table public.untradeable_items enable row level security;  -- functions only

insert into public.untradeable_items (item_key, reason) values
    ('tool:tractor', 'Unique permanent tool — player can only own one.')
on conflict (item_key) do nothing;

-- ── 2. Guard list_item (CREATE OR REPLACE the 004 version) ───────────────────
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
begin
    select id into v_seller from public.accounts where device_hash = p_device_hash;
    if v_seller is null then
        return json_build_object('error', 'account_not_found');
    end if;

    if p_item_key is null or length(p_item_key) < 3 then
        return json_build_object('error', 'invalid_item_key');
    end if;
    -- Reject blocklisted (untradeable) items.
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

    insert into public.listings (seller_id, item_key, unit_price, quantity_remaining, per_buyer_daily_limit)
    values (v_seller, p_item_key, p_unit_price, p_quantity, coalesce(p_daily_limit, 0))
    returning id into v_id;

    return json_build_object('ok', true, 'listing_id', v_id);
end;
$$;

grant execute on function public.list_item(text, text, int, bigint, int) to anon, authenticated;

-- ── 3. Cancel existing ACTIVE bad listings; return held stock to seller escrow.
do $$
declare
    r record;
begin
    for r in
        select l.id, l.seller_id, l.item_key, l.quantity_remaining
        from public.listings l
        join public.untradeable_items u on u.item_key = l.item_key
        where l.status = 'active'
    loop
        if r.quantity_remaining > 0 then
            perform public._escrow_add(r.seller_id, r.item_key, r.quantity_remaining);
        end if;
        update public.listings set status = 'cancelled', quantity_remaining = 0
        where id = r.id;
    end loop;
end $$;

-- ── 4. Refund buyers who already purchased a blocked item. ───────────────────
-- Credit tokens back (unit_price * quantity), log a 'refund' ledger entry, and
-- remove the unusable item from their escrow so it doesn't get claimed.
do $$
declare
    p record;
begin
    for p in
        select pu.id, pu.buyer_id, pu.item_key, pu.unit_price, pu.quantity
        from public.purchases pu
        join public.untradeable_items u on u.item_key = pu.item_key
    loop
        -- Refund tokens to the buyer.
        update public.accounts
        set token_balance = token_balance + (p.unit_price * p.quantity)
        where id = p.buyer_id;

        insert into public.token_ledger (account_id, delta, reason, ref_id)
        values (p.buyer_id, p.unit_price * p.quantity, 'refund', p.id);

        -- Remove the unusable item from the buyer's escrow (down to 0, never
        -- negative — they may have partially claimed already, which is fine
        -- since the client now refuses to add it anyway).
        update public.escrow
        set quantity = greatest(0, quantity - p.quantity)
        where account_id = p.buyer_id and item_key = p.item_key;
        delete from public.escrow
        where account_id = p.buyer_id and item_key = p.item_key and quantity = 0;
    end loop;
end $$;
