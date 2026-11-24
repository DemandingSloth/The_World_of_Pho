-- ============================================================================
-- Migration 062: Guild jewelry inventory (production -> guild pool -> storefront)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Produced jewelry no longer goes to the collecting member's PERSONAL inventory.
-- Instead it lands in a shared GUILD JEWELRY INVENTORY owned by the guild, and
-- the guild storefront lists OUT of that pool. The only way a player gets a
-- jewelry piece personally is by BUYING it from a guild storefront (the buy
-- RPCs in 057/059 still escrow the item to the buyer) — which closes the loop:
--   produce -> guild pool -> list -> someone buys -> buyer owns it personally.
--
-- Changes:
--   • New table guild_jewelry_inventory(guild_id, item_key, quantity).
--   • collect_production (was 055): finished crafts -> guild_jewelry_inventory
--     (NOT the collector's escrow).
--   • list_guild_item (was 057): draws stock FROM the guild pool (server-
--     authoritative; rejects if the pool lacks enough). The client no longer
--     needs to own the item.
--   • cancel_guild_listing (was 057): returns unsold stock TO the guild pool.
--   • get_guild_jewelry: new read for the Store "List Jewelry" dropdown.
--   • buy_guild_item (057) / buy_guild_front_item (059) are UNCHANGED — buyers
--     still receive the item in their personal escrow.
-- ============================================================================


-- ── guild_jewelry_inventory ───────────────────────────────────────────────────
-- Finished, guild-owned jewelry awaiting listing. One row per (guild, item_key);
-- quantity accumulates. item_key is always an 'item:<id>' jewelry key.
create table if not exists public.guild_jewelry_inventory (
    guild_id   uuid   not null references public.guilds(id) on delete cascade,
    item_key   text   not null,
    quantity   bigint not null default 0 check (quantity >= 0),
    updated_at timestamptz not null default now(),
    primary key (guild_id, item_key)
);
alter table public.guild_jewelry_inventory enable row level security;  -- RPCs only


-- ── _guild_jewelry_add ────────────────────────────────────────────────────────
-- Adds qty of a jewelry key to the guild pool (upsert). Uncapped (jewelry is
-- low-volume, unlike the raw-materials stockpile). Internal; callers validate.
create or replace function public._guild_jewelry_add(
    p_guild_id uuid,
    p_item_key text,
    p_qty      bigint
)
returns void
language sql
security definer
set search_path = public
as $$
    insert into public.guild_jewelry_inventory (guild_id, item_key, quantity, updated_at)
    values (p_guild_id, p_item_key, p_qty, now())
    on conflict (guild_id, item_key)
    do update set quantity = public.guild_jewelry_inventory.quantity + excluded.quantity,
                  updated_at = now();
$$;
revoke all on function public._guild_jewelry_add(uuid, text, bigint) from anon, authenticated;


-- ── collect_production (REWRITTEN: output -> guild jewelry inventory) ─────────
-- Any active member may collect. Every FINISHED active craft is moved into the
-- GUILD jewelry inventory (shared), not the collector's personal escrow.
-- Returns { ok, collected:{item_key:count}, total }.
create or replace function public.collect_production(
    p_device_hash text,
    p_guild_id    uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_member  public.guild_members%rowtype;
    r         record;
    v_counts  jsonb := '{}'::jsonb;
    v_total   int := 0;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    for r in
        select id, output_item_key
        from public.guild_production_queue
        where guild_id = p_guild_id and status = 'active' and finish_at <= now()
        for update
    loop
        -- Shared guild pool (NOT the collector's escrow).
        perform public._guild_jewelry_add(p_guild_id, r.output_item_key, 1);
        update public.guild_production_queue set status = 'collected' where id = r.id;
        v_counts := jsonb_set(
            v_counts,
            array[r.output_item_key],
            to_jsonb(coalesce((v_counts ->> r.output_item_key)::int, 0) + 1)
        );
        v_total := v_total + 1;
    end loop;

    return json_build_object('ok', true, 'collected', v_counts, 'total', v_total);
end;
$$;
grant execute on function public.collect_production(text, uuid) to anon, authenticated;


-- ── get_guild_jewelry ─────────────────────────────────────────────────────────
-- Any active member views the guild's finished-jewelry pool (for the Store
-- "List Jewelry" dropdown). { items: [{ item_key, quantity }] }.
create or replace function public.get_guild_jewelry(
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
        'item_key', j.item_key,
        'quantity', j.quantity
    ) order by j.item_key), '[]'::json)
    into v_items
    from public.guild_jewelry_inventory j
    where j.guild_id = p_guild_id and j.quantity > 0;

    return json_build_object('items', v_items);
end;
$$;
grant execute on function public.get_guild_jewelry(text, uuid) to anon, authenticated;


-- ── list_guild_item (REWRITTEN: draws stock from the guild jewelry pool) ──────
-- Any active member lists guild-owned jewelry on the storefront. The quantity
-- is pulled from guild_jewelry_inventory (server-authoritative) — the member
-- does NOT need to own it personally. seller_id records WHO listed it (display
-- + cannot_buy_own only).
-- Returns { ok, listing_id } | { error }.
--   errors: account_not_found, not_in_guild, not_jewelry, invalid_quantity,
--           invalid_price, insufficient_jewelry
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
    v_have    bigint;
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

    if not public._is_jewelry_key(p_item_key) then
        return json_build_object('error', 'not_jewelry');
    end if;
    if p_quantity is null or p_quantity < 1 then
        return json_build_object('error', 'invalid_quantity');
    end if;
    if p_unit_price is null or p_unit_price < 1 then
        return json_build_object('error', 'invalid_price');
    end if;

    -- Pull the stock from the guild pool (lock the row).
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

    insert into public.guild_store_listings
        (guild_id, seller_id, item_key, unit_price, quantity_remaining)
    values (p_guild_id, v_account, p_item_key, p_unit_price, p_quantity)
    returning id into v_id;

    return json_build_object('ok', true, 'listing_id', v_id);
end;
$$;
grant execute on function public.list_guild_item(text, uuid, text, int, bigint) to anon, authenticated;


-- ── cancel_guild_listing (REWRITTEN: unsold stock -> guild jewelry pool) ──────
-- Cancels an active listing; any unsold remainder returns to the GUILD jewelry
-- pool (not a personal escrow). The caller must be the lister OR the guild
-- leader (leaders can tidy up any member's listing).
-- Returns { ok, returned_qty, item_key } | { error }.
--   errors: account_not_found, listing_not_found, not_allowed, listing_not_active
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

    -- Lister OR guild leader may cancel.
    select leader_id into v_leader from public.guilds where id = v_listing.guild_id;
    if v_listing.seller_id <> v_account and v_leader is distinct from v_account then
        return json_build_object('error', 'not_allowed');
    end if;

    -- Unsold remainder returns to the GUILD jewelry pool.
    if v_listing.quantity_remaining > 0 then
        perform public._guild_jewelry_add(v_listing.guild_id, v_listing.item_key, v_listing.quantity_remaining);
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
