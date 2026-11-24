-- ============================================================================
-- Migration 075: Seeded race simulation + resolution + replay (Task 6)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 + 074 already applied.
--
-- Takes a `closed` race to `resolved`: a DETERMINISTIC, stats-weighted lap sim
-- driven purely by races.seed, so the same race always plays out identically.
-- The exact per-segment positions are STORED as a replay (races.results_json),
-- kept for 12 hours after the race runs, then purged — so a watch within that
-- window is byte-for-byte the same race every time.
--
-- Sim model (per entry, SEGMENTS=6 laps):
--   • pace from SPEED (base per-segment distance).
--   • ENDURANCE resists late-race decay — BUT even at 100 endurance there is a
--     1-in-100 roll per segment to decay anyway (no horse is immune).
--   • LIFE condition multiplier: full life = no penalty; below 50% life applies
--     a penalty, below 25% stacks another — tired horses race worse, so feeding
--     before a race matters.
--   • seeded jitter per (seed, lane, segment) for upsets.
-- Finishing order = total distance -> finish_place 1..field_size.
--
-- Resolution also bumps horses.races_run (all real entrants) + horses.wins (the
-- real 1st-placer). Betting payouts are Task 7; cup prizes Task 9.
-- ============================================================================


-- ── Replay columns on races ─────────────────────────────────────────────────────
alter table public.races
    add column if not exists run_at            timestamptz,   -- when the sim ran
    add column if not exists replay_expires_at timestamptz,   -- run_at + 12h
    add column if not exists results_json      jsonb;         -- the stored replay

-- ── Snapshot life_cap on entries (needed for the life-fraction condition) ───────
-- 074 only snapshotted `life`; the condition multiplier needs the fraction
-- life/life_cap. Default existing rows to 100 (a sane band for the old NPCs).
alter table public.race_entries
    add column if not exists life_cap numeric(5,2) not null default 100;


-- ── Deterministic PRNG (pure function of seed + stream) ─────────────────────────
-- Uses the built-in stable hash `hashtextextended(text, seed)`: given the race
-- seed and an integer `stream` (built from lane*1000 + segment*7 + channel),
-- returns a reproducible float in [0,1). Identical inputs always give identical
-- output, and there's no bigint-overflow risk (the hash is computed internally).
create or replace function public._race_rng(p_seed bigint, p_stream bigint)
returns double precision
language sql
immutable
as $$
    -- hashtextextended returns a signed bigint; abs + mod maps it to [0,1).
    select (abs(hashtextextended(p_stream::text, p_seed)) % 1000000000)::double precision
           / 1000000000.0;
$$;


-- ── Life condition multiplier ───────────────────────────────────────────────────
-- Scales a stat by how healthy the horse is. 1.0 at/above 50% life, degrading
-- below 50% and again below 25%. Floors at 0.4 so a near-dead horse still moves.
--   life_frac = life / greatest(life_cap, 1)
--   >=0.50 -> 1.00 ;  0.25..0.50 -> 0.85 ;  <0.25 -> 0.65 (then scaled by frac)
create or replace function public._race_condition_mult(p_life numeric, p_life_cap numeric)
returns numeric
language sql
immutable
as $$
    select case
        when coalesce(p_life_cap, 0) <= 0 then 0.65
        when (p_life / p_life_cap) >= 0.50 then 1.00
        when (p_life / p_life_cap) >= 0.25 then 0.85
        else greatest(0.65, 0.40 + (p_life / p_life_cap))  -- very low life bites hard
    end;
$$;


-- ── SEGMENTS: how many laps the sim ticks ───────────────────────────────────────
create or replace function public._race_segments() returns int
language sql immutable as $$ select 6; $$;


