-- ============================================================================
-- Guilds: get_top_active_guilds — recommend the most active guilds to join
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- WHY: the Guilds lobby, when the player is NOT in a guild, should suggest the
-- top 10 most active guilds to join instead of showing an empty search list.
--
-- "Activity" is a composite score, favoring guilds that are actually DOING
-- things recently:
--   recent_completions (guild missions completed in the last 7 days) × 10
--   + member_count × 2
--   + least(upgrade_points, 500) / 50     (small, capped nudge from investment)
-- Recent mission completions dominate; members and upgrade points break ties.
--
-- Full guilds are excluded (you can't join them), mirroring search_guilds.
-- An optional spec filter is supported for parity with the search UI.
--
-- Returns json: { guilds: [ { id, name, specialization, capacity,
--                             member_count, upgrade_points, recent_completions,
--                             activity_score } ] }   (ordered best-first)
-- Error codes: account_not_found
-- ============================================================================

create or replace function public.get_top_active_guilds(
    p_device_hash    text,
    p_specialization text default null,
    p_limit          int  default 10
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
    v_limit   int := least(greatest(coalesce(p_limit, 10), 1), 50);
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select json_build_object(
        'guilds',
        coalesce(
            json_agg(row_to_json(r) order by r.activity_score desc, r.member_count desc, r.name asc),
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
            count(distinct gm.id) filter (where gm.left_at is null)::int as member_count,
            count(distinct cm.id)::int as recent_completions,
            (
                count(distinct cm.id) * 10
                + count(distinct gm.id) filter (where gm.left_at is null) * 2
                + least(g.upgrade_points, 500) / 50
            )::int as activity_score
        from public.guilds g
        left join public.guild_members gm
            on gm.guild_id = g.id
        -- Recent completed missions (activity window = last 7 days).
        left join public.guild_missions cm
            on cm.guild_id = g.id
            and cm.status = 'completed'
            and cm.completed_at is not null
            and cm.completed_at >= now() - interval '7 days'
        where (p_specialization is null or g.specialization = p_specialization)
        group by g.id
        -- Only joinable (non-full) guilds.
        having count(distinct gm.id) filter (where gm.left_at is null) < g.capacity
        order by activity_score desc, member_count desc, g.name asc
        limit v_limit
    ) r;

    return v_results;
end;
$$;

grant execute on function public.get_top_active_guilds(text, text, int) to anon, authenticated;
