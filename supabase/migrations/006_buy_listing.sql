-- ============================================================================
-- Marketplace Task 9: buy_listing — atomic purchase with limits + token moves
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- The single most safety-critical function. In ONE transaction it:
--   1. Locks the listing row (FOR UPDATE) to prevent concurrent overselling.
--   2. Validates: listing active, enough stock, buyer isn't the seller, buyer
--      has enough tokens, and the per-buyer daily limit isn't exceeded.
--   3. Decrements listing stock (marks sold_out at 0).
--   4. Debits buyer tokens, credits seller tokens.
--   5. Adds the item to the BUYER's escrow (claimed into local inventory later).
--   6. Records the purchase (also the price-history log) + token_ledger entries
--      + the daily counter.
-- All-or-nothing: any failure returns { error } and rolls back.
-- ============================================================================

-- purchases: one row per completed buy. Doubles as the price-history event log.
create table if not exists public.purchases (
    id          uuid        primary key default gen_random_uuid(),
    listing_id  uuid        not null references public.listings(id) on delete set null,
    buyer_id    uuid        not null references public.accounts(id) on delete cascade,
    seller_id   uuid        not null references public.accounts(id) on delete cascade,
    item_key    text        not null,
    unit_price  bigint      not null,
    quantity    int         not null,
    created_at  timestamptz not null default now()
);
create index if not exists purchases_item_time_idx on public.purchases (item_key, created_at);
alter table public.purchases enable row level security;  -- no client policies

-- daily_purchase_counters: enforces per-buyer, per-listing daily limits.
create table if not exists public.daily_purchase_counters (
    buyer_id   uuid   not null references public.accounts(id) on delete cascade,
    listing_id uuid   not null references public.listings(id) on delete cascade,
    day        date   not null default (now() at time zone 'utc')::date,
    qty_bought int    not null default 0,
    primary key (buyer_id, listing_id, day)
);
alter table public.daily_purchase_counters enable row level security;  -- no client policies

-- token_ledger: append-only audit of every token change (earn/spend).
create table if not exists public.token_ledger (
    id         uuid        primary key default gen_random_uuid(),
    account_id uuid        not null references public.accounts(id) on delete cascade,
    delta      bigint      not null,          -- +credit / -debit
    reason     text        not null,          -- 'buy', 'sell', 'mission', ...
    ref_id     uuid,                          -- e.g. purchase id
    created_at timestamptz not null default now()
);
alter table public.token_ledger enable row level security;  -- no client policies

-- ── buy_listing ──────────────────────────────────────────────────────────────
-- Returns json:
--   { ok, quantity, item_key, spent, new_balance } on success
--   { error: <code> } on failure
--     codes: account_not_found, listing_not_found, listing_not_active,
--            cannot_buy_own, invalid_quantity, insufficient_stock,
--            daily_limit_exceeded, insufficient_tokens
create or replace function public.buy_listing(
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
    v_buyer    uuid;
    v_balance  bigint;
    v_listing  public.listings%rowtype;
    v_today    date := (now() at time zone 'utc')::date;
    v_already  int;
    v_cost     bigint;
    v_purchase uuid;
begin
    -- Resolve buyer + lock their account row for the token update.
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
    select * into v_listing from public.listings
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

    -- Per-buyer daily limit (0 = unlimited).
    if v_listing.per_buyer_daily_limit > 0 then
        select coalesce(qty_bought, 0) into v_already
        from public.daily_purchase_counters
        where buyer_id = v_buyer and listing_id = p_listing_id and day = v_today;
        v_already := coalesce(v_already, 0);
        if v_already + p_quantity > v_listing.per_buyer_daily_limit then
            return json_build_object('error', 'daily_limit_exceeded');
        end if;
    end if;

    -- Cost + funds check.
    v_cost := v_listing.unit_price * p_quantity;
    if v_balance < v_cost then
        return json_build_object('error', 'insufficient_tokens');
    end if;

    -- ── Mutations (all within this transaction) ──────────────────────────────
    -- Decrement stock; mark sold_out when depleted.
    update public.listings
    set quantity_remaining = quantity_remaining - p_quantity,
        status = case when quantity_remaining - p_quantity <= 0 then 'sold_out' else status end
    where id = p_listing_id;

    -- Move tokens: debit buyer, credit seller.
    update public.accounts set token_balance = token_balance - v_cost where id = v_buyer;
    update public.accounts set token_balance = token_balance + v_cost where id = v_listing.seller_id;

    -- Item into buyer escrow.
    perform public._escrow_add(v_buyer, v_listing.item_key, p_quantity);

    -- Record purchase (price-history) + ledger + daily counter.
    insert into public.purchases (listing_id, buyer_id, seller_id, item_key, unit_price, quantity)
    values (p_listing_id, v_buyer, v_listing.seller_id, v_listing.item_key, v_listing.unit_price, p_quantity)
    returning id into v_purchase;

    -- Roll this sale into the daily price-history bucket (Task 12).
    perform public._record_price_point(v_listing.item_key, v_listing.unit_price, p_quantity);

    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_buyer, -v_cost, 'buy', v_purchase),
           (v_listing.seller_id, v_cost, 'sale', v_purchase);

    insert into public.daily_purchase_counters (buyer_id, listing_id, day, qty_bought)
    values (v_buyer, p_listing_id, v_today, p_quantity)
    on conflict (buyer_id, listing_id, day)
    do update set qty_bought = public.daily_purchase_counters.qty_bought + excluded.qty_bought;

    return json_build_object(
        'ok', true,
        'quantity', p_quantity,
        'item_key', v_listing.item_key,
        'spent', v_cost,
        'new_balance', v_balance - v_cost
    );
end;
$$;

grant execute on function public.buy_listing(text, uuid, int) to anon, authenticated;
