-- ============================================================================
-- Migration 065: Horse catalog + ownership (Horse Racing — Task 1)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- First slice of the horse-racing feature: the horses table + buy/sell/list
-- RPCs. The SERVER owns horse existence, stats, naming, and stable capacity.
-- COINS are a LOCAL currency (PlayerData.coins; there is no coin column on
-- accounts), so the client charges/credits coins locally AFTER the server
-- confirms the ownership change — mirroring the Money Gun purchase trust model.
--
-- Breeds (base stats; Life/Speed/Endurance):
--   Thoroughbred 80/10/6, Arabian 100/8/10, Standardbred 90/9/8   (purchasable)
--   Pegasus 90/10/6, Centaur 110/9/10, Unicorn 150/10/10          (cup prizes)
-- Caps: speed<=100, endurance<=100, life<=200. A horse tracks current `life`
-- and a `life_cap` (feed tops up to life_cap; raising life_cap is grooming /
-- pink-stone only — later tasks).
--
-- Pricing (coins, computed CLIENT-side; echoed by RPC for display/trust):
--   buy  = stat_total * 100000           (stat_total = life+speed+endurance)
--   sell = buy_price * stat_total / 10   (= stat_total^2 * 10000)
-- Stable base capacity = 5 active horses (horse-guild perk raises it — Task 10).
-- ============================================================================


-- ── horses ────────────────────────────────────────────────────────────────────
create table if not exists public.horses (
    id          uuid        primary key default gen_random_uuid(),
    owner_id    uuid        not null references public.accounts(id) on delete cascade,
    name        text        not null,
    breed       text        not null,
    life        int         not null check (life >= 0 and life <= 200),
    life_cap    int         not null check (life_cap >= 0 and life_cap <= 200),
    speed       int         not null check (speed >= 0 and speed <= 100),
    endurance   int         not null check (endurance >= 0 and endurance <= 100),
    status      text        not null default 'active' check (status in ('active', 'retired')),
    wins        int         not null default 0,
    races_run   int         not null default 0,
    created_at  timestamptz not null default now()
);
create index if not exists horses_owner_idx on public.horses (owner_id, status);
alter table public.horses enable row level security;  -- RPCs only


-- ── Breed stats (authoritative) ───────────────────────────────────────────────
-- Returns one row: (life, speed, endurance, purchasable). Unknown breed -> no row.
create or replace function public._horse_breed_stats(p_breed text)
returns table (life int, speed int, endurance int, purchasable boolean)
language sql
immutable
as $$
    select t.life, t.speed, t.endurance, t.purchasable from (values
        ('thoroughbred', 80,  10, 6,  true),
        ('arabian',      100, 8,  10, true),
        ('standardbred', 90,  9,  8,  true),
        ('pegasus',      90,  10, 6,  false),
        ('centaur',      110, 9,  10, false),
        ('unicorn',      150, 10, 10, false)
    ) as t(breed, life, speed, endurance, purchasable)
    where t.breed = p_breed;
$$;


