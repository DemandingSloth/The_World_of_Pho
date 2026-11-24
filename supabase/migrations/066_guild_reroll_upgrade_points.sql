-- ============================================================================
-- Migration 066: Guild mission reroll — unlimited, priced in upgrade points
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Guild mission rerolls are now LEADER-ONLY and priced in the guild's shared
-- UPGRADE POINTS on a tiered curve, replacing the old per-player coin cost:
--   • Rerolls 1-3 (per guild per day)  : FREE  (0 points)
--   • Rerolls 4-6                      : 1 point each
--   • Rerolls 7-9                      : 2 points each
--   • Rerolls 10-12                    : 3 points each ... +1 point per tier of 3
--   cost(n_used_so_far) = (n_used_so_far < 3) ? 0 : floor(n_used_so_far / 3)
-- The per-guild counter resets to 0 (back to free) at the normal daily rollover
-- (UTC day change). Server-authoritative because upgrade_points live on guilds.
--
-- This supersedes migration 064's reroll_guild_mission. The reroll BODY (refund
-- deposits, pick a new key from the recipe-aligned pool, insert the new mission)
-- is unchanged — this adds the leader gate + the per-guild counter/cost in front.
-- ============================================================================


-- ── Per-guild daily reroll counter ─────────────────────────────────────────────
alter table public.guilds
    add column if not exists reroll_count int not null default 0,
    add column if not exists reroll_day   int not null default -1;


-- ── Reroll cost curve (upgrade points) ─────────────────────────────────────────
-- p_used = how many rerolls the guild has ALREADY done today (0-based). The cost
-- of the NEXT reroll: free for the first 3, then +1 point per further block of 3.
create or replace function public._guild_reroll_cost(p_used int)
returns int
language sql
immutable
as $$
    select case when coalesce(p_used, 0) < 3 then 0 else (coalesce(p_used, 0) / 3) end;
$$;


