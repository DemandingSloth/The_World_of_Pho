-- ============================================================================
-- Verification for migration 078 (horse guild spec + caps + missions)
-- ============================================================================
-- AFTER 022 + 064 + 065 + 070 + 077 + 078. Transactional; ROLLS BACK.
-- Success -> notice "ALL HORSE GUILD TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_owner   text := 'test_hg_owner';
    v_ao      uuid;
    r         json;
    v_guild   uuid;
    v_cap     int;
    v_tcap    numeric;
    v_keys    text[];
    v_mkey    text;
    v_prog    int;
    v_mid     uuid;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_owner, 'hg_owner', 'x') returning id into v_ao;

    -- ── 'horse' is now a valid specialization ────────────────────────────────
    r := public.create_guild(v_owner, 'Gallopers United', 'horse');
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL create horse guild: %', r;
    end if;
    select id into v_guild from public.guilds where lower(name) = lower('Gallopers United');
    if v_guild is null then raise exception 'FAIL horse guild not created'; end if;
    if (select specialization from public.guilds where id = v_guild) <> 'horse' then
        raise exception 'FAIL guild spec not horse';
    end if;

    -- ── Caps at base (no upgrades yet) ───────────────────────────────────────
    v_cap  := public._horse_stable_capacity(v_ao);
    v_tcap := public._horse_training_session_cap(v_ao);
    if v_cap <> 5 then raise exception 'FAIL base stable cap: %', v_cap; end if;
    if v_tcap <> 10.00 then raise exception 'FAIL base training cap: %', v_tcap; end if;

    -- ── Buy stable + training upgrades to level 3 each ───────────────────────
    insert into public.guild_upgrade_levels (guild_id, upgrade_key, level)
    values (v_guild, 'horse_stable_size', 3), (v_guild, 'horse_training_cap', 3);

    v_cap  := public._horse_stable_capacity(v_ao);
    v_tcap := public._horse_training_session_cap(v_ao);
    if v_cap <> 8 then raise exception 'FAIL stable cap at lvl 3 (want 8): %', v_cap; end if;
    if v_tcap <> 13.00 then raise exception 'FAIL training cap at lvl 3 (want 13): %', v_tcap; end if;

    -- ── Probation: perks inactive -> caps fall back to base ──────────────────
    update public.guild_members
    set perks_active_at = extract(epoch from now()) + 3600  -- active in 1h
    where guild_id = v_guild and account_id = v_ao;
    if public._horse_stable_capacity(v_ao) <> 5 then
        raise exception 'FAIL probation should drop stable cap to base';
    end if;
    if public._horse_training_session_cap(v_ao) <> 10.00 then
        raise exception 'FAIL probation should drop training cap to base';
    end if;
    -- Clear probation.
    update public.guild_members set perks_active_at = null
    where guild_id = v_guild and account_id = v_ao;
    if public._horse_stable_capacity(v_ao) <> 8 then
        raise exception 'FAIL cap should restore after probation clears';
    end if;

    -- ── A gardening/mining member gets NO horse bonus (spec gate) ────────────
    -- (Simulate by flipping the guild spec; the upgrade rows stay.)
    update public.guilds set specialization = 'gardening' where id = v_guild;
    if public._horse_stable_capacity(v_ao) <> 5 then
        raise exception 'FAIL non-horse guild should not grant stable bonus';
    end if;
    update public.guilds set specialization = 'horse' where id = v_guild;

    -- ── Mission key pool includes the horse keys ─────────────────────────────
    v_keys := public._guild_mission_key_pool('horse');
    if not ('race_wins' = any(v_keys)) or not ('train_sessions' = any(v_keys)) then
        raise exception 'FAIL horse mission pool missing keys: %', v_keys;
    end if;
    if 'deposit_beans' = any(v_keys) then
        raise exception 'FAIL horse pool should not contain gardening keys';
    end if;

    -- ── Base targets defined for horse keys ──────────────────────────────────
    if public._guild_mission_base_target('race_wins', 'hard') is null then
        raise exception 'FAIL race_wins has no hard target';
    end if;
    if public._guild_mission_base_target('train_sessions', 'easy') is null then
        raise exception 'FAIL train_sessions has no easy target';
    end if;

    -- ── record_horse_guild_activity credits an active horse mission ──────────
    -- Spawn a horse mission directly (bypass the random spawner) and credit it.
    insert into public.guild_missions (
        guild_id, base_mission_key, difficulty, target, reward_tokens,
        reward_upgrade_points, status, expires_at
    ) values (
        v_guild, 'race_wins', 'hard', 10, 100, 5, 'active', now() + interval '48 hours'
    ) returning id into v_mid;

    r := public.record_horse_guild_activity(v_owner, 'race_wins', 3);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL record activity: %', r; end if;
    select progress into v_prog from public.guild_missions where id = v_mid;
    if v_prog <> 3 then raise exception 'FAIL race_wins progress (want 3): %', v_prog; end if;

    -- Account-based internal variant (used by race resolution) also credits.
    perform public._record_horse_guild_activity_acct(v_ao, 'race_wins', 2);
    select progress into v_prog from public.guild_missions where id = v_mid;
    if v_prog <> 5 then raise exception 'FAIL acct credit progress (want 5): %', v_prog; end if;

    -- Non-horse key is a no-op.
    r := public.record_horse_guild_activity(v_owner, 'deposit_beans', 5);
    select progress into v_prog from public.guild_missions where id = v_mid;
    if v_prog <> 5 then raise exception 'FAIL wrong-key credit changed progress: %', v_prog; end if;

    raise notice 'ALL HORSE GUILD TESTS PASSED';
end;
$$;

rollback;
