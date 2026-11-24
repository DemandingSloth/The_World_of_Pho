-- ============================================================================
-- Migration 052: Dedicated Guild Stockpile (production input store)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- A NEW shared per-guild store, SEPARATE from the mission-fed warehouse/silo.
-- Its purpose is to be the raw-material INPUT for the future Guild Production
-- Facility (migration 054+). Members pool resources here; the leader manages it.
--
-- Access model:
--   * Any member may DEPOSIT into and VIEW the stockpile.
--   * Only the guild LEADER may lock withdrawals, reserve stock, or withdraw
--     (leader controls live in Task 2, appended to this same migration below).
--
-- Trust model (mirrors mission deposits, migration 042/049): the CLIENT removes
-- the deposited item from the player's local inventory first, then calls
-- deposit_to_stockpile, which only adds to the shared stock (capped). The server
-- holds no per-player inventory, so there is nothing to "spend" server-side on a
-- deposit — same model the game already uses for shovel/seed/mission spend.
--
-- Capacity: per item key, from the 'stockpile_capacity' guild upgrade track,
-- bought with upgrade points via the existing purchase_guild_upgrade (which
-- accepts any key and caps level at 10 — no RPC change needed, same as the
-- 'warehouse_capacity' track added in migration 048).
--   capacity = 50,000 + level * 45,000   (level 0 = 50,000; level 10 = 500,000)
-- ============================================================================


-- ── Table: guild_stockpile ───────────────────────────────────────────────────
-- One row per (guild, item_key). `amount` is the shared stock; `reserved` is the
-- portion the leader has earmarked (reserved stock cannot be withdrawn or spent
-- by anything until un-reserved — productions in Stage 3 will respect it too).
-- item_key is a canonical key ('resource:iron_ore', 'gem:diamond',
-- 'polished:emerald', 'crop:beans', 'fruit:plum').
create table if not exists public.guild_stockpile (
    guild_id   uuid   not null references public.guilds(id) on delete cascade,
    item_key   text   not null,
    amount     bigint not null default 0 check (amount   >= 0),
    reserved   bigint not null default 0 check (reserved >= 0),
    updated_at timestamptz not null default now(),
    primary key (guild_id, item_key),
    -- Reserved can never exceed the amount on hand.
    check (reserved <= amount)
);
alter table public.guild_stockpile enable row level security;
-- No client policies — RPCs only.


-- ── Lock flag on guilds ──────────────────────────────────────────────────────
-- When true, the leader has locked the stockpile: withdrawals are refused.
-- Deposits are always allowed (locking only blocks taking stock OUT).
alter table public.guilds
    add column if not exists stockpile_locked boolean not null default false;


-- ── Capacity helper ──────────────────────────────────────────────────────────
-- Per-item-key capacity from the 'stockpile_capacity' upgrade level.
--   50,000 + level * 45,000  -> level 0 = 50,000, level 10 (max) = 500,000.
create or replace function public._guild_stockpile_capacity(p_guild_id uuid)
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_level int := 0;
begin
    select coalesce(level, 0) into v_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'stockpile_capacity';
    return 50000::bigint + coalesce(v_level, 0)::bigint * 45000::bigint;
end;
$$;
revoke all on function public._guild_stockpile_capacity(uuid) from anon, authenticated;


-- ── Canonical item-key validation ────────────────────────────────────────────
-- Accepts only the stockpile-eligible categories (raw/intermediate goods and
-- gems). Produced jewelry ('item:') is NOT stockpilable — it is an OUTPUT, not
-- an input. Returns true for a well-formed key in an allowed category.
create or replace function public._guild_stockpile_key_ok(p_item_key text)
returns boolean
language plpgsql
immutable
security definer
set search_path = public
as $$
declare
    v_sep int;
    v_cat text;
    v_id  text;
begin
    if p_item_key is null then
        return false;
    end if;
    v_sep := position(':' in p_item_key);
    if v_sep <= 1 then                 -- no colon, or leading colon
        return false;
    end if;
    v_cat := substring(p_item_key from 1 for v_sep - 1);
    v_id  := substring(p_item_key from v_sep + 1);
    if length(v_id) = 0 then           -- trailing colon
        return false;
    end if;
    return v_cat in ('resource', 'gem', 'polished', 'crop', 'fruit');
end;
$$;
revoke all on function public._guild_stockpile_key_ok(text) from anon, authenticated;


