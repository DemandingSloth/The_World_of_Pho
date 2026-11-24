-- ============================================================================
-- Marketplace missions: 24h window + per-slot replace-on-claim
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Supersedes the relevant functions from 011 and 012.
--
-- Changes vs the previous (48h, whole-set) behavior:
--   * Window shortened 48h -> 24h.
--   * Missions are now managed PER SLOT (0..2), not as one all-or-nothing trio:
--       - _ensure_missions refills any slot that is missing OR expired, each
--         with its own fresh 24h window + baseline.
--       - claim_mission, after granting a reward, immediately spawns a NEW
--         mission into that same slot (fresh 24h window) so completing a
--         mission is instantly replaced instead of leaving an empty slot.
--   * Replacement avoids handing the player a template already active in one of
--     their other slots.
-- ============================================================================

-- Window length in one place.
-- (Inlined as interval literals below; documented here: 24 hours.)

-- ── Assign one weighted-random enabled template into a specific slot ─────────
-- Captures the account's current objective count as the baseline (so progress
-- is windowed) and sets a fresh 24h expiry. Excludes templates already active
-- in the account's OTHER slots to avoid duplicates. Upserts the slot row.
create or replace function public._assign_mission_to_slot(p_account uuid, p_slot int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_expiry timestamptz := now() + interval '24 hours';
    v_tpl    record;
    v_count  int;
begin
    select id, objective_type
    into v_tpl
    from public.mission_templates
    where is_enabled
      and id not in (
          select template_id from public.account_missions
          where account_id = p_account
            and slot <> p_slot
            and expires_at > now()
      )
    order by (random() / greatest(weight, 1)) asc
    limit 1;

    -- If the pool is too small to avoid a duplicate, fall back to any enabled
    -- template (better a repeat than an empty slot).
    if v_tpl.id is null then
        select id, objective_type into v_tpl
        from public.mission_templates
        where is_enabled
        order by (random() / greatest(weight, 1)) asc
        limit 1;
    end if;
    if v_tpl.id is null then
        return;  -- no enabled templates at all
    end if;

    v_count := public._mission_progress_count(p_account, v_tpl.objective_type);

    insert into public.account_missions
        (account_id, template_id, slot, assigned_at, expires_at, baseline_count, claimed, claimed_at)
    values
        (p_account, v_tpl.id, p_slot, now(), v_expiry, v_count, false, null)
    on conflict (account_id, slot) do update set
        template_id    = excluded.template_id,
        assigned_at    = excluded.assigned_at,
        expires_at     = excluded.expires_at,
        baseline_count = excluded.baseline_count,
        claimed        = false,
        claimed_at     = null;
end;
$$;

revoke all on function public._assign_mission_to_slot(uuid, int) from anon, authenticated;

-- ── ensure_missions: fill any missing/expired slot (per-slot, 24h) ───────────
create or replace function public._ensure_missions(p_account uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_slot   int;
    v_live   int;
begin
    if p_account is null then
        return;
    end if;

    -- Serialize concurrent assignment for THIS account (see 011 rationale).
    perform pg_advisory_xact_lock(hashtextextended(p_account::text, 0));

    -- Remove expired rows so their slots are free to refill.
    delete from public.account_missions
    where account_id = p_account and expires_at <= now();

    -- Fill any slot 0..2 that currently has no live mission.
    for v_slot in 0..2 loop
        select count(*) into v_live
        from public.account_missions
        where account_id = p_account and slot = v_slot and expires_at > now();
        if v_live = 0 then
            perform public._assign_mission_to_slot(p_account, v_slot);
        end if;
    end loop;
end;
$$;

revoke all on function public._ensure_missions(uuid) from anon, authenticated;

-- ── claim_mission: verify windowed progress, grant, then REPLACE the slot ────
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

    select coalesce(sum(delta), 0) into v_earned_today
    from public.token_ledger
    where account_id = v_account and reason = 'mission' and delta > 0
      and created_at >= (now() at time zone 'utc')::date;
    if v_earned_today + v_tpl.reward_tokens > v_daily_cap then
        return json_build_object('error', 'daily_cap_reached');
    end if;

    -- Grant reward.
    update public.accounts set token_balance = token_balance + v_tpl.reward_tokens
    where id = v_account;

    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_account, v_tpl.reward_tokens, 'mission', v_am.id);

    -- Immediately spawn a NEW mission into this slot (fresh 24h window + new
    -- baseline), so completing one is instantly replaced. Serialize per account
    -- to avoid colliding with a concurrent get_mission_status/ensure.
    perform pg_advisory_xact_lock(hashtextextended(v_account::text, 0));
    perform public._assign_mission_to_slot(v_account, v_am.slot);

    return json_build_object('ok', true, 'reward', v_tpl.reward_tokens,
        'new_balance', v_balance + v_tpl.reward_tokens);
end;
$$;

grant execute on function public.claim_mission(text, uuid) to anon, authenticated;
