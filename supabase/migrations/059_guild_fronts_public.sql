-- ============================================================================
-- Migration 059: Public Guild Fronts (any player buys guild-listed jewelry)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Extends the guild store (057/058) into a PUBLIC storefront. Members still list
-- produced jewelry with list_guild_item (057) and manage it with
-- cancel_guild_listing (057); the bank + even-disperse model (058) is unchanged.
-- What this migration adds is the PUBLIC side:
--
--   get_guild_fronts(device_hash, limit, offset)
--       Browse ACTIVE guild-store listings across ALL guilds. ANY account may
--       call it (no guild membership required) — it's a public shop window.
--       Each row carries the guild name + seller name so the UI can group by
--       guild ("Guild Fronts").
--
--   buy_guild_front_item(device_hash, listing_id, quantity)
--       ANY account buys. The buyer's tokens are debited and the FULL proceeds
--       are routed to the LISTING'S GUILD BANK via _distribute_guild_pool (058),
--       which disperses evenly to that guild's members and holds the sub-member
--       remainder. The item lands in the BUYER's escrow. The only person who
--       cannot buy a listing is its own lister (cannot_buy_own).
--
-- WHY route to the bank (not the seller): per design, public sales fund the
-- whole guild, not the individual lister — the lister gets only their equal
-- member share back out of the bank disperse, exactly like internal sales.
-- ============================================================================


-- ── get_guild_fronts (public browse) ──────────────────────────────────────────
-- Returns { now, items:[{ id, guild_id, guild_name, seller_name, item_key,
--   unit_price, quantity_remaining, mine }] }. `mine` is true when the caller is
-- the lister (so the UI can show Cancel instead of Buy). No membership needed.
create or replace function public.get_guild_fronts(
    p_device_hash text,
    p_limit        int default 50,
    p_offset       int default 0
)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_limit   int := least(greatest(coalesce(p_limit, 50), 1), 200);
    v_offset  int := greatest(coalesce(p_offset, 0), 0);
    v_items   json;
begin
    -- Resolve the caller if they have an account (used only for the `mine` flag
    -- and the cannot_buy_own hint); browsing does NOT require an account.
    v_account := public._guild_resolve_account(p_device_hash);

    select coalesce(json_agg(json_build_object(
        'id',                 l.id,
        'guild_id',           l.guild_id,
        'guild_name',         g.name,
        'seller_name',        a.username,
        'item_key',           l.item_key,
        'unit_price',         l.unit_price,
        'quantity_remaining', l.quantity_remaining,
        'mine',               (v_account is not null and l.seller_id = v_account)
    ) order by g.name asc, l.created_at desc), '[]'::json)
    into v_items
    from (
        select l.*
        from public.guild_store_listings l
        where l.status = 'active'
        order by l.created_at desc
        limit v_limit offset v_offset
    ) l
    join public.guilds   g on g.id = l.guild_id
    join public.accounts a on a.id = l.seller_id;

    return json_build_object('now', extract(epoch from now()), 'items', v_items);
end;
$$;
grant execute on function public.get_guild_fronts(text, int, int) to anon, authenticated;


-- ── buy_guild_front_item (public buy; proceeds -> guild bank) ──────────────────
-- Any account buys from any guild's storefront. Debits the buyer, routes the
-- full price into the listing's guild bank (even-dispersed to that guild's
-- members), and escrows the item to the buyer.
-- Returns { ok, quantity, item_key, spent, new_balance, guild_id } | { error }.
--   errors: account_not_found, listing_not_found, listing_not_active,
--           cannot_buy_own, invalid_quantity, insufficient_stock,
--           insufficient_tokens
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
    -- Resolve + lock the buyer's account row for the token debit.
    select id, token_balance into v_buyer, v_balance
    from public.accounts where device_hash = p_device_hash
    for update;
    if v_buyer is null then
        return json_build_object('error', 'account_not_found');
    end if;

    if p_quantity is null or p_quantity < 1 then
        return json_build_object('error', 'invalid_quantity');
    end if;

    -- Lock the listing row to serialize concurrent buyers.
    select * into v_listing from public.guild_store_listings
    where id = p_listing_id for update;
    if not found then
        return json_build_object('error', 'listing_not_found');
    end if;
    if v_listing.status <> 'active' then
        return json_build_object('error', 'listing_not_active');
    end if;
    if v_listing.seller_id = v_buyer then
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

    -- Debit buyer; log their spend line.
    update public.accounts set token_balance = token_balance - v_cost where id = v_buyer;
    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_buyer, -v_cost, 'guild_front_buy', p_listing_id);

    -- Item into buyer escrow.
    perform public._escrow_add(v_buyer, v_listing.item_key, p_quantity);

    -- Full proceeds -> the listing's guild bank, even-dispersed to its members.
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
