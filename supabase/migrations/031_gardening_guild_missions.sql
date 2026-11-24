-- ============================================================================
-- Migration 031: gardening guild missions — per-crop deposit keys
-- ============================================================================
-- Gardening guilds now only receive crop-specific deposit missions:
--   deposit_beans, deposit_cucumbers, deposit_peppers, deposit_squash,
--   deposit_grapes, deposit_sunflower, deposit_cauliflower, deposit_pineapple,
--   deposit_watermelon
--
-- Mining guilds keep the original generic key pool (unchanged).
--
-- Changes:
--   1. _guild_mission_base_target  — add per-crop deposit keys
--   2. _spawn_guild_missions       — pick from spec-appropriate key list
--   3. reroll_guild_mission        — same spec-aware key list
--   4. spawn_guild_mission         — same
--   5. record_guild_contribution   — accept deposit_<crop> keys
-- ============================================================================


-- ── 1. Add per-crop deposit keys to the target table ─────────────────────────

create or replace function public._guild_mission_base_target(
    p_key        text,
    p_difficulty text
)
returns int
language sql
immutable
security definer
set search_path = public
as $$
    select case p_difficulty
        when 'easy'   then t.easy_target
        when 'medium' then t.medium_target
        else               t.hard_target
    end
    from (values
        -- generic keys (mining guilds + legacy)
        ('gems',              3,    10,     25),
        ('crops',             3,    10,     25),
        ('expeditions',       1,     3,      8),
        ('deep_mine',        10,    40,    100),
        ('polish',            5,    20,     60),
        ('smelt',             5,    20,     60),
        ('fruit',             5,    20,     60),
        ('chop',              2,     5,     12),
        ('sell_polished',     3,    10,     30),
        ('sell_bars',         2,     8,     20),
        ('game_easy',         1,     3,      8),
        ('game_medium',       1,     2,      5),
        ('game_hard',         1,     2,      4),
        ('game_brutal',       1,     1,      2),
        ('beat_wolves',       2,     5,     15),
        ('beat_bears',        2,     5,     15),
        ('beat_npcs',         2,     5,     15),
        ('win_terrain',       1,     3,      8),
        ('prospectors',       2,     5,     10),
        ('deposit',           3,    10,     25),
        -- per-crop deposit keys (gardening guilds)
        ('deposit_beans',        5,    20,     50),
        ('deposit_cucumbers',    4,    15,     40),
        ('deposit_peppers',      4,    15,     35),
        ('deposit_squash',       3,    12,     30),
        ('deposit_grapes',       3,    10,     25),
        ('deposit_sunflower',    3,    10,     25),
        ('deposit_cauliflower',  2,     8,     20),
        ('deposit_pineapple',    2,     7,     18),
        ('deposit_watermelon',   2,     6,     15)
    ) as t(key, easy_target, medium_target, hard_target)
    where t.key = p_key;
$$;
revoke all on function public._guild_mission_base_target(text, text) from anon, authenticated;


-- ── 2. _spawn_guild_missions — spec-aware key list ────────────────────────────

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

    v_multiplier := greatest(
        (v_guild.capacity::float + v_member_count::float) / 2.0,
        1.0
    );

    select coalesce(level, 0) into v_boost_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'mission_reward_boost';
    v_boost_level := coalesce(v_boost_level, 0);

    -- Choose key pool based on guild specialization.
    if v_guild.specialization = 'gardening' then
        v_keys := array[
            'deposit_beans','deposit_cucumbers','deposit_peppers','deposit_squash',
            'deposit_grapes','deposit_sunflower','deposit_cauliflower',
            'deposit_pineapple','deposit_watermelon'
        ];
    else
        v_keys := array[
            'gems','expeditions','deep_mine','polish','smelt',
            'sell_polished','sell_bars','game_easy','game_medium','game_hard',
            'game_brutal','beat_wolves','beat_bears','beat_npcs','win_terrain',
            'prospectors','deposit'
        ];
    end if;

    foreach v_difficulty in array array['easy','medium','hard'] loop
        if exists (
            select 1 from public.guild_missions
            where guild_id  = p_guild_id
              and difficulty = v_difficulty
              and status     = 'active'
        ) then
            continue;
        end if;

        v_key := v_keys[1 + floor(random() * array_length(v_keys, 1))::int];

        v_base_target := public._guild_mission_base_target(v_key, v_difficulty);
        if v_base_target is null then
            v_base_target := 5;
        end if;
        v_target := greatest(ceil(v_base_target::float * v_multiplier)::int, 1) * 15;

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


