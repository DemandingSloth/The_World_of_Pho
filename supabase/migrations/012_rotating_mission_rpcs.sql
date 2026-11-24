-- ============================================================================
-- Marketplace Option B (Task 4+5/7): rotating get_mission_status + claim_mission
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 010_mission_templates.sql, 011_account_missions.sql,
-- 008_mission_rewards.sql (for _mission_progress_count + token_ledger/daily cap).
--
-- These CREATE OR REPLACE the get_mission_status / claim_mission from migration
-- 008 so they now work off the per-account rotating assignments instead of the
-- global online_missions rows.
--
-- The client contract is preserved: get_mission_status still returns an array of
--   { id, title, description, objective_type, target, reward_tokens,
--     progress, claimed, window_end }
-- with two changes:
--   • id is now the ASSIGNMENT id (account_missions.id) — claim_mission takes it.
--   • window_end is the assignment's expires_at (the 48h refresh time).
-- A new field expires_at is included too (same value) for clarity/countdown.
-- ============================================================================

-- ── get_mission_status(device_hash) ─────────────────────────────────────────
-- Ensures the caller has a live set of 3, then returns them with windowed
-- progress. Anonymous / unregistered callers get an empty array.
create or replace function public.get_mission_status(p_device_hash text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_result  json;
begin
    select id into v_account from public.accounts where device_hash = p_device_hash;
    if v_account is null then
        return '[]'::json;
    end if;

    -- Lazily (re)assign the trio if the previous set expired.
    perform public._ensure_missions(v_account);

    select coalesce(json_agg(row_to_json(t) order by t.slot asc), '[]'::json)
    into v_result
    from (
        select
            am.id,                                   -- assignment id (claim uses this)
            mt.title,
            mt.description,
            mt.objective_type,
            mt.target,
            mt.reward_tokens,
            -- Windowed progress: lifetime count minus baseline at assignment.
            greatest(0, least(mt.target,
                public._mission_progress_count(v_account, mt.objective_type) - am.baseline_count
            )) as progress,
            am.claimed,
            am.expires_at as window_end,
            am.expires_at,
            am.slot
        from public.account_missions am
        join public.mission_templates mt on mt.id = am.template_id
        where am.account_id = v_account and am.expires_at > now()
    ) t;

    return v_result;
end;
$$;

grant execute on function public.get_mission_status(text) to anon, authenticated;

-- ── claim_mission(device_hash, assignment_id) ───────────────────────────────
-- Verifies WINDOWED progress on the server, checks not-already-claimed, not
-- expired, and the daily earn cap, then credits the reward + logs it.
-- Returns: { ok, reward, new_balance } | { error }
--   codes: account_not_found, mission_not_found, mission_expired,
--          not_eligible, already_claimed, daily_cap_reached
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
    v_daily_cap    bigint := 5000;   -- max mission tokens per account per UTC day
    v_account      uuid;
    v_balance      bigint;
    v_am           public.account_missions%rowtype;
    v_tpl          public.mission_templates%rowtype;
    v_progress     int;
    v_earned_today bigint;
begin
    select id, token_balance into v_account, v_balance
    from public.accounts where device_hash = p_device_hash for update;
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    -- Lock the assignment row for this account.
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

    -- Server-verified WINDOWED progress.
    v_progress := public._mission_progress_count(v_account, v_tpl.objective_type) - v_am.baseline_count;
    if v_progress < v_tpl.target then
        return json_build_object('error', 'not_eligible',
            'progress', greatest(0, v_progress), 'target', v_tpl.target);
    end if;

    -- Daily earn cap (sum today's positive 'mission' ledger credits).
    select coalesce(sum(delta), 0) into v_earned_today
    from public.token_ledger
    where account_id = v_account and reason = 'mission' and delta > 0
      and created_at >= (now() at time zone 'utc')::date;
    if v_earned_today + v_tpl.reward_tokens > v_daily_cap then
        return json_build_object('error', 'daily_cap_reached');
    end if;

    -- Grant.
    update public.accounts set token_balance = token_balance + v_tpl.reward_tokens
    where id = v_account;

    update public.account_missions
    set claimed = true, claimed_at = now()
    where id = v_am.id;

    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_account, v_tpl.reward_tokens, 'mission', v_am.id);

    return json_build_object('ok', true, 'reward', v_tpl.reward_tokens,
        'new_balance', v_balance + v_tpl.reward_tokens);
end;
$$;

grant execute on function public.claim_mission(text, uuid) to anon, authenticated;
