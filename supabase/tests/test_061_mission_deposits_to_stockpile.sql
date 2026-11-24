-- ============================================================================
-- Verification for migration 061 (mission deposits -> stockpile) — RUN AFTER 061.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL DEPOSIT->STOCKPILE TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_hash   text := 'test_dep_hash';
    v_acct   uuid;
    v_guild  uuid;
    r        json;
    v_m1     uuid;   -- generic deposit_ores mission
    v_m2     uuid;   -- specific deposit_ore_iron_bar mission
    v_stock  bigint;
    v_prog1  int;
    v_prog2  int;
    v_ledger int;
    v_cap    bigint;
begin
    -- ── Setup: account + guild + ACTIVE membership (perks active) ────────────
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash, 'dep_user', 'x') returning id into v_acct;
    insert into public.guilds (name, specialization, leader_id)
    values ('test_dep_guild', 'mining', v_acct) returning id into v_guild;
    insert into public.guild_members (guild_id, account_id, role, perks_active_at)
    values (v_guild, v_acct, 'leader', null);   -- null = perks active immediately

    -- Two active missions that an iron_bar deposit fans out to:
    --   generic 'deposit_ores' + specific 'deposit_ore_iron_bar'.
    insert into public.guild_missions
        (guild_id, base_mission_key, difficulty, target, progress, status, spawned_at)
    values (v_guild, 'deposit_ores', 'easy', 1000, 0, 'active', now())
    returning id into v_m1;
    insert into public.guild_missions
        (guild_id, base_mission_key, difficulty, target, progress, status, spawned_at)
    values (v_guild, 'deposit_ore_iron_bar', 'medium', 1000, 0, 'active', now() + interval '1 second')
    returning id into v_m2;

    -- ── Deposit 100 iron bars toward the mission ─────────────────────────────
    r := public.record_guild_contribution(v_hash, v_guild, 'deposit_ore_iron_bar', 100, 'resource:iron_bar');
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL deposit returned: %', r;
    end if;

    -- Progress advanced on BOTH fanned-out missions (full 100 each).
    select progress into v_prog1 from public.guild_missions where id = v_m1;
    select progress into v_prog2 from public.guild_missions where id = v_m2;
    if v_prog1 <> 100 then raise exception 'FAIL generic mission progress: expected 100, got %', v_prog1; end if;
    if v_prog2 <> 100 then raise exception 'FAIL specific mission progress: expected 100, got %', v_prog2; end if;

    -- Stockpile got the 100 iron bars exactly ONCE (not once per mission).
    select amount into v_stock from public.guild_stockpile
    where guild_id = v_guild and item_key = 'resource:iron_bar';
    if coalesce(v_stock, 0) <> 100 then
        raise exception 'FAIL stockpile after deposit: expected 100 (once), got %', coalesce(v_stock, 0);
    end if;

    -- NO refund ledger row was written (items are now shared stock).
    select count(*) into v_ledger from public.guild_contribution_items
    where account_id = v_acct and item_key = 'resource:iron_bar';
    if v_ledger <> 0 then
        raise exception 'FAIL refund ledger should be empty, got % rows', v_ledger;
    end if;

    -- ── A second deposit accumulates in the stockpile ────────────────────────
    r := public.record_guild_contribution(v_hash, v_guild, 'deposit_ore_iron_bar', 50, 'resource:iron_bar');
    select amount into v_stock from public.guild_stockpile
    where guild_id = v_guild and item_key = 'resource:iron_bar';
    if v_stock <> 150 then raise exception 'FAIL stockpile accumulate: expected 150, got %', v_stock; end if;

    -- ── Capacity clamp: overflow is LOST ─────────────────────────────────────
    v_cap := public._guild_stockpile_capacity(v_guild);   -- 50000 at level 0
    -- Deposit way over the cap; stockpile should clamp to cap, remainder lost.
    r := public.record_guild_contribution(v_hash, v_guild, 'deposit_ore_iron_bar', 1000000, 'resource:iron_bar');
    select amount into v_stock from public.guild_stockpile
    where guild_id = v_guild and item_key = 'resource:iron_bar';
    if v_stock <> v_cap then
        raise exception 'FAIL stockpile cap clamp: expected cap %, got %', v_cap, v_stock;
    end if;
    -- A further deposit at cap stores nothing (overflow lost), no error.
    r := public.record_guild_contribution(v_hash, v_guild, 'deposit_ore_iron_bar', 500, 'resource:iron_bar');
    select amount into v_stock from public.guild_stockpile
    where guild_id = v_guild and item_key = 'resource:iron_bar';
    if v_stock <> v_cap then
        raise exception 'FAIL stockpile stays at cap: expected %, got %', v_cap, v_stock;
    end if;

    -- ── Non-stockpilable key is ignored by the helper (defensive) ────────────
    -- 'item:' (produced jewelry) must never enter the stockpile.
    perform public._guild_stockpile_add_capped(v_guild, 'item:gold_ring', 5);
    if exists (select 1 from public.guild_stockpile
               where guild_id = v_guild and item_key = 'item:gold_ring') then
        raise exception 'FAIL jewelry key must not be stockpilable';
    end if;

    -- ── A crop deposit routes to the stockpile too ───────────────────────────
    insert into public.guild_missions
        (guild_id, base_mission_key, difficulty, target, progress, status, spawned_at)
    values (v_guild, 'deposit_beans', 'easy', 500, 0, 'active', now() + interval '2 seconds');
    r := public.record_guild_contribution(v_hash, v_guild, 'deposit_beans', 40, 'crop:beans');
    select amount into v_stock from public.guild_stockpile
    where guild_id = v_guild and item_key = 'crop:beans';
    if coalesce(v_stock, 0) <> 40 then
        raise exception 'FAIL crop deposit to stockpile: expected 40, got %', coalesce(v_stock, 0);
    end if;

    raise notice 'ALL DEPOSIT->STOCKPILE TESTS PASSED';
end;
$$;

rollback;
