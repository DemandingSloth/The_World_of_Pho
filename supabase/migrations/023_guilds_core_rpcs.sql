-- ============================================================================
-- Guilds Task 2: core lifecycle RPCs
-- ============================================================================
-- Run AFTER 022_guilds_tables.sql.
--
-- Functions created here:
--   create_guild              — create a new guild; caller becomes leader
--   join_guild                — join an existing guild
--   leave_guild               — leave current guild (leader must transfer first
--                               if other members exist, or guild is dissolved)
--   kick_guild_member         — leader removes a member
--   search_guilds             — fuzzy name search with optional spec filter
--   get_player_guild_summary  — single call that fetches everything GuildManager
--                               needs: guild, roster, missions, upgrades,
--                               effective_perks, member_info
-- ============================================================================

-- ── create_guild ─────────────────────────────────────────────────────────────
-- Creates a new guild and makes the caller its leader.
-- Returns json: { ok, guild: { id, name, specialization, capacity } }
--         or  : { error: <code> }
-- Error codes: account_not_found, already_in_guild, guild_name_taken
create or replace function public.create_guild(
    p_device_hash    text,
    p_name           text,
    p_specialization text,
    p_capacity       int default 5
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
    v_cap      int := least(greatest(coalesce(p_capacity, 5), 5), 20);
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

    -- Unique name check (the unique constraint will also catch races, but a
    -- pre-check gives a friendlier error code).
    if exists (select 1 from public.guilds where lower(name) = lower(v_name)) then
        return json_build_object('error', 'guild_name_taken');
    end if;

    -- Create the guild row (leader_id set after we have the member row).
    insert into public.guilds (name, specialization, capacity)
    values (v_name, p_specialization, v_cap)
    returning id into v_guild_id;

    -- Add the creator as leader.
    insert into public.guild_members (guild_id, account_id, role, perks_active_at)
    values (v_guild_id, v_account, 'leader', null);   -- immediate perks on creation

    -- Backfill leader_id now that we have the member row id (using account_id
    -- as the authoritative leader reference — cleaner than the member row id).
    update public.guilds set leader_id = v_account where id = v_guild_id;

    return json_build_object(
        'ok', true,
        'guild', json_build_object(
            'id',             v_guild_id,
            'name',           v_name,
            'specialization', p_specialization,
            'capacity',       v_cap
        )
    );
exception
    when unique_violation then
        return json_build_object('error', 'guild_name_taken');
end;
$$;
grant execute on function public.create_guild(text, text, text, int) to anon, authenticated;


-- ── join_guild ───────────────────────────────────────────────────────────────
-- Adds the caller to an existing guild.
-- Returns json: { ok } or { error: <code> }
-- Error codes: account_not_found, already_in_guild, guild_not_found, guild_full
create or replace function public.join_guild(
    p_device_hash text,
    p_guild_id    uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account      uuid;
    v_existing_mem public.guild_members%rowtype;
    v_guild        public.guilds%rowtype;
    v_member_count int;
    v_perks_at     double precision;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    -- Already a member somewhere?
    v_existing_mem := public._guild_active_member(v_account);
    if v_existing_mem.id is not null then
        return json_build_object('error', 'already_in_guild');
    end if;

    -- Lock the guild row so concurrent joins can't exceed capacity.
    select * into v_guild from public.guilds where id = p_guild_id for update;
    if not found then
        return json_build_object('error', 'guild_not_found');
    end if;

    -- Count active members.
    select count(*) into v_member_count
    from public.guild_members
    where guild_id = p_guild_id and left_at is null;

    if v_member_count >= v_guild.capacity then
        return json_build_object('error', 'guild_full');
    end if;

    -- Calculate probation end time.
    v_perks_at := public._guild_perks_active_at(v_account, v_guild.specialization);

    -- Record the join, preserving previous guild info for future cooldowns.
    insert into public.guild_members (
        guild_id, account_id, role, perks_active_at,
        previous_guild_id, previous_guild_spec
    )
    select
        p_guild_id,
        v_account,
        'member',
        v_perks_at,
        -- Pull the last guild this player was in (if any).
        gm_prev.guild_id,
        g_prev.specialization
    from (select 1) as _dummy
    left join public.guild_members gm_prev
        on gm_prev.account_id = v_account
        and gm_prev.left_at is not null
        -- Most recent departure.
        and gm_prev.left_at = (
            select max(left_at) from public.guild_members
            where account_id = v_account and left_at is not null
        )
    left join public.guilds g_prev on g_prev.id = gm_prev.guild_id;

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.join_guild(text, uuid) to anon, authenticated;


-- ── leave_guild ──────────────────────────────────────────────────────────────
-- The caller leaves their current guild.
-- * If they are the leader AND other active members exist → error (must kick or
--   transfer first; keeps us from orphaning a guild silently).
-- * If they are the sole member → guild is dissolved entirely.
-- Returns json: { ok } or { error: <code> }
-- Error codes: account_not_found, not_in_guild, leader_must_transfer
create or replace function public.leave_guild(
    p_device_hash text,
    p_guild_id    uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account      uuid;
    v_member       public.guild_members%rowtype;
    v_other_count  int;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    -- Count other active members.
    select count(*) into v_other_count
    from public.guild_members
    where guild_id = p_guild_id
      and account_id <> v_account
      and left_at is null;

    -- Leader can't abandon members.
    if v_member.role = 'leader' and v_other_count > 0 then
        return json_build_object('error', 'leader_must_transfer');
    end if;

    -- Mark member as having left.
    update public.guild_members
    set left_at = now()
    where id = v_member.id;

    -- If no one remains, dissolve the guild (cascade deletes handle child rows).
    if v_other_count = 0 then
        delete from public.guilds where id = p_guild_id;
    end if;

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.leave_guild(text, uuid) to anon, authenticated;


-- ── kick_guild_member ─────────────────────────────────────────────────────────
-- Leader removes another member from the guild.
-- Returns json: { ok } or { error: <code> }
-- Error codes: account_not_found, not_in_guild, not_guild_leader,
--              member_not_found, cannot_kick_self
create or replace function public.kick_guild_member(
    p_device_hash text,
    p_guild_id    uuid,
    p_target_id   uuid     -- account_id of the member to kick
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account    uuid;
    v_leader_mem public.guild_members%rowtype;
    v_target_mem public.guild_members%rowtype;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_leader_mem := public._guild_active_member(v_account);
    if v_leader_mem.id is null or v_leader_mem.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;
    if v_leader_mem.role <> 'leader' then
        return json_build_object('error', 'not_guild_leader');
    end if;
    if p_target_id = v_account then
        return json_build_object('error', 'cannot_kick_self');
    end if;

    -- Find target member row.
    select * into v_target_mem
    from public.guild_members
    where guild_id = p_guild_id
      and account_id = p_target_id
      and left_at is null;

    if v_target_mem.id is null then
        return json_build_object('error', 'member_not_found');
    end if;

    -- Mark them as having left.
    update public.guild_members
    set left_at = now()
    where id = v_target_mem.id;

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.kick_guild_member(text, uuid, uuid) to anon, authenticated;


-- ── search_guilds ─────────────────────────────────────────────────────────────
-- Fuzzy name search; returns guilds that are not full, ordered by member count
-- descending (most active first).  Optional spec filter.
-- Returns json: { guilds: [ { id, name, specialization, capacity,
--                              member_count, upgrade_points } ] }
-- Error codes: account_not_found
create or replace function public.search_guilds(
    p_device_hash    text,
    p_query          text    default '',
    p_specialization text    default null
)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_results json;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select json_build_object(
        'guilds',
        coalesce(
            json_agg(row_to_json(r) order by r.member_count desc),
            '[]'::json
        )
    ) into v_results
    from (
        select
            g.id,
            g.name,
            g.specialization,
            g.capacity,
            g.upgrade_points,
            count(gm.id)::int as member_count
        from public.guilds g
        left join public.guild_members gm
            on gm.guild_id = g.id and gm.left_at is null
        where
            -- Name filter (case-insensitive substring).
            (p_query = '' or g.name ilike '%' || p_query || '%')
            -- Spec filter (optional).
            and (p_specialization is null or g.specialization = p_specialization)
        group by g.id
        -- Exclude full guilds.
        having count(gm.id) < g.capacity
        limit 50
    ) r;

    return v_results;
end;
$$;
grant execute on function public.search_guilds(text, text, text) to anon, authenticated;


-- ── get_player_guild_summary ──────────────────────────────────────────────────
-- One-shot fetch for GuildManager.refresh_all().
-- Returns everything the client needs:
--   guild         — guild info dict (or null)
--   roster        — array of member dicts
--   missions      — array of active mission dicts
--   upgrades      — { upgrade_key: level } dict
--   effective_perks — own + linked guild perk levels
--   member_info   — { role, perks_active_at, joined_at }
--
-- Returns json: { guild, roster, missions, upgrades, effective_perks,
--                 member_info }
--         or  : { error: 'account_not_found' }
create or replace function public.get_player_guild_summary(
    p_device_hash text
)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account  uuid;
    v_member   public.guild_members%rowtype;
    v_guild    public.guilds%rowtype;

    v_roster        json;
    v_missions      json;
    v_upgrades      json;
    v_perks         json;
    v_member_count  int;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    -- Check guild membership.
    v_member := public._guild_active_member(v_account);

    -- Not in any guild — return empty shell.
    if v_member.id is null then
        return json_build_object(
            'guild',          null,
            'roster',         '[]'::json,
            'missions',       '[]'::json,
            'upgrades',       '{}'::json,
            'effective_perks','{}' ::json,
            'member_info',    '{}'::json
        );
    end if;

    -- Load guild row.
    select * into v_guild from public.guilds where id = v_member.guild_id;

    -- Roster: all active members + their username from accounts.
    select coalesce(json_agg(json_build_object(
        'user_id',        gm.account_id,
        'username',       a.username,
        'role',           gm.role,
        'joined_at',      extract(epoch from gm.joined_at),
        'perks_active_at', gm.perks_active_at
    ) order by gm.role desc, gm.joined_at asc), '[]'::json)
    into v_roster
    from public.guild_members gm
    join public.accounts a on a.id = gm.account_id
    where gm.guild_id = v_member.guild_id
      and gm.left_at is null;

    select count(*) into v_member_count
    from public.guild_members
    where guild_id = v_member.guild_id and left_at is null;

    -- Active missions (expire stale ones first).
    update public.guild_missions
    set status = 'expired'
    where guild_id = v_member.guild_id
      and status = 'active'
      and expires_at < now();

    select coalesce(json_agg(json_build_object(
        'id',                   gm.id,
        'base_mission_key',     gm.base_mission_key,
        'difficulty',           gm.difficulty,
        'target',               gm.target,
        'progress',             gm.progress,
        'reward_tokens',        gm.reward_tokens,
        'reward_upgrade_points',gm.reward_upgrade_points,
        'status',               gm.status,
        'spawned_at',           extract(epoch from gm.spawned_at),
        'expires_at',           extract(epoch from gm.expires_at)
    ) order by gm.difficulty), '[]'::json)
    into v_missions
    from public.guild_missions gm
    where gm.guild_id = v_member.guild_id
      and gm.status = 'active';

    -- Upgrades dict.
    v_upgrades := public._guild_upgrades_dict(v_member.guild_id);

    -- Effective perks (own + linked guild).
    v_perks := public._guild_effective_perks(v_account, v_member.guild_id);

    return json_build_object(
        'guild', json_build_object(
            'id',             v_guild.id,
            'name',           v_guild.name,
            'specialization', v_guild.specialization,
            'capacity',       v_guild.capacity,
            'upgrade_points', v_guild.upgrade_points,
            'leader_id',      v_guild.leader_id,
            'member_count',   v_member_count
        ),
        'roster',          v_roster,
        'missions',        v_missions,
        'upgrades',        v_upgrades,
        'effective_perks', v_perks,
        'member_info', json_build_object(
            'role',            v_member.role,
            'perks_active_at', v_member.perks_active_at,
            'joined_at',       extract(epoch from v_member.joined_at)
        )
    );
end;
$$;
grant execute on function public.get_player_guild_summary(text) to anon, authenticated;
