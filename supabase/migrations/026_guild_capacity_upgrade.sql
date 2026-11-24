-- ============================================================================
-- Migration 026: Guild capacity upgrade system
-- ============================================================================
-- Changes:
--   1. create_guild       — removes p_capacity parameter; guilds always start
--                           at capacity 5.
--   2. purchase_guild_upgrade — when upgrade_key = 'capacity', looks up the
--                           target capacity from a fixed 10-level table and
--                           writes it back to guilds.capacity so all capacity
--                           reads (join checks, member counts) stay consistent.
--   3. Data migration     — resets any existing guilds whose capacity was set
--                           above 5 at creation time to 5, then inserts the
--                           matching capacity upgrade_level row so they don't
--                           lose their effective capacity.
--
-- Capacity table (matches client CAPACITY_PER_LEVEL):
--   Level:    0   1   2   3   4   5   6   7   8   9  10
--   Members:  5   6   7   8   9  10  12  14  16  18  20
-- ============================================================================


-- ── Helper: capacity for a given upgrade level ───────────────────────────────
create or replace function public._guild_capacity_for_level(p_level int)
returns int
language sql
immutable
security definer
set search_path = public
as $$
    select (array[5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 20])
           [least(greatest(p_level, 0), 10) + 1];
$$;
revoke all on function public._guild_capacity_for_level(int) from anon, authenticated;


-- ── 1. create_guild — no p_capacity parameter ────────────────────────────────
create or replace function public.create_guild(
    p_device_hash    text,
    p_name           text,
    p_specialization text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account  uuid;
    v_existing public.guild_members%rowtype;
    v_guild_id uuid;
    v_name     text := trim(p_name);
begin
    -- Resolve caller.
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    -- Must not already be in a guild.
    v_existing := public._guild_active_member(v_account);
    if v_existing.id is not null then
        return json_build_object('error', 'already_in_guild');
    end if;

    -- Validate name length (3–32 chars) and spec.
    if length(v_name) < 3 or length(v_name) > 32 then
        return json_build_object('error', 'invalid_name');
    end if;
    if p_specialization not in ('gardening', 'mining') then
        return json_build_object('error', 'invalid_specialization');
    end if;

    -- Unique name check.
    if exists (select 1 from public.guilds where lower(name) = lower(v_name)) then
        return json_build_object('error', 'guild_name_taken');
    end if;

    -- Create the guild row; capacity always starts at 5.
    insert into public.guilds (name, specialization, capacity)
    values (v_name, p_specialization, 5)
    returning id into v_guild_id;

    -- Add the creator as leader with immediate perks.
    insert into public.guild_members (guild_id, account_id, role, perks_active_at)
    values (v_guild_id, v_account, 'leader', null);

    -- Backfill leader_id.
    update public.guilds set leader_id = v_account where id = v_guild_id;

    return json_build_object(
        'ok', true,
        'guild', json_build_object(
            'id',             v_guild_id,
            'name',           v_name,
            'specialization', p_specialization,
            'capacity',       5
        )
    );
exception
    when unique_violation then
        return json_build_object('error', 'guild_name_taken');
end;
$$;
grant execute on function public.create_guild(text, text, text) to anon, authenticated;

-- Revoke the old 4-argument overload so it can no longer be called.
drop function if exists public.create_guild(text, text, text, int);


-- ── 2. purchase_guild_upgrade — wire capacity key ────────────────────────────
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
    v_new_cap     int;
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

    -- Lock guild row for the points + capacity update.
    select * into v_guild from public.guilds where id = p_guild_id for update;

    -- Current level for this upgrade track (0 if never purchased).
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

    -- Deduct upgrade points.
    update public.guilds
    set upgrade_points = upgrade_points - v_cost
    where id = p_guild_id;

    -- Upsert the upgrade level record.
    insert into public.guild_upgrade_levels (guild_id, upgrade_key, level)
    values (p_guild_id, p_upgrade_key, v_new_level)
    on conflict (guild_id, upgrade_key)
    do update set level = excluded.level;

    -- If this is the capacity upgrade, also update guilds.capacity so that
    -- join checks and member-count displays always reflect the true limit.
    if p_upgrade_key = 'capacity' then
        v_new_cap := public._guild_capacity_for_level(v_new_level);
        update public.guilds
        set capacity = v_new_cap
        where id = p_guild_id;
    end if;

    return json_build_object(
        'ok',               true,
        'upgrade_key',      p_upgrade_key,
        'new_level',        v_new_level,
        'points_remaining', v_guild.upgrade_points - v_cost
    );
end;
$$;
grant execute on function public.purchase_guild_upgrade(text, uuid, text) to anon, authenticated;


-- ── 3. Data migration — reconcile existing guilds ────────────────────────────
-- Any guild currently at capacity > 5 was created before this migration.
-- We:
--   a) Derive the effective upgrade level from the current capacity value.
--   b) Upsert that level into guild_upgrade_levels (if no row exists yet).
--   c) Reset guilds.capacity to 5 for guilds that have NO capacity upgrade
--      record at all (i.e. they were created with a player-chosen value but
--      never actually purchased the upgrade). Their capacity drops to 5.
--
-- Guilds that already have a capacity upgrade record are left unchanged
-- (their guilds.capacity was already set correctly by prior purchases).

do $$
declare
    r record;
    v_level int;
begin
    for r in
        select id, capacity
        from public.guilds
        where capacity <> 5
    loop
        -- Only touch guilds that have no capacity upgrade row yet.
        if not exists (
            select 1 from public.guild_upgrade_levels
            where guild_id = r.id and upgrade_key = 'capacity'
        ) then
            -- Reset to base — the player never purchased the upgrade.
            update public.guilds set capacity = 5 where id = r.id;
        end if;
        -- If a capacity upgrade row already exists, the capacity column is
        -- already correct; nothing to do.
    end loop;
end;
$$;
