-- ============================================================================
-- Guilds Task 1: core tables
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Tables created here:
--   guilds               — one row per guild
--   guild_members        — membership + probation + role
--   guild_upgrade_levels — per-guild upgrade track levels
--   guild_missions       — active collaborative missions
--   guild_contributions  — per-member progress on a guild mission
--   guild_links          — active links between two guilds (different specs)
--   guild_link_requests  — pending link requests awaiting acceptance
--
-- Design rules (mirrors the marketplace pattern):
--   * RLS ON for every table, zero client policies — all access through
--     SECURITY DEFINER RPCs only.
--   * UUID PKs everywhere, timestamptz for all times.
--   * No direct client reads/writes.
-- ============================================================================

-- ── guilds ──────────────────────────────────────────────────────────────────
-- One row per guild. `specialization` is always 'gardening' or 'mining'.
-- `upgrade_points` accumulates whenever a guild mission completes; it is spent
-- by purchase_guild_upgrade.
-- `leader_id` is a denormalized FK into guild_members for fast leader checks.
create table if not exists public.guilds (
    id               uuid        primary key default gen_random_uuid(),
    name             text        not null unique,
    specialization   text        not null check (specialization in ('gardening', 'mining')),
    capacity         int         not null default 5 check (capacity between 5 and 20),
    upgrade_points   int         not null default 0,
    leader_id        uuid,       -- FK to accounts.id set after first insert
    created_at       timestamptz not null default now()
);
alter table public.guilds enable row level security;
-- No client policies — RPCs only.

-- ── guild_members ────────────────────────────────────────────────────────────
-- One row per (guild, account) pair.
-- `role`            : 'leader' | 'member'
-- `perks_active_at` : NULL means perks are immediately active (first-ever join
--                     never had a previous guild, no probation needed).
--                     Non-null means perks become active after this timestamp
--                     (Unix epoch stored as float for easy GDScript comparison).
-- `joined_at`       : when they joined this guild.
-- `left_at`         : when they left (NULL while still active); kept for the
--                     48h/24h cooldown enforcement.
create table if not exists public.guild_members (
    id              uuid        primary key default gen_random_uuid(),
    guild_id        uuid        not null references public.guilds(id) on delete cascade,
    account_id      uuid        not null references public.accounts(id) on delete cascade,
    role            text        not null default 'member' check (role in ('leader', 'member')),
    perks_active_at double precision,    -- NULL = active immediately
    joined_at       timestamptz not null default now(),
    left_at         timestamptz,         -- NULL = currently active
    previous_guild_id uuid,              -- guild they left before joining this one
    previous_guild_spec text,            -- cached spec of previous guild for cooldown check
    unique (guild_id, account_id)
);
create index if not exists guild_members_account_idx on public.guild_members (account_id)
    where left_at is null;
alter table public.guild_members enable row level security;

-- ── guild_upgrade_levels ────────────────────────────────────────────────────
-- One row per (guild, upgrade_key). Max level is 10 for all tracks.
-- upgrade_key values (matches client GuildManager references):
--   gardening spec: 'garden_yield', 'garden_speed', 'community_garden_size'
--   mining spec   : 'gem_bonus', 'mine_depth', 'expedition_reward'
--   shared        : 'mission_reward_boost', 'capacity_boost', 'perk_duration'
create table if not exists public.guild_upgrade_levels (
    guild_id    uuid not null references public.guilds(id) on delete cascade,
    upgrade_key text not null,
    level       int  not null default 0 check (level between 0 and 10),
    primary key (guild_id, upgrade_key)
);
alter table public.guild_upgrade_levels enable row level security;

