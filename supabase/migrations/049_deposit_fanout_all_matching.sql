-- ============================================================================
-- Migration 049: Guild deposits credit EVERY matching active mission
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Mirrors solo missions: completing one action advances every active mission
-- that wants it. For guilds, a single deposit of an item should advance EVERY
-- active mission compatible with that item, not just the one the client picked.
--
-- Example: a guild has two active missions wanting pink stones — a specific
-- 'deposit_gem_pink_stone' and a generic 'deposit_gems'. Depositing pink stones
-- now advances BOTH by the full amount deposited (same semantics the solo
-- mission board already uses: no splitting, each matching mission gets +amount).
--
-- How it worked before: record_guild_contribution (migration 042) looped over
-- active missions matching the EXACT base_mission_key the client sent — but the
-- client sends one specific key, so a 'deposit_gem_pink_stone' deposit never
-- touched a concurrent generic 'deposit_gems' mission. We now compute the set of
-- COMPATIBLE base keys from the canonical item key the client already passes and
-- credit all active missions in that set.
--
-- Compatible keys for an item key:
--   gem:<id>       -> {'deposit_gems',     'deposit_gem_<id>'}
--   polished:<id>  -> {'deposit_polished', 'deposit_polished_<id>'}
--   resource:<id>  -> {'deposit_ores',     'deposit_ore_<id>'}
--   crop:<id>      -> {'deposit_produce',  'deposit_<id>'}
--   fruit:<id>     -> {'deposit_fruit',    'deposit_<id>'}
--
-- Refund correctness: when a deposit fans out to N missions, the per-item ledger
-- (guild_contribution_items, used for reroll/expire refunds) is written against
-- only the PRIMARY (first) mission, so a fan-out deposit can never be refunded
-- more than once. Aggregate contribution rows (guild_contributions, used for the
-- reward split) are still written per mission, so each completed mission pays
-- its contributors correctly.
-- ============================================================================


-- ── Item key -> compatible mission base keys ─────────────────────────────────
-- Returns the set of base_mission_key values a deposit of p_item_key may satisfy
-- (its generic bucket + its specific key). Empty array for unknown keys.
create or replace function public._guild_deposit_keys_for_item(p_item_key text)
returns text[]
language plpgsql
immutable
security definer
set search_path = public
as $$
declare
    v_sep  int;
    v_cat  text;
    v_id   text;
begin
    if p_item_key is null then
        return array[]::text[];
    end if;
    v_sep := position(':' in p_item_key);
    if v_sep <= 0 then
        return array[]::text[];
    end if;
    v_cat := substring(p_item_key from 1 for v_sep - 1);
    v_id  := substring(p_item_key from v_sep + 1);
    if length(v_id) = 0 then
        return array[]::text[];
    end if;

    case v_cat
        when 'gem'      then return array['deposit_gems',     'deposit_gem_' || v_id];
        when 'polished' then return array['deposit_polished', 'deposit_polished_' || v_id];
        when 'resource' then return array['deposit_ores',     'deposit_ore_' || v_id];
        when 'crop'     then return array['deposit_produce',  'deposit_' || v_id];
        when 'fruit'    then return array['deposit_fruit',    'deposit_' || v_id];
        else                 return array[]::text[];
    end case;
end;
$$;
revoke all on function public._guild_deposit_keys_for_item(text) from anon, authenticated;


-- ── record_guild_contribution — fan out across all compatible missions ───────
-- When p_item_key is provided (the deposit paths always send it), credit EVERY
-- active mission whose base_mission_key is compatible with the item, plus the
-- key the client explicitly named (p_base_key) in case it isn't in the computed
-- set. When p_item_key is empty (the legacy 4-arg record_contribution path for
-- non-deposit mirrors), fall back to matching p_base_key exactly as before.
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
    v_primary   boolean := true;   -- item ledger written only for the first mission
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
        -- Always include the explicitly-named key (dedup via array below).
        if p_base_key is not null and length(p_base_key) > 0
           and not (p_base_key = any(v_keys)) then
            v_keys := v_keys || p_base_key;
        end if;
    else
        -- Legacy / non-deposit path: match exactly the named key.
        v_keys := array[p_base_key];
    end if;

    if array_length(v_keys, 1) is null then
        return json_build_object('ok', true);
    end if;

    -- Credit every active mission whose base key is in the compatible set.
    -- Order by spawned_at so the "primary" ledger mission is stable.
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

        -- Per-item ledger (refunds) — ONLY the primary mission, so a fan-out
        -- deposit can never be refunded more than the amount deposited.
        if v_itemized and v_primary then
            insert into public.guild_contribution_items (mission_id, account_id, item_key, amount, updated_at)
            values (v_mission.id, v_account, p_item_key, p_amount, now())
            on conflict (mission_id, account_id, item_key)
            do update set
                amount     = public.guild_contribution_items.amount + excluded.amount,
                updated_at = now();
            v_primary := false;
        end if;

        v_new_prog := least(v_mission.progress + p_amount, v_mission.target);

        update public.guild_missions
        set progress = v_new_prog
        where id = v_mission.id;

        if v_new_prog >= v_mission.target then
            perform public._complete_guild_mission(v_mission.id);
        end if;
    end loop;

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.record_guild_contribution(text, uuid, text, int, text) to anon, authenticated;


