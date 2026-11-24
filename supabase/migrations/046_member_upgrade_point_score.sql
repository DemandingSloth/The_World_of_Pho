-- ============================================================================
-- Migration 046: Per-member lifetime upgrade-point contribution score
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- The roster screen shows a per-member "Score" that was never populated
-- (the client read lifetime_participation_score, which the server never sent).
-- We now track, per member, the total guild UPGRADE POINTS they've earned FOR
-- their guild — i.e. their proportional share of each completed mission's
-- reward_upgrade_points, by contribution. This is a lifetime tracking stat; the
-- guild still receives the FULL upgrade_points to spend (unchanged).
--
-- Changes:
--   1. guild_members.lifetime_upgrade_points  — new column (default 0)
--   2. _guild_distribute_reward  — credit each contributor's share on completion
--   3. get_player_guild_summary  — include it in the roster payload
-- ============================================================================


-- ── 1. Track per-member lifetime upgrade points earned ───────────────────────
alter table public.guild_members
    add column if not exists lifetime_upgrade_points bigint not null default 0;


-- ── 2. Credit each contributor's share on mission completion ─────────────────
-- Same proportional split basis as the token reward. The guild still gets the
-- full reward_upgrade_points to spend; this only ALSO records each member's
-- earned share as a lifetime stat.
create or replace function public._guild_distribute_reward(
    p_mission_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_mission      public.guild_missions%rowtype;
    v_total_contrib int;
    v_member       record;
    v_share        int;
    v_pt_share     int;
begin
    select * into v_mission from public.guild_missions where id = p_mission_id;
    if not found or v_mission.status <> 'completed' then
        return;
    end if;

    select coalesce(sum(amount), 0) into v_total_contrib
    from public.guild_contributions
    where mission_id = p_mission_id;

    if v_total_contrib <= 0 then
        return;
    end if;

    for v_member in
        select gc.account_id, gc.amount
        from public.guild_contributions gc
        where gc.mission_id = p_mission_id and gc.amount > 0
    loop
        -- Proportional token share (floor; leftover stays in the pool).
        v_share := floor(
            v_mission.reward_tokens::float * v_member.amount::float / v_total_contrib::float
        )::int;

        if v_share > 0 then
            update public.accounts
            set token_balance = token_balance + v_share
            where id = v_member.account_id;

            insert into public.token_ledger (account_id, delta, reason, ref_id)
            values (v_member.account_id, v_share, 'guild_reward', p_mission_id);
        end if;

        -- Proportional upgrade-point share -> this member's lifetime score.
        -- (Tracking only; the guild still receives the full amount below.)
        v_pt_share := floor(
            v_mission.reward_upgrade_points::float * v_member.amount::float / v_total_contrib::float
        )::int;
        if v_pt_share > 0 then
            update public.guild_members
            set lifetime_upgrade_points = lifetime_upgrade_points + v_pt_share
            where guild_id = v_mission.guild_id
              and account_id = v_member.account_id;
        end if;
    end loop;

    -- Upgrade points go to the guild as a whole (not per-member) — unchanged.
    if v_mission.reward_upgrade_points > 0 then
        update public.guilds
        set upgrade_points = upgrade_points + v_mission.reward_upgrade_points
        where id = v_mission.guild_id;
    end if;
end;
$$;
revoke all on function public._guild_distribute_reward(uuid) from anon, authenticated;


-- ── 3. Include the score in the roster payload ───────────────────────────────
-- Recreate get_player_guild_summary (VOLATILE, from migration 042's version)
-- adding 'score' to each roster member. Body otherwise identical to 042.
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
        'perks_active_at', gm.perks_active_at,
        'score',          gm.lifetime_upgrade_points
    ) order by gm.role desc, gm.lifetime_upgrade_points desc, gm.joined_at asc), '[]'::json)
    into v_roster
    from public.guild_members gm
    join public.accounts a on a.id = gm.account_id
    where gm.guild_id = v_member.guild_id
      and gm.left_at is null;

    select count(*) into v_member_count
    from public.guild_members
    where guild_id = v_member.guild_id and left_at is null;

    -- Expire stale missions first, refunding their deposits to owners.
    perform public._guild_expire_and_refund(v_member.guild_id);

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
