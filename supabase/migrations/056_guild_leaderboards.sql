-- ============================================================================
-- Migration 056: Guild leaderboards (top players by score, top guilds by points)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Two read-only leaderboards for the guild detail screen's Leaderboard tab:
--
--   get_player_leaderboard(device_hash, limit=25)
--     Top players by TOTAL lifetime_upgrade_points SUMMED across every guild
--     membership they've ever had (active or left). Each player is shown with
--     their CURRENT guild name, or their MOST-RECENTLY-LEFT guild if not
--     currently in one. Requires the caller to be in a guild (detail-screen
--     feature). Returns { players: [{ username, score, guild_name, is_you }] }.
--
--   get_guild_leaderboard(device_hash, limit=10)
--     Top guilds by guilds.upgrade_points (lifetime points earned by the guild).
--     Returns { guilds: [{ name, specialization, upgrade_points, member_count,
--     is_yours }] }.
--
-- Both mirror the get_top_active_guilds pattern (migration 038): SECURITY
-- DEFINER, account resolved via _guild_resolve_account, json_agg output.
-- ============================================================================


-- ── get_player_leaderboard ────────────────────────────────────────────────────
create or replace function public.get_player_leaderboard(
    p_device_hash text,
    p_limit        int default 25
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
    v_limit   int := least(greatest(coalesce(p_limit, 25), 1), 100);
    v_result  json;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    -- Detail-screen feature: require guild membership.
    v_member := public._guild_active_member(v_account);
    if v_member.id is null then
        return json_build_object('error', 'not_in_guild');
    end if;

    select json_build_object(
        'players',
        coalesce(json_agg(json_build_object(
            'username',   r.username,
            'score',      r.score,
            'guild_name', r.guild_name,
            'is_you',     (r.account_id = v_account)
        ) order by r.score desc, r.username asc), '[]'::json)
    ) into v_result
    from (
        select
            a.id as account_id,
            a.username,
            sum(gm.lifetime_upgrade_points)::bigint as score,
            -- Current guild name if active, else the most-recently-left guild.
            (
                select g2.name
                from public.guild_members gm2
                join public.guilds g2 on g2.id = gm2.guild_id
                where gm2.account_id = a.id
                order by (gm2.left_at is null) desc,   -- active first
                         gm2.left_at desc nulls last,   -- then most recent leave
                         gm2.joined_at desc
                limit 1
            ) as guild_name
        from public.accounts a
        join public.guild_members gm on gm.account_id = a.id
        group by a.id, a.username
        having sum(gm.lifetime_upgrade_points) > 0
        order by score desc, a.username asc
        limit v_limit
    ) r;

    return v_result;
end;
$$;
grant execute on function public.get_player_leaderboard(text, int) to anon, authenticated;


-- ── get_guild_leaderboard ─────────────────────────────────────────────────────
create or replace function public.get_guild_leaderboard(
    p_device_hash text,
    p_limit        int default 10
)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_account   uuid;
    v_member    public.guild_members%rowtype;
    v_my_guild  uuid;
    v_limit     int := least(greatest(coalesce(p_limit, 10), 1), 100);
    v_result    json;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null then
        return json_build_object('error', 'not_in_guild');
    end if;
    v_my_guild := v_member.guild_id;

    select json_build_object(
        'guilds',
        coalesce(json_agg(json_build_object(
            'name',           r.name,
            'specialization', r.specialization,
            'upgrade_points', r.upgrade_points,
            'member_count',   r.member_count,
            'is_yours',       (r.id = v_my_guild)
        ) order by r.upgrade_points desc, r.member_count desc, r.name asc), '[]'::json)
    ) into v_result
    from (
        select
            g.id,
            g.name,
            g.specialization,
            g.upgrade_points,
            count(gm.id) filter (where gm.left_at is null)::int as member_count
        from public.guilds g
        left join public.guild_members gm on gm.guild_id = g.id
        group by g.id
        order by g.upgrade_points desc, member_count desc, g.name asc
        limit v_limit
    ) r;

    return v_result;
end;
$$;
grant execute on function public.get_guild_leaderboard(text, int) to anon, authenticated;
