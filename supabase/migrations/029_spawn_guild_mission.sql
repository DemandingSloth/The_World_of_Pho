-- ============================================================================
-- Migration 029: spawn_guild_mission RPC
-- ============================================================================
-- Allows a guild leader to manually spawn a mission into a specific difficulty
-- slot (easy / medium / hard) when that slot is currently empty.
-- The logic mirrors _spawn_guild_missions but targets one slot and is callable
-- by authenticated clients.
--
-- Function:
--   spawn_guild_mission(p_device_hash text, p_guild_id uuid, p_difficulty text)
--     → json { ok } or { error }
--
-- Error codes:
--   account_not_found  — device_hash not registered
--   not_in_guild       — caller is not an active member of p_guild_id
--   not_leader         — caller is not the guild leader
--   invalid_difficulty — p_difficulty is not 'easy', 'medium', or 'hard'
--   slot_occupied      — an active mission already exists for this difficulty
-- ============================================================================

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
    v_all_keys     text[] := array[
        'gems','crops','expeditions','deep_mine','polish','smelt',
        'fruit','chop','sell_polished','sell_bars',
        'game_easy','game_medium','game_hard','game_brutal',
        'beat_wolves','beat_bears','beat_npcs','win_terrain',
        'prospectors','deposit'
    ];
    v_key          text;
    v_base_target  int;
    v_target       int;
    v_tokens       int;
    v_upgrade_pts  int;
begin
    -- Resolve caller.
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    -- Must be an active member of the given guild.
    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    -- Leader only.
    if v_member.role <> 'leader' then
        return json_build_object('error', 'not_leader');
    end if;

    -- Validate difficulty.
    if p_difficulty not in ('easy', 'medium', 'hard') then
        return json_build_object('error', 'invalid_difficulty');
    end if;

    -- Slot must be empty.
    if exists (
        select 1 from public.guild_missions
        where guild_id  = p_guild_id
          and difficulty = p_difficulty
          and status     = 'active'
    ) then
        return json_build_object('error', 'slot_occupied');
    end if;

    -- Load guild + member count for multiplier.
    select * into v_guild from public.guilds where id = p_guild_id;

    select count(*) into v_member_count
    from public.guild_members
    where guild_id = p_guild_id and left_at is null;

    v_multiplier := greatest(
        (v_guild.capacity::float + v_member_count::float) / 2.0,
        1.0
    );

    -- Reward boost level.
    select coalesce(level, 0) into v_boost_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'mission_reward_boost';
    v_boost_level := coalesce(v_boost_level, 0);

    -- Pick a random mission key.
    v_key := v_all_keys[1 + floor(random() * array_length(v_all_keys, 1))::int];

    -- Scale target.
    v_base_target := public._guild_mission_base_target(v_key, p_difficulty);
    if v_base_target is null then
        v_base_target := 5;
    end if;
    v_target := greatest(ceil(v_base_target::float * v_multiplier)::int, 1);

    -- Compute rewards.
    select tokens, upgrade_pts
    into v_tokens, v_upgrade_pts
    from public._guild_mission_base_reward(p_difficulty)
        as r(difficulty text, tokens int, upgrade_pts int);
    v_tokens := round(v_tokens * (1.0 + v_boost_level * 0.10))::int;

    -- Insert the new mission.
    insert into public.guild_missions (
        guild_id, base_mission_key, difficulty,
        target, reward_tokens, reward_upgrade_points,
        status, expires_at
    ) values (
        p_guild_id, v_key, p_difficulty,
        v_target, v_tokens, v_upgrade_pts,
        'active', now() + interval '48 hours'
    );

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.spawn_guild_mission(text, uuid, text) to anon, authenticated;
