-- ============================================================================
-- Guilds Task 3: mission, upgrade, and linking RPCs
-- ============================================================================
-- Run AFTER 022_guilds_tables.sql and 023_guilds_core_rpcs.sql.
--
-- Functions created here:
--   get_guild_missions           — fetch active missions for the caller's guild
--   accept_guild_mission         — member opts in to track a mission locally
--   record_guild_contribution    — fire-and-forget progress increment from client
--   _complete_guild_mission      — internal: finalize + distribute rewards
--   _spawn_guild_missions        — internal: fill empty difficulty slots
--   purchase_guild_upgrade       — leader spends upgrade_points on a track
--   request_guild_link           — leader sends a link request to another guild
--   accept_guild_link            — target leader accepts a pending request
--   remove_guild_link            — either leader severs an active link
--   get_effective_guild_perks    — returns own + cross-spec perk table
-- ============================================================================

-- ── Upgrade cost table ───────────────────────────────────────────────────────
-- Cost in upgrade_points per level (level 1→10).
-- Levels are 0-indexed: cost[i] is the cost to go from level i to i+1.
-- Stored as a helper function so it can be called from purchase_guild_upgrade.
create or replace function public._guild_upgrade_cost(p_level int)
returns int
language sql
immutable
security definer
set search_path = public
as $$
    -- 50 → 250 → 1,250 → 5,000 → 15,000 → 50,000 → 150,000 → 300,000 → 600,000 → 1,000,000
    select (array[50, 250, 1250, 5000, 15000, 50000, 150000, 300000, 600000, 1000000])[least(greatest(p_level, 0), 9) + 1];
$$;
revoke all on function public._guild_upgrade_cost(int) from anon, authenticated;


-- ── Mission reward table ─────────────────────────────────────────────────────
-- Base token reward and upgrade-point reward per difficulty.
-- Scaled up by _guild_mission_reward_boost (upgrade level).
create or replace function public._guild_mission_base_reward(p_difficulty text)
returns record
language sql
immutable
security definer
set search_path = public
as $$
    select *
    from (values
        ('easy',   50,  1),
        ('medium', 150, 3),
        ('hard',   400, 7)
    ) as t(difficulty, tokens, upgrade_pts)
    where t.difficulty = p_difficulty;
$$;
revoke all on function public._guild_mission_base_reward(text) from anon, authenticated;


-- ── Base mission targets per difficulty ──────────────────────────────────────
-- Returns an approximate target count for a given base_mission_key + difficulty
-- BEFORE the mission_multiplier is applied.  These mirror solo MissionBoard
-- AMOUNT_RANGES midpoints and are intentionally generous.
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
        -- key,               easy, medium, hard
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
        ('deposit',           3,    10,     25)
    ) as t(key, easy_target, medium_target, hard_target)
    where t.key = p_key;
$$;
revoke all on function public._guild_mission_base_target(text, text) from anon, authenticated;


-- ── _spawn_guild_missions ─────────────────────────────────────────────────────
-- Fills any empty easy/medium/hard slots with freshly generated missions.
-- Called after a mission completes or expires.  Picks a random base_mission_key
-- for each empty slot and scales the target by the guild's mission_multiplier
-- ((capacity + member_count) / 2).
-- Also applies 'mission_reward_boost' upgrade if present.
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
    v_reward        record;
begin
    select * into v_guild from public.guilds where id = p_guild_id;
    if not found then return; end if;

    select count(*) into v_member_count
    from public.guild_members
    where guild_id = p_guild_id and left_at is null;

    -- mission_multiplier = (capacity + member_count) / 2  (min 1.0)
    v_multiplier := greatest(
        (v_guild.capacity::float + v_member_count::float) / 2.0,
        1.0
    );

    -- Check mission_reward_boost upgrade level for token multiplier.
    select coalesce(level, 0) into v_boost_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'mission_reward_boost';

    for v_difficulty in select unnest(array['easy','medium','hard'])
    loop
        -- Skip if this slot is already occupied.
        if exists (
            select 1 from public.guild_missions
            where guild_id = p_guild_id
              and difficulty = v_difficulty
              and status = 'active'
        ) then
            continue;
        end if;

        -- Pick a random key.
        v_key := v_all_keys[1 + floor(random() * array_length(v_all_keys, 1))::int];

        -- Base target scaled by multiplier.
        v_base_target := public._guild_mission_base_target(v_key, v_difficulty);
        if v_base_target is null then
            v_base_target := 5;
        end if;
        v_target := greatest(ceil(v_base_target::float * v_multiplier)::int, 1);

        -- Reward (tokens boosted by upgrade level: +10% per level).
        select * into v_reward from public._guild_mission_base_reward(v_difficulty);
        v_tokens      := round(v_reward.tokens      * (1.0 + v_boost_level * 0.10))::int;
        v_upgrade_pts := v_reward.upgrade_pts;

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


