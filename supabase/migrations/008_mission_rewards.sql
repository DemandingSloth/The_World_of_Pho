-- ============================================================================
-- Marketplace Task 11: online mission progress + claim (server-verified rewards)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Rewards are SERVER-VERIFIED. For the seeded objective types the server can
-- recompute progress from real tables (no client trust):
--   make_sale  -> count of the account's sales   (purchases.seller_id = me)
--   purchase   -> count of the account's buys     (purchases.buyer_id  = me)
--   list_item  -> count of listings the account has created (any status)
--
-- A fixed reward_tokens per mission, each claimable ONCE per account, subject to
-- a per-account DAILY EARN CAP so missions can't be farmed.
-- ============================================================================

-- Per-account daily token earn cap from missions.
-- (Kept as a simple constant here; adjust as needed.)
-- We enforce it inside claim_mission by summing today's 'mission' ledger credits.

-- mission_progress: which missions an account has claimed.
create table if not exists public.mission_progress (
    account_id  uuid        not null references public.accounts(id) on delete cascade,
    mission_id  uuid        not null references public.online_missions(id) on delete cascade,
    claimed     boolean     not null default false,
    claimed_at  timestamptz,
    primary key (account_id, mission_id)
);
alter table public.mission_progress enable row level security;  -- functions only

-- Server-side progress count for an account against a mission's objective type.
create or replace function public._mission_progress_count(p_account uuid, p_objective text)
returns int
language sql
security definer
set search_path = public
as $$
    select case p_objective
        when 'make_sale' then (select count(*)::int from public.purchases where seller_id = p_account)
        when 'purchase'  then (select count(*)::int from public.purchases where buyer_id  = p_account)
        when 'list_item' then (select count(*)::int from public.listings  where seller_id = p_account)
        else 0
    end;
$$;

-- get_mission_status(device_hash) -> active missions with the caller's live
-- progress + claimed flag, so the client can show progress bars and enable the
-- Claim button only when eligible.
--
-- Each row: { id, title, description, objective_type, target, reward_tokens,
--             progress, claimed, window_end }
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

    select coalesce(json_agg(row_to_json(t) order by t.window_end asc), '[]'::json)
    into v_result
    from (
        select m.id, m.title, m.description, m.objective_type, m.target, m.reward_tokens,
               case when v_account is null then 0
                    else public._mission_progress_count(v_account, m.objective_type) end as progress,
               case when v_account is null then false
                    else coalesce(mp.claimed, false) end as claimed,
               m.window_end
        from public.online_missions m
        left join public.mission_progress mp
               on mp.mission_id = m.id and mp.account_id = v_account
        where m.is_active and now() >= m.window_start and now() < m.window_end
    ) t;

    return v_result;
end;
$$;

grant execute on function public.get_mission_status(text) to anon, authenticated;

-- claim_mission(device_hash, mission_id): verifies progress >= target on the
-- server, checks not-already-claimed and the daily earn cap, then credits the
-- fixed reward and records the claim. Returns:
--   { ok, reward, new_balance } | { error }
--     codes: account_not_found, mission_not_found, mission_inactive,
--            not_eligible, already_claimed, daily_cap_reached
create or replace function public.claim_mission(
    p_device_hash text,
    p_mission_id  uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_daily_cap  bigint := 5000;   -- max mission tokens per account per UTC day
    v_account    uuid;
    v_balance    bigint;
    v_mission    public.online_missions%rowtype;
    v_progress   int;
    v_earned_today bigint;
begin
    select id, token_balance into v_account, v_balance
    from public.accounts where device_hash = p_device_hash for update;
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select * into v_mission from public.online_missions where id = p_mission_id;
    if not found then
        return json_build_object('error', 'mission_not_found');
    end if;
    if not (v_mission.is_active and now() >= v_mission.window_start and now() < v_mission.window_end) then
        return json_build_object('error', 'mission_inactive');
    end if;

    -- Already claimed?
    if exists (select 1 from public.mission_progress
               where account_id = v_account and mission_id = p_mission_id and claimed) then
        return json_build_object('error', 'already_claimed');
    end if;

    -- Server-verified progress.
    v_progress := public._mission_progress_count(v_account, v_mission.objective_type);
    if v_progress < v_mission.target then
        return json_build_object('error', 'not_eligible', 'progress', v_progress, 'target', v_mission.target);
    end if;

    -- Daily earn cap (sum today's positive 'mission' ledger credits).
    select coalesce(sum(delta), 0) into v_earned_today
    from public.token_ledger
    where account_id = v_account and reason = 'mission' and delta > 0
      and created_at >= (now() at time zone 'utc')::date;
    if v_earned_today + v_mission.reward_tokens > v_daily_cap then
        return json_build_object('error', 'daily_cap_reached');
    end if;

    -- Grant.
    update public.accounts set token_balance = token_balance + v_mission.reward_tokens
    where id = v_account;

    insert into public.mission_progress (account_id, mission_id, claimed, claimed_at)
    values (v_account, p_mission_id, true, now())
    on conflict (account_id, mission_id) do update set claimed = true, claimed_at = now();

    insert into public.token_ledger (account_id, delta, reason, ref_id)
    values (v_account, v_mission.reward_tokens, 'mission', p_mission_id);

    return json_build_object('ok', true, 'reward', v_mission.reward_tokens,
        'new_balance', v_balance + v_mission.reward_tokens);
end;
$$;

grant execute on function public.claim_mission(text, uuid) to anon, authenticated;

revoke all on function public._mission_progress_count(uuid, text) from anon, authenticated;
