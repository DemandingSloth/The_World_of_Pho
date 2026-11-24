-- ============================================================================
-- Migration 085: Horse marketplace — player-to-player horse sales (Task 12)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 (horses) + the accounts.token_balance currency + 082 (horseshoe
-- column) applied.
--
-- Players sell HORSES to each other for TOKENS (server currency). Unlike jewelry
-- (stackable item: keys sold via the guild store), each horse is a UNIQUE entity,
-- so a listing references a specific horse_id and a BUY transfers ownership
-- (horses.owner_id) rather than minting a copy.
--
-- Rules (a horse can only be in ONE place at a time):
--   • Only ACTIVE horses (retired horses stay retired — not listable).
--   • Not listable while entered in an open/betting race, or sitting in a guild
--     paddock. A LISTED horse likewise can't be raced (register_horse rejects it)
--     or paddocked.
--   • Buyer must have stable room (active-horse capacity) or the buy is refused.
--   • Mythical breeds are tradeable.
--   • Suggested price = coin buyback / 10 = stat_total*5000 tokens (client shows
--     this; the seller may set ANY price >= 1).
-- ============================================================================


-- ── horse_listings ──────────────────────────────────────────────────────────────
-- One active row per listed horse. The horse stays owned by the seller until a
-- buyer completes the purchase (ownership transfers then). status lifecycle:
--   active -> sold | cancelled.
create table if not exists public.horse_listings (
    id          uuid        primary key default gen_random_uuid(),
    horse_id    uuid        not null references public.horses(id)    on delete cascade,
    seller_id   uuid        not null references public.accounts(id)  on delete cascade,
    price       bigint      not null check (price > 0),              -- tokens
    status      text        not null default 'active'
                                 check (status in ('active', 'sold', 'cancelled')),
    buyer_id    uuid                 references public.accounts(id)  on delete set null,
    created_at  timestamptz not null default now(),
    sold_at     timestamptz
);
-- At most ONE active listing per horse.
create unique index if not exists horse_listings_one_active
    on public.horse_listings (horse_id) where status = 'active';
create index if not exists horse_listings_active_idx
    on public.horse_listings (status, created_at desc) where status = 'active';
alter table public.horse_listings enable row level security;  -- RPCs only


