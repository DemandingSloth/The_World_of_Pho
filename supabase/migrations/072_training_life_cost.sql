-- ============================================================================
-- Migration 072: Training costs life (sprint/hurdle) + work-to-death
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 + 067 + 070 + 071 already applied.
--
-- Replaces the per-day cooldown on sprint + hurdle with a LIFE COST: each run
-- drains the horse's current `life` by 1..5, scaled by the final score (harder
-- runs tire the horse more). If a run brings life to 0 or below, the horse is
-- RETIRED to the pasture (its earned stat gain from that final run still lands).
-- GROOM is unchanged: once per UTC day, no life cost, +5.00/+0.50 gain.
--
--   life_cost(score) = 1 + round(clamp(score,0,90)/90 * 4)   -> 1..5
--
-- The client warns when life <= 5 and lets the player train anyway; the server
-- is authoritative on the drain + retirement and returns `life_cost` + `retired`.
-- This supersedes migration 071's train_horse.
-- ============================================================================


-- ── Life cost helper ────────────────────────────────────────────────────────────
-- Higher score -> more life drained. score 0 -> 1, 90+ -> 5. Range 1..5.
create or replace function public._horse_training_life_cost(p_score int)
returns int
language sql
immutable
as $$
    select greatest(1, least(5, 1 + round(least(90, greatest(0, p_score))::numeric / 90.0 * 4.0)::int));
$$;


-- ── train_horse (life-cost model) ────────────────────────────────────────────────
-- sprint/hurdle: no cooldown, drain life 1..5, retire if life hits 0.
-- groom:         once per UTC day, no life cost.
-- Returns { ok, kind, stat, gain, life_cost, retired, horse } | { error }.
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
    v_account   uuid;
    v_horse     public.horses%rowtype;
    v_today     date := (now() at time zone 'utc')::date;
    v_last      date;
    v_cap       numeric;
    v_gain      numeric;
    v_stat      text;
    v_ceiling   numeric;
    v_current   numeric;
    v_new       numeric;
    v_life_cost int := 0;
    v_new_life  numeric;
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

    -- GROOM keeps the once-per-UTC-day cooldown. sprint/hurdle have none (they
    -- are throttled by the life cost instead).
    if p_kind = 'groom' then
        select trained_day into v_last
        from public.horse_training
        where horse_id = p_horse_id and kind = p_kind;
        if v_last is not null and v_last >= v_today then
            return json_build_object('error', 'already_trained');
        end if;
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

    -- Stat gain = round(score/10 + 1, 2), capped by the session cap; groom halved.
    v_cap  := public._horse_training_session_cap(v_account);
    v_gain := public._horse_training_gain(p_score, v_cap);
    if p_kind = 'groom' then
        v_gain := greatest(0.50, round(v_gain / 2.0, 2));
    end if;
    v_new  := least(v_ceiling, round(v_current + v_gain, 2));
    v_gain := round(v_new - v_current, 2);

    -- Apply the stat gain.
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

    -- LIFE COST (sprint/hurdle only). Drain 1..5; retire if it hits 0.
    if p_kind in ('sprint', 'hurdle') then
        v_life_cost := public._horse_training_life_cost(p_score);
        v_new_life  := round(v_horse.life - v_life_cost, 2);
        if v_new_life <= 0 then
            v_new_life := 0;
            v_retired  := true;
            update public.horses
            set life = 0, status = 'retired'
            where id = p_horse_id;
        else
            update public.horses set life = v_new_life where id = p_horse_id;
        end if;
    end if;

    -- Record the session (groom's row is what the daily cooldown reads).
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
        'life_cost', v_life_cost,
        'retired', v_retired,
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
