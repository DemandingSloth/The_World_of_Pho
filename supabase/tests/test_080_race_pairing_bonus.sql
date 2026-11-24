-- ============================================================================
-- Verification for migration 080 (horse-guild pairing bonus)
-- ============================================================================
-- AFTER 077 + 078 + 080. Transactional; ROLLS BACK.
-- Success -> notice "ALL PAIRING TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_a      text := 'test_pair_a';
    v_b      text := 'test_pair_b';
    v_solo   text := 'test_pair_solo';
    v_aa     uuid;
    v_ab     uuid;
    v_as     uuid;
    v_guild  uuid;
    r        json;
    v_ha     uuid;
    v_hb     uuid;
    v_hs     uuid;
    v_race   uuid;
    v_spd_a0 numeric := 30;
    v_spd_a1 numeric;
    v_spd_s0 numeric := 30;
    v_spd_s1 numeric;
    v_pct    numeric;
begin
    insert into public.accounts (device_hash, username, recovery_hash) values (v_a, 'pair_a', 'x') returning id into v_aa;
    insert into public.accounts (device_hash, username, recovery_hash) values (v_b, 'pair_b', 'x') returning id into v_ab;
    insert into public.accounts (device_hash, username, recovery_hash) values (v_solo, 'pair_solo', 'x') returning id into v_as;

    -- A + B are in the SAME horse guild; solo is in none.
    r := public.create_guild(v_a, 'Stable Mates', 'horse');
    select id into v_guild from public.guilds where lower(name) = lower('Stable Mates');
    insert into public.guild_members (guild_id, account_id, role, perks_active_at)
    values (v_guild, v_ab, 'member', null);

    -- Three horses, same stats, so the bonus is the only differentiator.
    r := public.buy_horse(v_a, 'standardbred', 'Ay'); v_ha := (r->'horse'->>'id')::uuid;
    r := public.buy_horse(v_b, 'standardbred', 'Bee'); v_hb := (r->'horse'->>'id')::uuid;
    r := public.buy_horse(v_solo, 'standardbred', 'Essy'); v_hs := (r->'horse'->>'id')::uuid;
    update public.horses set speed = v_spd_a0, endurance = 30 where id in (v_ha, v_hb, v_hs);

    -- A regular 8-lane race; A, B, solo all register.
    insert into public.races (name, field_size, status, opens_at, closes_at)
    values ('PairRace', 8, 'open', now(), now() + interval '5 hours')
    returning id into v_race;
    r := public.register_horse(v_a,    v_race, v_ha);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL reg A: %', r; end if;
    r := public.register_horse(v_b,    v_race, v_hb);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL reg B: %', r; end if;
    r := public.register_horse(v_solo, v_race, v_hs);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL reg solo: %', r; end if;

    -- Lock the field (expire the 5h cap), which applies the pairing bonus.
    update public.races set closes_at = now() - interval '1 min' where id = v_race;
    perform public._horse_advance_races();
    if (select status from public.races where id = v_race) <> 'betting' then
        raise exception 'FAIL race should be betting';
    end if;

    v_pct := public._race_pairing_bonus_pct();

    -- A + B (guildmates, 2 in the race) got the boost; their entry snapshots rose.
    select speed into v_spd_a1 from public.race_entries where race_id = v_race and horse_id = v_ha;
    if v_spd_a1 <> round(v_spd_a0 * (1.0 + v_pct), 2) then
        raise exception 'FAIL A speed not boosted: % (want %)', v_spd_a1, round(v_spd_a0 * (1.0 + v_pct), 2);
    end if;
    if (select pairing_bonus from public.race_entries where race_id = v_race and horse_id = v_ha) <> true then
        raise exception 'FAIL A not flagged pairing_bonus';
    end if;
    if (select pairing_bonus from public.race_entries where race_id = v_race and horse_id = v_hb) <> true then
        raise exception 'FAIL B not flagged pairing_bonus';
    end if;

    -- Solo (no guildmate in the race) was NOT boosted.
    select speed into v_spd_s1 from public.race_entries where race_id = v_race and horse_id = v_hs;
    if v_spd_s1 <> v_spd_s0 then
        raise exception 'FAIL solo should not be boosted: % (want %)', v_spd_s1, v_spd_s0;
    end if;
    if (select pairing_bonus from public.race_entries where race_id = v_race and horse_id = v_hs) <> false then
        raise exception 'FAIL solo wrongly flagged pairing_bonus';
    end if;

    -- NPC backfill lanes never get the bonus.
    if exists (select 1 from public.race_entries where race_id = v_race and horse_id is null and pairing_bonus) then
        raise exception 'FAIL an NPC entry got pairing_bonus';
    end if;

    -- get_races surfaces the flag.
    r := public.get_races(v_a);
    if not exists (
        select 1 from json_array_elements(r->'races') rr,
                     json_array_elements(rr->'entries') ee
        where (ee->>'pairing_bonus')::boolean = true
    ) then
        raise exception 'FAIL get_races did not surface pairing_bonus';
    end if;

    raise notice 'ALL PAIRING TESTS PASSED';
end;
$$;

rollback;
