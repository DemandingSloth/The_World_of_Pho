-- ============================================================================
-- Marketplace missions: extend a slot to 48h once it has progress
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Supersedes _ensure_missions from 014.
--
-- Rule: a mission slot is assigned with a 24h window. If the player makes ANY
-- progress toward it, its window extends to 48h from assignment (a grace period
-- so partial progress isn't wasted). Untouched slots still expire at 24h.
--
-- Implemented lazily in _ensure_missions (which runs on every get_mission_status
-- read, per account, under the advisory lock): before deleting expired rows, we
-- bump the expiry of any live slot that has progress and is still on its 24h
-- clock. expires_at remains the single stored source of truth.
--
-- 48h is the hard cap: a slot with progress that still isn't completed will
-- expire at 48h and be replaced like any other.
-- ============================================================================

create or replace function public._ensure_missions(p_account uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_slot int;
    v_live int;
    r      record;
    v_prog int;
begin
    if p_account is null then
        return;
    end if;

    -- Serialize concurrent assignment for THIS account (see 011 rationale).
    perform pg_advisory_xact_lock(hashtextextended(p_account::text, 0));

    -- Grace extension: any LIVE slot that has made progress and is still on its
    -- original 24h clock gets extended to 48h from assignment. Do this BEFORE
    -- the expired-row cleanup so an extended slot survives.
    for r in
        select am.id, am.template_id, am.assigned_at, am.baseline_count,
               mt.objective_type, mt.target
        from public.account_missions am
        join public.mission_templates mt on mt.id = am.template_id
        where am.account_id = p_account
          and am.expires_at > now()
          and am.expires_at < am.assigned_at + interval '48 hours'
          and not am.claimed
    loop
        v_prog := public._mission_progress_count(p_account, r.objective_type) - r.baseline_count;
        if v_prog > 0 then
            update public.account_missions
            set expires_at = r.assigned_at + interval '48 hours'
            where id = r.id;
        end if;
    end loop;

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
