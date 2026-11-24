-- ============================================================================
-- Migration 067: Horse training (Horse Racing — Task 3)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Adds server-authoritative training to the horses from migration 065. The
-- client runs a little mini-game and reports a PERFORMANCE SCORE (0..100); the
-- SERVER decides the actual stat gain from that score, clamps it to the stat
-- ceilings, and enforces a once-per-UTC-day-per-kind cooldown. A cheating client
-- can at most claim a perfect score — it can never choose the stored stat, skip
-- the cooldown, or exceed the ceilings.
--
-- Training kinds -> stat raised:
--   'sprint' -> speed      (ceiling 100)
--   'hurdle' -> endurance  (ceiling 100)
--   'groom'  -> life_cap   (ceiling 200; also tops `life` up toward life_cap)
--
-- Gain curve (per session): a score of 0..100 maps to a gain of 1..MAX for the
-- kind, so even a poor run earns +1 (and a perfect run earns the max). Speed/
-- endurance cap their session gain lower than life_cap because they're the
-- smaller-range, higher-impact stats.
--   sprint/hurdle: 1..3 per day   groom: 1..5 per day
--
-- Cooldown is tracked per (horse, kind) in a new horse_training table keyed by
-- the UTC day, so each kind can be trained once per calendar day (UTC) and the
-- three kinds are independent.
-- ============================================================================


-- ── horse_training (per-horse, per-kind last-trained day) ──────────────────────
create table if not exists public.horse_training (
    horse_id     uuid        not null references public.horses(id) on delete cascade,
    kind         text        not null check (kind in ('sprint', 'hurdle', 'groom')),
    trained_day  date        not null,
    sessions     int         not null default 0,
    updated_at   timestamptz not null default now(),
    primary key (horse_id, kind)
);
alter table public.horse_training enable row level security;  -- RPCs only


-- ── Gain curve helper ──────────────────────────────────────────────────────────
-- Maps a clamped score (0..100) to a gain of 1..p_max (ceil so a non-zero score
-- never rounds down to 0, and 0 still yields the floor of 1).
create or replace function public._horse_training_gain(p_score int, p_max int)
returns int
language sql
immutable
as $$
    select greatest(1, least(p_max, ceil((greatest(0, least(100, p_score))::numeric / 100.0) * p_max)::int));
$$;


-- ── train_horse ────────────────────────────────────────────────────────────────
-- Trains one of the caller's ACTIVE horses in `p_kind`, applying a server-decided
-- gain derived from the reported `p_score` (0..100). Once per UTC day per kind.
-- Returns { ok, kind, stat, gain, horse:{...} } | { error }.
--   errors: account_not_found, horse_not_found, not_your_horse, horse_retired,
--           invalid_kind, already_trained, at_ceiling
create or replace function public.train_horse(
    p_device_hash text,
    p_horse_id    uuid,
    p_kind        text,
    p_score       int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account  uuid;
    v_horse    public.horses%rowtype;
    v_today    date := (now() at time zone 'utc')::date;
    v_last     date;
    v_max      int;
    v_gain     int;
    v_stat     text;
    v_ceiling  int;
    v_current  int;
    v_new      int;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    if p_kind not in ('sprint', 'hurdle', 'groom') then
        return json_build_object('error', 'invalid_kind');
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

    -- Cooldown: one session per (horse, kind) per UTC day.
    select trained_day into v_last
    from public.horse_training
    where horse_id = p_horse_id and kind = p_kind;
    if v_last is not null and v_last >= v_today then
        return json_build_object('error', 'already_trained');
    end if;

    -- Pick the stat, ceiling, and per-session max for the kind.
    if p_kind = 'sprint' then
        v_stat := 'speed';      v_ceiling := 100; v_max := 3; v_current := v_horse.speed;
    elsif p_kind = 'hurdle' then
        v_stat := 'endurance';  v_ceiling := 100; v_max := 3; v_current := v_horse.endurance;
    else -- groom
        v_stat := 'life_cap';   v_ceiling := 200; v_max := 5; v_current := v_horse.life_cap;
    end if;

    if v_current >= v_ceiling then
        return json_build_object('error', 'at_ceiling', 'stat', v_stat, 'ceiling', v_ceiling);
    end if;

    -- Server decides the gain from the reported score, then clamps to ceiling.
    v_gain := public._horse_training_gain(p_score, v_max);
    v_new  := least(v_ceiling, v_current + v_gain);
    v_gain := v_new - v_current;  -- real gain after clamping

    -- Apply the stat change.
    if p_kind = 'sprint' then
        update public.horses set speed = v_new where id = p_horse_id;
    elsif p_kind = 'hurdle' then
        update public.horses set endurance = v_new where id = p_horse_id;
    else -- groom: raise life_cap, and top `life` up toward the new cap.
        update public.horses
        set life_cap = v_new,
            life = least(v_new, greatest(life, v_new))
        where id = p_horse_id;
    end if;

    -- Record the cooldown (upsert).
    insert into public.horse_training (horse_id, kind, trained_day, sessions, updated_at)
    values (p_horse_id, p_kind, v_today, 1, now())
    on conflict (horse_id, kind) do update
        set trained_day = excluded.trained_day,
            sessions = public.horse_training.sessions + 1,
            updated_at = now();

    -- Re-read the horse for the response.
    select * into v_horse from public.horses where id = p_horse_id;

    return json_build_object(
        'ok', true,
        'kind', p_kind,
        'stat', v_stat,
        'gain', v_gain,
        'horse', json_build_object(
            'id', v_horse.id, 'name', v_horse.name, 'breed', v_horse.breed,
            'life', v_horse.life, 'life_cap', v_horse.life_cap,
            'speed', v_horse.speed, 'endurance', v_horse.endurance,
            'status', v_horse.status, 'wins', v_horse.wins, 'races_run', v_horse.races_run
        )
    );
end;
$$;
grant execute on function public.train_horse(text, uuid, text, int) to anon, authenticated;


-- ── get_training_status ──────────────────────────────────────────────────────────
-- Returns, for each of the caller's active horses, which kinds are available to
-- train today (UTC). Lets the client grey out already-done buttons without a
-- round-trip per horse.
--   { day, horses:[{ horse_id, sprint:bool, hurdle:bool, groom:bool }] }
--   (bool = available to train now)
create or replace function public.get_training_status(p_device_hash text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_today   date := (now() at time zone 'utc')::date;
    v_rows    json;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select coalesce(json_agg(json_build_object(
        'horse_id', h.id,
        'sprint', coalesce((select t.trained_day < v_today from public.horse_training t
                            where t.horse_id = h.id and t.kind = 'sprint'), true),
        'hurdle', coalesce((select t.trained_day < v_today from public.horse_training t
                            where t.horse_id = h.id and t.kind = 'hurdle'), true),
        'groom',  coalesce((select t.trained_day < v_today from public.horse_training t
                            where t.horse_id = h.id and t.kind = 'groom'),  true)
    )), '[]'::json)
    into v_rows
    from public.horses h
    where h.owner_id = v_account and h.status = 'active';

    return json_build_object('day', v_today, 'horses', v_rows);
end;
$$;
grant execute on function public.get_training_status(text) to anon, authenticated;
