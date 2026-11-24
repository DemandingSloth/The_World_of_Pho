-- ============================================================================
-- Migration 053: Benjamins currency + Money Gun (server-authoritative accrual)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Benjamins are a NEW personal, UNTRADEABLE currency, printed over time by the
-- Money Gun (a one-per-save item bought from the market for 100,000,000,000
-- coins — the coin cost is deducted LOCALLY like the Tractor/Excavator; the
-- GUN'S OWNERSHIP + LEVEL + accrual clock live SERVER-SIDE so printing is
-- authoritative and can't be forged by a tampered client).
--
-- Server owns, on accounts:
--   benjamin_balance        bigint  — the player's Benjamin wallet
--   money_gun_owned         bool    — one per save
--   money_gun_level         int     — upgrade level 0..10 (raises print rate)
--   money_gun_last_claim_at timestamptz — accrual clock; accrued is computed
--                                         from (now - this) * rate(level)
--
-- Printing model (fully server-authoritative):
--   rate(level)  = 1 * 2^level  Benjamins / HOUR   (L0=1/h, L5=32/h, L10=1024/h)
--   cap(level)   = rate(level) * 48                (max unclaimed = 48h worth)
--   claim_benjamins(device_hash): server computes accrued = min(cap,
--     floor(rate(level) * hours_since_last_claim)), credits it, resets the
--     clock, writes a ledger row. The CLIENT sends NO amount — it cannot inflate
--     the print. (Chosen over client-trust because Benjamins are printed, not
--     spent-to-exist like shovels, so an unbounded client exploit would mint
--     spending power for guild cooldown rushes.)
--
-- benjamin_ledger mirrors token_ledger (append-only audit).
-- ============================================================================


-- ── accounts: new columns ────────────────────────────────────────────────────
alter table public.accounts
    add column if not exists benjamin_balance        bigint      not null default 0,
    add column if not exists money_gun_owned         boolean     not null default false,
    add column if not exists money_gun_level         int         not null default 0
        check (money_gun_level between 0 and 10),
    add column if not exists money_gun_last_claim_at  timestamptz;


-- ── benjamin_ledger (append-only audit, mirrors token_ledger) ────────────────
create table if not exists public.benjamin_ledger (
    id         uuid        primary key default gen_random_uuid(),
    account_id uuid        not null references public.accounts(id) on delete cascade,
    delta      bigint      not null,          -- +print / -spend
    reason     text        not null,          -- 'money_gun', 'rush', ...
    ref_id     uuid,                           -- optional reference (e.g. production id)
    created_at timestamptz not null default now()
);
alter table public.benjamin_ledger enable row level security;  -- no client policies


-- ── Tuning helpers (single source of truth; client mirrors for display) ──────

-- Benjamins printed PER HOUR at a given gun level: 1 * 2^level.
--   L0=1, L1=2, L2=4, ... L10=1024.
create or replace function public._money_gun_rate_per_hour(p_level int)
returns bigint
language sql
immutable
as $$
    select (1::bigint << greatest(least(coalesce(p_level, 0), 10), 0));
$$;

-- Max UNCLAIMED Benjamins the gun can hold at a given level = 48h of output.
create or replace function public._money_gun_cap(p_level int)
returns bigint
language sql
immutable
as $$
    select public._money_gun_rate_per_hour(p_level) * 48::bigint;
$$;


-- ── get_benjamin_balance ──────────────────────────────────────────────────────
-- Returns the wallet + gun state + the amount CURRENTLY accrued-but-unclaimed
-- (computed, not stored) so the client can show "ready to claim" without a claim.
--   { balance, owned, level, rate_per_hour, cap, accrued, last_claim_at }
create or replace function public.get_benjamin_balance(
    p_device_hash text
)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_acct   public.accounts%rowtype;
    v_rate   bigint;
    v_cap    bigint;
    v_hours  double precision;
    v_accrued bigint := 0;
begin
    select * into v_acct from public.accounts where device_hash = p_device_hash;
    if not found then
        return json_build_object('error', 'account_not_found');
    end if;

    v_rate := public._money_gun_rate_per_hour(v_acct.money_gun_level);
    v_cap  := public._money_gun_cap(v_acct.money_gun_level);

    if v_acct.money_gun_owned and v_acct.money_gun_last_claim_at is not null then
        v_hours := extract(epoch from (now() - v_acct.money_gun_last_claim_at)) / 3600.0;
        if v_hours < 0 then
            v_hours := 0;
        end if;
        v_accrued := least(v_cap, floor(v_rate::double precision * v_hours)::bigint);
    end if;

    return json_build_object(
        'balance',       v_acct.benjamin_balance,
        'owned',         v_acct.money_gun_owned,
        'level',         v_acct.money_gun_level,
        'rate_per_hour', v_rate,
        'cap',           v_cap,
        'accrued',       v_accrued,
        'last_claim_at', case when v_acct.money_gun_last_claim_at is null then null
                              else extract(epoch from v_acct.money_gun_last_claim_at) end
    );
end;
$$;
grant execute on function public.get_benjamin_balance(text) to anon, authenticated;


-- ── claim_benjamins ───────────────────────────────────────────────────────────
-- SERVER-AUTHORITATIVE. Computes accrued Benjamins from the stored gun level and
-- last-claim clock, credits the wallet, resets the clock, writes a ledger row.
-- The client sends NO amount. Returns { ok, claimed, balance } or { error }.
-- Claiming 0 (nothing accrued yet) is a no-op success (does NOT reset the clock,
-- so sub-hour fractions aren't lost to repeated taps).
create or replace function public.claim_benjamins(
    p_device_hash text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_acct    public.accounts%rowtype;
    v_rate    bigint;
    v_cap     bigint;
    v_hours   double precision;
    v_accrued bigint := 0;
begin
    -- Lock the account row so concurrent claims can't double-credit.
    select * into v_acct from public.accounts
    where device_hash = p_device_hash
    for update;
    if not found then
        return json_build_object('error', 'account_not_found');
    end if;

    if not v_acct.money_gun_owned then
        return json_build_object('error', 'no_money_gun');
    end if;

    -- First claim after purchase: establish the clock, nothing to pay yet.
    if v_acct.money_gun_last_claim_at is null then
        update public.accounts set money_gun_last_claim_at = now()
        where id = v_acct.id;
        return json_build_object('ok', true, 'claimed', 0, 'balance', v_acct.benjamin_balance);
    end if;

    v_rate := public._money_gun_rate_per_hour(v_acct.money_gun_level);
    v_cap  := public._money_gun_cap(v_acct.money_gun_level);

    v_hours := extract(epoch from (now() - v_acct.money_gun_last_claim_at)) / 3600.0;
    if v_hours < 0 then
        v_hours := 0;
    end if;
    v_accrued := least(v_cap, floor(v_rate::double precision * v_hours)::bigint);

    -- Nothing whole accrued yet: no-op, keep the clock so fractions aren't lost.
    if v_accrued <= 0 then
        return json_build_object('ok', true, 'claimed', 0, 'balance', v_acct.benjamin_balance);
    end if;

    update public.accounts
    set benjamin_balance = benjamin_balance + v_accrued,
        money_gun_last_claim_at = now()
    where id = v_acct.id;

    insert into public.benjamin_ledger (account_id, delta, reason)
    values (v_acct.id, v_accrued, 'money_gun');

    return json_build_object(
        'ok',      true,
        'claimed', v_accrued,
        'balance', v_acct.benjamin_balance + v_accrued
    );
end;
$$;
grant execute on function public.claim_benjamins(text) to anon, authenticated;


-- ── buy_money_gun ─────────────────────────────────────────────────────────────
-- Records server-side ownership of the Money Gun (one per save) and starts the
-- accrual clock. The 100B COIN COST is deducted LOCALLY by the client before
-- calling this (coins are a local currency); this RPC only flips server state.
-- Refused if already owned. Returns { ok, owned, level } or { error }.
create or replace function public.buy_money_gun(
    p_device_hash text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_acct public.accounts%rowtype;
begin
    select * into v_acct from public.accounts
    where device_hash = p_device_hash
    for update;
    if not found then
        return json_build_object('error', 'account_not_found');
    end if;
    if v_acct.money_gun_owned then
        return json_build_object('error', 'already_owned');
    end if;

    update public.accounts
    set money_gun_owned = true,
        money_gun_level = 0,
        money_gun_last_claim_at = now()
    where id = v_acct.id;

    return json_build_object('ok', true, 'owned', true, 'level', 0);
end;
$$;
grant execute on function public.buy_money_gun(text) to anon, authenticated;


-- ── upgrade_money_gun ─────────────────────────────────────────────────────────
-- Bumps the gun's level by 1 (max 10), raising the print rate. SETTLES any
-- accrued Benjamins at the OLD rate first (so an upgrade can't retroactively
-- inflate already-earned time), then raises the level and resets the clock.
-- The upgrade COST (coins or Benjamins — decided client-side in Task 7) is
-- handled by the caller; this RPC only advances server state. Returns
-- { ok, level, claimed, balance } or { error }.
create or replace function public.upgrade_money_gun(
    p_device_hash text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_acct    public.accounts%rowtype;
    v_rate    bigint;
    v_cap     bigint;
    v_hours   double precision;
    v_accrued bigint := 0;
begin
    select * into v_acct from public.accounts
    where device_hash = p_device_hash
    for update;
    if not found then
        return json_build_object('error', 'account_not_found');
    end if;
    if not v_acct.money_gun_owned then
        return json_build_object('error', 'no_money_gun');
    end if;
    if v_acct.money_gun_level >= 10 then
        return json_build_object('error', 'max_level');
    end if;

    -- Settle accrued Benjamins at the CURRENT (pre-upgrade) rate.
    if v_acct.money_gun_last_claim_at is not null then
        v_rate := public._money_gun_rate_per_hour(v_acct.money_gun_level);
        v_cap  := public._money_gun_cap(v_acct.money_gun_level);
        v_hours := extract(epoch from (now() - v_acct.money_gun_last_claim_at)) / 3600.0;
        if v_hours < 0 then
            v_hours := 0;
        end if;
        v_accrued := least(v_cap, floor(v_rate::double precision * v_hours)::bigint);
    end if;

    update public.accounts
    set benjamin_balance = benjamin_balance + v_accrued,
        money_gun_level  = money_gun_level + 1,
        money_gun_last_claim_at = now()
    where id = v_acct.id;

    if v_accrued > 0 then
        insert into public.benjamin_ledger (account_id, delta, reason)
        values (v_acct.id, v_accrued, 'money_gun');
    end if;

    return json_build_object(
        'ok',      true,
        'level',   v_acct.money_gun_level + 1,
        'claimed', v_accrued,
        'balance', v_acct.benjamin_balance + v_accrued
    );
end;
$$;
grant execute on function public.upgrade_money_gun(text) to anon, authenticated;
