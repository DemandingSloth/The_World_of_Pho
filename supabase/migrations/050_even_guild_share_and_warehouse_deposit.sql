-- ============================================================================
-- Migration 050: Even guild/warehouse reward share + warehouse-to-mission deposit
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- TWO changes:
--
-- 1) REWARD MODEL (Model A). A completed mission's token reward R is split into:
--      • Personal share: each player who deposited gets R * (their_qty / target).
--      • Guild share: the portion filled from shared guild WAREHOUSE stock
--        (guild_qty = target - sum(player deposits)) is worth R * (guild_qty /
--        target), and THAT is split EVENLY across all current members.
--    So each member m receives:
--        floor( R * m.personal_qty / target )            -- personal
--      + floor( (R * guild_qty / target) / member_count ) -- even guild share
--    Any rounding remainder (R minus the sum actually paid) goes to the leader,
--    so the full R is always distributed.
--
--    Example: 100-bean mission, reward R, 3 members. P1 deposits 10, P2 deposits
--    20, P3 deposits 0; warehouse fills the other 70.
--      personal:  P1 = 10% R,  P2 = 20% R,  P3 = 0
--      guild share = 70% R, split 3 ways = ~23.3% R each
--      totals:    P1 ~ 33% R,  P2 ~ 43% R,  P3 ~ 23% R
--
--    Upgrade points still go to the guild as a whole (unchanged). Per-member
--    lifetime_upgrade_points (roster "score") is still credited by personal
--    contribution only — the warehouse share has no personal owner.
--
-- 2) WAREHOUSE -> MISSION DEPOSIT. New RPC deposit_warehouse_to_mission lets a
--    mining guild spend shared warehouse stock on a matching active mission.
--    It advances mission progress WITHOUT writing a per-player guild_contributions
--    row, so the amount it fills becomes part of guild_qty (the evenly-split
--    share). Fans out across every compatible active mission like direct
--    deposits (migration 049). Warehouse stock spent this way is consumed (not
--    refundable) — it's already shared guild property.
-- ============================================================================