-- ── guild_missions ──────────────────────────────────────────────────────────
-- Active collaborative missions for a guild. A guild can have up to 3 active
-- missions at once (easy / medium / hard difficulty slots, mirroring solo
-- MissionBoard).
-- `base_mission_key` matches the strings in GuildManager.mission_type_to_base_key().
-- `target`     : total contributions needed (pre-scaled by mission_multiplier).
-- `progress`   : running total of all member contributions.
-- `status`     : 'active' | 'completed' | 'expired'
-- `reward_tokens` : total tokens shared among members on completion.
create table if not exists public.guild_missions (
    id               uuid        primary key default gen_random_uuid(),
    guild_id         uuid        not null references public.guilds(id) on delete cascade,
    base_mission_key text        not null,
    difficulty       text        not null check (difficulty in ('easy', 'medium', 'hard')),
    target           int         not null,
    progress         int         not null default 0,
    reward_tokens    int         not null default 0,
    reward_upgrade_points int   not null default 0,
    status           text        not null default 'active'
                                    check (status in ('active', 'completed', 'expired')),
    spawned_at       timestamptz not null default now(),
    completed_at     timestamptz,
    expires_at       timestamptz not null default (now() + interval '48 hours')
);
create index if not exists guild_missions_guild_active_idx
    on public.guild_missions (guild_id) where status = 'active';
alter table public.guild_missions enable row level security;

-- ── guild_contributions ─────────────────────────────────────────────────────
-- Per-member contribution to a specific guild_mission.
-- Used to calculate each member's share of the reward on completion.
create table if not exists public.guild_contributions (
    id          uuid    primary key default gen_random_uuid(),
    mission_id  uuid    not null references public.guild_missions(id) on delete cascade,
    account_id  uuid    not null references public.accounts(id)       on delete cascade,
    amount      int     not null default 0,
    updated_at  timestamptz not null default now(),
    unique (mission_id, account_id)
);
create index if not exists guild_contributions_mission_idx
    on public.guild_contributions (mission_id);
alter table public.guild_contributions enable row level security;

-- ── guild_links ──────────────────────────────────────────────────────────────
-- A confirmed link between two guilds with different specializations.
-- One row per pair; guild_a_id < guild_b_id to prevent duplicates.
-- Members of a linked guild get the cross-spec perks from effective_perks.
-- `linked_at` : when the link was accepted.
create table if not exists public.guild_links (
    id         uuid        primary key default gen_random_uuid(),
    guild_a_id uuid        not null references public.guilds(id) on delete cascade,
    guild_b_id uuid        not null references public.guilds(id) on delete cascade,
    linked_at  timestamptz not null default now(),
    check (guild_a_id < guild_b_id),
    unique (guild_a_id, guild_b_id)
);
alter table public.guild_links enable row level security;

-- ── guild_link_requests ──────────────────────────────────────────────────────
-- Pending link requests sent by one guild's leader to another.
-- Status: 'pending' | 'accepted' | 'rejected'
create table if not exists public.guild_link_requests (
    id                  uuid        primary key default gen_random_uuid(),
    requesting_guild_id uuid        not null references public.guilds(id) on delete cascade,
    target_guild_id     uuid        not null references public.guilds(id) on delete cascade,
    status              text        not null default 'pending'
                                        check (status in ('pending', 'accepted', 'rejected')),
    created_at          timestamptz not null default now(),
    unique (requesting_guild_id, target_guild_id)
);
alter table public.guild_link_requests enable row level security;

-- ── Internal helpers (no client access) ─────────────────────────────────────

