-- ============================================================================
-- Migration 060: Benjamin production rush (spend Benjamins to speed a craft)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- A guild member spends their personal Benjamins (printed by the money gun,
-- migration 053) to pull an in-progress production craft's finish time closer.
-- Each Benjamin removes a fixed number of seconds from the craft's remaining
-- time. Benjamins are the money gun's untradeable currency, so this is a pure
-- personal-time-for-personal-currency trade — it does NOT touch the stockpile
-- or the guild bank.
--
-- RATE: _rush_seconds_per_benjamin() = 600 (10 minutes shaved per Benjamin).
--   e.g. a diamond ring (180 min) fully rushes in ceil(180*60 / 600) = 18.
--
-- OVERSHOOT PROTECTION: a craft can never finish before now(). If the requested
-- Benjamins would push finish_at past now(), we charge ONLY the whole Benjamins
-- needed to reach now() and refund the rest (i.e. we never debit more than it
-- takes to make the craft Ready). Already-ready crafts cost nothing.
--
-- All-or-nothing in one transaction. Member-only (any active member of the
-- guild may rush any of that guild's crafts).
-- ============================================================================


-- ── Rush rate (single source of truth; client mirrors for cost preview) ───────
create or replace function public._rush_seconds_per_benjamin()
returns int
language sql
immutable
as $$
    select 600;     -- 10 minutes shaved per Benjamin
$$;


-- ── rush_production ────────────────────────────────────────────────────────────
-- Spend up to p_benjamins Benjamins to shave time off an active craft. Returns
--   { ok, spent, seconds_removed, finish_at, ready, balance } | { error }
--     spent          = Benjamins actually debited (<= p_benjamins)
--     seconds_removed= seconds pulled off finish_at
--     finish_at      = new finish epoch (seconds)
--     ready          = whether the craft is now finished
--     balance        = caller's remaining Benjamin balance
--   errors: account_not_found, not_in_guild, invalid_amount, craft_not_found,
--           wrong_guild, craft_not_active, already_ready, insufficient_benjamins
create or replace function public.rush_production(
    p_device_hash text,
    p_guild_id    uuid,
    p_queue_id    uuid,
    p_benjamins   int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account   uuid;
    v_member    public.guild_members%rowtype;
    v_balance   bigint;
    v_craft     public.guild_production_queue%rowtype;
    v_per       int;
    v_remaining numeric;     -- seconds left on the craft (can be fractional)
    v_needed    int;         -- whole Benjamins needed to reach now()
    v_spend     int;         -- Benjamins actually charged
    v_removed   bigint;      -- seconds removed
    v_new_fin   timestamptz;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    if p_benjamins is null or p_benjamins < 1 then
        return json_build_object('error', 'invalid_amount');
    end if;

    -- Lock the craft row.
    select * into v_craft from public.guild_production_queue
    where id = p_queue_id for update;
    if not found then
        return json_build_object('error', 'craft_not_found');
    end if;
    if v_craft.guild_id <> p_guild_id then
        return json_build_object('error', 'wrong_guild');
    end if;
    if v_craft.status <> 'active' then
        return json_build_object('error', 'craft_not_active');
    end if;

    -- Seconds remaining (clamped at 0). An already-finished craft needs no rush.
    v_remaining := extract(epoch from (v_craft.finish_at - now()));
    if v_remaining <= 0 then
        return json_build_object('error', 'already_ready');
    end if;

    v_per := public._rush_seconds_per_benjamin();

    -- Whole Benjamins needed to reach now() (ceil), so we never charge for more
    -- time than the craft has left.
    v_needed := ceil(v_remaining / v_per)::int;
    v_spend  := least(p_benjamins, v_needed);

    -- Lock the caller's wallet + check funds.
    select benjamin_balance into v_balance
    from public.accounts where id = v_account for update;
    if v_balance < v_spend then
        return json_build_object('error', 'insufficient_benjamins',
            'need', v_spend, 'have', v_balance);
    end if;

    -- Compute the new finish time, floored at now().
    v_removed := (v_spend::bigint) * v_per;
    v_new_fin := v_craft.finish_at - make_interval(secs => v_removed);
    if v_new_fin < now() then
        v_new_fin := now();
    end if;

    -- ── Mutations ────────────────────────────────────────────────────────────
    update public.guild_production_queue
    set finish_at = v_new_fin
    where id = p_queue_id;

    update public.accounts
    set benjamin_balance = benjamin_balance - v_spend
    where id = v_account;

    insert into public.benjamin_ledger (account_id, delta, reason, ref_id)
    values (v_account, -v_spend, 'rush', p_queue_id);

    return json_build_object(
        'ok',              true,
        'spent',           v_spend,
        'seconds_removed', v_removed,
        'finish_at',       extract(epoch from v_new_fin),
        'ready',           (v_new_fin <= now()),
        'balance',         v_balance - v_spend
    );
end;
$$;
grant execute on function public.rush_production(text, uuid, uuid, int) to anon, authenticated;
revoke all on function public._rush_seconds_per_benjamin() from anon, authenticated;
