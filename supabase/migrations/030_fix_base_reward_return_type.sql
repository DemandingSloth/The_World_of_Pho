-- ============================================================================
-- Migration 030: fix _guild_mission_base_reward return type
-- ============================================================================
-- `_guild_mission_base_reward` was declared as `RETURNS record`, which causes
-- Postgres error "a column definition list is required for function returning
-- record" whenever it is called from PL/pgSQL via SELECT * INTO.
--
-- Fix: change to RETURNS TABLE so callers don't need a column alias, then
-- re-create every function that calls it (_spawn_guild_missions and
-- reroll_guild_mission) with the corrected SELECT syntax.
-- ============================================================================

-- ── 1. Fix the return type ───────────────────────────────────────────────────
-- Must DROP first because PostgreSQL won't let CREATE OR REPLACE change the
-- return type of an existing function.

drop function if exists public._guild_mission_base_reward(text);

create or replace function public._guild_mission_base_reward(p_difficulty text)
returns table(difficulty text, tokens int, upgrade_pts int)
language sql
immutable
security definer
set search_path = public
as $$
    select *
    from (values
        ('easy'::text,   50,  1),
        ('medium'::text, 150, 3),
        ('hard'::text,   400, 7)
    ) as t(difficulty, tokens, upgrade_pts)
    where t.difficulty = p_difficulty;
$$;
revoke all on function public._guild_mission_base_reward(text) from anon, authenticated;


-- ── 2. Re-create _spawn_guild_missions ───────────────────────────────────────
-- Identical to 024 except the reward SELECT is now:
--   SELECT tokens, upgrade_pts INTO v_tokens, v_upgrade_pts
--   FROM public._guild_mission_base_reward(v_difficulty);

create or replace function public._spawn_guild_missions(p_guild_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_guild         public.guilds%rowtype;
    v_member_count  int;
    v_multiplier    float;
    v_boost_level   int := 0;
    v_difficulty    text;
    v_all_keys text[] := array[
        'gems','crops','expeditions','deep_mine','polish','smelt',
        'fruit','chop','sell_polished','sell_bars',
        'game_easy','game_medium','game_hard','game_brutal',
        'beat_wolves','beat_bears','beat_npcs','win_terrain',
        'prospectors','deposit'
    ];
    v_key           text;
    v_base_target   int;
    v_target        int;
    v_tokens        int;
    v_upgrade_pts   int;
begin
    select * into v_guild from public.guilds where id = p_guild_id;
    if not found then return; end if;

    select count(*) into v_member_count
    from public.guild_members
    where guild_id = p_guild_id and left_at is null;

    v_multiplier := greatest(
        (v_guild.capacity::float + v_member_count::float) / 2.0,
        1.0
    );

    select coalesce(level, 0) into v_boost_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'mission_reward_boost';
    v_boost_level := coalesce(v_boost_level, 0);

    foreach v_difficulty in array array['easy','medium','hard'] loop
        -- Skip slots that already have an active mission.
        if exists (
            select 1 from public.guild_missions
            where guild_id  = p_guild_id
              and difficulty = v_difficulty
              and status     = 'active'
        ) then
            continue;
        end if;

        -- Pick a random mission key.
        v_key := v_all_keys[1 + floor(random() * array_length(v_all_keys, 1))::int];

        -- Scale target.
        v_base_target := public._guild_mission_base_target(v_key, v_difficulty);
        if v_base_target is null then
            v_base_target := 5;
        end if;
        v_target := greatest(ceil(v_base_target::float * v_multiplier)::int, 1);

        -- Compute rewards.
        select r.tokens, r.upgrade_pts
        into v_tokens, v_upgrade_pts
        from public._guild_mission_base_reward(v_difficulty) as r;

        v_tokens := round(v_tokens * (1.0 + v_boost_level * 0.10))::int;

        insert into public.guild_missions (
            guild_id, base_mission_key, difficulty,
            target, reward_tokens, reward_upgrade_points,
            status, expires_at
        ) values (
            p_guild_id, v_key, v_difficulty,
            v_target, v_tokens, v_upgrade_pts,
            'active', now() + interval '48 hours'
        );
    end loop;
end;
$$;
revoke all on function public._spawn_guild_missions(uuid) from anon, authenticated;


-- ── 3. Re-create reroll_guild_mission ────────────────────────────────────────
-- Identical to 028 except the reward SELECT uses named columns.

create or replace function public.reroll_guild_mission(
    p_device_hash text,
    p_guild_id    uuid,
    p_mission_id  uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account    uuid;
    v_member     public.guild_members%rowtype;
    v_mission    public.guild_missions%rowtype;
    v_guild      public.guilds%rowtype;
    v_difficulty text;
    v_all_keys   text[] := array[
        'gems','crops','expeditions','deep_mine','polish','smelt',
        'fruit','chop','sell_polished','sell_bars',
        'game_easy','game_medium','game_hard','game_brutal',
        'beat_wolves','beat_bears','beat_npcs','win_terrain',
        'prospectors','deposit'
    ];
    v_new_key        text;
    v_member_count   int;
    v_multiplier     float;
    v_boost_level    int := 0;
    v_base_target    int;
    v_target         int;
    v_tokens         int;
    v_upgrade_pts    int;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    select * into v_mission
    from public.guild_missions
    where id = p_mission_id
    for update;

    if not found or v_mission.guild_id <> p_guild_id then
        return json_build_object('error', 'mission_not_found');
    end if;

    if v_mission.status <> 'active' then
        return json_build_object('error', 'mission_not_active');
    end if;

    v_difficulty := v_mission.difficulty;

    delete from public.guild_contributions where mission_id = p_mission_id;
    delete from public.guild_missions      where id         = p_mission_id;

    select * into v_guild from public.guilds where id = p_guild_id;

    select count(*) into v_member_count
    from public.guild_members
    where guild_id = p_guild_id and left_at is null;

    v_multiplier := greatest(
        (v_guild.capacity::float + v_member_count::float) / 2.0,
        1.0
    );

    select coalesce(level, 0) into v_boost_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'mission_reward_boost';
    v_boost_level := coalesce(v_boost_level, 0);

    v_new_key := v_mission.base_mission_key;
    declare
        v_attempt int := 0;
    begin
        while v_new_key = v_mission.base_mission_key and v_attempt < 5 loop
            v_new_key := v_all_keys[1 + floor(random() * array_length(v_all_keys, 1))::int];
            v_attempt := v_attempt + 1;
        end loop;
    end;

    v_base_target := public._guild_mission_base_target(v_new_key, v_difficulty);
    if v_base_target is null then
        v_base_target := 5;
    end if;
    v_target := greatest(ceil(v_base_target::float * v_multiplier)::int, 1);

    -- Compute rewards using named columns (TABLE return type, no alias needed).
    select r.tokens, r.upgrade_pts
    into v_tokens, v_upgrade_pts
    from public._guild_mission_base_reward(v_difficulty) as r;

    v_tokens := round(v_tokens * (1.0 + v_boost_level * 0.10))::int;

    insert into public.guild_missions (
        guild_id, base_mission_key, difficulty,
        target, reward_tokens, reward_upgrade_points,
        status, expires_at
    ) values (
        p_guild_id, v_new_key, v_difficulty,
        v_target, v_tokens, v_upgrade_pts,
        'active', now() + interval '48 hours'
    );

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.reroll_guild_mission(text, uuid, uuid) to anon, authenticated;