-- ── 3. reroll_guild_mission — spec-aware key list ─────────────────────────────

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

    if v_guild.specialization = 'gardening' then
        v_keys := array[
            'deposit_beans','deposit_cucumbers','deposit_peppers','deposit_squash',
            'deposit_grapes','deposit_sunflower','deposit_cauliflower',
            'deposit_pineapple','deposit_watermelon'
        ];
    else
        v_keys := array[
            'gems','expeditions','deep_mine','polish','smelt',
            'sell_polished','sell_bars','game_easy','game_medium','game_hard',
            'game_brutal','beat_wolves','beat_bears','beat_npcs','win_terrain',
            'prospectors','deposit'
        ];
    end if;

    -- Pick a new key, try up to 5 times to avoid repeating the same one.
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


-- ── 4. spawn_guild_mission — spec-aware key list ──────────────────────────────

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
        where guild_id  = p_guild_id
          and difficulty = p_difficulty
          and status     = 'active'
    ) then
        return json_build_object('error', 'slot_occupied');
    end if;

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

    if v_guild.specialization = 'gardening' then
        v_keys := array[
            'deposit_beans','deposit_cucumbers','deposit_peppers','deposit_squash',
            'deposit_grapes','deposit_sunflower','deposit_cauliflower',
            'deposit_pineapple','deposit_watermelon'
        ];
    else
        v_keys := array[
            'gems','expeditions','deep_mine','polish','smelt',
            'sell_polished','sell_bars','game_easy','game_medium','game_hard',
            'game_brutal','beat_wolves','beat_bears','beat_npcs','win_terrain',
            'prospectors','deposit'
        ];
    end if;

    v_key := v_keys[1 + floor(random() * array_length(v_keys, 1))::int];

    v_base_target := public._guild_mission_base_target(v_key, p_difficulty);
    if v_base_target is null then v_base_target := 5; end if;
    v_target := greatest(ceil(v_base_target::float * v_multiplier)::int, 1) * 15;

    select r.tokens, r.upgrade_pts
    into v_tokens, v_upgrade_pts
    from public._guild_mission_base_reward(p_difficulty) as r;
    v_tokens := round(v_tokens * (1.0 + v_boost_level * 0.10))::int;

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


-- ── 5. record_guild_contribution — accept deposit_<crop> keys ────────────────
-- The existing function matches missions by base_mission_key = p_base_key, so
-- passing 'deposit_beans' will naturally match only deposit_beans missions.
-- No change needed to the function body — this comment documents the intent.
-- (Re-creating it here anyway to keep the migration self-contained and ensure
--  the probation guard and fire-and-forget semantics are preserved.)

create or replace function public.record_guild_contribution(
    p_device_hash text,
    p_guild_id    uuid,
    p_base_key    text,
    p_amount      int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account  uuid;
    v_member   public.guild_members%rowtype;
    v_mission  record;
    v_new_prog int;
begin
    if p_amount is null or p_amount <= 0 then
        return json_build_object('ok', true);
    end if;

    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('ok', true);
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('ok', true);
    end if;

    -- Probation guard.
    if v_member.perks_active_at is not null
       and v_member.perks_active_at > extract(epoch from now()) then
        return json_build_object('ok', true);
    end if;

    for v_mission in
        select id, target, progress
        from public.guild_missions
        where guild_id = p_guild_id
          and base_mission_key = p_base_key
          and status = 'active'
        for update
    loop
        insert into public.guild_contributions (mission_id, account_id, amount, updated_at)
        values (v_mission.id, v_account, p_amount, now())
        on conflict (mission_id, account_id)
        do update set
            amount     = public.guild_contributions.amount + excluded.amount,
            updated_at = now();

        v_new_prog := least(v_mission.progress + p_amount, v_mission.target);

        update public.guild_missions
        set progress = v_new_prog
        where id = v_mission.id;

        if v_new_prog >= v_mission.target then
            perform public._complete_guild_mission(v_mission.id);
        end if;
    end loop;

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.record_guild_contribution(text, uuid, text, int) to anon, authenticated;
