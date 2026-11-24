-- ============================================================================
-- Verification for migration 069 (guild disband) — RUN AFTER 069.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL DISBAND TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_leader  text := 'test_dis_leader';
    v_member  text := 'test_dis_member';
    v_other   text := 'test_dis_other';
    v_la      uuid;
    v_ma      uuid;
    v_oa      uuid;
    v_guild   uuid;
    v_guild2  uuid;
    v_ga      uuid;
    v_gb      uuid;
    r         json;
    v_cnt     int;
begin
    -- ── Setup: a mining guild (leader + member) linked to a gardening guild ──
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_leader, 'dis_leader', 'x') returning id into v_la;
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_member, 'dis_member', 'x') returning id into v_ma;
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_other,  'dis_other',  'x') returning id into v_oa;

    insert into public.guilds (name, specialization, leader_id)
    values ('test_dis_guild', 'mining', v_la) returning id into v_guild;
    insert into public.guild_members (guild_id, account_id, role)
    values (v_guild, v_la, 'leader'),
           (v_guild, v_ma, 'member');

    -- A second guild (the "other" guild) linked to ours.
    insert into public.guilds (name, specialization, leader_id)
    values ('test_dis_other_guild', 'gardening', v_oa) returning id into v_guild2;
    insert into public.guild_members (guild_id, account_id, role)
    values (v_guild2, v_oa, 'leader');

    -- Create the link (guild_a_id < guild_b_id enforced by the table).
    if v_guild < v_guild2 then v_ga := v_guild; v_gb := v_guild2;
    else v_ga := v_guild2; v_gb := v_guild; end if;
    insert into public.guild_links (guild_a_id, guild_b_id) values (v_ga, v_gb);
    -- And a pending link request from the OTHER guild to ours.
    insert into public.guild_link_requests (requesting_guild_id, target_guild_id, status)
    values (v_guild2, v_guild, 'pending');

    -- ── A non-leader member cannot disband ──────────────────────────────────
    r := public.disband_guild(v_member, v_guild);
    if (r->>'error') is distinct from 'not_guild_leader' then
        raise exception 'FAIL member disband should be not_guild_leader: %', r;
    end if;
    -- Guild still exists.
    select count(*) into v_cnt from public.guilds where id = v_guild;
    if v_cnt <> 1 then raise exception 'FAIL guild gone after member attempt'; end if;

    -- ── An outsider cannot disband our guild ────────────────────────────────
    r := public.disband_guild(v_other, v_guild);
    if (r->>'error') is distinct from 'not_in_guild' then
        raise exception 'FAIL outsider disband should be not_in_guild: %', r;
    end if;

    -- ── Leader disbands: ok + dissolved ─────────────────────────────────────
    r := public.disband_guild(v_leader, v_guild);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL leader disband: %', r;
    end if;
    if (r->>'dissolved') is distinct from 'true' then
        raise exception 'FAIL disband should report dissolved: %', r;
    end if;

    -- ── Guild row gone ───────────────────────────────────────────────────────
    select count(*) into v_cnt from public.guilds where id = v_guild;
    if v_cnt <> 0 then raise exception 'FAIL guild row still present after disband'; end if;

    -- ── Member rows cascaded away ────────────────────────────────────────────
    select count(*) into v_cnt from public.guild_members where guild_id = v_guild;
    if v_cnt <> 0 then raise exception 'FAIL member rows not cascaded: %', v_cnt; end if;

    -- ── The LINK from the other guild is severed ─────────────────────────────
    select count(*) into v_cnt from public.guild_links
    where guild_a_id = v_ga and guild_b_id = v_gb;
    if v_cnt <> 0 then raise exception 'FAIL link not severed on disband: %', v_cnt; end if;

    -- ── The pending link request involving our guild is gone ─────────────────
    select count(*) into v_cnt from public.guild_link_requests
    where requesting_guild_id = v_guild or target_guild_id = v_guild;
    if v_cnt <> 0 then raise exception 'FAIL link request not cascaded: %', v_cnt; end if;

    -- ── The OTHER guild still exists (only ours was disbanded) ───────────────
    select count(*) into v_cnt from public.guilds where id = v_guild2;
    if v_cnt <> 1 then raise exception 'FAIL other guild should survive'; end if;

    raise notice 'ALL DISBAND TESTS PASSED';
end;
$$;

rollback;
