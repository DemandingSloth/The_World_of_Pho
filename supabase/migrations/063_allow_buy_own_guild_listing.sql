-- ============================================================================
-- Migration 063: Allow buying your own guild-store listing
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Since migration 062, guild-store stock is GUILD-OWNED (it comes from the guild
-- jewelry pool, not a person's inventory). The listing's seller_id is merely
-- "who moved it to the shelf" — not who owns it. So the old cannot_buy_own guard
-- no longer maps to anything real: the guild leader (or any member) legitimately
-- needs to be able to buy their guild's own listing (e.g. to pull a piece into
-- their personal inventory to equip it).
--
-- This migration redefines both buy RPCs to DROP the cannot_buy_own guard:
--   • buy_guild_item          (internal, same-guild members)   — was 058
--   • buy_guild_front_item    (public, any player)             — was 059
-- Everything else is unchanged: proceeds still route to the guild bank and split
-- evenly, so a self-buy is a net loss to the buyer (full price out, only an even
-- share back) and a net gain to the guild — not exploitable.
-- ============================================================================


-- ── buy_guild_item (internal; cannot_buy_own guard removed) ──────────────────
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
    v_shared  bigint;
    v_bank    bigint;
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

    select token_balance into v_balance
    from public.accounts where id = v_account
    for update;

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
    -- (cannot_buy_own guard removed — stock is guild-owned since migration 062)
    if v_listing.quantity_remaining < p_quantity then
        return json_build_object('error', 'insufficient_stock');
    end if;

    v_cost := v_listing.unit_price * p_quantity;
    if v_balance < v_cost then
        return json_build_object('error', 'insufficient_tokens');
    end if;

    update public.guild_store_listings
    set quantity_remaining = quantity_remaining - p_quantity,
        status = case when quantity_remaining - p_quantity <= 0 then 'sold_out' else status end
    where id = p_listing_id;

    update public.accounts set token_balance = token_balance - v_cost where id = v_account;
    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_account, -v_cost, 'guild_buy', p_listing_id);

    perform public._escrow_add(v_account, v_listing.item_key, p_quantity);

    v_shared := public._distribute_guild_pool(p_guild_id, v_cost, p_listing_id);
    select coalesce(bank_balance, 0) into v_bank from public.guilds where id = p_guild_id;

    return json_build_object(
        'ok', true,
        'quantity', p_quantity,
        'item_key', v_listing.item_key,
        'spent', v_cost,
        'new_balance', v_balance - v_cost,
        'shared', v_shared,
        'banked', v_bank
    );
end;
$$;
grant execute on function public.buy_guild_item(text, uuid, uuid, int) to anon, authenticated;


-- ── buy_guild_front_item (public; cannot_buy_own guard removed) ──────────────
create or replace function public.buy_guild_front_item(
    p_device_hash text,
    p_listing_id  uuid,
    p_quantity    int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_buyer   uuid;
    v_balance bigint;
    v_listing public.guild_store_listings%rowtype;
    v_cost    bigint;
begin
    select id, token_balance into v_buyer, v_balance
    from public.accounts where device_hash = p_device_hash
    for update;
    if v_buyer is null then
        return json_build_object('error', 'account_not_found');
    end if;

    if p_quantity is null or p_quantity < 1 then
        return json_build_object('error', 'invalid_quantity');
    end if;

    select * into v_listing from public.guild_store_listings
    where id = p_listing_id for update;
    if not found then
        return json_build_object('error', 'listing_not_found');
    end if;
    if v_listing.status <> 'active' then
        return json_build_object('error', 'listing_not_active');
    end if;
    -- (cannot_buy_own guard removed — stock is guild-owned since migration 062)
    if v_listing.quantity_remaining < p_quantity then
        return json_build_object('error', 'insufficient_stock');
    end if;

    v_cost := v_listing.unit_price * p_quantity;
    if v_balance < v_cost then
        return json_build_object('error', 'insufficient_tokens');
    end if;

    update public.guild_store_listings
    set quantity_remaining = quantity_remaining - p_quantity,
        status = case when quantity_remaining - p_quantity <= 0 then 'sold_out' else status end
    where id = p_listing_id;

    update public.accounts set token_balance = token_balance - v_cost where id = v_buyer;
    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_buyer, -v_cost, 'guild_front_buy', p_listing_id);

    perform public._escrow_add(v_buyer, v_listing.item_key, p_quantity);

    perform public._distribute_guild_pool(v_listing.guild_id, v_cost, p_listing_id);

    return json_build_object(
        'ok', true,
        'quantity', p_quantity,
        'item_key', v_listing.item_key,
        'spent', v_cost,
        'new_balance', v_balance - v_cost,
        'guild_id', v_listing.guild_id
    );
end;
$$;
grant execute on function public.buy_guild_front_item(text, uuid, int) to anon, authenticated;