-- ── 1. _guild_distribute_reward — Model A (personal + even guild share) ──────
create or replace function public._guild_distribute_reward(
    p_mission_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_mission       public.guild_missions%rowtype;
    v_personal_sum  int;
    v_guild_qty     int;
    v_denom         int;          -- reward denominator (guards over-deposit)
    v_member_count  int;
    v_guild_pool    int;          -- total tokens attributable to the guild share
    v_even_each     int;          -- even guild-share tokens per member
    v_paid          bigint := 0;  -- running total actually paid out
    v_member        record;
    v_personal_tok  int;
    v_leader_id     uuid;
    v_pt_share      int;
begin
    select * into v_mission from public.guild_missions where id = p_mission_id;
    if not found or v_mission.status <> 'completed' then
        return;
    end if;

    if v_mission.target <= 0 or v_mission.reward_tokens <= 0 then
        -- Still credit guild upgrade points below even if no tokens.
        null;
    end if;

    -- Sum of personal (player) deposits for this mission.
    select coalesce(sum(amount), 0) into v_personal_sum
    from public.guild_contributions
    where mission_id = p_mission_id;

    -- The guild/warehouse-filled portion is whatever personal deposits didn't
    -- cover (clamped to >= 0).
    v_guild_qty := greatest(v_mission.target - v_personal_sum, 0);

    -- Reward denominator. Normally the target; if members over-deposited past
    -- the target (contributions accumulate uncapped), use the personal sum so
    -- personal shares never sum beyond R and guild_qty stays 0.
    v_denom := greatest(v_mission.target, v_personal_sum);
    if v_denom <= 0 then
        v_denom := 1;   -- avoid divide-by-zero on a 0-target mission
    end if;

    -- Current full members (exclude members still on probation, mirroring the
    -- deposit guard: probationary members can't contribute, so they don't share
    -- the evenly-split guild pool either).
    select count(*) into v_member_count
    from public.guild_members
    where guild_id = v_mission.guild_id
      and left_at is null
      and (perks_active_at is null or perks_active_at <= extract(epoch from now()));

    -- Even guild-share tokens per member (floor; remainder handled via leader).
    v_guild_pool := 0;
    v_even_each := 0;
    if v_mission.reward_tokens > 0 and v_guild_qty > 0 then
        v_guild_pool := floor(
            v_mission.reward_tokens::float * v_guild_qty::float / v_denom::float
        )::int;
        if v_member_count > 0 then
            v_even_each := v_guild_pool / v_member_count;   -- integer division
        end if;
    end if;

    -- Guild leader (receives the rounding remainder so all of R is distributed).
    select leader_id into v_leader_id from public.guilds where id = v_mission.guild_id;

    -- Pay every full member: personal share (by their deposit) + even guild share.
    for v_member in
        select gm.account_id,
               coalesce(gc.amount, 0) as personal_qty
        from public.guild_members gm
        left join public.guild_contributions gc
          on gc.mission_id = p_mission_id and gc.account_id = gm.account_id
        where gm.guild_id = v_mission.guild_id
          and gm.left_at is null
          and (gm.perks_active_at is null or gm.perks_active_at <= extract(epoch from now()))
    loop
        v_personal_tok := 0;
        if v_mission.reward_tokens > 0 and v_member.personal_qty > 0 then
            v_personal_tok := floor(
                v_mission.reward_tokens::float * v_member.personal_qty::float / v_denom::float
            )::int;
        end if;

        if (v_personal_tok + v_even_each) > 0 then
            update public.accounts
            set token_balance = token_balance + (v_personal_tok + v_even_each)
            where id = v_member.account_id;

            insert into public.token_ledger (account_id, delta, reason, ref_id)
            values (v_member.account_id, v_personal_tok + v_even_each, 'guild_reward', p_mission_id);

            v_paid := v_paid + v_personal_tok + v_even_each;
        end if;

        -- Lifetime upgrade-point score: still credited by PERSONAL contribution
        -- only (the warehouse share has no personal owner).
        if v_mission.reward_upgrade_points > 0 and v_member.personal_qty > 0 then
            v_pt_share := floor(
                v_mission.reward_upgrade_points::float * v_member.personal_qty::float / v_denom::float
            )::int;
            if v_pt_share > 0 then
                update public.guild_members
                set lifetime_upgrade_points = lifetime_upgrade_points + v_pt_share
                where guild_id = v_mission.guild_id
                  and account_id = v_member.account_id;
            end if;
        end if;
    end loop;

    -- Hand any rounding remainder (R - total paid) to the leader so the full
    -- token reward is always distributed.
    if v_mission.reward_tokens > 0 and v_leader_id is not null then
        if v_mission.reward_tokens::bigint - v_paid > 0 then
            update public.accounts
            set token_balance = token_balance + (v_mission.reward_tokens::bigint - v_paid)
            where id = v_leader_id;

            insert into public.token_ledger (account_id, delta, reason, ref_id)
            values (v_leader_id, v_mission.reward_tokens::bigint - v_paid, 'guild_reward', p_mission_id);
        end if;
    end if;

    -- Guild upgrade points go to the guild as a whole (unchanged).
    if v_mission.reward_upgrade_points > 0 then
        update public.guilds
        set upgrade_points = upgrade_points + v_mission.reward_upgrade_points
        where id = v_mission.guild_id;
    end if;
end;
$$;
revoke all on function public._guild_distribute_reward(uuid) from anon, authenticated;


-- ── 2. deposit_warehouse_to_mission — spend shared stock as the GUILD share ──
-- Deducts p_amount of p_item_key from guild_warehouse and advances every active
-- mission compatible with that item (generic + specific key, migration 049).
-- Crucially, it does NOT write a per-player guild_contributions row — the amount
-- it fills becomes part of guild_qty and is rewarded as the evenly-split guild
-- share. Mining-guild / leader-or-member callable (any member may spend the
-- shared warehouse on a mission).
create or replace function public.deposit_warehouse_to_mission(
    p_device_hash text,
    p_guild_id    uuid,
    p_item_key    text,
    p_amount      int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account    uuid;
    v_member     public.guild_members%rowtype;
    v_spec       text;
    v_have       bigint;
    v_deduct     int;
    v_keys       text[];
    v_mission    record;
    v_new_prog   int;
    v_applied    boolean := false;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then return json_build_object('error', 'account_not_found'); end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    select specialization into v_spec from public.guilds where id = p_guild_id;
    if v_spec <> 'mining' then
        return json_build_object('error', 'not_mining_guild');
    end if;

    if p_amount is null or p_amount <= 0 then
        return json_build_object('error', 'invalid_amount');
    end if;

    v_keys := public._guild_deposit_keys_for_item(p_item_key);
    if array_length(v_keys, 1) is null then
        return json_build_object('error', 'invalid_item');
    end if;

    -- Must be at least one matching active mission, else don't spend stock.
    if not exists (
        select 1 from public.guild_missions
        where guild_id = p_guild_id
          and base_mission_key = any(v_keys)
          and status = 'active'
    ) then
        return json_build_object('error', 'no_matching_mission');
    end if;

    -- Lock + check warehouse stock.
    select coalesce(amount, 0) into v_have
    from public.guild_warehouse
    where guild_id = p_guild_id and item_key = p_item_key
    for update;
    v_have := coalesce(v_have, 0);
    if v_have <= 0 then
        return json_build_object('error', 'warehouse_empty');
    end if;

    v_deduct := least(p_amount, v_have::int);

    -- Deduct from the warehouse up front.
    update public.guild_warehouse
    set amount = amount - v_deduct, updated_at = now()
    where guild_id = p_guild_id and item_key = p_item_key;

    -- Advance every matching active mission by v_deduct, as the GUILD share
    -- (no guild_contributions row -> counts toward guild_qty at reward time).
    for v_mission in
        select id, target, progress
        from public.guild_missions
        where guild_id = p_guild_id
          and base_mission_key = any(v_keys)
          and status = 'active'
        order by spawned_at asc, id asc
        for update
    loop
        v_applied := true;
        v_new_prog := least(v_mission.progress + v_deduct, v_mission.target);
        update public.guild_missions
        set progress = v_new_prog
        where id = v_mission.id;

        if v_new_prog >= v_mission.target then
            perform public._complete_guild_mission(v_mission.id);
        end if;
    end loop;

    return json_build_object('ok', true, 'deposited', v_deduct);
end;
$$;
grant execute on function public.deposit_warehouse_to_mission(text, uuid, text, int) to anon, authenticated;
