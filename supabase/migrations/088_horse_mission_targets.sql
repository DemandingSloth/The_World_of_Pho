-- ============================================================================
-- Migration 088: Fix horse-guild mission targets (Task 10b tuning)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 064 + 066 + 078 (horse guild spec + keys) already applied.
--
-- Horse-guild activity missions ('race_wins', 'train_sessions') use the same
-- `× v_multiplier × 15` scaling as deposit missions.  That is fine for crops/
-- gems (each member can deposit hundreds), but completely wrong for race wins and
-- training sessions — nobody can win 90 races in 48 hours.
--
-- New flat FINAL targets (random within the range; no multiplier or ×15):
--   race_wins      easy 1–2    medium 3–5    hard  6–9
--   train_sessions easy 2–4    medium 6–10   hard 12–18
--
-- All other keys continue to use the existing `ceil(base × mult) × 15` formula
-- unchanged.  The same fix is applied to all three spawners:
--     _spawn_guild_missions, reroll_guild_mission, spawn_guild_mission.
-- ============================================================================


-- ── Target helper: horse keys use flat random ranges; everything else scales ───
-- Centralises the one-liner target calculation so future target tweaks are a
-- single-function change.
create or replace function public._guild_mission_scaled_target(
    p_key         text,
    p_difficulty  text,
    p_base_target int,
    p_multiplier  float
)
returns int
language plpgsql
immutable
as $$
declare
    lo int;
    hi int;
begin
    -- Horse activity keys: fixed random range, no multiplier, no ×15.
    if p_key = 'race_wins' then
        case p_difficulty
            when 'easy'   then lo := 1;  hi := 2;
            when 'medium' then lo := 3;  hi := 5;
            else               lo := 6;  hi := 9;
        end case;
        return lo + floor(random() * (hi - lo + 1))::int;
    end if;

    if p_key = 'train_sessions' then
        case p_difficulty
            when 'easy'   then lo := 2;  hi := 4;
            when 'medium' then lo := 6;  hi := 10;
            else               lo := 12; hi := 18;
        end case;
        return lo + floor(random() * (hi - lo + 1))::int;
    end if;

    -- All other keys: existing scaled formula.
    return greatest(ceil(p_base_target::float * p_multiplier)::int, 1) * 15;
end;
$$;
revoke all on function public._guild_mission_scaled_target(text, text, int, float) from anon, authenticated;


-- ── _spawn_guild_missions REWORKED (supersedes 064/078) ──────────────────────
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
    v_keys          text[];
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

    v_multiplier := greatest((v_guild.capacity::float + v_member_count::float) / 2.0, 1.0);

    select coalesce(level, 0) into v_boost_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'mission_reward_boost';
    v_boost_level := coalesce(v_boost_level, 0);

    v_keys := public._guild_mission_key_pool(v_guild.specialization);

    foreach v_difficulty in array array['easy','medium','hard'] loop
        if exists (
            select 1 from public.guild_missions
            where guild_id = p_guild_id and difficulty = v_difficulty and status = 'active'
        ) then
            continue;
        end if;

        v_key := v_keys[1 + floor(random() * array_length(v_keys, 1))::int];

        v_base_target := public._guild_mission_base_target(v_key, v_difficulty);
        if v_base_target is null then v_base_target := 5; end if;
        v_target := public._guild_mission_scaled_target(v_key, v_difficulty, v_base_target, v_multiplier);

        v_tokens := public._guild_reward_tokens_for(v_key, v_difficulty, v_target);
        v_tokens := round(v_tokens * (1.0 + v_boost_level * 0.10))::int;
        v_upgrade_pts := public._guild_mission_upgrade_points(v_difficulty);

        insert into public.guild_missions (
            guild_id, base_mission_key, difficulty,
            target, reward_tokens, reward_upgrade_points, status, expires_at
        ) values (
            p_guild_id, v_key, v_difficulty,
            v_target, v_tokens, v_upgrade_pts, 'active', now() + interval '48 hours'
        );
    end loop;
end;
$$;
revoke all on function public._spawn_guild_missions(uuid) from anon, authenticated;


