-- ============================================================================
-- Migration 101: One shared 3-per-day training limit + remaining count in replies
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- PROBLEMS FIXED:
--   1. Guild PADDOCK training (train_paddock_horse, migration 079) had its own
--      per-trainer, once-per-day cooldown and never touched the horse's
--      horse_training counter. A paddocked horse could be trained 3x in the
--      Stable PLUS again in the paddock (by its owner and every guildmate), so
--      players saw more sessions than the "3/3" shown. It also still used the old
--      100/200 ceilings from before migration 090.
--   2. Clients had to re-fetch get_training_status to learn the new remaining
--      count, so a quick re-open of the Train popup could show a stale number.
--
-- CHANGES:
--   • train_paddock_horse now counts against the SAME horse_training row as the
--     Stable: 3 sessions per kind per horse per UTC day, total, no matter who
--     trains it or from where. Ceilings raised to 500 to match 090.
--   • train_horse and train_paddock_horse both return `remaining` (0..3 sessions
--     left today for that kind) and `resets_at` (next UTC midnight, epoch secs).
--   • already_trained errors also carry `remaining` = 0 and `resets_at`.
--   • get_training_status additionally returns `resets_at`.
-- ============================================================================


-- ── Shared helpers ──────────────────────────────────────────────────────────

-- The daily session limit per training kind (single source of truth).
create or replace function public._horse_training_daily_limit() returns int
language sql immutable as $$ select 3; $$;

-- Epoch seconds of the next UTC midnight (when the per-day counters reset).
create or replace function public._horse_training_resets_at() returns double precision
language sql stable as $$
    select extract(epoch from (((now() at time zone 'utc')::date + 1)::timestamp at time zone 'utc'));
$$;

-- Sessions already used TODAY (UTC) for a horse + kind (0 if none / older day).
create or replace function public._horse_sessions_today(p_horse_id uuid, p_kind text)
returns int
language sql stable
set search_path = public
as $$
    select coalesce((
        select case when t.trained_day >= (now() at time zone 'utc')::date
                    then t.sessions else 0 end
        from public.horse_training t
        where t.horse_id = p_horse_id and t.kind = p_kind
    ), 0);
$$;

-- Records one session against the shared counter (resets on a new UTC day) and
-- returns the sessions used today AFTER this one.
create or replace function public._horse_record_session(p_horse_id uuid, p_kind text)
returns int
language plpgsql
set search_path = public
as $$
declare
    v_today date := (now() at time zone 'utc')::date;
    v_used  int;
begin
    insert into public.horse_training (horse_id, kind, trained_day, sessions, updated_at)
    values (p_horse_id, p_kind, v_today, 1, now())
    on conflict (horse_id, kind) do update
        set trained_day = excluded.trained_day,
            sessions    = case
                when public.horse_training.trained_day < excluded.trained_day then 1
                else public.horse_training.sessions + 1
            end,
            updated_at  = now()
    returning sessions into v_used;
    return v_used;
end;
$$;

revoke all on function public._horse_sessions_today(uuid, text) from anon, authenticated;
revoke all on function public._horse_record_session(uuid, text) from anon, authenticated;


