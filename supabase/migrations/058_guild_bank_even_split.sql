-- ============================================================================
-- Migration 058: Guild Bank + even-split sale proceeds
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Supersedes the proceeds model of migration 057. Instead of paying the seller,
-- guild-store sale proceeds are split EVENLY among ALL current guild members.
-- Any amount that does not divide evenly is held in a per-guild BANK until it
-- grows large enough to be distributed evenly, at which point the next sale (or
-- a manual distribute call) sweeps the divisible portion out to members.
--
-- DISTRIBUTION MATH (per sale): pot = sale_cost + bank_balance.
--   each        = floor(pot / member_count)           -- paid to every member
--   new_bank    = pot - each * member_count           -- sub-member remainder
-- Because the bank is folded back into the pot on every sale, accumulated
-- remainders are automatically released as soon as pot >= member_count. This is
-- the "held until it becomes evenly distributable" behaviour.
--
-- The seller is treated like any other member (they get their even share, not
-- the whole price). The buyer still pays full price and still receives the item
-- in escrow. Member set = active members (guild_members.left_at is null),
-- mirroring every other guild RPC. If member_count is 0 (shouldn't happen while
-- someone is buying), the whole pot is banked rather than lost.
--
-- Ledger reason for each member's share: 'guild_store_share'.
-- ============================================================================


-- ── Guild bank column ─────────────────────────────────────────────────────────
alter table public.guilds
    add column if not exists bank_balance bigint not null default 0;


-- ── _distribute_guild_pool ─────────────────────────────────────────────────────
-- Shared helper: given a guild and an amount to add to the pot (0 = just sweep
-- the existing bank), fold the bank into the pot, pay each active member an even
-- floor share, and leave the sub-member remainder in the bank. Returns the
-- amount actually distributed (each * member_count). Caller must already hold
-- any needed locks within its transaction.
create or replace function public._distribute_guild_pool(
    p_guild_id uuid,
    p_add      bigint,
    p_ref      uuid
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_bank    bigint;
    v_pot     bigint;
    v_members int;
    v_each    bigint;
    v_remain  bigint;
    v_distributed bigint := 0;
    r         record;
begin
    -- Lock the guild row so bank updates serialize with concurrent sales.
    select coalesce(bank_balance, 0) into v_bank
    from public.guilds where id = p_guild_id for update;
    if v_bank is null then
        return 0;   -- guild gone
    end if;

    v_pot := v_bank + coalesce(p_add, 0);

    select count(*) into v_members
    from public.guild_members
    where guild_id = p_guild_id and left_at is null;

    if v_members is null or v_members <= 0 then
        -- No one to pay: bank the whole pot.
        update public.guilds set bank_balance = v_pot where id = p_guild_id;
        return 0;
    end if;

    v_each   := v_pot / v_members;              -- integer floor division
    v_remain := v_pot - v_each * v_members;      -- stays in the bank

    if v_each > 0 then
        for r in
            select account_id
            from public.guild_members
            where guild_id = p_guild_id and left_at is null
        loop
            update public.accounts
            set token_balance = token_balance + v_each
            where id = r.account_id;

            insert into public.token_ledger (account_id, delta, reason, ref_id)
            values (r.account_id, v_each, 'guild_store_share', p_ref);
        end loop;
        v_distributed := v_each * v_members;
    end if;

    update public.guilds set bank_balance = v_remain where id = p_guild_id;
    return v_distributed;
end;
$$;
revoke all on function public._distribute_guild_pool(uuid, bigint, uuid) from anon, authenticated;


-- ── buy_guild_item (REWRITTEN: proceeds split evenly, remainder banked) ────────
-- Same guards as 057, but instead of crediting the seller the full price it
-- debits the buyer and distributes the price across all current members via
-- _distribute_guild_pool. Returns { ok, quantity, item_key, spent, new_balance,
-- shared, banked } | { error }.
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

    -- Lock the buyer's account row for the token debit.
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

    -- Debit buyer the full price.
    update public.accounts set token_balance = token_balance - v_cost where id = v_account;

    -- Buyer's own ledger line for the spend.
    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_account, -v_cost, 'guild_buy', p_listing_id);

    -- Item into buyer escrow.
    perform public._escrow_add(v_account, v_listing.item_key, p_quantity);

    -- Split proceeds evenly across all members; sub-member remainder -> bank.
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


-- ── get_guild_bank ─────────────────────────────────────────────────────────
-- Any active member reads the current banked (undistributed-remainder) balance.
-- Returns { bank_balance, member_count } | { error }.
create or replace function public.get_guild_bank(
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
    v_bank    bigint;
    v_members int;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    select coalesce(bank_balance, 0) into v_bank from public.guilds where id = p_guild_id;
    select count(*) into v_members
    from public.guild_members where guild_id = p_guild_id and left_at is null;

    return json_build_object('bank_balance', v_bank, 'member_count', coalesce(v_members, 0));
end;
$$;
grant execute on function public.get_guild_bank(text, uuid) to anon, authenticated;


-- ── distribute_guild_bank ──────────────────────────────────────────────────
-- Leader-triggered manual flush of the bank (e.g. before a member leaves).
-- Sweeps the evenly-divisible portion out to all members; sub-member remainder
-- stays banked. Returns { ok, distributed, bank_balance } | { error }.
--   errors: account_not_found, not_in_guild, not_leader
create or replace function public.distribute_guild_bank(
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
    v_leader  uuid;
    v_dist    bigint;
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

    select leader_id into v_leader from public.guilds where id = p_guild_id;
    if v_leader is distinct from v_account then
        return json_build_object('error', 'not_leader');
    end if;

    v_dist := public._distribute_guild_pool(p_guild_id, 0, null);
    select coalesce(bank_balance, 0) into v_bank from public.guilds where id = p_guild_id;

    return json_build_object('ok', true, 'distributed', v_dist, 'bank_balance', v_bank);
end;
$$;
grant execute on function public.distribute_guild_bank(text, uuid) to anon, authenticated;
