-- ============================================================================
-- Migration 077: Horse cups — tiers, top-3 coin prizes + mythical breed (Task 9)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 + 074 + 075 + 076 already applied.
--
-- Adds recurring CUP races (kind='cup') on top of the regular race lifecycle:
--
--   • Three tiers, gated by a horse's STAT-TOTAL (= current life+speed+endurance,
--     snapshotted at registration). A horse is LOCKED TO ITS HIGHEST eligible
--     tier — it may only enter the top cup it qualifies for, never a lower one:
--         tier 1  Little Cup  stat-total 125..229  1st prize 1,000,000 coins + unicorn
--         tier 2  Rodeo Cup   stat-total 230..349  1st prize 10,000,000 coins + centaur
--         tier 3  Derby Cup   stat-total >= 350     1st prize 100,000,000 coins + pegasus
--
--   • TOP-3 COIN PRIZES. The tier's number is the 1ST-PLACE prize; 2nd = 50%,
--     3rd = 25%. Only REAL player horses collect (NPC placings pay nothing).
--     COINS are a LOCAL currency (no coin column on accounts), so the prize is
--     RECORDED on the entry (race_entries.prize_coins) and the CLIENT credits it
--     exactly once on its next poll — same trust model as bet payouts.
--
--   • BREED PRIZE (winner only): a free mythical foal of the tier's breed, but
--     ONLY if the winner's stable has room. No room -> no foal (they still keep
--     the coin prize). NPC winners grant nothing.
--
--   • FIELD SIZE 5 for cups (vs 8 for regular). Empty lanes backfill with NPCs;
--     an all-NPC cup still runs autonomously. Full open->betting->resolved
--     lifecycle from 076 (odds, 3h betting window, seeded sim, 12h replay).
--
--   • SCHEDULE: the lazy advancer keeps ONE open cup of EACH tier available.
-- ============================================================================


-- ── Cup columns on races + prize record on entries ─────────────────────────────
alter table public.races
    add column if not exists tier        int,
    add column if not exists prize_breed text;

-- Coin prize won by this entry (top-3 cup placing). 0 = none. The client credits
-- it locally exactly once (tracked by applied bet/prize ids on the client).
alter table public.race_entries
    add column if not exists prize_coins bigint not null default 0;


-- ── Cup tier definitions (single source of truth) ──────────────────────────────
-- tier, min/max stat-total band (max null = open-ended), display name, prize
-- breed, and the 1ST-PLACE coin prize (2nd=50%, 3rd=25% derived at payout).
create or replace function public._race_cup_tiers()
returns table (
    tier int, min_total int, max_total int,
    name text, prize_breed text, first_prize bigint
)
language sql
immutable
as $$
    select t.tier, t.min_total, t.max_total, t.name, t.prize_breed, t.first_prize
    from (values
        (1, 125, 229,  'Little Cup', 'unicorn',   1000000::bigint),
        (2, 230, 349,  'Rodeo Cup',  'centaur',  10000000::bigint),
        (3, 350, null, 'Derby Cup',  'pegasus', 100000000::bigint)
    ) as t(tier, min_total, max_total, name, prize_breed, first_prize);
$$;

-- Cups run a smaller field than regular races.
create or replace function public._race_cup_field_size() returns int
language sql immutable as $$ select 5; $$;

-- The cup tier a given stat-total qualifies for = its HIGHEST eligible band, or
-- NULL if below the lowest cup. (Locks a strong horse out of lower cups.)
create or replace function public._race_cup_tier_for(p_total numeric)
returns int
language sql
immutable
as $$
    select max(tier) from public._race_cup_tiers()
    where p_total >= min_total;
$$;


