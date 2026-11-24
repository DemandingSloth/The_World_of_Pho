-- ============================================================================
-- Migration 079: Horse-guild SHARED TRAINING — the guild paddock (Task 10c)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 + 067 + 070 + 073 + 078 already applied.
--
-- The guild paddock is a horse-spec guild's shared training ground. A member
-- DEPOSITS one of their active horses into the paddock; then ANY member of that
-- guild can TRAIN it (sprint/hurdle/groom) — the stat gain lands on the OWNER's
-- horse. This spreads the daily training load across the guild (your horse can
-- be trained by several guildmates in a day).
--
-- Rules:
--   • Only members of a HORSE-spec guild may deposit / train in the paddock.
--   • A horse can't be paddocked while entered in a race (open/betting), and a
--     retired horse can't be deposited.
--   • Cooldown is PER-TRAINER, per horse, per kind, per UTC day — so each member
--     may train a given paddock horse once/day/kind (the owner's own daily
--     train_horse cooldown for 'groom' is separate and still applies to them).
--   • Gains use the SAME formula + ceilings + life rules as train_horse, and the
--     session cap is the OWNER's cap (their horse, their guild perks).
--   • Each completed paddock session also credits the trainer's 'train_sessions'
--     horse-guild mission (via record_horse_guild_activity).
-- ============================================================================


-- ── guild_paddock: horses currently in a guild's shared paddock ─────────────────
-- One row per paddocked horse (a horse can be in at most one paddock).
create table if not exists public.guild_paddock (
    id            uuid        primary key default gen_random_uuid(),
    guild_id      uuid        not null references public.guilds(id)   on delete cascade,
    horse_id      uuid        not null unique references public.horses(id) on delete cascade,
    owner_id      uuid        not null references public.accounts(id) on delete cascade,
    deposited_at  timestamptz not null default now()
);
create index if not exists guild_paddock_guild_idx on public.guild_paddock (guild_id);
alter table public.guild_paddock enable row level security;  -- RPCs only


-- ── paddock_training: per-trainer, per-horse, per-kind daily cooldown ───────────
create table if not exists public.paddock_training (
    horse_id     uuid        not null references public.horses(id)   on delete cascade,
    trainer_id   uuid        not null references public.accounts(id) on delete cascade,
    kind         text        not null check (kind in ('sprint', 'hurdle', 'groom')),
    trained_day  date        not null,
    sessions     int         not null default 0,
    updated_at   timestamptz not null default now(),
    primary key (horse_id, trainer_id, kind)
);
alter table public.paddock_training enable row level security;  -- RPCs only


