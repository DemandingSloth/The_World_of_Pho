-- ============================================================================
-- Migration 042: Refund guild mission deposits on fail (reroll / expire)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- WHAT: When a DEPOSIT guild mission is rerolled or expires before reaching
-- 100%, the items members deposited are returned to those members via escrow
-- (claimed back into their local inventory next time they open the online
-- marketplace — same mechanism as marketplace buys/cancels). Previously these
-- items were silently discarded.
--
-- HOW: contributions were stored only as a numeric amount, so the server never
-- knew WHICH item was deposited. We add a per-item ledger
-- (guild_contribution_items) and thread the item key through
-- record_guild_contribution. On reroll/expire we read that ledger and escrow
-- each (account, item_key, amount) back to its owner, then clear it.
--
-- CLEAN FROM DEPLOY: contributions made BEFORE this migration have no per-item
-- rows, so they aren't refunded (as before). Only deposits made after deploy
-- are tracked and refundable. The aggregate guild_contributions.amount is still
-- maintained for progress + reward distribution (unchanged).
-- ============================================================================


-- ── Per-item contribution ledger (for refunds) ───────────────────────────────
create table if not exists public.guild_contribution_items (
    mission_id uuid   not null references public.guild_missions(id) on delete cascade,
    account_id uuid   not null references public.accounts(id)       on delete cascade,
    item_key   text   not null,                 -- canonical key, e.g. 'gem:diamond', 'crop:beans'
    amount     bigint not null default 0 check (amount >= 0),
    updated_at timestamptz not null default now(),
    primary key (mission_id, account_id, item_key)
);
create index if not exists guild_contribution_items_mission_idx
    on public.guild_contribution_items (mission_id);
alter table public.guild_contribution_items enable row level security;
-- (no client policies — functions only)