-- ── deposit_to_stockpile ──────────────────────────────────────────────────────
-- Any active member may deposit. Adds p_amount of p_item_key to the guild's
-- shared stockpile, clamped to the per-key capacity. The CLIENT must have
-- already removed the items from the player's local inventory (trust model
-- above); on an error return the client refunds locally.
-- Returns { ok, deposited, amount, capacity } or { error }.
--   `deposited` = how much was actually stored (may be < p_amount if the cap was
--   hit); the client refunds (p_amount - deposited) locally.
create or replace function public.deposit_to_stockpile(
    p_device_hash text,
    p_guild_id    uuid,
    p_item_key    text,
    p_amount      int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account  uuid;
    v_member   public.guild_members%rowtype;
    v_cap      bigint;
    v_cur      bigint;
    v_space    bigint;
    v_store    bigint;
    v_new      bigint;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    if p_amount is null or p_amount <= 0 then
        return json_build_object('error', 'invalid_amount');
    end if;

    if not public._guild_stockpile_key_ok(p_item_key) then
        return json_build_object('error', 'invalid_item');
    end if;

    v_cap := public._guild_stockpile_capacity(p_guild_id);

    -- Lock the row (if any) so concurrent deposits don't both overshoot the cap.
    select coalesce(amount, 0) into v_cur
    from public.guild_stockpile
    where guild_id = p_guild_id and item_key = p_item_key
    for update;
    v_cur := coalesce(v_cur, 0);

    v_space := greatest(v_cap - v_cur, 0);
    if v_space <= 0 then
        return json_build_object('error', 'stockpile_full',
            'amount', v_cur, 'capacity', v_cap, 'deposited', 0);
    end if;

    v_store := least(p_amount::bigint, v_space);
    v_new   := v_cur + v_store;

    -- Clamp again inside the upsert so two concurrent FIRST deposits (no row to
    -- lock yet) can't push the total past the cap.
    insert into public.guild_stockpile (guild_id, item_key, amount, updated_at)
    values (p_guild_id, p_item_key, v_store, now())
    on conflict (guild_id, item_key)
    do update set amount = least(public.guild_stockpile.amount + v_store, v_cap),
                  updated_at = now();

    -- Re-read the authoritative stored total (post-clamp) for the response.
    select amount into v_new
    from public.guild_stockpile
    where guild_id = p_guild_id and item_key = p_item_key;

    return json_build_object(
        'ok',        true,
        'deposited', v_store,
        'amount',    v_new,
        'capacity',  v_cap
    );
end;
$$;
grant execute on function public.deposit_to_stockpile(text, uuid, text, int) to anon, authenticated;


-- ── get_guild_stockpile ───────────────────────────────────────────────────────
-- Any active member may view. Returns the full stockpile for the guild plus the
-- lock flag and per-key capacity.
--   { items: [{ item_key, amount, reserved }], locked, capacity }
create or replace function public.get_guild_stockpile(
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
    v_locked  boolean;
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
        'item_key', gs.item_key,
        'amount',   gs.amount,
        'reserved', gs.reserved
    ) order by gs.item_key), '[]'::json)
    into v_items
    from public.guild_stockpile gs
    where gs.guild_id = p_guild_id and gs.amount > 0;

    select coalesce(stockpile_locked, false) into v_locked
    from public.guilds where id = p_guild_id;

    return json_build_object(
        'items',    v_items,
        'locked',   coalesce(v_locked, false),
        'capacity', public._guild_stockpile_capacity(p_guild_id)
    );
end;
$$;
grant execute on function public.get_guild_stockpile(text, uuid) to anon, authenticated;


