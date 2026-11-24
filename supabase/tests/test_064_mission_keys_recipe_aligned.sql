-- ============================================================================
-- Verification for migration 064 (recipe-aligned mission keys) — RUN AFTER 064.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL MISSION KEY TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_mining  text[];
    v_garden  text[];
    v_banned  text[] := array[
        'deposit_gems','deposit_ores',
        'deposit_gem_blue_stone','deposit_gem_pink_stone','deposit_gem_violet_stone',
        'deposit_gem_black_pearl','deposit_gem_emerald','deposit_gem_ruby','deposit_gem_diamond',
        'deposit_ore_iron_ore','deposit_ore_copper_ore'
    ];
    v_required text[] := array[
        'deposit_polished','deposit_polished_blue_stone','deposit_polished_pink_stone',
        'deposit_polished_violet_stone','deposit_polished_black_pearl','deposit_polished_emerald',
        'deposit_polished_ruby','deposit_polished_diamond',
        'deposit_gem_gold',
        'deposit_ore_iron_bar','deposit_ore_copper_ingot','deposit_ore_gold_ingot'
    ];
    k text;
begin
    v_mining := public._guild_mission_key_pool('mining');
    v_garden := public._guild_mission_key_pool('gardening');

    -- ── No banned (non-recipe) key is in the mining pool ─────────────────────
    foreach k in array v_banned loop
        if k = any(v_mining) then
            raise exception 'FAIL banned key still present in mining pool: %', k;
        end if;
    end loop;

    -- ── Every required recipe-relevant key IS in the mining pool ─────────────
    foreach k in array v_required loop
        if not (k = any(v_mining)) then
            raise exception 'FAIL required key missing from mining pool: %', k;
        end if;
    end loop;

    -- ── Mining pool is exactly the 12 required keys (no extras) ──────────────
    if array_length(v_mining, 1) <> 12 then
        raise exception 'FAIL mining pool size: expected 12, got %', array_length(v_mining, 1);
    end if;

    -- ── Gardening pool is unchanged (still has crops/fruit, no gem keys) ─────
    if not ('deposit_beans' = any(v_garden)) then
        raise exception 'FAIL gardening pool missing deposit_beans';
    end if;
    if 'deposit_ores' = any(v_garden) or 'deposit_polished' = any(v_garden) then
        raise exception 'FAIL gardening pool should not contain mining keys';
    end if;

    -- ── End-to-end: spawn missions for a mining guild, assert every spawned
    --    mission's base_mission_key is in the allowed pool ─────────────────────
    declare
        v_acct  uuid;
        v_guild uuid;
        m       record;
    begin
        insert into public.accounts (device_hash, username, recovery_hash)
        values ('test_mk_leader', 'mk_leader', 'x') returning id into v_acct;
        insert into public.guilds (name, specialization, leader_id)
        values ('test_mk_guild', 'mining', v_acct) returning id into v_guild;
        insert into public.guild_members (guild_id, account_id, role)
        values (v_guild, v_acct, 'leader');

        perform public._spawn_guild_missions(v_guild);

        for m in
            select base_mission_key from public.guild_missions
            where guild_id = v_guild and status = 'active'
        loop
            if not (m.base_mission_key = any(v_mining)) then
                raise exception 'FAIL spawned mission uses disallowed key: %', m.base_mission_key;
            end if;
        end loop;
    end;

    raise notice 'ALL MISSION KEY TESTS PASSED';
end;
$$;

rollback;
