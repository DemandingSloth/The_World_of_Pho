-- ============================================================================
-- Migration 041: Surface guild links + pending link requests in the summary
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- BUG: request_guild_link inserted a PENDING row in guild_link_requests, but
-- nothing ever returned those requests to a client. So:
--   • The target guild's leader never saw the request and couldn't accept it.
--   • get_player_guild_summary never returned active links either, so the
--     "Linked" screen was always empty for both guilds.
--   • Re-requesting from the other side hit the "pending request in either
--     direction" guard and returned link_already_exists — looking like a link
--     existed when none was ever confirmed.
--
-- FIX: a _guild_links_json(guild) helper returns everything the Linking UI needs
-- as one array, and get_player_guild_summary (kept VOLATILE, per migration 027)
-- includes it as guild.links. Each row:
--   { guild_id, name, specialization, status }
--     guild_id : the OTHER guild — the one the client acts on (accept/remove)
--     status   : 'active'           — a confirmed link (Remove)
--                'pending_incoming'  — someone requested US (Accept)
--                'pending_outgoing'  — WE requested them (awaiting their accept)
-- ============================================================================


-- ── Helper: links + pending requests for a guild, as a JSON array ─────────────

create or replace function public._guild_links_json(p_guild_id uuid)
returns json
language sql
stable
security definer
set search_path = public
as $$
    with rows as (
        -- Confirmed active links: pick the OTHER guild in the pair.
        select
            case when gl.guild_a_id = p_guild_id then gl.guild_b_id else gl.guild_a_id end as other_id,
            'active'::text as status,
            gl.linked_at as sort_time
        from public.guild_links gl
        where gl.guild_a_id = p_guild_id or gl.guild_b_id = p_guild_id

        union all

        -- Incoming pending requests: the OTHER guild is the requester.
        select
            lr.requesting_guild_id as other_id,
            'pending_incoming'::text as status,
            lr.created_at as sort_time
        from public.guild_link_requests lr
        where lr.target_guild_id = p_guild_id
          and lr.status = 'pending'

        union all

        -- Outgoing pending requests: the OTHER guild is the target.
        select
            lr.target_guild_id as other_id,
            'pending_outgoing'::text as status,
            lr.created_at as sort_time
        from public.guild_link_requests lr
        where lr.requesting_guild_id = p_guild_id
          and lr.status = 'pending'
    )
    select coalesce(
        json_agg(
            json_build_object(
                'guild_id',       r.other_id,
                'name',           g.name,
                'specialization', g.specialization,
                'status',         r.status
            )
            order by (r.status <> 'pending_incoming'), r.sort_time desc
        ),
        '[]'::json
    )
    from rows r
    join public.guilds g on g.id = r.other_id;
$$;
revoke all on function public._guild_links_json(uuid) from anon, authenticated;


-- ── Recreate get_player_guild_summary (VOLATILE) including guild.links ────────
-- Identical to migration 027 except guild now carries a 'links' array.

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
    v_links         json;
    v_member_count  int;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);

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

    select * into v_guild from public.guilds where id = v_member.guild_id;

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

    -- Expire stale missions first.
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

    v_upgrades := public._guild_upgrades_dict(v_member.guild_id);
    v_perks    := public._guild_effective_perks(v_account, v_member.guild_id);
    v_links    := public._guild_links_json(v_member.guild_id);

    return json_build_object(
        'guild', json_build_object(
            'id',             v_guild.id,
            'name',           v_guild.name,
            'specialization', v_guild.specialization,
            'capacity',       v_guild.capacity,
            'upgrade_points', v_guild.upgrade_points,
            'leader_id',      v_guild.leader_id,
            'member_count',   v_member_count,
            'links',          v_links
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
