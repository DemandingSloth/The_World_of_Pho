-- ============================================================================
-- Migration 090: Raise stat caps to 500 + 3 training sessions per kind per day
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 (horses table + constraints) + 070 (fractional constraints)
--   + 073/078/083 (latest train_horse) + 075 (_race_run_sim) applied.
--
-- Changes:
--   1. Drop the old 100/200 CHECK constraints on horses, replace with 500/500.
--   2. Redefine _race_run_sim: decay formula endurance/100 -> endurance/500
--      (keeps the 1-in-100 floor; a 500-endurance horse now has the minimum
--      possible decay chance, consistent with the new ceiling).
--   3. Redefine train_horse (supersedes 083): ceilings 100->500, 200->500.
--      All three kinds (sprint, hurdle, groom) now allow up to 3 sessions per
--      UTC day (sessions counter resets when trained_day advances).
--      Groom loses its "once per day" hard block; it also counts toward the
--      shared 3-sessions limit.
-- ============================================================================


-- ── 1. Update stat CHECK constraints on the horses table ─────────────────────
-- Drop the 070 fractional constraints first, then the original 065 constraints
-- (whichever exist), and replace with new 500/500 limits.
alter table public.horses
    drop constraint if exists horses_life_check,
    drop constraint if exists horses_life_cap_check,
    drop constraint if exists horses_speed_check,
    drop constraint if exists horses_endurance_check;

-- Original 065 integer constraints (if still present):
alter table public.horses
    drop constraint if exists horses_life_key,
    drop constraint if exists horses_speed_key,
    drop constraint if exists horses_endurance_key;

-- New constraints matching the 500 cap.
alter table public.horses
    add constraint horses_life_check      check (life      >= 0 and life      <= 500),
    add constraint horses_life_cap_check  check (life_cap  >= 0 and life_cap  <= 500),
    add constraint horses_speed_check     check (speed     >= 0 and speed     <= 500),
    add constraint horses_endurance_check check (endurance >= 0 and endurance <= 500);


-- ── 2. _race_run_sim: scale decay formula to the new endurance ceiling ────────
-- Supersedes 075's version. Identical except:
--   • "1 - endurance/100" -> "1 - endurance/500"
--   • Comment updated.
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
begin
    select seed into v_seed from public.races where id = p_race_id;
    if v_seed is null then
        return null;
    end if;

    for e in
        select * from public.race_entries where race_id = p_race_id order by lane
    loop
        v_cond := public._race_condition_mult(e.life, e.life_cap);
        v_cum  := 0;
        v_samples := '[]'::jsonb;

        for s in 0 .. (v_segs - 1) loop
            v_pace := (5.0 + e.speed) * v_cond;

            v_decay := 1.0;
            if s >= (v_segs / 2) then
                v_decroll := public._race_rng(v_seed, e.lane * 1000 + s * 7 + 1);
                -- Decay chance = max(0.01, 1 - endurance/500). A horse at the
                -- new 500 ceiling has only the 1-in-100 residual chance, same
                -- floor behaviour as the old cap at 100.
                if v_decroll < greatest(0.01, 1.0 - (e.endurance / 500.0)) then
                    v_decay := 0.80;
                end if;
            end if;

            v_jit := 0.85 + public._race_rng(v_seed, e.lane * 1000 + s * 7 + 2) * 0.30;
            v_cum := round(v_cum + v_pace * v_decay * v_jit::numeric, 3);
            v_samples := v_samples || to_jsonb(v_cum);
        end loop;

        v_lanes := v_lanes || jsonb_build_object(
            'lane', e.lane, 'display_name', e.display_name, 'breed', e.breed,
            'is_npc', e.is_npc, 'horse_id', e.horse_id,
            'total', v_cum, 'samples', v_samples
        );
    end loop;

    select array_agg((l->>'lane')::int order by (l->>'total')::numeric desc, (l->>'lane')::int)
    into v_order from jsonb_array_elements(v_lanes) l;

    return jsonb_build_object('segments', v_segs, 'lanes', v_lanes, 'order', v_order);
end;
$$;
revoke all on function public._race_run_sim(uuid) from anon, authenticated;


-- ── 3. train_horse: new ceilings + 3 sessions per kind per day ───────────────
-- Supersedes 083's version (keeps the jewelry training-mult + guild activity
-- credit). New behaviour:
--   • ALL three kinds share the SAME daily limit: 3 sessions per UTC day.
--     The horse_training table already tracks sessions + trained_day; we just
--     check sessions < 3 (resetting when trained_day advances).
--   • Ceilings: speed/endurance → 500, life_cap → 500.
--   • Groom ceiling for life/life_cap → 500 (was 200).
drop function if exists public.train_horse(text, uuid, text, int, numeric);

