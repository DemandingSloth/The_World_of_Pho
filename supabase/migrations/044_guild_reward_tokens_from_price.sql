-- ============================================================================
-- Migration 044: Guild mission token rewards = 70% of (target × item price)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Previously reward_tokens came from a flat per-difficulty table
-- (_guild_mission_base_reward). Now a DEPOSIT mission pays tokens based on the
-- value of what it asks for:
--
--     reward_tokens = round(target × suggested_item_price × 0.70)
--
-- e.g. "deposit 100 of an item priced at 10 tokens" → round(100 × 10 × 0.70) =
-- 700 tokens. The guild `mission_reward_boost` upgrade still multiplies on top
-- (+10%/level), and reward_upgrade_points is unchanged (still from
-- _guild_mission_base_reward).
--
-- Prices mirror the client SUGGESTED_LIST_PRICE map. Generic category buckets
-- (deposit_gems / deposit_polished / deposit_ores / deposit_produce /
-- deposit_fruit) use the CHEAPEST item in their category, since the player may
-- satisfy them with the cheap items. Any key with no item price (legacy
-- non-deposit keys that no longer spawn) falls back to the old base-reward
-- tokens so nothing ever pays 0.
--
-- Recreates: _guild_mission_item_price (new), _spawn_guild_missions,
-- reroll_guild_mission, spawn_guild_mission. Bodies otherwise identical to 040.
-- ============================================================================


-- ── Suggested token price per deposit mission key ────────────────────────────
-- 0 means "no item price" → caller falls back to the base-reward tokens.
create or replace function public._guild_mission_item_price(p_key text)
returns int
language sql
immutable
security definer
set search_path = public
as $$
    select coalesce((
        select price from (values
            -- Generic buckets → cheapest item in the category.
            ('deposit_gems',       6),    -- gold
            ('deposit_polished',   76),   -- blue/pink polished
            ('deposit_ores',       76),   -- iron_ore (cheapest gem-group resource)
            ('deposit_produce',    2),    -- beans
            ('deposit_fruit',      51),   -- plum

            -- Per unpolished gem
            ('deposit_gem_gold',          6),
            ('deposit_gem_blue_stone',    8),
            ('deposit_gem_pink_stone',    8),
            ('deposit_gem_violet_stone',  11),
            ('deposit_gem_black_pearl',   16),
            ('deposit_gem_emerald',       21),
            ('deposit_gem_ruby',          31),
            ('deposit_gem_diamond',       51),

            -- Per polished gem
            ('deposit_polished_blue_stone',   76),
            ('deposit_polished_pink_stone',   76),
            ('deposit_polished_violet_stone', 101),
            ('deposit_polished_black_pearl',  151),
            ('deposit_polished_emerald',      201),
            ('deposit_polished_ruby',         301),
            ('deposit_polished_diamond',      501),

            -- Per ore / bar / ingot
            ('deposit_ore_iron_ore',      76),
            ('deposit_ore_iron_bar',      751),
            ('deposit_ore_copper_ore',    101),
            ('deposit_ore_copper_ingot',  1001),
            ('deposit_ore_gold_ingot',    2501),

            -- Per garden crop
            ('deposit_beans',        2),
            ('deposit_cucumbers',    5),
            ('deposit_peppers',      7),
            ('deposit_squash',       12),
            ('deposit_grapes',       16),
            ('deposit_sunflower',    20),
            ('deposit_cauliflower',  24),
            ('deposit_pineapple',    27),
            ('deposit_watermelon',   31),

            -- Per orchard fruit
            ('deposit_plum',     51),
            ('deposit_lemon',    101),
            ('deposit_apple',    151),
            ('deposit_banana',   201),
            ('deposit_coconut',  251)
        ) as t(key, price)
        where t.key = p_key
    ), 0);
$$;
revoke all on function public._guild_mission_item_price(text) from anon, authenticated;


-- Shared token-reward formula used by all three spawn paths. Keeps the behavior
-- in one place: price-based (70%) when the key has an item price, else the old
-- base-reward tokens. The mission_reward_boost multiplier is applied by callers
-- (they already fetch v_boost_level), matching the prior behavior.
create or replace function public._guild_reward_tokens_for(
    p_key        text,
    p_difficulty text,
    p_target     int
)
returns int
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_price  int;
    v_tokens int;
begin
    v_price := public._guild_mission_item_price(p_key);
    if v_price > 0 then
        -- 70% of the deposited value.
        v_tokens := round(p_target::float * v_price::float * 0.70)::int;
        return greatest(v_tokens, 1);
    end if;
    -- Fallback: legacy / non-deposit keys keep the old base-reward tokens.
    select tokens into v_tokens from public._guild_mission_base_reward(p_difficulty);
    return coalesce(v_tokens, 0);
end;
$$;
revoke all on function public._guild_reward_tokens_for(text, text, int) from anon, authenticated;


-- ── _spawn_guild_missions ─────────────────────────────────────────────────────
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

        -- Token reward: 70% of (target × item price); upgrade points unchanged.
        v_tokens := public._guild_reward_tokens_for(v_key, v_difficulty, v_target);
        v_tokens := round(v_tokens * (1.0 + v_boost_level * 0.10))::int;
        select upgrade_pts into v_upgrade_pts from public._guild_mission_base_reward(v_difficulty);

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
-- Identical to 042's reroll (which added the refund) except reward_tokens now
-- uses the price-based formula. (Keeps the _guild_refund_contributions call.)
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
    select upgrade_pts into v_upgrade_pts from public._guild_mission_base_reward(v_difficulty);

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
    select upgrade_pts into v_upgrade_pts from public._guild_mission_base_reward(p_difficulty);

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
