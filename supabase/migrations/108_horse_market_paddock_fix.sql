-- ============================================================================
-- Migration 108: Horse market — listed horses can't be paddocked; hide
--                unbuyable listings
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 079 (guild paddock) + 085 (horse marketplace).
--
-- BUG: 085 made a LISTED horse unable to race, but deposit_to_paddock (079)
-- never checked for a listing. A seller could list a horse, then put it in
-- their guild paddock. The listing stayed on the market, but every buy was
-- refused (horse_in_paddock), so buyers saw the horse and could never get it.
--
-- FIX:
--   1. deposit_to_paddock rejects a horse with an active listing
--      ('horse_listed'). Unlist it first.
--   2. get_horse_market hides listings whose horse is tied up (in the paddock
--      or entered in an open/betting race) from BUYERS. The seller still sees
--      their own listing (flagged unavailable) so they can unlist it.
-- ============================================================================


-- ── 1. deposit_to_paddock (supersedes 079): block listed horses ─────────────
create or replace function public.deposit_to_paddock(
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
    v_guild   uuid;
    v_horse   public.horses%rowtype;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_guild := public._horse_guild_of(v_account);
    if v_guild is null then
        return json_build_object('error', 'not_horse_guild');
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

    -- Not while listed for sale (a listed horse must stay buyable).
    if exists (select 1 from public.horse_listings
               where horse_id = p_horse_id and status = 'active') then
        return json_build_object('error', 'horse_listed');
    end if;

    -- Not while entered in a non-resolved race.
    if exists (
        select 1 from public.race_entries e
        join public.races r on r.id = e.race_id
        where e.horse_id = p_horse_id and r.status in ('open', 'betting')
    ) then
        return json_build_object('error', 'horse_in_race');
    end if;

    if exists (select 1 from public.guild_paddock where horse_id = p_horse_id) then
        return json_build_object('error', 'already_paddocked');
    end if;

    insert into public.guild_paddock (guild_id, horse_id, owner_id)
    values (v_guild, p_horse_id, v_account);

    return json_build_object('ok', true, 'horse_id', p_horse_id);
end;
$$;
grant execute on function public.deposit_to_paddock(text, uuid) to anon, authenticated;


-- ── 2. get_horse_market (supersedes 085): hide unbuyable listings ───────────
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
        'listing_id',  x.id,
        'horse_id',    x.horse_id,
        'price',       x.price,
        'seller_id',   x.seller_id,
        'seller_name', x.seller_name,
        'mine',        x.mine,
        'unavailable', x.tie_up is not null,
        'unavailable_reason', x.tie_up,
        'name',        x.name,
        'breed',       x.breed,
        'speed',       x.speed,
        'endurance',   x.endurance,
        'life',        x.life,
        'life_cap',    x.life_cap,
        'wins',        x.wins,
        'races_run',   x.races_run,
        'created_at',  extract(epoch from x.created_at)
    ) order by x.created_at desc), '[]'::json)
    into v_items
    from (
        select l.id, l.horse_id, l.price, l.seller_id, l.created_at,
               a.username as seller_name,
               (l.seller_id = v_account) as mine,
               public._horse_tie_up_reason(l.horse_id) as tie_up,
               h.name, h.breed, h.speed, h.endurance, h.life, h.life_cap,
               h.wins, h.races_run
        from public.horse_listings l
        join public.horses h   on h.id = l.horse_id
        join public.accounts a on a.id = l.seller_id
        where l.status = 'active'
    ) x
    -- Buyers only see horses they can actually buy; sellers see their own.
    where x.mine or x.tie_up is null;

    return json_build_object('ok', true, 'balance', v_balance, 'listings', v_items);
end;
$$;
grant execute on function public.get_horse_market(text) to anon, authenticated;