-- ── deposit_silo_to_mission — fan out across all matching crop missions ──────
-- The community garden silo deposit now credits EVERY active mission that wants
-- the crop (generic 'deposit_produce' + specific 'deposit_<crop>'), not just
-- one (dropped the LIMIT 1). It also now writes the per-item ledger so silo
-- deposits are refundable on reroll/expire, consistent with direct deposits.
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
    v_primary      boolean := true;
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

        -- Per-item ledger (refunds) — primary mission only.
        if v_primary then
            insert into public.guild_contribution_items
                (mission_id, account_id, item_key, amount, updated_at)
            values
                (v_mission.id, v_account, v_item_key, v_deduct, now())
            on conflict (mission_id, account_id, item_key)
            do update set
                amount     = public.guild_contribution_items.amount + v_deduct,
                updated_at = now();
            v_primary := false;
        end if;

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
grant execute on function public.deposit_silo_to_mission(text, uuid, text, int) to anon, authenticated;


-- ── harvest_guild_garden — one harvested crop advances all matching missions ─
-- A harvested crop now advances EVERY active mission that wants it (generic
-- 'deposit_produce' + specific 'deposit_<crop>') by 1, mirroring the fan-out of
-- direct deposits. If no mission consumes it, it falls through to the silo as
-- before. The per-item ledger ('crop:<id>') is written against the primary
-- mission so a refund on reroll/expire returns exactly one crop.
create or replace function public.harvest_guild_garden(
    p_device_hash text,
    p_guild_id    uuid,
    p_row         int,
    p_col         int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account        uuid;
    v_member         public.guild_members%rowtype;
    v_spec           text;
    v_cell           public.guild_garden_cells%rowtype;
    v_harvest_time   double precision;
    v_elapsed        double precision;
    v_crop_id        text;
    v_silo_cap       int;
    v_current_silo   int;
    v_silo_space     int;
    v_mission        record;
    v_new_prog       int;
    v_mission_amount int := 0;
    v_silo_amount    int := 0;
    v_item_key       text;
    v_keys           text[];
    v_primary        boolean := true;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    select specialization into v_spec from public.guilds where id = p_guild_id;
    if v_spec <> 'gardening' then
        return json_build_object('error', 'not_gardening_guild');
    end if;

    -- Lock and fetch the cell.
    select * into v_cell
    from public.guild_garden_cells
    where guild_id = p_guild_id and row = p_row and col = p_col
    for update;

    if not found then
        return json_build_object('error', 'cell_empty');
    end if;

    -- Check maturity.
    v_harvest_time := public._guild_garden_harvest_time(v_cell.plant_type);
    v_elapsed      := extract(epoch from now()) - v_cell.plant_time;
    if v_elapsed < v_harvest_time then
        return json_build_object('error', 'not_harvestable',
            'remaining', (v_harvest_time - v_elapsed)::int);
    end if;

    v_crop_id := public._guild_garden_crop_id(v_cell.plant_type);

    -- Remove the cell (harvested).
    delete from public.guild_garden_cells
    where guild_id = p_guild_id and row = p_row and col = p_col;

    -- 1. Advance every matching active mission (generic produce + specific crop).
    v_item_key := 'crop:' || v_crop_id;
    v_keys := public._guild_deposit_keys_for_item(v_item_key);
    for v_mission in
        select id, target, progress
        from public.guild_missions
        where guild_id         = p_guild_id
          and base_mission_key = any(v_keys)
          and status           = 'active'
        order by spawned_at asc, id asc
        for update
    loop
        v_mission_amount := 1;

        insert into public.guild_contributions
            (mission_id, account_id, amount, updated_at)
        values
            (v_mission.id, v_account, 1, now())
        on conflict (mission_id, account_id)
        do update set
            amount     = public.guild_contributions.amount + 1,
            updated_at = now();

        -- Per-item ledger (refunds) — primary mission only.
        if v_primary then
            insert into public.guild_contribution_items
                (mission_id, account_id, item_key, amount, updated_at)
            values
                (v_mission.id, v_account, v_item_key, 1, now())
            on conflict (mission_id, account_id, item_key)
            do update set
                amount     = public.guild_contribution_items.amount + 1,
                updated_at = now();
            v_primary := false;
        end if;

        v_new_prog := least(v_mission.progress + 1, v_mission.target);
        update public.guild_missions
        set progress = v_new_prog
        where id = v_mission.id;

        if v_new_prog >= v_mission.target then
            perform public._complete_guild_mission(v_mission.id);
        end if;
    end loop;

    -- 2. Remainder (if no mission took it) goes to the silo.
    if v_mission_amount = 0 then
        v_silo_cap := public._guild_silo_capacity(p_guild_id);

        select coalesce(amount, 0) into v_current_silo
        from public.guild_silo
        where guild_id = p_guild_id and crop_id = v_crop_id;
        v_current_silo := coalesce(v_current_silo, 0);

        v_silo_space := v_silo_cap - v_current_silo;
        if v_silo_space > 0 then
            v_silo_amount := 1;
            insert into public.guild_silo (guild_id, crop_id, amount, updated_at)
            values (p_guild_id, v_crop_id, 1, now())
            on conflict (guild_id, crop_id)
            do update set
                amount     = least(public.guild_silo.amount + 1, v_silo_cap),
                updated_at = now();
        end if;
    end if;

    return json_build_object(
        'ok',              true,
        'crop_id',         v_crop_id,
        'went_to_mission', v_mission_amount > 0,
        'went_to_silo',    v_silo_amount > 0
    );
end;
$$;
grant execute on function public.harvest_guild_garden(text, uuid, int, int) to anon, authenticated;
