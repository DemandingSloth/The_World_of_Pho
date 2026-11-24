-- ============================================================================
-- Migration 087: Guild leaderboard score = points available × upgrades purchased
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 022 (guild_upgrade_levels) + 056 (get_guild_leaderboard) applied.
--
-- Changes ONLY the guild leaderboard's score. The guild "score" shown under its
-- rank is now:
--     score = upgrade_points_available × upgrades_purchased
-- where:
--   • upgrade_points_available = guilds.upgrade_points (unspent points), and
--   • upgrades_purchased        = total upgrade LEVELS bought across all tracks
--                                 (sum of guild_upgrade_levels.level), since
--                                 each level is one purchased upgrade.
-- Example: 10 points available × 6 upgrades purchased = 60.
--
-- The PLAYER leaderboard (get_player_leaderboard) is intentionally LEFT ALONE —
-- this migration does not touch player score calculations.
-- Supersedes migration 056's get_guild_leaderboard only.
-- ============================================================================

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
            'name',               r.name,
            'specialization',     r.specialization,
            'upgrade_points',     r.upgrade_points,       -- points available
            'upgrades_purchased', r.upgrades_purchased,   -- total levels bought
            'score',              r.score,                -- points × upgrades
            'member_count',       r.member_count,
            'is_yours',           (r.id = v_my_guild)
        ) order by r.score desc, r.member_count desc, r.name asc), '[]'::json)
    ) into v_result
    from (
        select
            g.id,
            g.name,
            g.specialization,
            g.upgrade_points,
            -- Total upgrade levels bought across all tracks for this guild.
            coalesce((
                select sum(gul.level)
                from public.guild_upgrade_levels gul
                where gul.guild_id = g.id
            ), 0)::bigint as upgrades_purchased,
            -- Score = points available × upgrades purchased.
            (g.upgrade_points::bigint * coalesce((
                select sum(gul.level)
                from public.guild_upgrade_levels gul
                where gul.guild_id = g.id
            ), 0))::bigint as score,
            count(gm.id) filter (where gm.left_at is null)::int as member_count
        from public.guilds g
        left join public.guild_members gm on gm.guild_id = g.id
        group by g.id
        order by score desc, member_count desc, g.name asc
        limit v_limit
    ) r;

    return v_result;
end;
$$;
grant execute on function public.get_guild_leaderboard(text, int) to anon, authenticated;