-- ── Suggested price helper (tokens) ─────────────────────────────────────────────
-- Coin buyback is stat_total*50000; the token suggestion is 1/10 of that.
create or replace function public._horse_listing_suggested_price(p_horse_id uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
    select greatest(1, (round(h.life + h.speed + h.endurance)::bigint * 5000))
    from public.horses h where h.id = p_horse_id;
$$;
revoke all on function public._horse_listing_suggested_price(uuid) from anon, authenticated;


-- ── Is a horse free to be listed/raced? (not racing, not paddocked) ─────────────
-- Returns a text reason if the horse is tied up, else null.
create or replace function public._horse_tie_up_reason(p_horse_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
    if exists (
        select 1 from public.race_entries e
        join public.races r on r.id = e.race_id
        where e.horse_id = p_horse_id and r.status in ('open', 'betting')
    ) then
        return 'horse_in_race';
    end if;
    -- guild_paddock exists from migration 079; guard in case of ordering.
    if to_regclass('public.guild_paddock') is not null then
        if exists (select 1 from public.guild_paddock where horse_id = p_horse_id) then
            return 'horse_in_paddock';
        end if;
    end if;
    return null;
end;
$$;
revoke all on function public._horse_tie_up_reason(uuid) from anon, authenticated;


-- ── list_horse ────────────────────────────────────────────────────────────────
-- Lists one of the caller's ACTIVE horses for sale at p_price tokens.
-- Returns { ok, listing_id, price } | { error }.
--   errors: account_not_found, horse_not_found, not_your_horse, horse_retired,
--           bad_price, already_listed, horse_in_race, horse_in_paddock
create or replace function public.list_horse(
    p_device_hash text,
    p_horse_id    uuid,
    p_price       bigint
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_horse   public.horses%rowtype;
    v_reason  text;
    v_id      uuid;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;
    if p_price is null or p_price < 1 then
        return json_build_object('error', 'bad_price');
    end if;

    select * into v_horse from public.horses where id = p_horse_id for update;
    if not found then
        return json_build_object('error', 'horse_not_found');
    end if;
    if v_horse.owner_id <> v_account then
        return json_build_object('error', 'not_your_horse');
    end if;
    if v_horse.status <> 'active' then
        return json_build_object('error', 'horse_retired');
    end if;

    if exists (select 1 from public.horse_listings
               where horse_id = p_horse_id and status = 'active') then
        return json_build_object('error', 'already_listed');
    end if;

    v_reason := public._horse_tie_up_reason(p_horse_id);
    if v_reason is not null then
        return json_build_object('error', v_reason);
    end if;

    insert into public.horse_listings (horse_id, seller_id, price)
    values (p_horse_id, v_account, p_price)
    returning id into v_id;

    return json_build_object('ok', true, 'listing_id', v_id, 'price', p_price);
end;
$$;
grant execute on function public.list_horse(text, uuid, bigint) to anon, authenticated;


-- ── cancel_horse_listing ────────────────────────────────────────────────────────
-- Delists the caller's own active listing (the horse was never transferred).
--   errors: account_not_found, listing_not_found, not_your_listing, listing_not_active
create or replace function public.cancel_horse_listing(
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
    v_listing public.horse_listings%rowtype;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select * into v_listing from public.horse_listings where id = p_listing_id for update;
    if not found then
        return json_build_object('error', 'listing_not_found');
    end if;
    if v_listing.seller_id <> v_account then
        return json_build_object('error', 'not_your_listing');
    end if;
    if v_listing.status <> 'active' then
        return json_build_object('error', 'listing_not_active');
    end if;

    update public.horse_listings set status = 'cancelled' where id = p_listing_id;
    return json_build_object('ok', true);
end;
$$;
grant execute on function public.cancel_horse_listing(text, uuid) to anon, authenticated;


-- ── buy_horse_listing ───────────────────────────────────────────────────────────
-- Buys a listed horse: debits buyer tokens, credits seller, transfers ownership
-- (clears the horseshoe equip — a new owner re-equips their own shoes), marks the
-- listing sold. Buyer needs stable room.
-- Returns { ok, horse_id, price, new_balance } | { error }.
--   errors: account_not_found, listing_not_found, listing_not_active,
--           cannot_buy_own, insufficient_tokens, stable_full, horse_gone,
--           horse_in_race, horse_in_paddock
create or replace function public.buy_horse_listing(
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
    v_listing public.horse_listings%rowtype;
    v_horse   public.horses%rowtype;
    v_balance bigint;
    v_count   int;
    v_cap     int;
    v_reason  text;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    -- Lock buyer balance.
    select token_balance into v_balance from public.accounts where id = v_account for update;

    -- Lock the listing.
    select * into v_listing from public.horse_listings where id = p_listing_id for update;
    if not found then
        return json_build_object('error', 'listing_not_found');
    end if;
    if v_listing.status <> 'active' then
        return json_build_object('error', 'listing_not_active');
    end if;
    if v_listing.seller_id = v_account then
        return json_build_object('error', 'cannot_buy_own');
    end if;

    -- Lock the horse; it must still exist + still belong to the seller + active.
    select * into v_horse from public.horses where id = v_listing.horse_id for update;
    if not found or v_horse.owner_id <> v_listing.seller_id or v_horse.status <> 'active' then
        update public.horse_listings set status = 'cancelled' where id = p_listing_id;
        return json_build_object('error', 'horse_gone');
    end if;

    -- Still untied (not racing / paddocked since listing).
    v_reason := public._horse_tie_up_reason(v_listing.horse_id);
    if v_reason is not null then
        return json_build_object('error', v_reason);
    end if;

    if v_balance < v_listing.price then
        return json_build_object('error', 'insufficient_tokens');
    end if;

    -- Buyer stable room (active horses).
    select count(*) into v_count
    from public.horses where owner_id = v_account and status = 'active';
    v_cap := public._horse_stable_capacity(v_account);
    if v_count >= v_cap then
        return json_build_object('error', 'stable_full', 'capacity', v_cap);
    end if;

    -- ── Mutations ────────────────────────────────────────────────────────────
    update public.accounts set token_balance = token_balance - v_listing.price where id = v_account;
    update public.accounts set token_balance = token_balance + v_listing.price where id = v_listing.seller_id;

    -- Transfer the horse; a new owner starts with no horseshoe equipped.
    update public.horses set owner_id = v_account, horseshoe = null
    where id = v_listing.horse_id;

    update public.horse_listings
    set status = 'sold', buyer_id = v_account, sold_at = now()
    where id = p_listing_id;

    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_account,          -v_listing.price, 'horse_buy',  p_listing_id),
           (v_listing.seller_id, v_listing.price, 'horse_sale', p_listing_id);

    return json_build_object(
        'ok', true,
        'horse_id', v_listing.horse_id,
        'price', v_listing.price,
        'new_balance', v_balance - v_listing.price
    );
end;
$$;
grant execute on function public.buy_horse_listing(text, uuid) to anon, authenticated;


-- ── get_horse_market ────────────────────────────────────────────────────────────
-- Browse active horse listings (newest first), with each horse's stats + whether
-- it's the caller's own. Also returns the caller's token balance for the UI.
--   { ok, balance, listings:[{ listing_id, horse_id, price, seller_id,
--       seller_name, mine, name, breed, speed, endurance, life, life_cap,
--       wins, races_run, created_at }] }
create or replace function public.get_horse_market(p_device_hash text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_balance bigint := 0;
    v_items   json;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    select coalesce(token_balance, 0) into v_balance from public.accounts where id = v_account;

    select coalesce(json_agg(json_build_object(
        'listing_id',  l.id,
        'horse_id',    l.horse_id,
        'price',       l.price,
        'seller_id',   l.seller_id,
        'seller_name', a.username,
        'mine',        (l.seller_id = v_account),
        'name',        h.name,
        'breed',       h.breed,
        'speed',       h.speed,
        'endurance',   h.endurance,
        'life',        h.life,
        'life_cap',    h.life_cap,
        'wins',        h.wins,
        'races_run',   h.races_run,
        'created_at',  extract(epoch from l.created_at)
    ) order by l.created_at desc), '[]'::json)
    into v_items
    from public.horse_listings l
    join public.horses h   on h.id = l.horse_id
    join public.accounts a on a.id = l.seller_id
    where l.status = 'active';

    return json_build_object('ok', true, 'balance', v_balance, 'listings', v_items);
end;
$$;
grant execute on function public.get_horse_market(text) to anon, authenticated;


-- ── register_horse: reject a horse that's actively LISTED for sale ──────────────
-- Supersedes 083's version. Identical EXCEPT it also rejects a horse that has an
-- active marketplace listing (mutual exclusion: a listed horse can't be raced,
-- just as a racing horse can't be listed). Error 'horse_listed'.
create or replace function public.register_horse(
    p_device_hash     text,
    p_race_id         uuid,
    p_horse_id        uuid,
    p_horseshoe_level int default 0,
    p_emerald_level   int default 0,
    p_pink_level      int default 0
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account   uuid;
    v_horse     public.horses%rowtype;
    v_race      public.races%rowtype;
    v_count     int;
    v_lane      int := 0;
    v_entry     uuid;
    v_total     numeric;
    v_eligible  int;
    v_hs_pct    numeric := 0.0;
    v_em_pct    numeric := 0.0;
    v_pk_pct    numeric := 0.0;
    v_speed     numeric;
    v_endurance numeric;
    v_life      numeric;
    v_life_cap  numeric;
begin
    perform public._horse_advance_races();

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
    if v_horse.status <> 'active' then
        return json_build_object('error', 'horse_retired');
    end if;

    -- A horse listed for sale can't also be raced.
    if exists (select 1 from public.horse_listings
               where horse_id = p_horse_id and status = 'active') then
        return json_build_object('error', 'horse_listed');
    end if;

    select * into v_race from public.races where id = p_race_id for update;
    if not found then
        return json_build_object('error', 'race_not_found');
    end if;
    if v_race.status <> 'open' then
        return json_build_object('error', 'race_closed');
    end if;

    v_speed     := v_horse.speed;
    v_endurance := v_horse.endurance;
    v_life      := v_horse.life;
    v_life_cap  := v_horse.life_cap;

    if coalesce(p_emerald_level, 0) > 0 then
        v_em_pct := public._horse_jewelry_bonus_pct(p_emerald_level);
        v_speed     := round(v_speed     * (1.0 + v_em_pct), 2);
        v_endurance := round(v_endurance * (1.0 + v_em_pct), 2);
        v_life      := round(v_life      * (1.0 + v_em_pct), 2);
    end if;

    if coalesce(p_pink_level, 0) > 0 then
        v_pk_pct := public._horse_jewelry_bonus_pct(p_pink_level);
        v_life_cap := round(v_life_cap * (1.0 + v_pk_pct), 2);
    end if;

    if v_horse.horseshoe is not null and coalesce(p_horseshoe_level, 0) > 0 then
        v_hs_pct := public._horse_horseshoe_bonus_pct(p_horseshoe_level);
        if v_horse.horseshoe = 'copper' then
            v_speed := round(v_speed * (1.0 + v_hs_pct), 2);
        elsif v_horse.horseshoe = 'iron' then
            v_endurance := round(v_endurance * (1.0 + v_hs_pct), 2);
        end if;
    end if;

    v_speed     := least(100.0, v_speed);
    v_endurance := least(100.0, v_endurance);
    v_life_cap  := least(200.0, v_life_cap);
    v_life      := least(v_life, v_life_cap);

    if v_race.kind = 'cup' and v_race.tier is not null then
        v_total := v_horse.life + v_horse.speed + v_horse.endurance;
        v_eligible := public._race_cup_tier_for(v_total);
        if v_eligible is null or v_eligible <> v_race.tier then
            return json_build_object(
                'error', 'cup_tier_mismatch',
                'race_tier', v_race.tier,
                'eligible_tier', v_eligible,
                'stat_total', v_total
            );
        end if;
    end if;

    select count(*) into v_count from public.race_entries where race_id = p_race_id;
    if v_count >= v_race.field_size then
        return json_build_object('error', 'race_full');
    end if;

    if exists (select 1 from public.race_entries
               where race_id = p_race_id and horse_id = p_horse_id) then
        return json_build_object('error', 'already_entered');
    end if;

    if exists (
        select 1 from public.race_entries e
        join public.races r on r.id = e.race_id
        where e.horse_id = p_horse_id and r.status in ('open', 'betting')
    ) then
        return json_build_object('error', 'horse_in_race');
    end if;

    while exists (select 1 from public.race_entries
                  where race_id = p_race_id and lane = v_lane) loop
        v_lane := v_lane + 1;
    end loop;

    insert into public.race_entries (
        race_id, lane, is_npc, horse_id, owner_id,
        display_name, breed, speed, endurance, life, life_cap
    ) values (
        p_race_id, v_lane, false, p_horse_id, v_account,
        v_horse.name, v_horse.breed, v_speed, v_endurance, v_life, v_life_cap
    ) returning id into v_entry;

    perform public._horse_advance_races();

    return json_build_object(
        'ok', true, 'race_id', p_race_id, 'lane', v_lane,
        'entry', json_build_object(
            'id', v_entry, 'lane', v_lane, 'is_npc', false,
            'horse_id', p_horse_id, 'display_name', v_horse.name, 'breed', v_horse.breed,
            'speed', v_speed, 'endurance', v_endurance,
            'life', v_life, 'life_cap', v_life_cap,
            'horseshoe', coalesce(v_horse.horseshoe, '')
        )
    );
end;
$$;
grant execute on function public.register_horse(text, uuid, uuid, int, int, int) to anon, authenticated;
