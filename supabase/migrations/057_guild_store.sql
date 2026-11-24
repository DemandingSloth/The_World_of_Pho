-- ============================================================================
-- Migration 057: Guild Store (members-only marketplace for produced jewelry)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- The guild store is a GUILD-SCOPED marketplace. Any active member may list a
-- produced jewelry item (keys of the form 'item:<id>' only — raw resources,
-- gems, polished stones, etc. are REJECTED). Other members of the SAME guild
-- buy with marketplace TOKENS (accounts.token_balance — the game's real
-- currency; there is no separate guild currency). The listing SELLER receives
-- the tokens, mirroring the public marketplace (migration 006). The purchased
-- item lands in the BUYER's escrow (claimed into local inventory next
-- marketplace open), reusing _escrow_add from migration 004.
--
-- WHY A SEPARATE TABLE (not public.listings): guild stores are private to a
-- guild and restricted to jewelry; keeping them separate avoids leaking guild
-- inventory into the public listing feed and keeps the jewelry-only guard local.
--
-- SELF-DEAL: the same guard the public marketplace uses — a seller cannot buy
-- their own listing (cannot_buy_own). (An alt-account loop is the same risk the
-- public market already carries; tokens are real currency either way.)
--
-- AUTHORITY: all access via SECURITY DEFINER functions; RLS denies direct
-- writes. Members resolved through the existing _guild_resolve_account /
-- _guild_active_member helpers; token moves logged to the existing
-- token_ledger (reasons 'guild_sale' / 'guild_buy').
-- ============================================================================


-- ── guild_store_listings ──────────────────────────────────────────────────────
-- One active offer owned by a member, scoped to their guild. quantity_remaining
-- is HELD by the listing (the seller deducts locally only AFTER list ok).
create table if not exists public.guild_store_listings (
    id                 uuid        primary key default gen_random_uuid(),
    guild_id           uuid        not null references public.guilds(id)   on delete cascade,
    seller_id          uuid        not null references public.accounts(id) on delete cascade,
    item_key           text        not null,                 -- must be 'item:<id>'
    unit_price         bigint      not null check (unit_price > 0),
    quantity_remaining int         not null check (quantity_remaining >= 0),
    status             text        not null default 'active'
                                   check (status in ('active', 'cancelled', 'sold_out')),
    created_at         timestamptz not null default now()
);
create index if not exists guild_store_listings_guild_active_idx
    on public.guild_store_listings (guild_id, created_at desc) where status = 'active';
alter table public.guild_store_listings enable row level security;  -- functions only


-- ── Helper: is this a produced-jewelry key? ('item:<id>') ───────────────────────
create or replace function public._is_jewelry_key(p_item_key text)
returns boolean
language sql
immutable
as $$
    select p_item_key is not null and left(p_item_key, 5) = 'item:' and length(p_item_key) > 5;
$$;


-- ── list_guild_item ───────────────────────────────────────────────────────────
-- Any active member lists a produced jewelry item in their guild's store. The
-- caller asserts they moved `quantity` of the item out of local inventory (the
-- client deducts locally only AFTER this returns ok — server-authoritative).
-- Returns { ok, listing_id } | { error }.
--   errors: account_not_found, not_in_guild, not_jewelry, invalid_quantity,
--           invalid_price
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
    v_account uuid;
    v_member  public.guild_members%rowtype;
    v_id      uuid;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    -- Jewelry-only: reject raw resources / gems / polished / anything else.
    if not public._is_jewelry_key(p_item_key) then
        return json_build_object('error', 'not_jewelry');
    end if;
    if p_quantity is null or p_quantity < 1 then
        return json_build_object('error', 'invalid_quantity');
    end if;
    if p_unit_price is null or p_unit_price < 1 then
        return json_build_object('error', 'invalid_price');
    end if;

    insert into public.guild_store_listings
        (guild_id, seller_id, item_key, unit_price, quantity_remaining)
    values (p_guild_id, v_account, p_item_key, p_unit_price, p_quantity)
    returning id into v_id;

    return json_build_object('ok', true, 'listing_id', v_id);
end;
$$;
grant execute on function public.list_guild_item(text, uuid, text, int, bigint) to anon, authenticated;