-- ── Grant a mythical foal (winner only) — room-gated ────────────────────────────
-- Creates a horse of p_breed at base stats for p_account IF the active stable has
-- room; returns the new horse id, or NULL (unknown breed OR stable full). Caller
-- keeps the coin prize regardless.
create or replace function public._horse_grant_prize(
    p_account uuid,
    p_breed   text,
    p_label   text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_stats record;
    v_name  text;
    v_id    uuid;
    v_count int;
    v_cap   int;
begin
    select * into v_stats from public._horse_breed_stats(p_breed);
    if not found then
        return null;
    end if;

    -- Room check (active horses only; retired live in the pasture).
    select count(*) into v_count
    from public.horses where owner_id = p_account and status = 'active';
    v_cap := public._horse_stable_capacity(p_account);
    if v_count >= v_cap then
        return null;  -- no room: skip the foal, player still keeps coins
    end if;

    v_name := left(initcap(p_breed) || ' ' || coalesce(p_label, 'Champion'), 24);
    insert into public.horses (owner_id, name, breed, life, life_cap, speed, endurance)
    values (p_account, v_name, p_breed, v_stats.life, v_stats.life, v_stats.speed, v_stats.endurance)
    returning id into v_id;
    return v_id;
end;
$$;
revoke all on function public._horse_grant_prize(uuid, text, text) from anon, authenticated;


-- ── _horse_advance_races REWORKED: per-race field size + one open cup per tier ──
-- Supersedes 076's version. Lock/backfill now uses EACH RACE's own field_size
-- (so cups fill to 5, regular to 8). Step 4 tops up one open cup per tier.
create or replace function public._horse_advance_races()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_race     record;
    v_field    int;
    v_filled   int;
    v_lane     int;
    v_npc      record;
    v_open_cnt int;
    v_odds     record;
    v_tier     record;
    v_cup_cnt  int;
begin
    -- 1) LOCK: open races that FILLED (to their own field_size) or hit the 5h cap.
    for v_race in
        select r.* from public.races r
        where r.status = 'open'
          and ( (select count(*) from public.race_entries e where e.race_id = r.id) >= r.field_size
                or r.closes_at <= now() )
        for update
    loop
        v_field := v_race.field_size;
        select count(*) into v_filled from public.race_entries where race_id = v_race.id;
        v_lane := 0;
        while v_filled < v_field loop
            while exists (select 1 from public.race_entries
                          where race_id = v_race.id and lane = v_lane) loop
                v_lane := v_lane + 1;
            end loop;
            select * into v_npc from public._race_npc_entry_stats();
            insert into public.race_entries (
                race_id, lane, is_npc, horse_id, owner_id,
                display_name, breed, speed, endurance, life, life_cap
            ) values (
                v_race.id, v_lane, true, null, null,
                public._race_npc_name(), v_npc.breed, v_npc.speed, v_npc.endurance,
                v_npc.life, v_npc.life
            );
            v_filled := v_filled + 1;
            v_lane := v_lane + 1;
        end loop;

        update public.races
        set status = 'betting',
            seed = (floor(random() * 9223372036854775806) + 1)::bigint,
            fill_at = now(),
            bet_closes_at = now() + make_interval(hours => public._race_betting_hours())
        where id = v_race.id;

        for v_odds in select * from public._race_odds(v_race.id) loop
            update public.race_entries
            set odds = v_odds.odds
            where race_id = v_race.id and lane = v_odds.lane;
        end loop;
    end loop;

    -- 2) RESOLVE: betting races past their 3h window.
    for v_race in
        select id from public.races
        where status = 'betting' and bet_closes_at is not null and bet_closes_at <= now()
    loop
        perform public._horse_resolve_race(v_race.id);
    end loop;

    -- 3) Purge replays past 12h (keep the race row + placements + prizes).
    update public.races
    set results_json = null
    where status = 'resolved'
      and replay_expires_at is not null
      and replay_expires_at <= now()
      and results_json is not null;

    -- 4a) Keep the target number of open REGULAR races (field 8).
    select count(*) into v_open_cnt
    from public.races where status = 'open' and kind = 'regular';
    while v_open_cnt < public._race_open_target() loop
        insert into public.races (name, kind, field_size, opens_at, closes_at)
        values ('Daily Dash', 'regular', public._race_field_size(), now(),
                now() + make_interval(hours => public._race_open_cap_hours()));
        v_open_cnt := v_open_cnt + 1;
    end loop;

    -- 4b) Keep ONE open CUP of each tier available (field 5).
    for v_tier in select * from public._race_cup_tiers() loop
        select count(*) into v_cup_cnt
        from public.races
        where status = 'open' and kind = 'cup' and tier = v_tier.tier;
        if v_cup_cnt < 1 then
            insert into public.races (name, kind, tier, prize_breed, field_size, opens_at, closes_at)
            values (v_tier.name, 'cup', v_tier.tier, v_tier.prize_breed,
                    public._race_cup_field_size(), now(),
                    now() + make_interval(hours => public._race_open_cap_hours()));
        end if;
    end loop;
end;
$$;
revoke all on function public._horse_advance_races() from anon, authenticated;


