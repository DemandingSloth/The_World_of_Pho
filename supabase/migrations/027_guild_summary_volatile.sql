-- ============================================================================
-- Migration 027: Make get_player_guild_summary volatile
-- ============================================================================
-- Changes get_player_guild_summary from STABLE to VOLATILE so PostgreSQL
-- never uses statement-level cached reads. Without this, calling the function
-- immediately after create_guild or join_guild (within the same transaction
-- context or read replica window) could return stale data showing no guild
-- membership even though the guild_members row was just written.
-- ============================================================================

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
