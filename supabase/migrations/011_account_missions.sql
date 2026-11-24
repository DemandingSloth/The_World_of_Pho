-- ============================================================================
-- Marketplace Option B (Task 2+3/7): per-account mission assignments + rotation
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 010_mission_templates.sql and 008_mission_rewards.sql
-- (for _mission_progress_count).
--
-- Each account is assigned 3 missions from the pool. Each assignment records a
-- BASELINE (the account's lifetime objective count at assignment time) so
-- progress is WINDOWED: progress = current_count - baseline, clamped to target.
-- Assignments expire 48h after they are made; on the next read past expiry, a
-- fresh set of 3 is assigned.
-- ============================================================================

-- ── Assignment table ─────────────────────────────────────────────────────────
create table if not exists public.account_missions (
    id             uuid        primary key default gen_random_uuid(),
    account_id     uuid        not null references public.accounts(id) on delete cascade,
    template_id    uuid        not null references public.mission_templates(id) on delete cascade,
    slot           int         not null check (slot between 0 and 2),   -- 0..2
    assigned_at    timestamptz not null default now(),
    expires_at     timestamptz not null,
    baseline_count int         not null default 0,   -- objective count at assignment
    claimed        boolean     not null default false,
    claimed_at     timestamptz,
    unique (account_id, slot)                          -- one mission per slot per account
);
create index if not exists account_missions_account_idx on public.account_missions (account_id);
alter table public.account_missions enable row level security;  -- functions only

-- ── ensure_missions(account uuid) ────────────────────────────────────────────
-- Internal. Guarantees the account has a full, non-expired set of 3 missions.
-- If the account has NO active (non-expired) assignments, it (re)assigns 3
-- weighted-random enabled templates into slots 0..2, capturing each template's
-- baseline objective count for the account. Idempotent within a 48h window: if
-- a live set already exists, it does nothing.
--
-- Rotation policy: we rotate the WHOLE set together. A set is "live" while any
-- slot is unexpired; once every slot has expired, the next call assigns a fresh
-- trio. (This keeps the 3 missions on a shared 48h cadence per player.)
create or replace function public._ensure_missions(p_account uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_live   int;
    v_window interval := interval '48 hours';
    v_expiry timestamptz := now() + v_window;
    v_count  int;
    r        record;
    v_slot   int := 0;
begin
    if p_account is null then
        return;
    end if;

    -- Serialize concurrent assignment for THIS account. Two near-simultaneous
    -- get_mission_status calls could otherwise both see an empty set and both
    -- try to assign, colliding on the unique(account_id, slot) constraint.
    -- A transaction-scoped advisory lock (keyed on the account uuid) makes the
    -- check-then-assign atomic without blocking other accounts.
    perform pg_advisory_xact_lock(hashtextextended(p_account::text, 0));

    -- How many currently-live (unexpired) assignments does this account have?
    select count(*) into v_live
    from public.account_missions
    where account_id = p_account and expires_at > now();

    -- A live set already exists -> nothing to do.
    if v_live > 0 then
        return;
    end if;

    -- Clear any stale (expired) rows so we can reuse slots 0..2 cleanly.
    delete from public.account_missions where account_id = p_account;

    -- Pick up to 3 enabled templates, weighted-random (higher weight = more
    -- likely). random()/weight ordering approximates weighted sampling well
    -- enough for a small pool without extensions.
    for r in
        select id, objective_type
        from public.mission_templates
        where is_enabled
        order by (random() / greatest(weight, 1)) asc
        limit 3
    loop
        v_count := public._mission_progress_count(p_account, r.objective_type);
        insert into public.account_missions
            (account_id, template_id, slot, assigned_at, expires_at, baseline_count)
        values
            (p_account, r.id, v_slot, now(), v_expiry, v_count)
        on conflict (account_id, slot) do nothing;
        v_slot := v_slot + 1;
    end loop;
end;
$$;

revoke all on function public._ensure_missions(uuid) from anon, authenticated;
