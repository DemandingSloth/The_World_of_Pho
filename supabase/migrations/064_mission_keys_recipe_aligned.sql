-- ============================================================================
-- Migration 064: Mining guild missions only ask for recipe-relevant materials
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Mining-guild deposit missions used to ask for ANY gem/ore/bar, including raw
-- ores (iron_ore, copper_ore) and raw gems that the jewelry recipes never use.
-- Players found this confusing (a "Deposit Ores" mission accepting ingots, etc).
--
-- New rule: mining missions may ONLY ask for materials the production recipes
-- actually consume:
--   • Polished gems — all 7 polishable (blue_stone, pink_stone, violet_stone,
--     black_pearl, emerald, ruby, diamond) + the generic 'deposit_polished'.
--   • Raw GOLD only (gem:gold) — gold isn't polishable, so recipes use it raw.
--   • Bars/ingots used in recipes: iron_bar, copper_ingot, gold_ingot.
-- Explicitly REMOVED: the generic raw buckets 'deposit_gems' and 'deposit_ores'
-- (the latter mixed ores+bars — the source of the "ores accepting ingots" bug),
-- every raw gem except gold, and raw ores (iron_ore, copper_ore).
--
-- Recipe inputs this is derived from (player_data.gd ITEM_DEFS):
--   gold_ring:            gem:gold, resource:gold_ingot
--   blue_stone_necklace:  polished:blue_stone, resource:iron_bar
--   pink_stone_necklace:  polished:pink_stone, resource:iron_bar
--   violet_stone_ring:    polished:violet_stone, resource:copper_ingot
--   black_pearl_necklace: polished:black_pearl, resource:copper_ingot
--   emerald_necklace:     polished:emerald, resource:gold_ingot
--   ruby_ring:            polished:ruby, resource:gold_ingot
--   diamond_ring:         polished:diamond, resource:gold_ingot
--
-- The pool now lives in ONE helper (_guild_mission_key_pool) that the three
-- spawners call, so future tweaks are a one-line change. Gardening is unchanged.
-- Supersedes the inline v_keys arrays in migration 045.
-- ============================================================================


-- ── _guild_mission_key_pool ───────────────────────────────────────────────────
-- Single source of truth for which base_mission_keys a guild may be assigned,
-- by specialization. Mining is restricted to recipe-relevant materials.
create or replace function public._guild_mission_key_pool(p_spec text)
returns text[]
language sql
immutable
as $$
    select case
        when p_spec = 'gardening' then array[
            'deposit_beans','deposit_cucumbers','deposit_peppers','deposit_squash',
            'deposit_grapes','deposit_sunflower','deposit_cauliflower',
            'deposit_pineapple','deposit_watermelon',
            'deposit_produce','deposit_fruit',
            'deposit_plum','deposit_lemon','deposit_apple','deposit_banana','deposit_coconut'
        ]
        else array[
            -- Polished gems (recipe inputs) + the generic polished bucket.
            'deposit_polished',
            'deposit_polished_blue_stone','deposit_polished_pink_stone',
            'deposit_polished_violet_stone','deposit_polished_black_pearl',
            'deposit_polished_emerald','deposit_polished_ruby','deposit_polished_diamond',
            -- Raw gold (gold isn't polishable; recipes use it raw).
            'deposit_gem_gold',
            -- Bars/ingots the recipes consume.
            'deposit_ore_iron_bar','deposit_ore_copper_ingot','deposit_ore_gold_ingot'
        ]
    end;
$$;
revoke all on function public._guild_mission_key_pool(text) from anon, authenticated;


-- ── _spawn_guild_missions (uses the helper) ──────────────────────────────────
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


-- ── reroll_guild_mission (uses the helper) ───────────────────────────────────
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


-- ── spawn_guild_mission (leader manual spawn; uses the helper) ────────────────
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