-- ── _complete_guild_mission ───────────────────────────────────────────────────
-- Internal: marks a mission completed, distributes rewards, then spawns a
-- replacement.  Called inside record_guild_contribution when progress >= target.
create or replace function public._complete_guild_mission(p_mission_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_guild_id uuid;
begin
    -- Mark completed (guard against double-completion under concurrent calls).
    update public.guild_missions
    set status = 'completed', completed_at = now()
    where id = p_mission_id
      and status = 'active'
      and progress >= target;

    if not found then return; end if;

    -- Distribute token rewards + upgrade points.
    perform public._guild_distribute_reward(p_mission_id);

    -- Spawn a fresh mission in this difficulty slot.
    select guild_id into v_guild_id from public.guild_missions where id = p_mission_id;
    if v_guild_id is not null then
        perform public._spawn_guild_missions(v_guild_id);
    end if;
end;
$$;
revoke all on function public._complete_guild_mission(uuid) from anon, authenticated;


-- ── get_guild_missions ────────────────────────────────────────────────────────
-- Lighter fetch than get_player_guild_summary — only active missions + caller's
-- contribution amounts.
-- Returns json: { missions: [ { id, base_mission_key, difficulty, target,
--                                progress, my_contribution, reward_tokens,
--                                reward_upgrade_points, spawned_at, expires_at }
--                             ] }
--         or  : { error }
create or replace function public.get_guild_missions(
    p_device_hash text,
    p_guild_id    uuid
)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_member  public.guild_members%rowtype;
    v_result  json;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    -- Expire stale missions first.
    update public.guild_missions
    set status = 'expired'
    where guild_id = p_guild_id
      and status = 'active'
      and expires_at < now();

    select json_build_object(
        'missions',
        coalesce(json_agg(json_build_object(
            'id',                    gm.id,
            'base_mission_key',      gm.base_mission_key,
            'difficulty',            gm.difficulty,
            'target',                gm.target,
            'progress',              gm.progress,
            'my_contribution',       coalesce(gc.amount, 0),
            'reward_tokens',         gm.reward_tokens,
            'reward_upgrade_points', gm.reward_upgrade_points,
            'spawned_at',            extract(epoch from gm.spawned_at),
            'expires_at',            extract(epoch from gm.expires_at)
        ) order by gm.difficulty), '[]'::json)
    ) into v_result
    from public.guild_missions gm
    left join public.guild_contributions gc
        on gc.mission_id = gm.id and gc.account_id = v_account
    where gm.guild_id = p_guild_id
      and gm.status = 'active';

    return v_result;
end;
$$;
grant execute on function public.get_guild_missions(text, uuid) to anon, authenticated;


-- ── accept_guild_mission ──────────────────────────────────────────────────────
-- Member opts in to a mission — this pre-creates their contribution row at 0 so
-- record_guild_contribution can upsert cleanly.  Purely advisory on the server;
-- the client uses it to show "you've accepted" state.
-- Returns json: { ok } or { error }
create or replace function public.accept_guild_mission(
    p_device_hash text,
    p_mission_id  uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_member  public.guild_members%rowtype;
    v_mission public.guild_missions%rowtype;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null then
        return json_build_object('error', 'not_in_guild');
    end if;

    select * into v_mission from public.guild_missions where id = p_mission_id;
    if not found then
        return json_build_object('error', 'mission_not_found');
    end if;
    if v_mission.guild_id <> v_member.guild_id then
        return json_build_object('error', 'mission_not_found');
    end if;
    if v_mission.status <> 'active' then
        return json_build_object('error', 'mission_not_active');
    end if;

    -- Upsert a contribution row at zero (will be incremented by record_guild_contribution).
    insert into public.guild_contributions (mission_id, account_id, amount)
    values (p_mission_id, v_account, 0)
    on conflict (mission_id, account_id) do nothing;

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.accept_guild_mission(text, uuid) to anon, authenticated;


-- ── record_guild_contribution ─────────────────────────────────────────────────
-- Fire-and-forget from the client: adds `p_amount` to the player's contribution
-- row for every active mission in their guild that matches `p_base_key`.
-- If any mission reaches its target it is completed immediately.
--
-- Probation check: if perks_active_at > now() the contribution is silently
-- dropped (client-side GuildManager.perks_active() also guards this, but we
-- enforce it server-side too).
--
-- Returns json: { ok } (always — client does not await a meaningful response)
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
        return json_build_object('ok', true);   -- fire-and-forget: swallow error
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

    -- Find matching active missions and increment them.
    for v_mission in
        select id, target, progress
        from public.guild_missions
        where guild_id = p_guild_id
          and base_mission_key = p_base_key
          and status = 'active'
        for update
    loop
        -- Upsert contribution row.
        insert into public.guild_contributions (mission_id, account_id, amount, updated_at)
        values (v_mission.id, v_account, p_amount, now())
        on conflict (mission_id, account_id)
        do update set
            amount     = public.guild_contributions.amount + excluded.amount,
            updated_at = now();

        -- Increment mission progress (capped at target to keep it clean).
        v_new_prog := least(v_mission.progress + p_amount, v_mission.target);

        update public.guild_missions
        set progress = v_new_prog
        where id = v_mission.id;

        -- Complete the mission if target reached.
        if v_new_prog >= v_mission.target then
            perform public._complete_guild_mission(v_mission.id);
        end if;
    end loop;

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.record_guild_contribution(text, uuid, text, int) to anon, authenticated;


-- ── purchase_guild_upgrade ────────────────────────────────────────────────────
-- Leader spends guild upgrade_points to level up an upgrade track by 1.
-- Returns json: { ok, upgrade_key, new_level, points_remaining }
--         or  : { error }
-- Error codes: account_not_found, not_in_guild, not_guild_leader,
--              upgrade_max_level, insufficient_points
create or replace function public.purchase_guild_upgrade(
    p_device_hash text,
    p_guild_id    uuid,
    p_upgrade_key text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account     uuid;
    v_member      public.guild_members%rowtype;
    v_guild       public.guilds%rowtype;
    v_cur_level   int := 0;
    v_cost        int;
    v_new_level   int;
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
        return json_build_object('error', 'not_guild_leader');
    end if;

    -- Lock guild row for the points update.
    select * into v_guild from public.guilds where id = p_guild_id for update;

    -- Current level (0 if not yet purchased).
    select coalesce(level, 0) into v_cur_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = p_upgrade_key;

    v_cur_level := coalesce(v_cur_level, 0);

    if v_cur_level >= 10 then
        return json_build_object('error', 'upgrade_max_level');
    end if;

    v_cost := public._guild_upgrade_cost(v_cur_level);

    if v_guild.upgrade_points < v_cost then
        return json_build_object('error', 'insufficient_points');
    end if;

    v_new_level := v_cur_level + 1;

    -- Deduct points.
    update public.guilds
    set upgrade_points = upgrade_points - v_cost
    where id = p_guild_id;

    -- Upsert the upgrade level.
    insert into public.guild_upgrade_levels (guild_id, upgrade_key, level)
    values (p_guild_id, p_upgrade_key, v_new_level)
    on conflict (guild_id, upgrade_key)
    do update set level = excluded.level;

    return json_build_object(
        'ok',               true,
        'upgrade_key',      p_upgrade_key,
        'new_level',        v_new_level,
        'points_remaining', v_guild.upgrade_points - v_cost
    );
end;
$$;
grant execute on function public.purchase_guild_upgrade(text, uuid, text) to anon, authenticated;


-- ── request_guild_link ────────────────────────────────────────────────────────
-- Leader sends a link request to another guild with a different specialization.
-- Returns json: { ok } or { error }
-- Error codes: account_not_found, not_in_guild, not_guild_leader,
--              guild_not_found, link_same_specialization, link_already_exists
create or replace function public.request_guild_link(
    p_device_hash      text,
    p_guild_id         uuid,
    p_target_guild_id  uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account      uuid;
    v_member       public.guild_members%rowtype;
    v_own_spec     text;
    v_target_spec  text;
    v_a            uuid;
    v_b            uuid;
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
        return json_build_object('error', 'not_guild_leader');
    end if;

    -- Validate target guild.
    select specialization into v_target_spec
    from public.guilds where id = p_target_guild_id;
    if not found then
        return json_build_object('error', 'guild_not_found');
    end if;

    select specialization into v_own_spec from public.guilds where id = p_guild_id;

    if v_own_spec = v_target_spec then
        return json_build_object('error', 'link_same_specialization');
    end if;

    -- Check for an existing active link (canonical order: a < b).
    v_a := least(p_guild_id, p_target_guild_id);
    v_b := greatest(p_guild_id, p_target_guild_id);

    if exists (select 1 from public.guild_links where guild_a_id = v_a and guild_b_id = v_b) then
        return json_build_object('error', 'link_already_exists');
    end if;

    -- Check for a pending request in either direction.
    if exists (
        select 1 from public.guild_link_requests
        where status = 'pending'
          and (
            (requesting_guild_id = p_guild_id and target_guild_id = p_target_guild_id)
            or
            (requesting_guild_id = p_target_guild_id and target_guild_id = p_guild_id)
          )
    ) then
        return json_build_object('error', 'link_already_exists');
    end if;

    -- Insert the request (or silently re-use an existing rejected one).
    insert into public.guild_link_requests (requesting_guild_id, target_guild_id, status)
    values (p_guild_id, p_target_guild_id, 'pending')
    on conflict (requesting_guild_id, target_guild_id)
    do update set status = 'pending', created_at = now();

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.request_guild_link(text, uuid, uuid) to anon, authenticated;


-- ── accept_guild_link ─────────────────────────────────────────────────────────
-- Target guild's leader accepts a pending link request.
-- Creates the guild_links row and marks the request as accepted.
-- Returns json: { ok } or { error }
-- Error codes: account_not_found, not_in_guild, not_guild_leader,
--              request_not_found, link_already_exists
create or replace function public.accept_guild_link(
    p_device_hash          text,
    p_guild_id             uuid,    -- the accepting guild
    p_requesting_guild_id  uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account  uuid;
    v_member   public.guild_members%rowtype;
    v_req_id   uuid;
    v_a        uuid;
    v_b        uuid;
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
        return json_build_object('error', 'not_guild_leader');
    end if;

    -- Find the pending request.
    select id into v_req_id
    from public.guild_link_requests
    where requesting_guild_id = p_requesting_guild_id
      and target_guild_id = p_guild_id
      and status = 'pending';

    if v_req_id is null then
        return json_build_object('error', 'request_not_found');
    end if;

    -- Canonical order for the link row.
    v_a := least(p_guild_id, p_requesting_guild_id);
    v_b := greatest(p_guild_id, p_requesting_guild_id);

    if exists (select 1 from public.guild_links where guild_a_id = v_a and guild_b_id = v_b) then
        return json_build_object('error', 'link_already_exists');
    end if;

    -- Create the link.
    insert into public.guild_links (guild_a_id, guild_b_id)
    values (v_a, v_b);

    -- Mark the request accepted.
    update public.guild_link_requests
    set status = 'accepted'
    where id = v_req_id;

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.accept_guild_link(text, uuid, uuid) to anon, authenticated;


-- ── remove_guild_link ─────────────────────────────────────────────────────────
-- Either linked guild's leader can dissolve the link.
-- Returns json: { ok } or { error }
-- Error codes: account_not_found, not_in_guild, not_guild_leader, link_not_found
create or replace function public.remove_guild_link(
    p_device_hash    text,
    p_guild_id       uuid,
    p_linked_guild_id uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account  uuid;
    v_member   public.guild_members%rowtype;
    v_a        uuid;
    v_b        uuid;
    v_deleted  int;
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
        return json_build_object('error', 'not_guild_leader');
    end if;

    v_a := least(p_guild_id, p_linked_guild_id);
    v_b := greatest(p_guild_id, p_linked_guild_id);

    delete from public.guild_links
    where guild_a_id = v_a and guild_b_id = v_b;

    get diagnostics v_deleted = row_count;

    if v_deleted = 0 then
        return json_build_object('error', 'link_not_found');
    end if;

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.remove_guild_link(text, uuid, uuid) to anon, authenticated;


-- ── get_effective_guild_perks ─────────────────────────────────────────────────
-- Returns the caller's effective perk table: own guild upgrades + linked guild's
-- upgrades prefixed with 'linked_'.  Used by the client to display perk values.
-- Returns json: { perks: { upgrade_key: level, ... } }
--         or  : { error }
create or replace function public.get_effective_guild_perks(
    p_device_hash text
)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_member  public.guild_members%rowtype;
    v_perks   json;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null then
        return json_build_object('perks', '{}'::json);
    end if;

    -- Probation check: no perks while cooling down.
    if v_member.perks_active_at is not null
       and v_member.perks_active_at > extract(epoch from now()) then
        return json_build_object('perks', '{}'::json);
    end if;

    v_perks := public._guild_effective_perks(v_account, v_member.guild_id);

    return json_build_object('perks', v_perks);
end;
$$;
grant execute on function public.get_effective_guild_perks(text) to anon, authenticated;


-- ── Seed initial missions for existing guilds (idempotent) ───────────────────
-- If any guilds already exist without active missions, fill their slots now.
-- This is a no-op on a fresh DB.
do $$
declare
    v_guild record;
begin
    for v_guild in select id from public.guilds
    loop
        perform public._spawn_guild_missions(v_guild.id);
    end loop;
end;
$$;
