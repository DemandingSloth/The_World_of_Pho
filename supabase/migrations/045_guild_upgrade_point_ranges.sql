-- ============================================================================
-- Migration 045: Randomized guild-mission upgrade-point rewards per difficulty
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Upgrade-point rewards were a flat per-difficulty value (easy 1 / medium 3 /
-- hard 7). They are now a random range rolled at spawn time:
--     easy   : 1–5
--     medium : 15–20
--     hard   : 30–45
--
-- Token rewards (70% of target×price, migration 044) are unchanged. This only
-- changes how reward_upgrade_points is set in the three spawn paths.
-- ============================================================================


-- ── Random upgrade-point reward for a difficulty (rolled per spawn) ──────────
-- VOLATILE (uses random()), so each spawned mission gets its own roll.
create or replace function public._guild_mission_upgrade_points(p_difficulty text)
returns int
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_lo int;
    v_hi int;
begin
    case p_difficulty
        when 'easy'   then v_lo := 1;  v_hi := 5;
        when 'medium' then v_lo := 15; v_hi := 20;
        when 'hard'   then v_lo := 30; v_hi := 45;
        else               v_lo := 1;  v_hi := 5;   -- safety fallback
    end case;
    -- Inclusive random int in [v_lo, v_hi].
    return v_lo + floor(random() * (v_hi - v_lo + 1))::int;
end;
$$;
revoke all on function public._guild_mission_upgrade_points(text) from anon, authenticated;


-- ── _spawn_guild_missions ─────────────────────────────────────────────────────
-- Identical to migration 044 except reward_upgrade_points now uses the ranged
-- roll instead of _guild_mission_base_reward.upgrade_pts.
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

    if v_guild.specialization = 'gardening' then
        v_keys := array[
            'deposit_beans','deposit_cucumbers','deposit_peppers','deposit_squash',
            'deposit_grapes','deposit_sunflower','deposit_cauliflower',
            'deposit_pineapple','deposit_watermelon',
            'deposit_produce','deposit_fruit',
            'deposit_plum','deposit_lemon','deposit_apple','deposit_banana','deposit_coconut'
        ];
    else
        v_keys := array[
            'deposit_gems','deposit_polished','deposit_ores',
            'deposit_gem_gold','deposit_gem_blue_stone','deposit_gem_pink_stone',
            'deposit_gem_violet_stone','deposit_gem_black_pearl','deposit_gem_emerald',
            'deposit_gem_ruby','deposit_gem_diamond',
            'deposit_polished_blue_stone','deposit_polished_pink_stone',
            'deposit_polished_violet_stone','deposit_polished_black_pearl',
            'deposit_polished_emerald','deposit_polished_ruby','deposit_polished_diamond',
            'deposit_ore_iron_ore','deposit_ore_iron_bar','deposit_ore_copper_ore',
            'deposit_ore_copper_ingot','deposit_ore_gold_ingot'
        ];
    end if;

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
        v_target := greatest(ceil(v_base_target::float * v_multiplier)::int, 1) * 15;

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


-- ── reroll_guild_mission ──────────────────────────────────────────────────────
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
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    select * into v_mission from public.guild_missions where id = p_mission_id for update;
    if not found or v_mission.guild_id <> p_guild_id then
        return json_build_object('error', 'mission_not_found');
    end if;
    if v_mission.status <> 'active' then
        return json_build_object('error', 'mission_not_active');
    end if;

    v_difficulty := v_mission.difficulty;

    -- Return deposited items to their owners (escrow) before discarding.
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

    if v_guild.specialization = 'gardening' then
        v_keys := array[
            'deposit_beans','deposit_cucumbers','deposit_peppers','deposit_squash',
            'deposit_grapes','deposit_sunflower','deposit_cauliflower',
            'deposit_pineapple','deposit_watermelon',
            'deposit_produce','deposit_fruit',
            'deposit_plum','deposit_lemon','deposit_apple','deposit_banana','deposit_coconut'
        ];
    else
        v_keys := array[
            'deposit_gems','deposit_polished','deposit_ores',
            'deposit_gem_gold','deposit_gem_blue_stone','deposit_gem_pink_stone',
            'deposit_gem_violet_stone','deposit_gem_black_pearl','deposit_gem_emerald',
            'deposit_gem_ruby','deposit_gem_diamond',
            'deposit_polished_blue_stone','deposit_polished_pink_stone',
            'deposit_polished_violet_stone','deposit_polished_black_pearl',
            'deposit_polished_emerald','deposit_polished_ruby','deposit_polished_diamond',
            'deposit_ore_iron_ore','deposit_ore_iron_bar','deposit_ore_copper_ore',
            'deposit_ore_copper_ingot','deposit_ore_gold_ingot'
        ];
    end if;

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
    v_target := greatest(ceil(v_base_target::float * v_multiplier)::int, 1) * 15;

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

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.reroll_guild_mission(text, uuid, uuid) to anon, authenticated;


-- ── spawn_guild_mission (leader manual spawn) ─────────────────────────────────
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

    if v_guild.specialization = 'gardening' then
        v_keys := array[
            'deposit_beans','deposit_cucumbers','deposit_peppers','deposit_squash',
            'deposit_grapes','deposit_sunflower','deposit_cauliflower',
            'deposit_pineapple','deposit_watermelon',
            'deposit_produce','deposit_fruit',
            'deposit_plum','deposit_lemon','deposit_apple','deposit_banana','deposit_coconut'
        ];
    else
        v_keys := array[
            'deposit_gems','deposit_polished','deposit_ores',
            'deposit_gem_gold','deposit_gem_blue_stone','deposit_gem_pink_stone',
            'deposit_gem_violet_stone','deposit_gem_black_pearl','deposit_gem_emerald',
            'deposit_gem_ruby','deposit_gem_diamond',
            'deposit_polished_blue_stone','deposit_polished_pink_stone',
            'deposit_polished_violet_stone','deposit_polished_black_pearl',
            'deposit_polished_emerald','deposit_polished_ruby','deposit_polished_diamond',
            'deposit_ore_iron_ore','deposit_ore_iron_bar','deposit_ore_copper_ore',
            'deposit_ore_copper_ingot','deposit_ore_gold_ingot'
        ];
    end if;

    v_key := v_keys[1 + floor(random() * array_length(v_keys, 1))::int];

    v_base_target := public._guild_mission_base_target(v_key, p_difficulty);
    if v_base_target is null then v_base_target := 5; end if;
    v_target := greatest(ceil(v_base_target::float * v_multiplier)::int, 1) * 15;

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
