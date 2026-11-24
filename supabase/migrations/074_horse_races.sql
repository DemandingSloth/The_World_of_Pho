-- ============================================================================
-- Migration 074: Horse races — schedule, lifecycle, registration, NPC backfill
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 (horses) already applied.
--
-- Adds the race SCHEDULE + REGISTRATION layer (Task 5). The actual race
-- SIMULATION + payout (closed -> resolved) is Task 6 (migration 075); this file
-- only takes a race from `open` (registration) to `closed` (field locked, NPCs
-- backfilled), on a lazily-advanced schedule.
--
-- There is no cron on the hosted DB, so races advance LAZILY: any client call to
-- get_races / register_horse first runs _horse_advance_races(), which:
--   • closes every `open` race whose closes_at has passed, backfilling empty
--     lanes with NPC horses (an 8-horse field), and
--   • ensures at least one `open` race always exists to register into.
--
-- Field size 8. A race carries a deterministic `seed` (set at close) that the
-- Task 6 simulation uses. Entries SNAPSHOT the horse's stats at registration, so
-- later training can't change a locked-in race.
-- ============================================================================


-- ── races ────────────────────────────────────────────────────────────────────
-- kind: 'regular' for now ('cup' comes in Task 9). status lifecycle:
--   open -> closed -> resolved. seed is assigned when a race closes.
create table if not exists public.races (
    id          uuid        primary key default gen_random_uuid(),
    name        text        not null,
    kind        text        not null default 'regular' check (kind in ('regular', 'cup')),
    status      text        not null default 'open'
                                 check (status in ('open', 'closed', 'resolved')),
    field_size  int         not null default 8,
    seed        bigint,                       -- set at close (Task 6 sim input)
    opens_at    timestamptz not null default now(),
    closes_at   timestamptz not null,         -- registration deadline
    resolved_at timestamptz,                  -- set in Task 6
    created_at  timestamptz not null default now()
);
create index if not exists races_status_idx on public.races (status, closes_at);
alter table public.races enable row level security;  -- RPCs only


-- ── race_entries ─────────────────────────────────────────────────────────────
-- One row per lane (max field_size). Player entries reference a real horse +
-- snapshot its stats; NPC entries have horse_id NULL and carry generated stats.
--   finish_place: NULL until resolved (Task 6), then 1..field_size.
create table if not exists public.race_entries (
    id            uuid        primary key default gen_random_uuid(),
    race_id       uuid        not null references public.races(id) on delete cascade,
    lane          int         not null,
    is_npc        boolean     not null default false,
    horse_id      uuid                 references public.horses(id) on delete set null,
    owner_id      uuid                 references public.accounts(id) on delete set null,
    display_name  text        not null,       -- horse name (snapshot) or NPC name
    breed         text        not null,
    speed         numeric(5,2) not null,
    endurance     numeric(5,2) not null,
    life          numeric(5,2) not null,
    finish_place  int,                         -- set at resolve (Task 6)
    created_at    timestamptz not null default now(),
    unique (race_id, lane)
);
create index if not exists race_entries_race_idx on public.race_entries (race_id);
-- A given horse can only sit in ONE non-resolved race at a time (enforced in RPC).
create index if not exists race_entries_horse_idx on public.race_entries (horse_id);
alter table public.race_entries enable row level security;  -- RPCs only


-- ── Schedule tuning (single source of truth) ───────────────────────────────────
-- How long a race stays open for registration, and the target number of
-- always-open races. Kept as functions so Task 9 cups / tuning are one-liners.
create or replace function public._race_registration_minutes() returns int
language sql immutable as $$ select 30; $$;      -- open window per race
create or replace function public._race_field_size() returns int
language sql immutable as $$ select 8; $$;
create or replace function public._race_open_target() returns int
language sql immutable as $$ select 1; $$;       -- keep >=1 open race available


-- ── NPC generation helpers ─────────────────────────────────────────────────────
-- A random NPC "First Last" name (small server-side pool; the client has the big
-- list but SQL can't call it). Deterministic enough for flavour.
create or replace function public._race_npc_name()
returns text
language sql
volatile
as $$
    select (array[
        'Dusty','Shadow','Blaze','Comet','Rogue','Maple','Thunder','Willow','Ranger','Pepper',
        'Scout','Cinder','Jasper','Nova','Flint','Hazel','Bandit','Clover','Diesel','Ember'
    ])[1 + floor(random() * 20)::int]
    || ' ' ||
    (array[
        'Runner','Dash','Gallop','Strider','Flash','Hooves','Mane','Trot','Canter','Bolt',
        'Swift','Charger','Drifter','Prancer','Racer','Streak','Rocket','Arrow','Bullet','Zephyr'
    ])[1 + floor(random() * 20)::int];
$$;

-- An NPC's stats: a random breed + stats jittered around a mid band so NPC
-- fields are competitive but beatable by a trained horse. Returns one row.
create or replace function public._race_npc_entry_stats()
returns table (breed text, speed numeric, endurance numeric, life numeric)
language plpgsql
volatile
as $$
declare
    v_breeds text[] := array['thoroughbred','arabian','standardbred'];
begin
    breed     := v_breeds[1 + floor(random() * 3)::int];
    -- Mid-ish competitive stats: speed/endurance 15..45, life 40..90.
    speed     := round((15 + random() * 30)::numeric, 2);
    endurance := round((15 + random() * 30)::numeric, 2);
    life      := round((40 + random() * 50)::numeric, 2);
    return next;
end;
$$;


-- ── _horse_advance_races: the lazy scheduler ────────────────────────────────────
-- Closes expired open races (backfilling NPC lanes) and keeps _race_open_target()
-- open races available. Safe to call on every read; cheap when nothing is due.
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
        -- Backfill empty lanes with NPC horses up to the field size.
        select count(*) into v_filled from public.race_entries where race_id = v_race.id;
        v_lane := 0;
        while v_filled < v_field loop
            -- find the next free lane
            while exists (select 1 from public.race_entries
                          where race_id = v_race.id and lane = v_lane) loop
                v_lane := v_lane + 1;
            end loop;
            select * into v_npc from public._race_npc_entry_stats();
            insert into public.race_entries (
                race_id, lane, is_npc, horse_id, owner_id,
                display_name, breed, speed, endurance, life
            ) values (
                v_race.id, v_lane, true, null, null,
                public._race_npc_name(), v_npc.breed, v_npc.speed, v_npc.endurance, v_npc.life
            );
            v_filled := v_filled + 1;
            v_lane := v_lane + 1;
        end loop;

        -- Lock the field + assign the deterministic sim seed (Task 6 uses it).
        update public.races
        set status = 'closed',
            seed = (floor(random() * 9223372036854775806) + 1)::bigint
        where id = v_race.id;
    end loop;

    -- 2) Ensure the schedule always has the target number of open races.
    select count(*) into v_open_cnt from public.races where status = 'open';
    while v_open_cnt < public._race_open_target() loop
        insert into public.races (name, kind, field_size, opens_at, closes_at)
        values (
            'Daily Dash',
            'regular',
            v_field,
            now(),
            now() + make_interval(mins => v_mins)
        );
        v_open_cnt := v_open_cnt + 1;
    end loop;
