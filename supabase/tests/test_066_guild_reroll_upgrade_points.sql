-- ============================================================================
-- Verification for migration 066 (guild reroll upgrade-point cost) — AFTER 066.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL REROLL TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_hash   text := 'test_rr_leader';
    v_hash2  text := 'test_rr_member';
    v_acct   uuid;
    v_m2     uuid;
    v_guild  uuid;
    r        json;
    v_mid    uuid;
    v_pts    int;
    i        int;
begin
    -- ── Cost curve helper ────────────────────────────────────────────────────
    if public._guild_reroll_cost(0) <> 0 then raise exception 'FAIL cost(0)'; end if;
    if public._guild_reroll_cost(2) <> 0 then raise exception 'FAIL cost(2)'; end if;
    if public._guild_reroll_cost(3) <> 1 then raise exception 'FAIL cost(3) expected 1'; end if;
    if public._guild_reroll_cost(5) <> 1 then raise exception 'FAIL cost(5) expected 1'; end if;
    if public._guild_reroll_cost(6) <> 2 then raise exception 'FAIL cost(6) expected 2'; end if;
    if public._guild_reroll_cost(9) <> 3 then raise exception 'FAIL cost(9) expected 3'; end if;

    -- ── Setup: a guild with a leader + a non-leader member, lots of points ───
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash, 'rr_leader', 'x') returning id into v_acct;
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash2, 'rr_member', 'x') returning id into v_m2;

    insert into public.guilds (name, specialization, leader_id, upgrade_points)
    values ('test_rr_guild', 'mining', v_acct, 100) returning id into v_guild;
    insert into public.guild_members (guild_id, account_id, role)
    values (v_guild, v_acct, 'leader'),
           (v_guild, v_m2, 'member');

    -- Seed an active mission to reroll (easy).
    insert into public.guild_missions
        (guild_id, base_mission_key, difficulty, target, progress, status, spawned_at)
    values (v_guild, 'deposit_ore_iron_bar', 'easy', 100, 0, 'active', now())
    returning id into v_mid;

    -- ── Non-leader cannot reroll ─────────────────────────────────────────────
    r := public.reroll_guild_mission(v_hash2, v_guild, v_mid);
    if (r->>'error') is distinct from 'not_leader' then
        raise exception 'FAIL non-leader reroll guard: %', r;
    end if;

    -- ── Status before any reroll: free, next_cost 0, 3 free remaining ────────
    r := public.get_guild_reroll_status(v_hash, v_guild);
    if (r->>'next_cost')::int <> 0 then raise exception 'FAIL status next_cost pre: %', r; end if;
    if (r->>'free_remaining')::int <> 3 then raise exception 'FAIL status free_remaining pre: %', r; end if;
    if (r->>'is_leader') is distinct from 'true' then raise exception 'FAIL leader flag: %', r; end if;

    -- ── 3 FREE rerolls: points unchanged (100), cost 0 each ──────────────────
    for i in 1..3 loop
        select id into v_mid from public.guild_missions
        where guild_id = v_guild and difficulty = 'easy' and status = 'active' limit 1;
        r := public.reroll_guild_mission(v_hash, v_guild, v_mid);
        if (r->>'ok') is distinct from 'true' then raise exception 'FAIL free reroll %: %', i, r; end if;
        if (r->>'cost')::int <> 0 then raise exception 'FAIL free reroll % cost: %', i, r; end if;
    end loop;
    select upgrade_points into v_pts from public.guilds where id = v_guild;
    if v_pts <> 100 then raise exception 'FAIL points after 3 free: expected 100, got %', v_pts; end if;

    -- next_cost should now be 1 (used=3).
    r := public.get_guild_reroll_status(v_hash, v_guild);
    if (r->>'next_cost')::int <> 1 then raise exception 'FAIL next_cost after 3 free: %', r; end if;

    -- ── Rerolls 4-6 cost 1 pt each (total 3) -> 97 ───────────────────────────
    for i in 4..6 loop
        select id into v_mid from public.guild_missions
        where guild_id = v_guild and difficulty = 'easy' and status = 'active' limit 1;
        r := public.reroll_guild_mission(v_hash, v_guild, v_mid);
        if (r->>'cost')::int <> 1 then raise exception 'FAIL reroll % cost expected 1: %', i, r; end if;
    end loop;
    select upgrade_points into v_pts from public.guilds where id = v_guild;
    if v_pts <> 97 then raise exception 'FAIL points after rerolls 4-6: expected 97, got %', v_pts; end if;

    -- ── Reroll 7 costs 2 -> 95 ───────────────────────────────────────────────
    select id into v_mid from public.guild_missions
    where guild_id = v_guild and difficulty = 'easy' and status = 'active' limit 1;
    r := public.reroll_guild_mission(v_hash, v_guild, v_mid);
    if (r->>'cost')::int <> 2 then raise exception 'FAIL reroll 7 cost expected 2: %', r; end if;
    if (r->>'next_cost')::int <> 2 then raise exception 'FAIL reroll 7 next_cost expected 2: %', r; end if;
    select upgrade_points into v_pts from public.guilds where id = v_guild;
    if v_pts <> 95 then raise exception 'FAIL points after reroll 7: expected 95, got %', v_pts; end if;

    -- ── Rollover resets to free: back-date reroll_day, next reroll is free ───
    update public.guilds set reroll_day = reroll_day - 1 where id = v_guild;
    r := public.get_guild_reroll_status(v_hash, v_guild);
    if (r->>'next_cost')::int <> 0 then raise exception 'FAIL rollover reset next_cost: %', r; end if;
    if (r->>'free_remaining')::int <> 3 then raise exception 'FAIL rollover reset free_remaining: %', r; end if;
    select id into v_mid from public.guild_missions
    where guild_id = v_guild and difficulty = 'easy' and status = 'active' limit 1;
    r := public.reroll_guild_mission(v_hash, v_guild, v_mid);
    if (r->>'cost')::int <> 0 then raise exception 'FAIL post-rollover reroll should be free: %', r; end if;
    select upgrade_points into v_pts from public.guilds where id = v_guild;
    if v_pts <> 95 then raise exception 'FAIL points unchanged on free post-rollover: expected 95, got %', v_pts; end if;

    -- ── Insufficient points: drain to 0, force into a paid tier ──────────────
    update public.guilds set upgrade_points = 0, reroll_count = 3, reroll_day = floor(extract(epoch from now())/86400.0)::int
    where id = v_guild;   -- used=3 -> next costs 1, but 0 points
    select id into v_mid from public.guild_missions
    where guild_id = v_guild and difficulty = 'easy' and status = 'active' limit 1;
    r := public.reroll_guild_mission(v_hash, v_guild, v_mid);
    if (r->>'error') is distinct from 'insufficient_points' then
        raise exception 'FAIL insufficient_points guard: %', r;
    end if;

    raise notice 'ALL REROLL TESTS PASSED';
end;
$$;

rollback;