-- ── _horse_resolve_race REWORKED: cup top-3 coin prizes + room-gated foal ───────
-- Supersedes 076's version. Same placements/records/bet-settlement, then for a
-- CUP: records top-3 coin prizes on real-horse entries (1st=first_prize,
-- 2nd=50%, 3rd=25%) and grants the 1st-place real winner a mythical foal if the
-- stable has room.
create or replace function public._horse_resolve_race(p_race_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_race    public.races%rowtype;
    v_sim     jsonb;
    v_order   jsonb;
    v_place   int;
    v_lane    int;
    v_winner_horse uuid;
    v_win_lane int;
    v_win_owner uuid;
    b         record;
    v_payout  bigint;
    v_has_tokens boolean;
    v_tier    record;
    v_first   bigint;
    e         record;
    v_prize   bigint;
begin
    select * into v_race from public.races where id = p_race_id for update;
    if not found or v_race.status <> 'betting' then
        return;
    end if;

    v_sim := public._race_run_sim(p_race_id);
    if v_sim is null then
        return;
    end if;
    v_order := v_sim->'order';

    v_place := 1;
    for v_lane in select (value::text)::int from jsonb_array_elements(v_order)
    loop
        update public.race_entries set finish_place = v_place
        where race_id = p_race_id and lane = v_lane;
        v_place := v_place + 1;
    end loop;

    -- Real-horse records. (Alias 're' avoids colliding with the 'e record'
    -- loop variable declared above — a bare 'e' would resolve to the unassigned
    -- record var and raise "record e is not assigned yet".)
    update public.horses h set races_run = races_run + 1
    from public.race_entries re
    where re.race_id = p_race_id and re.horse_id = h.id;

    select horse_id, owner_id into v_winner_horse, v_win_owner
    from public.race_entries
    where race_id = p_race_id and finish_place = 1 and horse_id is not null;
    if v_winner_horse is not null then
        update public.horses set wins = wins + 1 where id = v_winner_horse;
    end if;

    -- Winning lane (1st place).
    select lane into v_win_lane from public.race_entries
    where race_id = p_race_id and finish_place = 1;

    -- Does accounts have a tokens column? (credit server-side if so.)
    select exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'accounts' and column_name = 'tokens'
    ) into v_has_tokens;

    -- Settle bets.
    for b in select * from public.bets where race_id = p_race_id and not settled for update loop
        if b.lane = v_win_lane then
            v_payout := (b.stake::numeric * b.odds)::bigint;
            update public.bets set settled = true, won = true, payout = v_payout where id = b.id;
            if b.currency = 'tokens' and v_has_tokens then
                execute 'update public.accounts set tokens = coalesce(tokens,0) + $1 where id = $2'
                    using v_payout, b.account_id;
            end if;
        else
            update public.bets set settled = true, won = false, payout = 0 where id = b.id;
        end if;
    end loop;

    -- CUP rewards: top-3 coin prizes (real horses) + a room-gated foal for 1st.
    if v_race.kind = 'cup' and v_race.tier is not null then
        select * into v_tier from public._race_cup_tiers() where tier = v_race.tier;
        if found then
            v_first := v_tier.first_prize;
            -- 1st=100%, 2nd=50%, 3rd=25% of the tier's first prize. Real horses only.
            for e in
                select * from public.race_entries
                where race_id = p_race_id and horse_id is not null
                  and finish_place in (1, 2, 3)
            loop
                v_prize := case e.finish_place
                    when 1 then v_first
                    when 2 then (v_first / 2)
                    when 3 then (v_first / 4)
                    else 0 end;
                update public.race_entries set prize_coins = v_prize where id = e.id;
            end loop;

            -- Mythical foal for the 1st-place real winner (if stable has room).
            if v_win_owner is not null and v_race.prize_breed is not null then
                perform public._horse_grant_prize(v_win_owner, v_race.prize_breed, v_race.name);
            end if;
        end if;
    end if;

    update public.races
    set status = 'resolved',
        run_at = now(),
        replay_expires_at = now() + interval '12 hours',
        results_json = v_sim
    where id = p_race_id;
end;
$$;
revoke all on function public._horse_resolve_race(uuid) from anon, authenticated;