-- ── reroll_guild_mission (LEADER-only; upgrade-point tiered cost) ──────────────
-- Returns on success:
--   { ok, cost, next_cost, points_remaining, rerolls_used }
--     cost            = points charged for THIS reroll
--     next_cost       = points the NEXT reroll will cost
--     points_remaining= guild upgrade_points after charging
--     rerolls_used    = per-guild reroll count today AFTER this one
-- Errors: account_not_found, not_in_guild, not_leader, mission_not_found,
--         mission_not_active, insufficient_points
create or replace function public.reroll_guild_mission(
    p_device_hash text,
    p_guild_id    uuid,
    p_mission_id  uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account        uuid;
    v_member         public.guild_members%rowtype;
    v_mission        public.guild_missions%rowtype;
    v_guild          public.guilds%rowtype;
    v_difficulty     text;
    v_keys           text[];
    v_new_key        text;
    v_member_count   int;
    v_multiplier     float;
    v_boost_level    int := 0;
    v_base_target    int;
    v_target         int;
    v_tokens         int;
    v_upgrade_pts    int;
    v_today          int;
    v_used           int;
    v_cost           int;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    -- Lock the guild row: leader check + atomic counter/points update.
    select * into v_guild from public.guilds where id = p_guild_id for update;
    if not found then
        return json_build_object('error', 'not_in_guild');
    end if;
    if v_guild.leader_id is distinct from v_account then
        return json_build_object('error', 'not_leader');
    end if;

    select * into v_mission from public.guild_missions where id = p_mission_id for update;
    if not found or v_mission.guild_id <> p_guild_id then
        return json_build_object('error', 'mission_not_found');
    end if;
    if v_mission.status <> 'active' then
        return json_build_object('error', 'mission_not_active');
    end if;

    -- ── Daily rollover + tiered cost ─────────────────────────────────────────
    v_today := floor(extract(epoch from now()) / 86400.0)::int;
    v_used  := case when v_guild.reroll_day = v_today then v_guild.reroll_count else 0 end;
    v_cost  := public._guild_reroll_cost(v_used);

    if v_guild.upgrade_points < v_cost then
        return json_build_object('error', 'insufficient_points',
            'cost', v_cost, 'points_remaining', v_guild.upgrade_points);
    end if;

    -- Charge points (if any) and advance the per-guild counter for today.
    update public.guilds
    set upgrade_points = upgrade_points - v_cost,
        reroll_count   = v_used + 1,
        reroll_day     = v_today
    where id = p_guild_id;

    v_difficulty := v_mission.difficulty;

    -- Return deposited items to their owners (escrow) before discarding.
    perform public._guild_refund_contributions(p_mission_id);

    delete from public.guild_contributions where mission_id = p_mission_id;
    delete from public.guild_missions      where id         = p_mission_id;

    -- Re-read the guild (points/counter just changed) for the spawn math.
    select * into v_guild from public.guilds where id = p_guild_id;

    select count(*) into v_member_count
    from public.guild_members
    where guild_id = p_guild_id and left_at is null;

    v_multiplier := greatest((v_guild.capacity::float + v_member_count::float) / 2.0, 1.0);

    select coalesce(level, 0) into v_boost_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'mission_reward_boost';
    v_boost_level := coalesce(v_boost_level, 0);

    v_keys := public._guild_mission_key_pool(v_guild.specialization);

    v_new_key := v_mission.base_mission_key;
    declare
        v_attempt int := 0;
    begin
        while v_new_key = v_mission.base_mission_key and v_attempt < 5 loop
            v_new_key := v_keys[1 + floor(random() * array_length(v_keys, 1))::int];
            v_attempt := v_attempt + 1;
        end loop;
    end;

    v_base_target := public._guild_mission_base_target(v_new_key, v_difficulty);
    if v_base_target is null then v_base_target := 5; end if;
    v_target := greatest(ceil(v_base_target::float * v_multiplier)::int, 1) * 15;

    v_tokens := public._guild_reward_tokens_for(v_new_key, v_difficulty, v_target);
    v_tokens := round(v_tokens * (1.0 + v_boost_level * 0.10))::int;
    v_upgrade_pts := public._guild_mission_upgrade_points(v_difficulty);

    insert into public.guild_missions (
        guild_id, base_mission_key, difficulty,
        target, reward_tokens, reward_upgrade_points, status, expires_at
    ) values (
        p_guild_id, v_new_key, v_difficulty,
        v_target, v_tokens, v_upgrade_pts, 'active', now() + interval '48 hours'
    );

    return json_build_object(
        'ok', true,
        'cost', v_cost,
        'next_cost', public._guild_reroll_cost(v_used + 1),
        'points_remaining', v_guild.upgrade_points,
        'rerolls_used', v_used + 1
    );
end;
$$;
grant execute on function public.reroll_guild_mission(text, uuid, uuid) to anon, authenticated;


-- ── get_guild_reroll_status ────────────────────────────────────────────────────
-- Lets the client show the NEXT reroll's cost + the free-rerolls-remaining
-- without doing a reroll. Any active member may read it.
--   { rerolls_used, next_cost, free_remaining, upgrade_points, is_leader }
create or replace function public.get_guild_reroll_status(
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
    v_guild   public.guilds%rowtype;
    v_today   int;
    v_used    int;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    select * into v_guild from public.guilds where id = p_guild_id;

    v_today := floor(extract(epoch from now()) / 86400.0)::int;
    v_used  := case when v_guild.reroll_day = v_today then v_guild.reroll_count else 0 end;

    return json_build_object(
        'rerolls_used',   v_used,
        'next_cost',      public._guild_reroll_cost(v_used),
        'free_remaining', greatest(3 - v_used, 0),
        'upgrade_points', v_guild.upgrade_points,
        'is_leader',      (v_guild.leader_id = v_account)
    );
end;
$$;
grant execute on function public.get_guild_reroll_status(text, uuid) to anon, authenticated;
