-- ============================================================================
-- Migration 061: Guild mission deposits flow into the guild STOCKPILE
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Change (user choice "Option A"): when a player deposits items toward a guild
-- mission, those items now ALSO land in the shared guild STOCKPILE (migration
-- 052) as guild property — fuel for the production facility. They are NO LONGER
-- individually refundable on reroll/expire (they've become shared stock).
--
-- Behaviour:
--   • Mission PROGRESS still counts the FULL deposited amount (progress and
--     storage are independent).
--   • The deposited amount is added to guild_stockpile ONCE per deposit (not
--     once per fanned-out mission), clamped to the per-key capacity. Anything
--     over the cap is LOST (user choice) — the stockpile just stores up to cap.
--   • The per-depositor refund ledger (guild_contribution_items) is NO LONGER
--     written for these deposits, so reroll/expire can't refund stock that is
--     now shared (prevents duplication). Existing ledger rows (if any) are left
--     alone and still refund via the unchanged _guild_refund_contributions.
--   • Only stockpile-eligible keys (resource/gem/polished/crop/fruit) are
--     stored; that already covers every item a mission deposit can carry.
--
-- NO CLIENT/APK CHANGE: the client already sends p_item_key on every deposit;
-- this only changes what the server does with it. Superseding migration 049's
-- record_guild_contribution / deposit_silo_to_mission (harvest_guild_garden is
-- also routed for the gardening community path).
-- ============================================================================


-- ── Shared helper: add to the stockpile, clamped to capacity (overflow lost) ─
-- Mirrors deposit_to_stockpile's clamp math but as a reusable internal routine
-- (no account/membership checks — callers already validated the member). Only
-- acts on stockpile-eligible keys; silently no-ops otherwise. Returns nothing.
create or replace function public._guild_stockpile_add_capped(
    p_guild_id uuid,
    p_item_key text,
    p_amount   bigint
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_cap   bigint;
    v_cur   bigint;
    v_space bigint;
    v_store bigint;
begin
    if p_amount is null or p_amount <= 0 then
        return;
    end if;
    if not public._guild_stockpile_key_ok(p_item_key) then
        return;   -- not stockpilable (e.g. produced jewelry) — skip silently
    end if;

    v_cap := public._guild_stockpile_capacity(p_guild_id);

    -- Lock the row (if present) so concurrent adds can't both overshoot the cap.
    select coalesce(amount, 0) into v_cur
    from public.guild_stockpile
    where guild_id = p_guild_id and item_key = p_item_key
    for update;
    v_cur := coalesce(v_cur, 0);

    v_space := greatest(v_cap - v_cur, 0);
    if v_space <= 0 then
        return;   -- already at cap; overflow is lost
    end if;

    v_store := least(p_amount, v_space);

    insert into public.guild_stockpile (guild_id, item_key, amount, updated_at)
    values (p_guild_id, p_item_key, v_store, now())
    on conflict (guild_id, item_key)
    do update set amount = least(public.guild_stockpile.amount + v_store, v_cap),
                  updated_at = now();
end;
$$;
revoke all on function public._guild_stockpile_add_capped(uuid, text, bigint) from anon, authenticated;


-- ── record_guild_contribution — deposits now feed the stockpile ──────────────
-- Same fan-out as migration 049, but: (1) adds the deposited item to the
-- stockpile ONCE (not per mission), and (2) no longer writes the refund ledger
-- (items are now shared guild stock). Progress still counts the full amount.
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
    v_account   uuid;
    v_member    public.guild_members%rowtype;
    v_mission   record;
    v_new_prog  int;
    v_keys      text[];
    v_itemized  boolean;
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

    v_itemized := (p_item_key is not null and length(p_item_key) > 0);

    -- Build the set of base keys this deposit should credit.
    if v_itemized then
        v_keys := public._guild_deposit_keys_for_item(p_item_key);
        if p_base_key is not null and length(p_base_key) > 0
           and not (p_base_key = any(v_keys)) then
            v_keys := v_keys || p_base_key;
        end if;
    else
        v_keys := array[p_base_key];
    end if;

    if array_length(v_keys, 1) is null then
        return json_build_object('ok', true);
    end if;

    -- Credit every active mission whose base key is in the compatible set.
    for v_mission in
        select id, target, progress
        from public.guild_missions
        where guild_id = p_guild_id
          and base_mission_key = any(v_keys)
          and status = 'active'
        order by spawned_at asc, id asc
        for update
    loop
        -- Aggregate contribution (reward split) — written per mission.
        insert into public.guild_contributions (mission_id, account_id, amount, updated_at)
        values (v_mission.id, v_account, p_amount, now())
        on conflict (mission_id, account_id)
        do update set
            amount     = public.guild_contributions.amount + excluded.amount,
            updated_at = now();

        v_new_prog := least(v_mission.progress + p_amount, v_mission.target);

        update public.guild_missions
        set progress = v_new_prog
        where id = v_mission.id;

        if v_new_prog >= v_mission.target then
            perform public._complete_guild_mission(v_mission.id);
        end if;
    end loop;

    -- Deposited items become shared guild stock (ONCE per deposit, capped).
    -- No refund ledger is written — these are no longer individually refundable.
    if v_itemized then
        perform public._guild_stockpile_add_capped(p_guild_id, p_item_key, p_amount::bigint);
    end if;

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.record_guild_contribution(text, uuid, text, int, text) to anon, authenticated;


-- ── deposit_silo_to_mission — silo deposits also feed the stockpile ──────────
-- Same as 049 but routes the deducted crop into the stockpile (once, capped)
-- and drops the refund-ledger write.
create or replace function public.deposit_silo_to_mission(
    p_device_hash text,
    p_guild_id    uuid,
    p_crop_id     text,
    p_amount      int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account      uuid;
    v_member       public.guild_members%rowtype;
    v_current_silo int;
    v_deduct       int;
    v_mission      record;
    v_new_prog     int;
    v_keys         text[];
    v_item_key     text;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then return json_build_object('error', 'account_not_found'); end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    if p_amount <= 0 then return json_build_object('error', 'invalid_amount'); end if;

    -- Lock silo row.
    select coalesce(amount, 0) into v_current_silo
    from public.guild_silo
    where guild_id = p_guild_id and crop_id = p_crop_id
    for update;

    if v_current_silo is null or v_current_silo <= 0 then
        return json_build_object('error', 'silo_empty');
    end if;

    v_deduct := least(p_amount, v_current_silo);

    -- Deduct from silo.
    update public.guild_silo
    set amount = amount - v_deduct, updated_at = now()
    where guild_id = p_guild_id and crop_id = p_crop_id;

    v_item_key := 'crop:' || p_crop_id;
    v_keys := public._guild_deposit_keys_for_item(v_item_key);

    -- Apply to every matching active mission (generic + specific crop key).
    for v_mission in
        select id, target, progress
        from public.guild_missions
        where guild_id         = p_guild_id
          and base_mission_key = any(v_keys)
          and status           = 'active'
        order by spawned_at asc, id asc
        for update
    loop
        insert into public.guild_contributions
            (mission_id, account_id, amount, updated_at)
        values
            (v_mission.id, v_account, v_deduct, now())
        on conflict (mission_id, account_id)
        do update set
            amount     = public.guild_contributions.amount + v_deduct,
            updated_at = now();

        v_new_prog := least(v_mission.progress + v_deduct, v_mission.target);
        update public.guild_missions
        set progress = v_new_prog
        where id = v_mission.id;

        if v_new_prog >= v_mission.target then
            perform public._complete_guild_mission(v_mission.id);
        end if;
    end loop;

    -- Silo crop becomes shared stockpile stock (once, capped; overflow lost).
    perform public._guild_stockpile_add_capped(p_guild_id, v_item_key, v_deduct::bigint);

    return json_build_object('ok', true, 'deposited', v_deduct);
end;
$$;
grant execute on function public.deposit_silo_to_mission(text, uuid, text, int) to anon, authenticated;