-- ── train_horse (Stable) — same as 090 + remaining/resets_at in replies ──────
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
    v_limit     int := public._horse_training_daily_limit();
    v_used      int;
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

    -- Row lock serializes concurrent trains of the same horse (Stable + paddock).
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

    v_used := public._horse_sessions_today(p_horse_id, p_kind);
    if v_used >= v_limit then
        return json_build_object('error', 'already_trained',
            'sessions_today', v_used, 'limit', v_limit, 'remaining', 0,
            'resets_at', public._horse_training_resets_at());
    end if;

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
        v_gain     := greatest(0.50, round(v_gain / 2.0, 2));
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

    v_used := public._horse_record_session(p_horse_id, p_kind);

    perform public.record_horse_guild_activity(p_device_hash, 'train_sessions', 1);

    select * into v_horse from public.horses where id = p_horse_id;

    return json_build_object(
        'ok', true,
        'kind', p_kind, 'stat', v_stat, 'gain', v_gain,
        'life_cost', v_life_cost, 'retired', v_retired,
        'remaining', greatest(0, v_limit - v_used),
        'resets_at', public._horse_training_resets_at(),
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


-- ── train_paddock_horse — now uses the SHARED per-horse counter ──────────────
create or replace function public.train_paddock_horse(
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
    v_trainer   uuid;
    v_guild     uuid;
    v_pad       public.guild_paddock%rowtype;
    v_horse     public.horses%rowtype;
    v_today     date := (now() at time zone 'utc')::date;
    v_limit     int := public._horse_training_daily_limit();
    v_used      int;
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
    v_trainer := public._horse_resolve_account(p_device_hash);
    if v_trainer is null then
        return json_build_object('error', 'account_not_found');
    end if;
    if p_kind not in ('sprint', 'hurdle', 'groom') then
        return json_build_object('error', 'invalid_kind');
    end if;

    v_guild := public._horse_guild_of(v_trainer);
    if v_guild is null then
        return json_build_object('error', 'not_horse_guild');
    end if;

    select * into v_pad from public.guild_paddock where horse_id = p_horse_id;
    if not found then
        return json_build_object('error', 'not_paddocked');
    end if;
    if v_pad.guild_id <> v_guild then
        return json_build_object('error', 'not_same_guild');
    end if;

    select * into v_horse from public.horses where id = p_horse_id for update;
    if not found then
        return json_build_object('error', 'horse_not_found');
    end if;
    if v_horse.status <> 'active' then
        return json_build_object('error', 'horse_retired');
    end if;

    -- SHARED limit: the same 3/kind/day the Stable uses, whoever trains it.
    v_used := public._horse_sessions_today(p_horse_id, p_kind);
    if v_used >= v_limit then
        return json_build_object('error', 'already_trained',
            'sessions_today', v_used, 'limit', v_limit, 'remaining', 0,
            'resets_at', public._horse_training_resets_at());
    end if;

    -- Gain uses the OWNER's session cap (their horse / their guild perks).
    v_cap  := public._horse_training_session_cap(v_pad.owner_id);
    v_gain := public._horse_training_gain(p_score, v_cap);

    if p_kind = 'groom' then
        v_stat    := 'life_cap';
        v_ceiling := 500;
        if v_horse.life_cap >= v_ceiling then
            return json_build_object('error', 'at_ceiling', 'stat', v_stat, 'ceiling', v_ceiling);
        end if;
        v_gain     := greatest(0.50, round(v_gain / 2.0, 2));
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

    v_used := public._horse_record_session(p_horse_id, p_kind);

    -- Keep the per-trainer history row (no longer used as a cooldown).
    insert into public.paddock_training (horse_id, trainer_id, kind, trained_day, sessions, updated_at)
    values (p_horse_id, v_trainer, p_kind, v_today, 1, now())
    on conflict (horse_id, trainer_id, kind) do update
        set trained_day = excluded.trained_day,
            sessions = public.paddock_training.sessions + 1,
            updated_at = now();

    perform public.record_horse_guild_activity(p_device_hash, 'train_sessions', 1);

    select * into v_horse from public.horses where id = p_horse_id;

    return json_build_object(
        'ok', true,
        'kind', p_kind, 'stat', v_stat, 'gain', v_gain,
        'life_cost', v_life_cost, 'retired', v_retired,
        'remaining', greatest(0, v_limit - v_used),
        'resets_at', public._horse_training_resets_at(),
        'horse', json_build_object(
            'id', v_horse.id, 'name', v_horse.name, 'breed', v_horse.breed,
            'life', v_horse.life, 'life_cap', v_horse.life_cap,
            'speed', v_horse.speed, 'endurance', v_horse.endurance,
            'status', v_horse.status, 'wins', v_horse.wins, 'races_run', v_horse.races_run
        )
    );
end;
$$;
grant execute on function public.train_paddock_horse(text, uuid, text, int) to anon, authenticated;


-- ── get_training_status — same as 090 + resets_at ───────────────────────────
create or replace function public.get_training_status(p_device_hash text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_limit   int := public._horse_training_daily_limit();
    v_rows    json;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select coalesce(json_agg(json_build_object(
        'horse_id', h.id,
        'sprint',  public._horse_sessions_today(h.id, 'sprint') < v_limit,
        'hurdle',  public._horse_sessions_today(h.id, 'hurdle') < v_limit,
        'groom',   public._horse_sessions_today(h.id, 'groom')  < v_limit,
        'sprint_remaining', greatest(0, v_limit - public._horse_sessions_today(h.id, 'sprint')),
        'hurdle_remaining', greatest(0, v_limit - public._horse_sessions_today(h.id, 'hurdle')),
        'groom_remaining',  greatest(0, v_limit - public._horse_sessions_today(h.id, 'groom'))
    )), '[]'::json)
    into v_rows
    from public.horses h
    where h.owner_id = v_account and h.status = 'active';

    return json_build_object(
        'day', (now() at time zone 'utc')::date,
        'resets_at', public._horse_training_resets_at(),
        'horses', v_rows);
end;
$$;
grant execute on function public.get_training_status(text) to anon, authenticated;