-- ── Stable capacity ────────────────────────────────────────────────────────────
-- Base 5. The horse-guild 'stable_size' upgrade will raise this in Task 10; for
-- now it's a flat 5 so the function is a stable call site to extend later.
create or replace function public._horse_stable_capacity(p_account uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
    select 5;
$$;
revoke all on function public._horse_stable_capacity(uuid) from anon, authenticated;


-- ── Resolve a device_hash to an account id (local helper) ──────────────────────
create or replace function public._horse_resolve_account(p_device_hash text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
    select id from public.accounts where device_hash = p_device_hash limit 1;
$$;
revoke all on function public._horse_resolve_account(text) from anon, authenticated;


-- ── buy_horse ──────────────────────────────────────────────────────────────────
-- Creates a PURCHASABLE-breed horse at base stats owned by the caller, if the
-- stable has room. Coins are NOT touched here (local currency) — the RPC returns
-- `price` so the client can verify + deduct locally after this succeeds.
-- Returns { ok, horse:{...}, price } | { error }.
--   errors: account_not_found, invalid_breed, not_purchasable, stable_full,
--           invalid_name
create or replace function public.buy_horse(
    p_device_hash text,
    p_breed       text,
    p_name        text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_stats   record;
    v_name    text;
    v_count   int;
    v_cap     int;
    v_total   int;
    v_price   bigint;
    v_id      uuid;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select * into v_stats from public._horse_breed_stats(p_breed);
    if not found then
        return json_build_object('error', 'invalid_breed');
    end if;
    if not v_stats.purchasable then
        return json_build_object('error', 'not_purchasable');
    end if;

    -- Name: trimmed, 1..24 chars. (Client runs the full profanity filter; the
    -- server just guards length/non-empty so a bad client can't store junk.)
    v_name := btrim(coalesce(p_name, ''));
    if length(v_name) < 1 or length(v_name) > 24 then
        return json_build_object('error', 'invalid_name');
    end if;

    -- Stable room (active horses only; retired live in the pasture).
    select count(*) into v_count
    from public.horses where owner_id = v_account and status = 'active';
    v_cap := public._horse_stable_capacity(v_account);
    if v_count >= v_cap then
        return json_build_object('error', 'stable_full', 'capacity', v_cap);
    end if;

    v_total := v_stats.life + v_stats.speed + v_stats.endurance;
    v_price := v_total::bigint * 100000;

    insert into public.horses (owner_id, name, breed, life, life_cap, speed, endurance)
    values (v_account, v_name, p_breed, v_stats.life, v_stats.life, v_stats.speed, v_stats.endurance)
    returning id into v_id;

    return json_build_object(
        'ok', true,
        'price', v_price,
        'horse', json_build_object(
            'id', v_id, 'name', v_name, 'breed', p_breed,
            'life', v_stats.life, 'life_cap', v_stats.life,
            'speed', v_stats.speed, 'endurance', v_stats.endurance,
            'status', 'active', 'wins', 0, 'races_run', 0
        )
    );
end;
$$;
grant execute on function public.buy_horse(text, text, text) to anon, authenticated;


-- ── sell_horse ──────────────────────────────────────────────────────────────────
-- Sells one of the caller's horses back to the game for coins. Deletes the horse
-- and returns the coin `price` the client should credit locally. Works for both
-- active and retired horses. sell = (life+speed+endurance)^2 * 10000.
-- Returns { ok, price } | { error }.
--   errors: account_not_found, horse_not_found, not_your_horse
create or replace function public.sell_horse(
    p_device_hash text,
    p_horse_id    uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_horse   public.horses%rowtype;
    v_total   int;
    v_price   bigint;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select * into v_horse from public.horses where id = p_horse_id for update;
    if not found then
        return json_build_object('error', 'horse_not_found');
    end if;
    if v_horse.owner_id <> v_account then
        return json_build_object('error', 'not_your_horse');
    end if;

    v_total := v_horse.life + v_horse.speed + v_horse.endurance;
    -- base_price (stat_total*100000) * stat_total/10 = stat_total^2 * 10000.
    v_price := (v_total::bigint * v_total::bigint) * 10000;

    delete from public.horses where id = p_horse_id;

    return json_build_object('ok', true, 'price', v_price);
end;
$$;
grant execute on function public.sell_horse(text, uuid) to anon, authenticated;


-- ── get_horses ──────────────────────────────────────────────────────────────────
-- Returns all of the caller's horses (active + retired) + the stable capacity.
--   { capacity, horses:[{id,name,breed,life,life_cap,speed,endurance,status,wins,races_run}] }
create or replace function public.get_horses(p_device_hash text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_horses  json;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select coalesce(json_agg(json_build_object(
        'id',        h.id,
        'name',      h.name,
        'breed',     h.breed,
        'life',      h.life,
        'life_cap',  h.life_cap,
        'speed',     h.speed,
        'endurance', h.endurance,
        'status',    h.status,
        'wins',      h.wins,
        'races_run', h.races_run
    ) order by h.status, h.created_at), '[]'::json)
    into v_horses
    from public.horses h
    where h.owner_id = v_account;

    return json_build_object(
        'capacity', public._horse_stable_capacity(v_account),
        'horses',   v_horses
    );
end;
$$;
grant execute on function public.get_horses(text) to anon, authenticated;
