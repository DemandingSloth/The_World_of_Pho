-- ============================================================================
-- Migration 028: reroll_guild_mission RPC
-- ============================================================================
-- Allows any guild member to replace one active guild mission with a freshly
-- generated one of the same difficulty.  The cost (coins) and daily allowance
-- are enforced client-side via PlayerData; the server just validates membership
-- and replaces the row.
--
-- Function:
--   reroll_guild_mission(p_device_hash text, p_guild_id uuid, p_mission_id uuid)
--     → json { ok } or { error }
--
-- Error codes:
--   account_not_found  — device_hash not registered
--   not_in_guild       — caller is not an active member of p_guild_id
--   mission_not_found  — p_mission_id does not belong to this guild
--   mission_not_active — mission is already completed or expired
-- ============================================================================

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
    v_reward         record;
    v_tokens         int;
    v_upgrade_pts    int;
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

    -- Validate the mission exists and belongs to this guild.
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

    -- Delete the old mission and any contribution rows (cascade handled by FK,
    -- but we clean explicitly to be safe).
    delete from public.guild_contributions where mission_id = p_mission_id;
    delete from public.guild_missions      where id         = p_mission_id;

    -- Compute mission multiplier: same formula as _spawn_guild_missions.
    select * into v_guild from public.guilds where id = p_guild_id;

    select count(*) into v_member_count
    from public.guild_members
    where guild_id = p_guild_id and left_at is null;

    v_multiplier := greatest(
        (v_guild.capacity::float + v_member_count::float) / 2.0,
        1.0
    );

    -- Pick reward boost level.
    select coalesce(level, 0) into v_boost_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'mission_reward_boost';
    v_boost_level := coalesce(v_boost_level, 0);

    -- Pick a random mission key (different from the one just removed when possible).
    -- Try up to 5 times to avoid repeating the same key.
    v_new_key := v_mission.base_mission_key;
    declare
        v_attempt int := 0;
    begin
        while v_new_key = v_mission.base_mission_key and v_attempt < 5 loop
            v_new_key := v_all_keys[1 + floor(random() * array_length(v_all_keys, 1))::int];
            v_attempt := v_attempt + 1;
        end loop;
    end;

    -- Scale target.
    v_base_target := public._guild_mission_base_target(v_new_key, v_difficulty);
    if v_base_target is null then
        v_base_target := 5;
    end if;
    v_target := greatest(ceil(v_base_target::float * v_multiplier)::int, 1);

    -- Compute rewards.
    select * into v_reward from public._guild_mission_base_reward(v_difficulty);
    v_tokens      := round(v_reward.tokens      * (1.0 + v_boost_level * 0.10))::int;
    v_upgrade_pts := v_reward.upgrade_pts;

    -- Insert the replacement mission.
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