-- ── get_guild_store ─────────────────────────────────────────────────────────
-- Any active member views their guild's active listings.
--   { now, items:[{ id, seller_id, seller_name, item_key, unit_price,
--                    quantity_remaining, mine, created_at }] }
create or replace function public.get_guild_store(
    p_device_hash text,
    p_guild_id    uuid
)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_member  public.guild_members%rowtype;
    v_items   json;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    select coalesce(json_agg(json_build_object(
        'id',                 l.id,
        'seller_id',          l.seller_id,
        'seller_name',        a.username,
        'item_key',           l.item_key,
        'unit_price',         l.unit_price,
        'quantity_remaining', l.quantity_remaining,
        'mine',               (l.seller_id = v_account),
        'created_at',         extract(epoch from l.created_at)
    ) order by l.created_at desc), '[]'::json)
    into v_items
    from public.guild_store_listings l
    join public.accounts a on a.id = l.seller_id
    where l.guild_id = p_guild_id and l.status = 'active';

    return json_build_object('now', extract(epoch from now()), 'items', v_items);
end;
$$;
grant execute on function public.get_guild_store(text, uuid) to anon, authenticated;


-- ── buy_guild_item ────────────────────────────────────────────────────────────
-- Atomic purchase from the guild store. Buyer must be an active member of the
-- SAME guild as the listing. In one transaction: lock listing, validate, debit
-- buyer tokens, credit seller tokens, add item to buyer escrow, log ledger.
-- Returns { ok, quantity, item_key, spent, new_balance } | { error }.
--   errors: account_not_found, not_in_guild, listing_not_found,
--           listing_not_active, wrong_guild, cannot_buy_own, invalid_quantity,
--           insufficient_stock, insufficient_tokens
create or replace function public.buy_guild_item(
    p_device_hash text,
    p_guild_id    uuid,
    p_listing_id  uuid,
    p_quantity    int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_member  public.guild_members%rowtype;
    v_balance bigint;
    v_listing public.guild_store_listings%rowtype;
    v_cost    bigint;
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

    -- Lock the buyer's account row for the token update.
    select token_balance into v_balance
    from public.accounts where id = v_account
    for update;

    -- Lock the listing row to serialize concurrent buyers.
    select * into v_listing from public.guild_store_listings
    where id = p_listing_id for update;
    if not found then
        return json_build_object('error', 'listing_not_found');
    end if;
    if v_listing.status <> 'active' then
        return json_build_object('error', 'listing_not_active');
    end if;
    if v_listing.guild_id <> p_guild_id then
        return json_build_object('error', 'wrong_guild');
    end if;
    if v_listing.seller_id = v_account then
        return json_build_object('error', 'cannot_buy_own');
    end if;
    if v_listing.quantity_remaining < p_quantity then
        return json_build_object('error', 'insufficient_stock');
    end if;

    v_cost := v_listing.unit_price * p_quantity;
    if v_balance < v_cost then
        return json_build_object('error', 'insufficient_tokens');
    end if;

    -- ── Mutations (all within this transaction) ──────────────────────────────
    update public.guild_store_listings
    set quantity_remaining = quantity_remaining - p_quantity,
        status = case when quantity_remaining - p_quantity <= 0 then 'sold_out' else status end
    where id = p_listing_id;

    update public.accounts set token_balance = token_balance - v_cost where id = v_account;
    update public.accounts set token_balance = token_balance + v_cost where id = v_listing.seller_id;

    perform public._escrow_add(v_account, v_listing.item_key, p_quantity);

    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_account,            -v_cost, 'guild_buy',  p_listing_id),
           (v_listing.seller_id,   v_cost, 'guild_sale', p_listing_id);

    return json_build_object(
        'ok', true,
        'quantity', p_quantity,
        'item_key', v_listing.item_key,
        'spent', v_cost,
        'new_balance', v_balance - v_cost
    );
end;
$$;
grant execute on function public.buy_guild_item(text, uuid, uuid, int) to anon, authenticated;


-- ── cancel_guild_listing ──────────────────────────────────────────────────────
-- Cancels the caller's own active listing; any unsold remainder returns to the
-- SELLER's escrow (claimable back into local inventory).
-- Returns { ok, returned_qty, item_key } | { error }.
--   errors: account_not_found, listing_not_found, not_your_listing,
--           listing_not_active
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
    if v_listing.seller_id <> v_account then
        return json_build_object('error', 'not_your_listing');
    end if;
    if v_listing.status <> 'active' then
        return json_build_object('error', 'listing_not_active');
    end if;

    if v_listing.quantity_remaining > 0 then
        perform public._escrow_add(v_account, v_listing.item_key, v_listing.quantity_remaining);
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
