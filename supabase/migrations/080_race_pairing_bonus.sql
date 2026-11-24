-- ============================================================================
-- Migration 080: Horse-guild PAIRING BONUS — guildmates in the same race (10d)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 077 (_horse_advance_races) + 078 (horse spec) already applied.
--
-- When TWO OR MORE members of the same HORSE-spec guild each have a real horse
-- entered in the SAME race, those horses race as a team: each paired entry gets
-- a small performance boost (+5% speed and +5% endurance, applied to the entry
-- SNAPSHOT at field-lock, clamped to the 100 ceilings). Because the odds helper
-- and the sim both read speed/endurance straight off race_entries, nudging the
-- snapshot is all that's needed — the boost flows into both the published odds
-- AND the race outcome with no change to _race_odds / _race_run_sim.
--
-- The boost is applied ONCE, at the moment a race locks from 'open' -> 'betting'
-- (right after NPC backfill, before odds are snapshotted). A boolean flag on the
-- entry records that it was boosted so the UI can show a "paired" badge.
-- ============================================================================


-- ── Flag column: this entry got the pairing boost ───────────────────────────────
alter table public.race_entries
    add column if not exists pairing_bonus boolean not null default false;


-- ── Pairing-bonus tuning ─────────────────────────────────────────────────────────
create or replace function public._race_pairing_bonus_pct() returns numeric
language sql immutable as $$ select 0.05; $$;   -- +5% speed & endurance


-- ── _race_apply_pairing_bonus: boost guildmate entries in one race ──────────────
-- For the given race, finds every HORSE-spec guild that has 2+ real entries, and
-- boosts each of those entries' snapshot speed/endurance by the pairing %, capped
-- at 100, flagging them. Idempotent-ish: only boosts entries not already flagged.
create or replace function public._race_apply_pairing_bonus(p_race_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_pct numeric := public._race_pairing_bonus_pct();
begin
    update public.race_entries e
    set speed         = least(100.0, round(e.speed     * (1.0 + v_pct), 2)),
        endurance     = least(100.0, round(e.endurance * (1.0 + v_pct), 2)),
        pairing_bonus = true
    where e.race_id = p_race_id
      and e.horse_id is not null
      and e.pairing_bonus = false
      and e.owner_id in (
          -- Account ids of real entrants whose horse guild has 2+ distinct real
          -- entrants in THIS race. First find those qualifying guild ids, then
          -- the entrants belonging to them.
          select gm.account_id
          from public.race_entries e3
          join public.guild_members gm
            on gm.account_id = e3.owner_id and gm.left_at is null
          where e3.race_id = p_race_id and e3.horse_id is not null
            and gm.guild_id in (
                select gm2.guild_id
                from public.race_entries e2
                join public.guild_members gm2
                  on gm2.account_id = e2.owner_id and gm2.left_at is null
                join public.guilds g on g.id = gm2.guild_id and g.specialization = 'horse'
                where e2.race_id = p_race_id and e2.horse_id is not null
                group by gm2.guild_id
                having count(distinct e2.owner_id) >= 2
            )
      );
end;
$$;
revoke all on function public._race_apply_pairing_bonus(uuid) from anon, authenticated;


-- ── _horse_advance_races REWORKED: apply the pairing bonus before odds ──────────
-- Supersedes 077's version. Identical EXCEPT: right after NPC backfill and before
-- the odds snapshot, call _race_apply_pairing_bonus so guildmate boosts are baked
-- into both the odds and the sim.
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

        -- PAIRING BONUS: boost guildmate entries BEFORE odds + sim read the snapshot.
        perform public._race_apply_pairing_bonus(v_race.id);

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

    for v_race in
        select id from public.races
        where status = 'betting' and bet_closes_at is not null and bet_closes_at <= now()
    loop
        perform public._horse_resolve_race(v_race.id);
    end loop;

    update public.races
    set results_json = null
    where status = 'resolved'
      and replay_expires_at is not null
      and replay_expires_at <= now()
      and results_json is not null;

    select count(*) into v_open_cnt
    from public.races where status = 'open' and kind = 'regular';
    while v_open_cnt < public._race_open_target() loop
        insert into public.races (name, kind, field_size, opens_at, closes_at)
        values ('Daily Dash', 'regular', public._race_field_size(), now(),
                now() + make_interval(hours => public._race_open_cap_hours()));
        v_open_cnt := v_open_cnt + 1;
    end loop;

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


-- ── get_races: surface the pairing_bonus flag per entry ─────────────────────────
-- Supersedes 077's get_races (adds 'pairing_bonus' to each entry object).
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
                        'pairing_bonus', e.pairing_bonus,
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