-- ── reroll_guild_mission REWORKED (supersedes 066) ───────────────────────────
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
    v_account        uuid;
    v_member         public.guild_members%rowtype;
    v_mission        public.guild_missions%rowtype;
    v_guild          public.guilds%rowtype;
    v_difficulty     text;
    v_keys           text[];
    v_new_key        text;
    v_member_count   int;
    v_multiplier     float;
    v_boost_level    int := 0;
    v_base_target    int;
    v_target         int;
    v_tokens         int;
    v_upgrade_pts    int;
    v_today          int;
    v_used           int;
    v_cost           int;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    select * into v_guild from public.guilds where id = p_guild_id for update;
    if not found then
        return json_build_object('error', 'not_in_guild');
    end if;
    if v_guild.leader_id is distinct from v_account then
        return json_build_object('error', 'not_leader');
    end if;

    select * into v_mission from public.guild_missions where id = p_mission_id for update;
    if not found or v_mission.guild_id <> p_guild_id then
        return json_build_object('error', 'mission_not_found');
    end if;
    if v_mission.status <> 'active' then
        return json_build_object('error', 'mission_not_active');
    end if;

    v_today := floor(extract(epoch from now()) / 86400.0)::int;
    v_used  := case when v_guild.reroll_day = v_today then v_guild.reroll_count else 0 end;
    v_cost  := public._guild_reroll_cost(v_used);

    if v_guild.upgrade_points < v_cost then
        return json_build_object('error', 'insufficient_points',
            'cost', v_cost, 'points_remaining', v_guild.upgrade_points);
    end if;

    update public.guilds
    set upgrade_points = upgrade_points - v_cost,
        reroll_count   = v_used + 1,
        reroll_day     = v_today
    where id = p_guild_id;

    v_difficulty := v_mission.difficulty;

    perform public._guild_refund_contributions(p_mission_id);

    delete from public.guild_contributions where mission_id = p_mission_id;
    delete from public.guild_missions      where id         = p_mission_id;

    select * into v_guild from public.guilds where id = p_guild_id;

    select count(*) into v_member_count
    from public.guild_members
    where guild_id = p_guild_id and left_at is null;

    v_multiplier := greatest((v_guild.capacity::float + v_member_count::float) / 2.0, 1.0);

    select coalesce(level, 0) into v_boost_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'mission_reward_boost';
    v_boost_level := coalesce(v_boost_level, 0);

    v_keys := public._guild_mission_key_pool(v_guild.specialization);

    v_new_key := v_mission.base_mission_key;
    declare
        v_attempt int := 0;
    begin
        while v_new_key = v_mission.base_mission_key and v_attempt < 5 loop
            v_new_key := v_keys[1 + floor(random() * array_length(v_keys, 1))::int];
            v_attempt := v_attempt + 1;
        end loop;
    end;

    v_base_target := public._guild_mission_base_target(v_new_key, v_difficulty);
    if v_base_target is null then v_base_target := 5; end if;
    v_target := public._guild_mission_scaled_target(v_new_key, v_difficulty, v_base_target, v_multiplier);

    v_tokens := public._guild_reward_tokens_for(v_new_key, v_difficulty, v_target);
    v_tokens := round(v_tokens * (1.0 + v_boost_level * 0.10))::int;
    v_upgrade_pts := public._guild_mission_upgrade_points(v_difficulty);

    insert into public.guild_missions (
        guild_id, base_mission_key, difficulty,
        target, reward_tokens, reward_upgrade_points, status, expires_at
    ) values (
        p_guild_id, v_new_key, v_difficulty,
        v_target, v_tokens, v_upgrade_pts, 'active', now() + interval '48 hours'
    );

    return json_build_object(
        'ok', true,
        'cost', v_cost,
        'next_cost', public._guild_reroll_cost(v_used + 1),
        'points_remaining', v_guild.upgrade_points,
        'rerolls_used', v_used + 1
    );
end;
$$;
grant execute on function public.reroll_guild_mission(text, uuid, uuid) to anon, authenticated;


-- ── spawn_guild_mission REWORKED (supersedes 064) ────────────────────────────
create or replace function public.spawn_guild_mission(
    p_device_hash text,
    p_guild_id    uuid,
    p_difficulty  text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account      uuid;
    v_member       public.guild_members%rowtype;
    v_guild        public.guilds%rowtype;
    v_member_count int;
    v_multiplier   float;
    v_boost_level  int := 0;
    v_keys         text[];
    v_key          text;
    v_base_target  int;
    v_target       int;
    v_tokens       int;
    v_upgrade_pts  int;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;
    if v_member.role <> 'leader' then
        return json_build_object('error', 'not_leader');
    end if;
    if p_difficulty not in ('easy', 'medium', 'hard') then
        return json_build_object('error', 'invalid_difficulty');
    end if;
    if exists (
        select 1 from public.guild_missions
        where guild_id = p_guild_id and difficulty = p_difficulty and status = 'active'
    ) then
        return json_build_object('error', 'slot_occupied');
    end if;

    select * into v_guild from public.guilds where id = p_guild_id;

    select count(*) into v_member_count
    from public.guild_members
    where guild_id = p_guild_id and left_at is null;

    v_multiplier := greatest((v_guild.capacity::float + v_member_count::float) / 2.0, 1.0);

    select coalesce(level, 0) into v_boost_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'mission_reward_boost';
    v_boost_level := coalesce(v_boost_level, 0);

    v_keys := public._guild_mission_key_pool(v_guild.specialization);

    v_key := v_keys[1 + floor(random() * array_length(v_keys, 1))::int];

    v_base_target := public._guild_mission_base_target(v_key, p_difficulty);
    if v_base_target is null then v_base_target := 5; end if;
    v_target := public._guild_mission_scaled_target(v_key, p_difficulty, v_base_target, v_multiplier);

    v_tokens := public._guild_reward_tokens_for(v_key, p_difficulty, v_target);
    v_tokens := round(v_tokens * (1.0 + v_boost_level * 0.10))::int;
    v_upgrade_pts := public._guild_mission_upgrade_points(p_difficulty);

    insert into public.guild_missions (
        guild_id, base_mission_key, difficulty,
        target, reward_tokens, reward_upgrade_points, status, expires_at
    ) values (
        p_guild_id, v_key, p_difficulty,
        v_target, v_tokens, v_upgrade_pts, 'active', now() + interval '48 hours'
    );

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.spawn_guild_mission(text, uuid, text) to anon, authenticated;