-- ── register_horse REWORKED: cup is locked to a horse's HIGHEST tier ────────────
-- Supersedes 076's version. For a cup race, the horse must qualify for EXACTLY
-- that tier (its highest eligible band). Entering a lower cup you over-qualify
-- for -> 'cup_tier_mismatch'; too weak for any cup / this one -> same guard with
-- the horse's own eligible tier echoed.
create or replace function public.register_horse(
    p_device_hash text,
    p_race_id     uuid,
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
    v_race    public.races%rowtype;
    v_count   int;
    v_lane    int := 0;
    v_entry   uuid;
    v_total   numeric;
    v_eligible int;
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

    select * into v_race from public.races where id = p_race_id for update;
    if not found then
        return json_build_object('error', 'race_not_found');
    end if;
    if v_race.status <> 'open' then
        return json_build_object('error', 'race_closed');  -- betting/resolved: locked
    end if;

    -- Cup gate: a horse is LOCKED to its highest eligible tier.
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
        v_horse.name, v_horse.breed, v_horse.speed, v_horse.endurance,
        v_horse.life, v_horse.life_cap
    ) returning id into v_entry;

    perform public._horse_advance_races();

    return json_build_object(
        'ok', true, 'race_id', p_race_id, 'lane', v_lane,
        'entry', json_build_object(
            'id', v_entry, 'lane', v_lane, 'is_npc', false,
            'horse_id', p_horse_id, 'display_name', v_horse.name, 'breed', v_horse.breed,
            'speed', v_horse.speed, 'endurance', v_horse.endurance,
            'life', v_horse.life, 'life_cap', v_horse.life_cap
        )
    );
end;
$$;
grant execute on function public.register_horse(text, uuid, uuid) to anon, authenticated;


-- ── get_races REWORKED: surface cup tier + band + prize breed + first prize ─────
-- Supersedes 076's version. Adds tier, prize_breed, the tier's stat-total band
-- (min/max) and the 1st-place coin prize, so the UI can show cup requirements +
-- rewards and grey out horses whose highest tier isn't this one.
create or replace function public.get_races(p_device_hash text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_races   json;
begin
    perform public._horse_advance_races();
    v_account := public._horse_resolve_account(p_device_hash);

    select coalesce(json_agg(rj order by rj_order), '[]'::json) into v_races
    from (
        select
            r.closes_at as rj_order,
            json_build_object(
                'id', r.id, 'name', r.name, 'kind', r.kind, 'status', r.status,
                'tier', r.tier, 'prize_breed', r.prize_breed,
                'min_total',   (select min_total   from public._race_cup_tiers() t where t.tier = r.tier),
                'max_total',   (select max_total   from public._race_cup_tiers() t where t.tier = r.tier),
                'first_prize', (select first_prize from public._race_cup_tiers() t where t.tier = r.tier),
                'field_size', r.field_size, 'opens_at', r.opens_at,
                'closes_at', r.closes_at, 'bet_closes_at', r.bet_closes_at,
                'mine_in_race', exists (
                    select 1 from public.race_entries e
                    where e.race_id = r.id and e.owner_id = v_account),
                'entries', coalesce((
                    select json_agg(json_build_object(
                        'lane', e.lane, 'is_npc', e.is_npc,
                        'display_name', e.display_name, 'breed', e.breed,
                        'speed', e.speed, 'endurance', e.endurance, 'life', e.life,
                        'odds', e.odds, 'horse_id', e.horse_id,
                        'mine', (e.owner_id is not null and e.owner_id = v_account)
                    ) order by e.lane)
                    from public.race_entries e where e.race_id = r.id
                ), '[]'::json)
            ) as rj
        from public.races r
        where r.status in ('open', 'betting')
    ) sub;

    return json_build_object('now', now(), 'races', v_races);
end;
$$;
grant execute on function public.get_races(text) to anon, authenticated;


-- ── get_my_cup_prizes: unclaimed cup coin prizes for the caller ─────────────────
-- Returns the caller's resolved cup entries that carry a coin prize, so the
-- CLIENT can credit them locally exactly once (tracked by entry id client-side).
--   { ok, prizes:[{ entry_id, race_id, race_name, tier, finish_place, prize_coins }] }
create or replace function public.get_my_cup_prizes(p_device_hash text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_prizes  json;
begin
    perform public._horse_advance_races();
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select coalesce(json_agg(json_build_object(
        'entry_id', e.id, 'race_id', r.id, 'race_name', r.name,
        'tier', r.tier, 'finish_place', e.finish_place, 'prize_coins', e.prize_coins
    ) order by r.run_at desc nulls last), '[]'::json)
    into v_prizes
    from public.race_entries e
    join public.races r on r.id = e.race_id
    where e.owner_id = v_account
      and e.prize_coins > 0
      and r.status = 'resolved';

    return json_build_object('ok', true, 'prizes', v_prizes);
end;
$$;
grant execute on function public.get_my_cup_prizes(text) to anon, authenticated;