-- ── Helper: the caller's active HORSE-spec guild id, or null ────────────────────
create or replace function public._horse_guild_of(p_account uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
    select gm.guild_id
    from public.guild_members gm
    join public.guilds g on g.id = gm.guild_id
    where gm.account_id = p_account
      and gm.left_at is null
      and g.specialization = 'horse'
    limit 1;
$$;
revoke all on function public._horse_guild_of(uuid) from anon, authenticated;


-- ── deposit_to_paddock ──────────────────────────────────────────────────────────
-- Places one of the caller's ACTIVE horses into their horse-guild's paddock.
-- Returns { ok, horse_id } | { error }.
--   errors: account_not_found, not_horse_guild, horse_not_found, not_your_horse,
--           horse_retired, horse_in_race, already_paddocked
create or replace function public.deposit_to_paddock(
    p_device_hash text,
    p_horse_id    uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_guild   uuid;
    v_horse   public.horses%rowtype;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_guild := public._horse_guild_of(v_account);
    if v_guild is null then
        return json_build_object('error', 'not_horse_guild');
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

    -- Not while entered in a non-resolved race.
    if exists (
        select 1 from public.race_entries e
        join public.races r on r.id = e.race_id
        where e.horse_id = p_horse_id and r.status in ('open', 'betting')
    ) then
        return json_build_object('error', 'horse_in_race');
    end if;

    if exists (select 1 from public.guild_paddock where horse_id = p_horse_id) then
        return json_build_object('error', 'already_paddocked');
    end if;

    insert into public.guild_paddock (guild_id, horse_id, owner_id)
    values (v_guild, p_horse_id, v_account);

    return json_build_object('ok', true, 'horse_id', p_horse_id);
end;
$$;
grant execute on function public.deposit_to_paddock(text, uuid) to anon, authenticated;


-- ── withdraw_from_paddock ────────────────────────────────────────────────────────
-- Removes one of the CALLER's horses from the paddock (owner only).
-- Returns { ok } | { error: account_not_found, not_paddocked, not_your_horse }
create or replace function public.withdraw_from_paddock(
    p_device_hash text,
    p_horse_id    uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_row     public.guild_paddock%rowtype;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select * into v_row from public.guild_paddock where horse_id = p_horse_id for update;
    if not found then
        return json_build_object('error', 'not_paddocked');
    end if;
    if v_row.owner_id <> v_account then
        return json_build_object('error', 'not_your_horse');
    end if;

    delete from public.guild_paddock where horse_id = p_horse_id;
    return json_build_object('ok', true);
end;
$$;
grant execute on function public.withdraw_from_paddock(text, uuid) to anon, authenticated;


-- ── get_guild_paddock ──────────────────────────────────────────────────────────
-- Lists the horses in the caller's horse-guild paddock, each with the kinds the
-- CALLER may still train today (so the UI can show per-trainer availability).
--   { ok, horses:[{ horse_id, name, breed, speed, endurance, life, life_cap,
--                   owner_id, mine, can_sprint, can_hurdle, can_groom }] }
create or replace function public.get_guild_paddock(p_device_hash text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_guild   uuid;
    v_today   date := (now() at time zone 'utc')::date;
    v_horses  json;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;
    v_guild := public._horse_guild_of(v_account);
    if v_guild is null then
        return json_build_object('error', 'not_horse_guild');
    end if;

    select coalesce(json_agg(json_build_object(
        'horse_id', h.id, 'name', h.name, 'breed', h.breed,
        'speed', h.speed, 'endurance', h.endurance, 'life', h.life, 'life_cap', h.life_cap,
        'owner_id', p.owner_id, 'mine', (p.owner_id = v_account),
        'can_sprint', not exists (select 1 from public.paddock_training pt
            where pt.horse_id = h.id and pt.trainer_id = v_account and pt.kind = 'sprint' and pt.trained_day >= v_today),
        'can_hurdle', not exists (select 1 from public.paddock_training pt
            where pt.horse_id = h.id and pt.trainer_id = v_account and pt.kind = 'hurdle' and pt.trained_day >= v_today),
        'can_groom', not exists (select 1 from public.paddock_training pt
            where pt.horse_id = h.id and pt.trainer_id = v_account and pt.kind = 'groom' and pt.trained_day >= v_today)
    ) order by p.deposited_at), '[]'::json)
    into v_horses
    from public.guild_paddock p
    join public.horses h on h.id = p.horse_id
    where p.guild_id = v_guild;

    return json_build_object('ok', true, 'horses', v_horses);
end;
$$;
grant execute on function public.get_guild_paddock(text) to anon, authenticated;


-- ── train_paddock_horse ──────────────────────────────────────────────────────────
-- Trains a paddocked horse on behalf of the guild. Gain lands on the OWNER's
-- horse, using the OWNER's session cap and the same formula/ceilings/life rules
-- as train_horse. Cooldown is PER-TRAINER (p_device_hash's account) per kind per
-- UTC day. Also credits the trainer's 'train_sessions' horse-guild mission.
--   returns { ok, kind, stat, gain, life_cost, retired, horse } | { error }
--   errors: account_not_found, not_horse_guild, invalid_kind, not_paddocked,
--           not_same_guild, horse_retired, already_trained, at_ceiling
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

    -- Per-trainer daily cooldown for this kind.
    select trained_day into v_last
    from public.paddock_training
    where horse_id = p_horse_id and trainer_id = v_trainer and kind = p_kind;
    if v_last is not null and v_last >= v_today then
        return json_build_object('error', 'already_trained');
    end if;

    -- Gain uses the OWNER's session cap (their horse / their guild perks).
    v_cap  := public._horse_training_session_cap(v_pad.owner_id);
    v_gain := public._horse_training_gain(p_score, v_cap);

    if p_kind = 'groom' then
        v_stat    := 'life_cap';
        v_ceiling := 200;
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

        v_life_cost := public._horse_training_life_cost(p_score);
        v_new_life  := round(v_horse.life - v_life_cost, 2);
        if v_new_life <= 0 then
            v_new_life := 0;
            v_retired  := true;
            update public.horses set life = 0, status = 'retired' where id = p_horse_id;
            -- A retired horse leaves the paddock automatically.
            delete from public.guild_paddock where horse_id = p_horse_id;
        else
            update public.horses set life = v_new_life where id = p_horse_id;
        end if;
    end if;

    -- Record the per-trainer cooldown.
    insert into public.paddock_training (horse_id, trainer_id, kind, trained_day, sessions, updated_at)
    values (p_horse_id, v_trainer, p_kind, v_today, 1, now())
    on conflict (horse_id, trainer_id, kind) do update
        set trained_day = excluded.trained_day,
            sessions = public.paddock_training.sessions + 1,
            updated_at = now();

    -- Credit the TRAINER's horse-guild 'train_sessions' mission.
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
grant execute on function public.train_paddock_horse(text, uuid, text, int) to anon, authenticated;