-- ── _race_run_sim: pure deterministic sim for one race ──────────────────────────
-- Reads the race's entries + seed, simulates SEGMENTS laps, and returns a jsonb:
--   { segments, lanes:[{ lane, display_name, breed, is_npc, horse_id, mine? (no),
--                        total, samples:[cumulative distance after each seg] }],
--     order:[lane,...] }  (order = finish order, best first)
-- Does NOT write anything. Caller persists finish_place + results_json.
create or replace function public._race_run_sim(p_race_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_seed    bigint;
    v_segs    int := public._race_segments();
    e         record;
    s         int;
    v_cond    numeric;
    v_pace    numeric;
    v_decay   numeric;
    v_jit     double precision;
    v_decroll double precision;
    v_cum     numeric;
    v_samples jsonb;
    v_lanes   jsonb := '[]'::jsonb;
    v_order   int[];
    v_life_frac numeric;
begin
    select seed into v_seed from public.races where id = p_race_id;
    if v_seed is null then
        return null;  -- not closed / no seed yet
    end if;

    for e in
        select * from public.race_entries where race_id = p_race_id order by lane
    loop
        v_cond := public._race_condition_mult(e.life, e.life_cap);
        v_cum  := 0;
        v_samples := '[]'::jsonb;

        for s in 0 .. (v_segs - 1) loop
            -- Base pace from speed (scaled), tuned so a mid horse covers ~1/seg.
            v_pace := (5.0 + e.speed) * v_cond;

            -- Late-race decay: segments past the midpoint can sap pace unless
            -- endurance holds. Decay chance drops with endurance, but even at
            -- 100 endurance there's a 1-in-100 floor.
            v_decay := 1.0;
            if s >= (v_segs / 2) then
                v_decroll := public._race_rng(v_seed, e.lane * 1000 + s * 7 + 1);
                -- chance to decay = max(0.01, 1 - endurance/100)
                if v_decroll < greatest(0.01, 1.0 - (e.endurance / 100.0)) then
                    v_decay := 0.80;  -- a tired stride this segment
                end if;
            end if;

            -- Seeded jitter +-15% for upsets.
            v_jit := 0.85 + public._race_rng(v_seed, e.lane * 1000 + s * 7 + 2) * 0.30;

            v_cum := round(v_cum + v_pace * v_decay * v_jit::numeric, 3);
            v_samples := v_samples || to_jsonb(v_cum);
        end loop;

        v_lanes := v_lanes || jsonb_build_object(
            'lane', e.lane,
            'display_name', e.display_name,
            'breed', e.breed,
            'is_npc', e.is_npc,
            'horse_id', e.horse_id,
            'total', v_cum,
            'samples', v_samples
        );
    end loop;

    -- Finish order: lanes by descending total distance (ties broken by lane).
    select array_agg((l->>'lane')::int order by (l->>'total')::numeric desc, (l->>'lane')::int)
    into v_order
    from jsonb_array_elements(v_lanes) l;

    return jsonb_build_object('segments', v_segs, 'lanes', v_lanes, 'order', v_order);
end;
$$;
revoke all on function public._race_run_sim(uuid) from anon, authenticated;


-- ── _horse_resolve_race: run the sim, persist placements + replay ───────────────
-- Idempotent-ish: only resolves a race in `closed` status. Writes finish_place
-- on every entry, bumps horse records, stores results_json + a 12h replay TTL,
-- and flips the race to `resolved`.
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
begin
    select * into v_race from public.races where id = p_race_id for update;
    if not found or v_race.status <> 'closed' then
        return;
    end if;

    v_sim := public._race_run_sim(p_race_id);
    if v_sim is null then
        return;
    end if;
    v_order := v_sim->'order';

    -- Assign finish_place 1..N from the finish order.
    v_place := 1;
    for v_lane in select (value::text)::int from jsonb_array_elements(v_order)
    loop
        update public.race_entries
        set finish_place = v_place
        where race_id = p_race_id and lane = v_lane;
        v_place := v_place + 1;
    end loop;

    -- Real-horse records: every real entrant +1 race; the real 1st-placer +1 win.
    update public.horses h
    set races_run = races_run + 1
    from public.race_entries e
    where e.race_id = p_race_id and e.horse_id = h.id;

    select horse_id into v_winner_horse
    from public.race_entries
    where race_id = p_race_id and finish_place = 1 and horse_id is not null;
    if v_winner_horse is not null then
        update public.horses set wins = wins + 1 where id = v_winner_horse;
    end if;

    -- Persist the replay + mark resolved. Replay kept 12h, then purged.
    update public.races
    set status = 'resolved',
        run_at = now(),
        replay_expires_at = now() + interval '12 hours',
        results_json = v_sim
    where id = p_race_id;
end;
$$;
revoke all on function public._horse_resolve_race(uuid) from anon, authenticated;


-- ── Extend the lazy scheduler: resolve closed races + purge old replays ─────────
-- Supersedes migration 074's _horse_advance_races. Same close/backfill/open-keep
-- logic, PLUS: resolve every `closed` race (immediately after close, so the
-- result is ready to watch), and clear results_json on resolved races whose 12h
-- replay window has elapsed.
create or replace function public._horse_advance_races()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_race     record;
    v_field    int := public._race_field_size();
    v_filled   int;
    v_lane     int;
    v_npc      record;
    v_open_cnt int;
    v_mins     int := public._race_registration_minutes();
begin
    -- 1) Close any open race whose registration window has elapsed.
    for v_race in
        select * from public.races
        where status = 'open' and closes_at <= now()
        for update
    loop
        select count(*) into v_filled from public.race_entries where race_id = v_race.id;
        v_lane := 0;
        while v_filled < v_field loop
            while exists (select 1 from public.race_entries
                          where race_id = v_race.id and lane = v_lane) loop
                v_lane := v_lane + 1;
            end loop;
            select * into v_npc from public._race_npc_entry_stats();
            -- NPCs race at full condition: life_cap = life (no life penalty).
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
        set status = 'closed',
            seed = (floor(random() * 9223372036854775806) + 1)::bigint
        where id = v_race.id;
    end loop;

    -- 2) Resolve every closed race (runs the deterministic sim + stores replay).
    for v_race in
        select id from public.races where status = 'closed'
    loop
        perform public._horse_resolve_race(v_race.id);
    end loop;

    -- 3) Purge replays past their 12h window (keep the race row + placements).
    update public.races
    set results_json = null
    where status = 'resolved'
      and replay_expires_at is not null
      and replay_expires_at <= now()
      and results_json is not null;

    -- 4) Ensure the schedule always has the target number of open races.
    select count(*) into v_open_cnt from public.races where status = 'open';
    while v_open_cnt < public._race_open_target() loop
        insert into public.races (name, kind, field_size, opens_at, closes_at)
        values ('Daily Dash', 'regular', v_field, now(),
                now() + make_interval(mins => v_mins));
        v_open_cnt := v_open_cnt + 1;
    end loop;
