-- ============================================================================
-- Migration 073: Groom raises current life (cap only follows on overflow)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 + 067 + 070 + 071 + 072 already applied.
--
-- Fixes groom's effect. Groom now adds its (halved) gain to the horse's CURRENT
-- life; life_cap only rises if the refill would push life ABOVE the cap, and
-- then just enough to hold it. Examples (gain +5):
--     80 / 100  ->  85 / 100   (cap unchanged — room to spare)
--     96 / 100  -> 101 / 101   (life overflowed, so cap bumps to 101)
-- Hard ceiling for life/life_cap stays 200. Groom is still once per UTC day and
-- costs no life. sprint/hurdle (stat gain + 1..5 life drain + retire-on-0) are
-- unchanged from migration 072.
--
-- This supersedes migration 072's train_horse (groom branch only changed).
-- ============================================================================


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

    -- GROOM keeps the once-per-UTC-day cooldown. sprint/hurdle have none.
    if p_kind = 'groom' then
        select trained_day into v_last
        from public.horse_training
        where horse_id = p_horse_id and kind = p_kind;
        if v_last is not null and v_last >= v_today then
            return json_build_object('error', 'already_trained');
        end if;
    end if;

    -- ── Raw gain = round(score/10 + 1, 2), capped by the session cap ─────────
    v_cap  := public._horse_training_session_cap(v_account);
    v_gain := public._horse_training_gain(p_score, v_cap);

    if p_kind = 'groom' then
        -- Groom halves its gain, adds it to CURRENT life, and only raises the
        -- cap if life overflows it. Ceiling for groom is life_cap >= 200.
        v_stat    := 'life_cap';
        v_ceiling := 200;
        if v_horse.life_cap >= v_ceiling then
            return json_build_object('error', 'at_ceiling', 'stat', v_stat, 'ceiling', v_ceiling);
        end if;
        v_gain    := greatest(0.50, round(v_gain / 2.0, 2));
        v_new_life := least(v_ceiling, round(v_horse.life + v_gain, 2));
        v_new_cap  := greatest(v_horse.life_cap, v_new_life);  -- cap follows only on overflow
        v_gain     := round(v_new_life - v_horse.life, 2);     -- actual life added (post-clamp)
        update public.horses
        set life = v_new_life, life_cap = v_new_cap
        where id = p_horse_id;
    else
        -- sprint -> speed, hurdle -> endurance (ceiling 100). Clamp gain to it.
        if p_kind = 'sprint' then
            v_stat := 'speed';      v_ceiling := 100; v_current := v_horse.speed;
        else
            v_stat := 'endurance';  v_ceiling := 100; v_current := v_horse.endurance;
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

        -- LIFE COST (sprint/hurdle only). Drain 1..5; retire if it hits 0.
        v_life_cost := public._horse_training_life_cost(p_score);
        v_new_life  := round(v_horse.life - v_life_cost, 2);
        if v_new_life <= 0 then
            v_new_life := 0;
            v_retired  := true;
            update public.horses set life = 0, status = 'retired' where id = p_horse_id;
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