end;
$$;
revoke all on function public._horse_advance_races() from anon, authenticated;


-- ── register_horse: enter one of your ACTIVE horses into an OPEN race ───────────
-- Snapshots the horse's current stats into the next free lane. A horse may sit
-- in only ONE non-resolved race at a time. Advances the schedule first.
-- Returns { ok, race_id, lane, entry:{...} } | { error }.
--   errors: account_not_found, horse_not_found, not_your_horse, horse_retired,
--           race_not_found, race_closed, race_full, already_entered,
--           horse_in_race
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

    -- Field full?
    select count(*) into v_count from public.race_entries where race_id = p_race_id;
    if v_count >= v_race.field_size then
        return json_build_object('error', 'race_full');
    end if;

    -- Already in THIS race?
    if exists (select 1 from public.race_entries
               where race_id = p_race_id and horse_id = p_horse_id) then
        return json_build_object('error', 'already_entered');
    end if;

    -- Already in ANOTHER non-resolved race?
    if exists (
        select 1 from public.race_entries e
        join public.races r on r.id = e.race_id
        where e.horse_id = p_horse_id and r.status in ('open', 'closed')
    ) then
        return json_build_object('error', 'horse_in_race');
    end if;

    -- Next free lane (lanes are 0-based; NPCs backfill the rest at close).
    while exists (select 1 from public.race_entries
                  where race_id = p_race_id and lane = v_lane) loop
        v_lane := v_lane + 1;
    end loop;

    insert into public.race_entries (
        race_id, lane, is_npc, horse_id, owner_id,
        display_name, breed, speed, endurance, life
    ) values (
        p_race_id, v_lane, false, p_horse_id, v_account,
        v_horse.name, v_horse.breed, v_horse.speed, v_horse.endurance, v_horse.life
    ) returning id into v_entry;

    return json_build_object(
        'ok', true,
        'race_id', p_race_id,
        'lane', v_lane,
        'entry', json_build_object(
            'id', v_entry, 'lane', v_lane, 'is_npc', false,
            'horse_id', p_horse_id, 'display_name', v_horse.name, 'breed', v_horse.breed,
            'speed', v_horse.speed, 'endurance', v_horse.endurance, 'life', v_horse.life
        )
    );
end;
$$;
grant execute on function public.register_horse(text, uuid, uuid) to anon, authenticated;


-- ── get_races: upcoming/open races + their entries (advances schedule first) ────
-- Returns open + recently-closed races (not yet resolved) with their fields, plus
-- which of the caller's horses are entered. Keeps the UI's upcoming list fresh.
--   { now, races:[ { id,name,kind,status,field_size,opens_at,closes_at,
--                    entries:[{lane,is_npc,display_name,breed,speed,endurance,
--                              life,mine:bool,horse_id}] } ] }
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
    v_account := public._horse_resolve_account(p_device_hash);  -- may be null (not logged in)

    select coalesce(json_agg(rj order by rj_closes), '[]'::json) into v_races
    from (
        select
            r.closes_at as rj_closes,
            json_build_object(
                'id', r.id, 'name', r.name, 'kind', r.kind, 'status', r.status,
                'field_size', r.field_size, 'opens_at', r.opens_at, 'closes_at', r.closes_at,
                'entries', coalesce((
                    select json_agg(json_build_object(
                        'lane', e.lane, 'is_npc', e.is_npc,
                        'display_name', e.display_name, 'breed', e.breed,
                        'speed', e.speed, 'endurance', e.endurance, 'life', e.life,
                        'horse_id', e.horse_id,
                        'mine', (e.owner_id is not null and e.owner_id = v_account)
                    ) order by e.lane)
                    from public.race_entries e where e.race_id = r.id
                ), '[]'::json)
            ) as rj
        from public.races r
        where r.status in ('open', 'closed')
    ) sub;

    return json_build_object('now', now(), 'races', v_races);
end;
$$;
grant execute on function public.get_races(text) to anon, authenticated;
