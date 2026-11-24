-- ============================================================================
-- Migration 104: Trader's Tongue — double Online Special Mission rewards
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 014 (claim_mission + _assign_mission_to_slot + _mission_progress_count).
--
-- The Curried Veggie Bowl recipe grants "Trader's Tongue": for 1 hour, online
-- special mission rewards are doubled. Mission tokens are server-authoritative,
-- so the boost window lives ON THE SERVER (accounts.mission_boost_until) — the
-- client can't double a reward by itself.
--
--   1. accounts.mission_boost_until — end of the active boost window (or NULL).
--   2. activate_mission_boost(device_hash, recipes) — opens/extends the window
--      by 1 hour per recipe used (stacks onto an active window), capped at
--      24 hours ahead. The client calls this BEFORE consuming the recipe.
--   3. claim_mission REWRITTEN (supersedes 014) — identical, plus: while the
--      window is open the reward is doubled. The 5,000/day mission cap is
--      checked against the BASE reward only; the bonus half is logged
--      separately ('mission_boost') and does not count toward the cap.
--      Returns { ok, reward (total), base_reward, bonus, new_balance }.
-- ============================================================================


-- ── 1. Boost window ─────────────────────────────────────────────────────────
alter table public.accounts
    add column if not exists mission_boost_until timestamptz;


-- ── 2. activate_mission_boost ───────────────────────────────────────────────
-- Returns { ok, boost_until (epoch secs), seconds_left } | { error }
--   errors: account_not_found, invalid_quantity
create or replace function public.activate_mission_boost(
    p_device_hash text,
    p_recipes     int default 1
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_current timestamptz;
    v_new     timestamptz;
begin
    if p_recipes is null or p_recipes < 1 or p_recipes > 24 then
        return json_build_object('error', 'invalid_quantity');
    end if;

    select id, mission_boost_until into v_account, v_current
    from public.accounts where device_hash = p_device_hash for update;
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    -- Stack onto an active window; never more than 24h ahead.
    v_new := greatest(coalesce(v_current, now()), now())
             + make_interval(hours => p_recipes);
    v_new := least(v_new, now() + interval '24 hours');

    update public.accounts set mission_boost_until = v_new where id = v_account;

    return json_build_object('ok', true,
        'boost_until',  extract(epoch from v_new),
        'seconds_left', greatest(0, floor(extract(epoch from (v_new - now()))))::bigint);
end;
$$;
grant execute on function public.activate_mission_boost(text, int) to anon, authenticated;


-- ── 3. claim_mission (supersedes 014) ───────────────────────────────────────
create or replace function public.claim_mission(
    p_device_hash text,
    p_mission_id  uuid          -- account_missions.id (the assignment)
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_daily_cap    bigint := 5000;
    v_account      uuid;
    v_balance      bigint;
    v_boost_until  timestamptz;
    v_am           public.account_missions%rowtype;
    v_tpl          public.mission_templates%rowtype;
    v_progress     int;
    v_earned_today bigint;
    v_base         bigint;
    v_bonus        bigint := 0;
begin
    select id, token_balance, mission_boost_until
    into v_account, v_balance, v_boost_until
    from public.accounts where device_hash = p_device_hash for update;
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select * into v_am from public.account_missions
    where id = p_mission_id and account_id = v_account for update;
    if not found then
        return json_build_object('error', 'mission_not_found');
    end if;
    if v_am.expires_at <= now() then
        return json_build_object('error', 'mission_expired');
    end if;
    if v_am.claimed then
        return json_build_object('error', 'already_claimed');
    end if;

    select * into v_tpl from public.mission_templates where id = v_am.template_id;
    if not found then
        return json_build_object('error', 'mission_not_found');
    end if;

    v_progress := public._mission_progress_count(v_account, v_tpl.objective_type) - v_am.baseline_count;
    if v_progress < v_tpl.target then
        return json_build_object('error', 'not_eligible',
            'progress', greatest(0, v_progress), 'target', v_tpl.target);
    end if;

    v_base := v_tpl.reward_tokens;

    -- Daily cap counts BASE mission rewards only (reason 'mission').
    select coalesce(sum(delta), 0) into v_earned_today
    from public.token_ledger
    where account_id = v_account and reason = 'mission' and delta > 0
      and created_at >= (now() at time zone 'utc')::date;
    if v_earned_today + v_base > v_daily_cap then
        return json_build_object('error', 'daily_cap_reached');
    end if;

    -- Trader's Tongue: double while the server-side window is open.
    if v_boost_until is not null and v_boost_until > now() then
        v_bonus := v_base;
    end if;

    -- Grant reward (base + bonus).
    update public.accounts set token_balance = token_balance + v_base + v_bonus
    where id = v_account;

    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_account, v_base, 'mission', v_am.id);
    if v_bonus > 0 then
        insert into public.token_ledger (account_id, delta, reason, ref_id)
        values (v_account, v_bonus, 'mission_boost', v_am.id);
    end if;

    -- Immediately spawn a NEW mission into this slot (fresh 24h window + new
    -- baseline). Serialize per account (same as 014).
    perform pg_advisory_xact_lock(hashtextextended(v_account::text, 0));
    perform public._assign_mission_to_slot(v_account, v_am.slot);

    return json_build_object('ok', true,
        'reward',      v_base + v_bonus,
        'base_reward', v_base,
        'bonus',       v_bonus,
        'new_balance', v_balance + v_base + v_bonus);
end;
$$;
grant execute on function public.claim_mission(text, uuid) to anon, authenticated;
