-- ============================================================================
-- Marketplace missions: refill slots that are claimed OR expired
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Supersedes _ensure_missions from 015.
--
-- Bug: missions CLAIMED under the pre-014 code were marked claimed but never
-- replaced. _ensure_missions only refilled slots that were empty/expired, so a
-- claimed-but-unexpired slot stayed occupied by a done mission and never
-- generated a new one. (Post-014 claims replace in place, so a lingering
-- claimed row is always stale legacy state.)
--
-- Fix: treat a CLAIMED slot the same as an expired one — clear it and assign a
-- fresh mission. This self-heals existing accounts on their next mission read.
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

    -- Grace extension: any LIVE, UNCLAIMED slot that has made progress and is
    -- still on its original 24h clock gets extended to 48h from assignment.
    for r in
        select am.id, am.assigned_at, am.baseline_count,
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

    -- Free up slots that are expired OR already claimed (a claimed slot is done
    -- and should be replaced by a fresh mission).
    delete from public.account_missions
    where account_id = p_account and (expires_at <= now() or claimed);

    -- Fill any slot 0..2 that no longer has a live, UNCLAIMED mission.
    for v_slot in 0..2 loop
        select count(*) into v_live
        from public.account_missions
        where account_id = p_account and slot = v_slot
          and expires_at > now() and not claimed;
        if v_live = 0 then
            perform public._assign_mission_to_slot(p_account, v_slot);
        end if;
    end loop;
end;
$$;

revoke all on function public._ensure_missions(uuid) from anon, authenticated;