create or replace function public.train_horse(
    p_device_hash text,
    p_horse_id    uuid,
    p_kind        text,
    p_score       int,
    p_train_mult  numeric default 1.0
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account   uuid;
    v_horse     public.horses%rowtype;
    v_today     date := (now() at time zone 'utc')::date;
    v_last      date;
    v_sessions  int;
    v_cap       numeric;
    v_gain      numeric;
    v_mult      numeric;
    v_stat      text;
    v_ceiling   numeric;
    v_current   numeric;
    v_new       numeric;
    v_life_cost int := 0;
    v_new_life  numeric;
    v_new_cap   numeric;
    v_retired   boolean := false;
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

    -- 3-sessions-per-UTC-day limit for ALL kinds.
    select trained_day, sessions into v_last, v_sessions
    from public.horse_training
    where horse_id = p_horse_id and kind = p_kind;

    if v_last is not null and v_last >= v_today then
        -- Same day: check session count.
        if coalesce(v_sessions, 0) >= 3 then
            return json_build_object('error', 'already_trained',
                'sessions_today', coalesce(v_sessions, 0), 'limit', 3);
        end if;
    end if;

    -- Capped gain × jewelry multiplier (mult clamped to 1.0..5.0).
    v_cap  := public._horse_training_session_cap(v_account);
    v_gain := public._horse_training_gain(p_score, v_cap);
    v_mult := least(greatest(coalesce(p_train_mult, 1.0), 1.0), 5.0);
    v_gain := round(v_gain * v_mult, 2);

    if p_kind = 'groom' then
        v_stat    := 'life_cap';
        v_ceiling := 500;
        if v_horse.life_cap >= v_ceiling then
            return json_build_object('error', 'at_ceiling', 'stat', v_stat, 'ceiling', v_ceiling);
        end if;
        v_gain    := greatest(0.50, round(v_gain / 2.0, 2));
        v_new_life := least(v_ceiling, round(v_horse.life + v_gain, 2));
        v_new_cap  := greatest(v_horse.life_cap, v_new_life);
        v_gain     := round(v_new_life - v_horse.life, 2);
        update public.horses set life = v_new_life, life_cap = v_new_cap where id = p_horse_id;
    else
        if p_kind = 'sprint' then
            v_stat := 'speed';      v_ceiling := 500; v_current := v_horse.speed;
        else
            v_stat := 'endurance';  v_ceiling := 500; v_current := v_horse.endurance;
        end if;
        if v_current >= v_ceiling then
            return json_build_object('error', 'at_ceiling', 'stat', v_stat, 'ceiling', v_ceiling);
        end if;
        v_new  := least(v_ceiling, round(v_current + v_gain, 2));
        v_gain := round(v_new - v_current, 2);
        if p_kind = 'sprint' then
            update public.horses set speed = v_new where id = p_horse_id;
        else
            update public.horses set endurance = v_new where id = p_horse_id;
        end if;

        v_life_cost := public._horse_training_life_cost(p_score);
        v_new_life  := round(v_horse.life - v_life_cost, 2);
        if v_new_life <= 0 then
            v_new_life := 0;
            v_retired  := true;
            update public.horses set life = 0, status = 'retired' where id = p_horse_id;
            delete from public.guild_paddock where horse_id = p_horse_id;
        else
            update public.horses set life = v_new_life where id = p_horse_id;
        end if;
    end if;

    -- Record the session (upsert increments counter; resets when day advances).
    insert into public.horse_training (horse_id, kind, trained_day, sessions, updated_at)
    values (p_horse_id, p_kind, v_today, 1, now())
    on conflict (horse_id, kind) do update
        set trained_day = excluded.trained_day,
            sessions    = case
                when public.horse_training.trained_day < excluded.trained_day then 1
                else public.horse_training.sessions + 1
            end,
            updated_at  = now();

    perform public.record_horse_guild_activity(p_device_hash, 'train_sessions', 1);

    select * into v_horse from public.horses where id = p_horse_id;

    return json_build_object(
        'ok', true,
        'kind', p_kind, 'stat', v_stat, 'gain', v_gain,
        'life_cost', v_life_cost, 'retired', v_retired,
        'horse', json_build_object(
            'id', v_horse.id, 'name', v_horse.name, 'breed', v_horse.breed,
            'life', v_horse.life, 'life_cap', v_horse.life_cap,
            'speed', v_horse.speed, 'endurance', v_horse.endurance,
            'status', v_horse.status, 'wins', v_horse.wins, 'races_run', v_horse.races_run
        )
    );
end;
$$;
grant execute on function public.train_horse(text, uuid, text, int, numeric) to anon, authenticated;


-- ── 4. get_training_status: return sessions_remaining per kind ────────────────
-- Supersedes 067's version. Returns the remaining sessions today (0..3) per
-- kind so the client can show "1 of 3 remaining" and disable when 0.
-- For backward compat, the existing bool keys (sprint/hurdle/groom) stay and
-- mean "at least 1 session available". New _remaining keys carry the count.
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
        -- Bool keys (backward compat): true = at least 1 session left today.
        'sprint',  coalesce((select case
            when t.trained_day < v_today then true
            else t.sessions < 3
        end from public.horse_training t where t.horse_id = h.id and t.kind = 'sprint'), true),
        'hurdle',  coalesce((select case
            when t.trained_day < v_today then true
            else t.sessions < 3
        end from public.horse_training t where t.horse_id = h.id and t.kind = 'hurdle'), true),
        'groom',   coalesce((select case
            when t.trained_day < v_today then true
            else t.sessions < 3
        end from public.horse_training t where t.horse_id = h.id and t.kind = 'groom'),  true),
        -- Remaining count keys (0..3): for the UI to display "2 left today".
        'sprint_remaining',  coalesce((select case
            when t.trained_day < v_today then 3
            else greatest(0, 3 - t.sessions)
        end from public.horse_training t where t.horse_id = h.id and t.kind = 'sprint'), 3),
        'hurdle_remaining',  coalesce((select case
            when t.trained_day < v_today then 3
            else greatest(0, 3 - t.sessions)
        end from public.horse_training t where t.horse_id = h.id and t.kind = 'hurdle'), 3),
        'groom_remaining',   coalesce((select case
            when t.trained_day < v_today then 3
            else greatest(0, 3 - t.sessions)
        end from public.horse_training t where t.horse_id = h.id and t.kind = 'groom'),  3)
    )), '[]'::json)
    into v_rows
    from public.horses h
    where h.owner_id = v_account and h.status = 'active';

    return json_build_object('day', v_today, 'horses', v_rows);
end;
$$;
grant execute on function public.get_training_status(text) to anon, authenticated;