-- Returns the account_id for a device_hash, or null if not found.
create or replace function public._guild_resolve_account(p_device_hash text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
    select id from public.accounts where device_hash = p_device_hash limit 1;
$$;
revoke all on function public._guild_resolve_account(text) from anon, authenticated;

-- Returns the active guild_members row for an account, or null.
create or replace function public._guild_active_member(p_account_id uuid)
returns public.guild_members
language sql
stable
security definer
set search_path = public
as $$
    select * from public.guild_members
    where account_id = p_account_id and left_at is null
    limit 1;
$$;
revoke all on function public._guild_active_member(uuid) from anon, authenticated;

-- Returns the Unix timestamp (double) for when perks should activate after
-- joining a new guild. NULL if the player has never been in a guild before.
-- Rules (§9 of the plan):
--   * No previous guild → NULL (perks immediately active)
--   * Previous guild had different spec, and player chose this guild for its
--     linked spec → COOLDOWN_LINKED_SEC = 24 h
--   * Otherwise → COOLDOWN_NORMAL_SEC = 48 h
create or replace function public._guild_perks_active_at(
    p_account_id       uuid,
    p_new_guild_spec   text
)
returns double precision
language plpgsql
security definer
set search_path = public
as $$
declare
    v_prev_spec text;
    v_linked    bool := false;
    v_delay     double precision;
begin
    -- Find the most recent guild the player was in (left_at is not null).
    select previous_guild_spec into v_prev_spec
    from public.guild_members
    where account_id = p_account_id and left_at is not null
    order by left_at desc
    limit 1;

    if v_prev_spec is null then
        return null;   -- never been in a guild → immediate perks
    end if;

    -- Check if the previous and new guilds are linked (§7 cooldown reduction).
    -- If the new guild was linked to their old one they benefit from the shorter delay.
    -- We can't check that directly here (the link uses guild ids not specs), so
    -- we conservatively use spec difference as the heuristic.
    if v_prev_spec <> p_new_guild_spec then
        v_delay := 24.0 * 3600.0;  -- 24 h — linked-guild swap
    else
        v_delay := 48.0 * 3600.0;  -- 48 h — same-spec swap
    end if;

    return extract(epoch from now()) + v_delay;
end;
$$;
revoke all on function public._guild_perks_active_at(uuid, text) from anon, authenticated;

-- Builds the upgrades dict {upgrade_key: level} for a guild.
create or replace function public._guild_upgrades_dict(p_guild_id uuid)
returns json
language sql
stable
security definer
set search_path = public
as $$
    select coalesce(
        (select json_object_agg(upgrade_key, level)
         from public.guild_upgrade_levels
         where guild_id = p_guild_id),
        '{}'::json
    );
$$;
revoke all on function public._guild_upgrades_dict(uuid) from anon, authenticated;

-- Returns the effective perk dict for an account: their own guild's perks
-- plus cross-spec perks from the linked guild (if any).
-- Perk values are upgrade levels cast to int; the client interprets the key.
create or replace function public._guild_effective_perks(
    p_account_id uuid,
    p_guild_id   uuid
)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_linked_guild uuid;
    v_perks        json;
begin
    -- Own guild upgrades.
    v_perks := public._guild_upgrades_dict(p_guild_id);

    -- Find linked guild (if any).
    select case
        when guild_a_id = p_guild_id then guild_b_id
        else guild_a_id
    end into v_linked_guild
    from public.guild_links
    where guild_a_id = p_guild_id or guild_b_id = p_guild_id
    limit 1;

    if v_linked_guild is null then
        return v_perks;
    end if;

    -- Merge linked guild's upgrades under a 'linked_' prefix so the client
    -- can distinguish own vs cross-spec perks.
    return (
        select v_perks::jsonb || jsonb_object_agg('linked_' || upgrade_key, level)
        from public.guild_upgrade_levels
        where guild_id = v_linked_guild
    )::json;
end;
$$;
revoke all on function public._guild_effective_perks(uuid, uuid) from anon, authenticated;

-- Awards upgrade points (and optionally tokens) to all active members of a
-- guild upon mission completion. Called inside complete_guild_mission.
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
    v_contrib      int;
begin
    select * into v_mission from public.guild_missions where id = p_mission_id;
    if not found or v_mission.status <> 'completed' then
        return;
    end if;

    -- Sum all contributions so we can allocate proportionally.
    select coalesce(sum(amount), 0) into v_total_contrib
    from public.guild_contributions
    where mission_id = p_mission_id;

    if v_total_contrib <= 0 then
        return;
    end if;

    -- Distribute token reward + upgrade_points to each contributing member.
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
    end loop;

    -- Upgrade points go to the guild as a whole (not per-member).
    if v_mission.reward_upgrade_points > 0 then
        update public.guilds
        set upgrade_points = upgrade_points + v_mission.reward_upgrade_points
        where id = v_mission.guild_id;
    end if;
end;
$$;
revoke all on function public._guild_distribute_reward(uuid) from anon, authenticated;
