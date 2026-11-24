-- ============================================================================
-- Marketplace Task 7: escrow + listings tables, list_item / cancel_listing
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Model
--  * listings: an active offer. quantity_remaining is HELD by the listing (the
--    seller already moved these items server-side when listing).
--  * escrow: items an account owns SERVER-SIDE awaiting claim into their local
--    game inventory. Buyers accrue escrow on purchase; sellers accrue escrow
--    when they cancel a listing (unsold remainder returns to them).
--
-- Item identity uses the client's canonical string keys (e.g. "gem:diamond").
-- Both tables are locked with RLS; all access goes through SECURITY DEFINER
-- functions so the client can't tamper with quantities/prices directly.
-- ============================================================================

-- ── listings ────────────────────────────────────────────────────────────────
create table if not exists public.listings (
    id                    uuid        primary key default gen_random_uuid(),
    seller_id             uuid        not null references public.accounts(id) on delete cascade,
    item_key              text        not null,
    unit_price            bigint      not null check (unit_price > 0),
    quantity_remaining    int         not null check (quantity_remaining >= 0),
    per_buyer_daily_limit int         not null default 0 check (per_buyer_daily_limit >= 0), -- 0 = no limit
    status                text        not null default 'active',  -- 'active' | 'cancelled' | 'sold_out'
    created_at            timestamptz not null default now()
);
create index if not exists listings_active_idx on public.listings (status, created_at desc);

alter table public.listings enable row level security;
-- Anyone may browse ACTIVE listings; no direct writes (functions only).
drop policy if exists "read active listings" on public.listings;
create policy "read active listings"
    on public.listings for select to anon, authenticated
    using (status = 'active');

-- ── escrow ───────────────────────────────────────────────────────────────────
-- One row per (account, item_key); quantity accumulates. Locked down entirely
-- (no client policies) — only functions read/write it, exposed via reconcile.
create table if not exists public.escrow (
    account_id uuid not null references public.accounts(id) on delete cascade,
    item_key   text not null,
    quantity   bigint not null default 0 check (quantity >= 0),
    primary key (account_id, item_key)
);
alter table public.escrow enable row level security;
-- (no policies: direct client access denied)

-- Helper: add qty of an item to an account's escrow (upsert).
create or replace function public._escrow_add(p_account uuid, p_item_key text, p_qty bigint)
returns void
language sql
security definer
set search_path = public
as $$
    insert into public.escrow (account_id, item_key, quantity)
    values (p_account, p_item_key, p_qty)
    on conflict (account_id, item_key)
    do update set quantity = public.escrow.quantity + excluded.quantity;
$$;

-- ── list_item ────────────────────────────────────────────────────────────────
-- Creates an active listing owned by the caller's account. The caller asserts
-- they moved `quantity` items out of their local inventory (the client deducts
-- locally only AFTER this returns ok — server-authoritative escrow).
--
-- Returns json: { ok, listing_id } | { error }
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
    -- Resolve caller.
    select id into v_seller from public.accounts where device_hash = p_device_hash;
    if v_seller is null then
        return json_build_object('error', 'account_not_found');
    end if;

    -- Validate inputs.
    if p_item_key is null or length(p_item_key) < 3 then
        return json_build_object('error', 'invalid_item_key');
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

-- ── cancel_listing ───────────────────────────────────────────────────────────
-- Cancels the caller's own active listing. Any unsold quantity_remaining is
-- returned to the SELLER's escrow (claimable back into their local inventory).
--
-- Returns json: { ok, returned_qty, item_key } | { error }
create or replace function public.cancel_listing(
    p_device_hash text,
    p_listing_id  uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_seller uuid;
    v_listing public.listings%rowtype;
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

    -- Return the unsold remainder to the seller's escrow.
    if v_listing.quantity_remaining > 0 then
        perform public._escrow_add(v_seller, v_listing.item_key, v_listing.quantity_remaining);
    end if;

    update public.listings
    set status = 'cancelled', quantity_remaining = 0
    where id = p_listing_id;

    return json_build_object('ok', true,
        'returned_qty', v_listing.quantity_remaining,
        'item_key', v_listing.item_key);
end;
$$;

-- ── Grants ───────────────────────────────────────────────────────────────────
grant execute on function public.list_item(text, text, int, bigint, int) to anon, authenticated;
grant execute on function public.cancel_listing(text, uuid)             to anon, authenticated;
revoke all on function public._escrow_add(uuid, text, bigint) from anon, authenticated;