end;
$$;
revoke all on function public._horse_advance_races() from anon, authenticated;


-- ── get_race_result: the stored replay + placements for one race ────────────────
-- Advances the schedule first (so a just-closed race is resolved). Returns the
-- replay if still within the 12h window, plus the final placements either way.
--   { ok, status, has_replay, replay:{segments,lanes,order}|null, run_at,
--     placements:[{lane,finish_place,display_name,breed,is_npc,horse_id,mine}] }
--   errors: race_not_found, not_resolved
create or replace function public.get_race_result(
    p_device_hash text,
    p_race_id     uuid
)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_race    public.races%rowtype;
    v_places  json;
begin
    perform public._horse_advance_races();
    v_account := public._horse_resolve_account(p_device_hash);

    select * into v_race from public.races where id = p_race_id;
    if not found then
        return json_build_object('error', 'race_not_found');
    end if;
    if v_race.status <> 'resolved' then
        return json_build_object('error', 'not_resolved', 'status', v_race.status);
    end if;

    select coalesce(json_agg(json_build_object(
        'lane', e.lane,
        'finish_place', e.finish_place,
        'display_name', e.display_name,
        'breed', e.breed,
        'is_npc', e.is_npc,
        'horse_id', e.horse_id,
        'mine', (e.owner_id is not null and e.owner_id = v_account)
    ) order by e.finish_place), '[]'::json)
    into v_places
    from public.race_entries e where e.race_id = p_race_id;

    return json_build_object(
        'ok', true,
        'status', v_race.status,
        'run_at', v_race.run_at,
        'has_replay', (v_race.results_json is not null),
        'replay', v_race.results_json,     -- null once purged (>12h)
        'placements', v_places
    );
end;
$$;
grant execute on function public.get_race_result(text, uuid) to anon, authenticated;


-- ── register_horse: re-defined to also snapshot life_cap ────────────────────────
-- Same logic as migration 074, but the entry now records life_cap so the sim's
-- condition multiplier can use the real life fraction. Supersedes 074's version.
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
        return json_build_object('error', 'race_closed');
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
        where e.horse_id = p_horse_id and r.status in ('open', 'closed')
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

    return json_build_object(
        'ok', true,
        'race_id', p_race_id,
        'lane', v_lane,
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