-- ── record_guild_contribution — now records the item key per deposit ─────────
-- Adds p_item_key. The aggregate guild_contributions row (amount only) is kept
-- exactly as before for progress + reward distribution; we ALSO upsert a
-- per-item row so a later reroll/expire can refund the exact items.
-- Backward compatible: p_item_key defaults to '' (older clients) — in that case
-- only the aggregate is updated and the deposit simply isn't itemized/refundable.
create or replace function public.record_guild_contribution(
    p_device_hash text,
    p_guild_id    uuid,
    p_base_key    text,
    p_amount      int,
    p_item_key    text default ''
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account  uuid;
    v_member   public.guild_members%rowtype;
    v_mission  record;
    v_new_prog int;
begin
    if p_amount is null or p_amount <= 0 then
        return json_build_object('ok', true);
    end if;

    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('ok', true);
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('ok', true);
    end if;

    -- Probation guard.
    if v_member.perks_active_at is not null
       and v_member.perks_active_at > extract(epoch from now()) then
        return json_build_object('ok', true);
    end if;

    for v_mission in
        select id, target, progress
        from public.guild_missions
        where guild_id = p_guild_id
          and base_mission_key = p_base_key
          and status = 'active'
        for update
    loop
        -- Aggregate (progress + reward distribution) — unchanged.
        insert into public.guild_contributions (mission_id, account_id, amount, updated_at)
        values (v_mission.id, v_account, p_amount, now())
        on conflict (mission_id, account_id)
        do update set
            amount     = public.guild_contributions.amount + excluded.amount,
            updated_at = now();

        -- Per-item ledger (for refunds). Only when the client told us the item.
        if p_item_key is not null and length(p_item_key) > 0 then
            insert into public.guild_contribution_items (mission_id, account_id, item_key, amount, updated_at)
            values (v_mission.id, v_account, p_item_key, p_amount, now())
            on conflict (mission_id, account_id, item_key)
            do update set
                amount     = public.guild_contribution_items.amount + excluded.amount,
                updated_at = now();
        end if;

        v_new_prog := least(v_mission.progress + p_amount, v_mission.target);

        update public.guild_missions
        set progress = v_new_prog
        where id = v_mission.id;

        if v_new_prog >= v_mission.target then
            perform public._complete_guild_mission(v_mission.id);
        end if;
    end loop;

    return json_build_object('ok', true);
end;
$$;
-- Grant the new 5-arg signature. (The old 4-arg one is replaced; PostgREST
-- resolves by provided args, and the new client always sends p_item_key.)
grant execute on function public.record_guild_contribution(text, uuid, text, int, text) to anon, authenticated;


-- ── _guild_refund_contributions — escrow deposited items back to owners ──────
-- Reads the per-item ledger for a mission and credits each owner's escrow, then
-- clears the ledger rows (so a refund can't double-fire). Safe to call on a
-- completed mission too (there just won't be a refund if you only call it on
-- fail paths — we call it only on reroll/expire).
create or replace function public._guild_refund_contributions(p_mission_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    r record;
begin
    for r in
        select account_id, item_key, amount
        from public.guild_contribution_items
        where mission_id = p_mission_id and amount > 0
    loop
        perform public._escrow_add(r.account_id, r.item_key, r.amount);
    end loop;

    delete from public.guild_contribution_items where mission_id = p_mission_id;
end;
$$;
revoke all on function public._guild_refund_contributions(uuid) from anon, authenticated;


-- ── _guild_expire_and_refund — refund + expire stale missions for a guild ────
-- Replaces the bare "update ... set status='expired'" used on read. For every
-- active mission past its expiry, refund the depositors (escrow) and then mark
-- it expired. Called from get_guild_missions / get_player_guild_summary.
create or replace function public._guild_expire_and_refund(p_guild_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_id uuid;
begin
    for v_id in
        select id from public.guild_missions
        where guild_id = p_guild_id
          and status = 'active'
          and expires_at < now()
        for update
    loop
        perform public._guild_refund_contributions(v_id);
        update public.guild_missions set status = 'expired' where id = v_id;
    end loop;
end;
$$;
revoke all on function public._guild_expire_and_refund(uuid) from anon, authenticated;


-- ── reroll_guild_mission — refund before discarding ──────────────────────────
-- Same as migration 040 but calls _guild_refund_contributions(mission) before
-- deleting, so a rerolled mission returns its deposits to the depositors.
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
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    select * into v_mission from public.guild_missions where id = p_mission_id for update;
    if not found or v_mission.guild_id <> p_guild_id then
        return json_build_object('error', 'mission_not_found');
    end if;
    if v_mission.status <> 'active' then
        return json_build_object('error', 'mission_not_active');
    end if;

    v_difficulty := v_mission.difficulty;

    -- Return deposited items to their owners (escrow) before discarding.
    perform public._guild_refund_contributions(p_mission_id);

    delete from public.guild_contributions where mission_id = p_mission_id;
    delete from public.guild_missions      where id         = p_mission_id;

    select * into v_guild from public.guilds where id = p_guild_id;

    select count(*) into v_member_count
    from public.guild_members
    where guild_id = p_guild_id and left_at is null;

    v_multiplier := greatest((v_guild.capacity::float + v_member_count::float) / 2.0, 1.0);

    select coalesce(level, 0) into v_boost_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'mission_reward_boost';
    v_boost_level := coalesce(v_boost_level, 0);

    if v_guild.specialization = 'gardening' then
        v_keys := array[
            'deposit_beans','deposit_cucumbers','deposit_peppers','deposit_squash',
            'deposit_grapes','deposit_sunflower','deposit_cauliflower',
            'deposit_pineapple','deposit_watermelon',
            'deposit_produce','deposit_fruit',
            'deposit_plum','deposit_lemon','deposit_apple','deposit_banana','deposit_coconut'
        ];
    else
        v_keys := array[
            'deposit_gems','deposit_polished','deposit_ores',
            'deposit_gem_gold','deposit_gem_blue_stone','deposit_gem_pink_stone',
            'deposit_gem_violet_stone','deposit_gem_black_pearl','deposit_gem_emerald',
            'deposit_gem_ruby','deposit_gem_diamond',
            'deposit_polished_blue_stone','deposit_polished_pink_stone',
            'deposit_polished_violet_stone','deposit_polished_black_pearl',
            'deposit_polished_emerald','deposit_polished_ruby','deposit_polished_diamond',
            'deposit_ore_iron_ore','deposit_ore_iron_bar','deposit_ore_copper_ore',
            'deposit_ore_copper_ingot','deposit_ore_gold_ingot'
        ];
    end if;

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

    select r.tokens, r.upgrade_pts into v_tokens, v_upgrade_pts
    from public._guild_mission_base_reward(v_difficulty) as r;
    v_tokens := round(v_tokens * (1.0 + v_boost_level * 0.10))::int;

    insert into public.guild_missions (
        guild_id, base_mission_key, difficulty,
        target, reward_tokens, reward_upgrade_points, status, expires_at
    ) values (
        p_guild_id, v_new_key, v_difficulty,
        v_target, v_tokens, v_upgrade_pts, 'active', now() + interval '48 hours'
    );

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.reroll_guild_mission(text, uuid, uuid) to anon, authenticated;


-- ── Rewire the expire-on-read paths to refund first ──────────────────────────
-- get_guild_missions (was 039) and get_player_guild_summary (was 041) each did
-- a bare "update ... set status='expired'". Recreate them to call
-- _guild_expire_and_refund instead so expiry returns deposits. Bodies are
-- otherwise identical to 039 / 041.

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

    -- Expire stale missions first, refunding their deposits to owners.
    perform public._guild_expire_and_refund(p_guild_id);

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
