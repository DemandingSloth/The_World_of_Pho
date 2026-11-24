-- ============================================================================
-- Migration 039: Make get_guild_missions VOLATILE
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- WHY: get_guild_missions (024) was declared STABLE. A STABLE function may be
-- served from a statement-level cached snapshot, so calling it immediately after
-- record_guild_contribution (a deposit) could return the PRE-deposit progress —
-- the mission appeared unchanged until the player hit Refresh, which calls
-- get_player_guild_summary (already made VOLATILE in migration 027 for the exact
-- same stale-read reason on membership).
--
-- This recreates get_guild_missions as VOLATILE so the post-deposit refresh
-- always reads the just-committed progress / replacement mission. The body is
-- otherwise identical to 024.
-- ============================================================================

create or replace function public.get_guild_missions(
    p_device_hash text,
    p_guild_id    uuid
)
returns json
language plpgsql
volatile
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