-- ============================================================================
-- Task 2: Leader management RPCs — lock, reserve, withdraw
-- ============================================================================
-- Only the guild LEADER (guilds.leader_id = caller's account) may:
--   * set_stockpile_lock    — flip the stockpile_locked flag
--   * reserve_stockpile      — earmark (or un-earmark) stock; reserved <= amount
--   * withdraw_from_stockpile — take stock OUT (escrowed back to the leader),
--     refused while locked, and never dipping into the reserved portion.
-- ============================================================================


-- Internal: resolve the caller and assert they are this guild's LEADER.
-- Returns the leader's account_id on success; raises a sentinel via the OUT
-- error string handled by each RPC. (Kept inline in each RPC for clear error
-- codes rather than exceptions.)


-- ── set_stockpile_lock ────────────────────────────────────────────────────────
-- Leader-only. Sets guilds.stockpile_locked. Returns { ok, locked } or { error }.
create or replace function public.set_stockpile_lock(
    p_device_hash text,
    p_guild_id    uuid,
    p_locked      boolean
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_leader  uuid;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select leader_id into v_leader from public.guilds where id = p_guild_id;
    if v_leader is null then
        return json_build_object('error', 'guild_not_found');
    end if;
    if v_leader <> v_account then
        return json_build_object('error', 'not_leader');
    end if;

    update public.guilds
    set stockpile_locked = coalesce(p_locked, false)
    where id = p_guild_id;

    return json_build_object('ok', true, 'locked', coalesce(p_locked, false));
end;
$$;
grant execute on function public.set_stockpile_lock(text, uuid, boolean) to anon, authenticated;


-- ── reserve_stockpile ─────────────────────────────────────────────────────────
-- Leader-only. Sets the ABSOLUTE reserved amount for an item key (not a delta),
-- clamped to [0, amount on hand]. Reserved stock is protected from withdrawal
-- (and, later, from production consumption). Returns { ok, item_key, reserved,
-- amount } or { error }.
create or replace function public.reserve_stockpile(
    p_device_hash text,
    p_guild_id    uuid,
    p_item_key    text,
    p_amount      int           -- desired absolute reserved amount
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account  uuid;
    v_leader   uuid;
    v_amount   bigint;
    v_reserve  bigint;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select leader_id into v_leader from public.guilds where id = p_guild_id;
    if v_leader is null then
        return json_build_object('error', 'guild_not_found');
    end if;
    if v_leader <> v_account then
        return json_build_object('error', 'not_leader');
    end if;

    if p_amount is null or p_amount < 0 then
        return json_build_object('error', 'invalid_amount');
    end if;

    -- Lock the row; the key must exist with some stock to reserve against.
    select amount into v_amount
    from public.guild_stockpile
    where guild_id = p_guild_id and item_key = p_item_key
    for update;

    if v_amount is null then
        return json_build_object('error', 'item_not_in_stockpile');
    end if;

    -- Clamp the requested reservation to what's actually on hand.
    v_reserve := least(p_amount::bigint, v_amount);

    update public.guild_stockpile
    set reserved = v_reserve, updated_at = now()
    where guild_id = p_guild_id and item_key = p_item_key;

    return json_build_object(
        'ok',       true,
        'item_key', p_item_key,
        'reserved', v_reserve,
        'amount',   v_amount
    );
end;
$$;
grant execute on function public.reserve_stockpile(text, uuid, text, int) to anon, authenticated;


-- ── withdraw_from_stockpile ────────────────────────────────────────────────────
-- Leader-only. Removes p_amount of p_item_key from the stockpile and escrows it
-- back to the LEADER (claimed into their local inventory next time they open the
-- online marketplace, same mechanism as mission-deposit refunds). Refused while
-- the stockpile is locked, and can never take from the RESERVED portion
-- (withdrawable = amount - reserved). Returns { ok, withdrawn, amount } or
-- { error }.
create or replace function public.withdraw_from_stockpile(
    p_device_hash text,
    p_guild_id    uuid,
    p_item_key    text,
    p_amount      int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account    uuid;
    v_leader     uuid;
    v_locked     boolean;
    v_amount     bigint;
    v_reserved   bigint;
    v_available  bigint;
    v_take       bigint;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select leader_id, coalesce(stockpile_locked, false)
      into v_leader, v_locked
    from public.guilds where id = p_guild_id;
    if v_leader is null then
        return json_build_object('error', 'guild_not_found');
    end if;
    if v_leader <> v_account then
        return json_build_object('error', 'not_leader');
    end if;

    if v_locked then
        return json_build_object('error', 'stockpile_locked');
    end if;

    if p_amount is null or p_amount <= 0 then
        return json_build_object('error', 'invalid_amount');
    end if;

    -- Lock the row.
    select amount, reserved
      into v_amount, v_reserved
    from public.guild_stockpile
    where guild_id = p_guild_id and item_key = p_item_key
    for update;

    if v_amount is null then
        return json_build_object('error', 'item_not_in_stockpile');
    end if;

    v_available := greatest(v_amount - coalesce(v_reserved, 0), 0);
    if v_available <= 0 then
        return json_build_object('error', 'nothing_available',
            'amount', v_amount, 'reserved', coalesce(v_reserved, 0));
    end if;

    v_take := least(p_amount::bigint, v_available);

    update public.guild_stockpile
    set amount = amount - v_take, updated_at = now()
    where guild_id = p_guild_id and item_key = p_item_key;

    -- Escrow the withdrawn stock back to the leader.
    perform public._escrow_add(v_account, p_item_key, v_take);

    return json_build_object(
        'ok',        true,
        'withdrawn', v_take,
        'amount',    v_amount - v_take
    );
end;
$$;
grant execute on function public.withdraw_from_stockpile(text, uuid, text, int) to anon, authenticated;
