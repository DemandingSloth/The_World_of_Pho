-- ============================================================================
-- Migration 070: Fractional stats + new training gain formula (Horse Racing)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 (horses) and 067 (horse_training) already applied.
--
-- Reworks training per the final design:
--   • Horse stats (life, life_cap, speed, endurance) become NUMERIC(5,2) — two
--     decimal places — so training can award fractional gains.
--   • The mini-games now report an INTEGER `score` = points earned in that run
--     (sprint: green sections cleared; hurdle: hurdles cleared before a miss;
--      groom: center-hits before a miss). The server turns that into a gain:
--         gain = round(score / 10.0 + 1, 2)
--     capped per session by _horse_training_session_cap() (10.00 for now; the
--     horse-guild raises it later), then clamped so the stat stays <= ceiling.
--   • Ceilings unchanged: speed/endurance <= 100, life/life_cap <= 200.
--   • Daily cap unchanged: still once per UTC day per kind (horse_training).
--
-- This supersedes migration 067's integer _horse_training_gain + train_horse.
-- ============================================================================


-- ── Widen stat columns to NUMERIC(5,2) ──────────────────────────────────────────
-- Drop the old int CHECK constraints, change type (int values convert cleanly),
-- then re-add range checks against the numeric columns.
alter table public.horses
    drop constraint if exists horses_life_check,
    drop constraint if exists horses_life_cap_check,
    drop constraint if exists horses_speed_check,
    drop constraint if exists horses_endurance_check;

alter table public.horses
    alter column life      type numeric(5,2) using life::numeric(5,2),
    alter column life_cap  type numeric(5,2) using life_cap::numeric(5,2),
    alter column speed     type numeric(5,2) using speed::numeric(5,2),
    alter column endurance type numeric(5,2) using endurance::numeric(5,2);

alter table public.horses
    add constraint horses_life_check      check (life      >= 0 and life      <= 200),
    add constraint horses_life_cap_check  check (life_cap  >= 0 and life_cap  <= 200),
    add constraint horses_speed_check     check (speed     >= 0 and speed     <= 100),
    add constraint horses_endurance_check check (endurance >= 0 and endurance <= 100);


-- ── Per-session gain cap (authoritative; raised later by the horse guild) ───────
-- The most a single training session can add to a stat. Base 10.00. Task 10's
-- horse-guild upgrades/links will extend this per-account; kept as a function so
-- that's a one-line change here later. (p_account reserved for that.)
create or replace function public._horse_training_session_cap(p_account uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
    select 10.00::numeric;
$$;
revoke all on function public._horse_training_session_cap(uuid) from anon, authenticated;


-- ── Gain formula ────────────────────────────────────────────────────────────────
-- gain = round(score/10 + 1, 2), floored at 1.00 and capped at p_cap. `score` is
-- the integer points from the mini-game (>= 0). So 0 -> +1.00, 10 -> +2.00,
-- 90 -> +10.00; with the default 10.00 cap, score >= 90 all yield +10.00.
create or replace function public._horse_training_gain(p_score int, p_cap numeric)
returns numeric
language sql
immutable
as $$
    select least(
        greatest(1.00::numeric, round((greatest(0, p_score)::numeric / 10.0) + 1.0, 2)),
        p_cap
    );
$$;


-- ── train_horse (fractional) ─────────────────────────────────────────────────────
-- Trains one of the caller's ACTIVE horses in `p_kind` using the integer run
-- `p_score`. Once per UTC day per kind. Returns { ok, kind, stat, gain, horse }.
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
    v_cap      numeric;
    v_gain     numeric;
    v_stat     text;
    v_ceiling  numeric;
    v_current  numeric;
    v_new      numeric;
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

    -- Daily cap: one session per (horse, kind) per UTC day.
    select trained_day into v_last
    from public.horse_training
    where horse_id = p_horse_id and kind = p_kind;
    if v_last is not null and v_last >= v_today then
        return json_build_object('error', 'already_trained');
    end if;

    -- Pick the stat + ceiling for the kind.
    if p_kind = 'sprint' then
        v_stat := 'speed';      v_ceiling := 100; v_current := v_horse.speed;
    elsif p_kind = 'hurdle' then
        v_stat := 'endurance';  v_ceiling := 100; v_current := v_horse.endurance;
    else -- groom
        v_stat := 'life_cap';   v_ceiling := 200; v_current := v_horse.life_cap;
    end if;

    if v_current >= v_ceiling then
        return json_build_object('error', 'at_ceiling', 'stat', v_stat, 'ceiling', v_ceiling);
    end if;

    -- gain = round(score/10 + 1, 2), capped by the session cap, then clamped so
    -- the stat never exceeds its ceiling. Real gain = new - current.
    v_cap  := public._horse_training_session_cap(v_account);
    v_gain := public._horse_training_gain(p_score, v_cap);
    v_new  := least(v_ceiling, round(v_current + v_gain, 2));
    v_gain := round(v_new - v_current, 2);

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

    insert into public.horse_training (horse_id, kind, trained_day, sessions, updated_at)
    values (p_horse_id, p_kind, v_today, 1, now())
    on conflict (horse_id, kind) do update
        set trained_day = excluded.trained_day,
            sessions = public.horse_training.sessions + 1,
            updated_at = now();

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
