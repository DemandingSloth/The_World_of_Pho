-- ============================================================================
-- Verification for migrations 081 + 082 (horseshoe recipes + equip + bonus)
-- ============================================================================
-- AFTER 055 + 065 + 077 + 078 + 080 + 081 + 082. Transactional; ROLLS BACK.
-- Success -> notice "ALL HORSESHOE TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_owner  text := 'test_hs_owner';
    v_ao     uuid;
    r        json;
    v_h1     uuid;
    v_race   uuid;
    v_snap_speed numeric;
    v_snap_end   numeric;
    v_pct0   numeric;
    v_pct10  numeric;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_owner, 'hs_owner', 'x') returning id into v_ao;

    -- ── 081: recipes seeded ──────────────────────────────────────────────────
    if not exists (select 1 from public.guild_production_recipes
                   where recipe_id = 'copper_horseshoe' and input_item_key = 'resource:copper_ingot') then
        raise exception 'FAIL copper_horseshoe recipe not seeded';
    end if;
    if not exists (select 1 from public.guild_production_recipes
                   where recipe_id = 'iron_horseshoe' and input_item_key = 'resource:iron_bar') then
        raise exception 'FAIL iron_horseshoe recipe not seeded';
    end if;
    if (select output_item_key from public.guild_production_recipes
        where recipe_id = 'copper_horseshoe' limit 1) <> 'item:copper_horseshoe' then
        raise exception 'FAIL copper output_item_key';
    end if;

    -- ── 082: bonus curve ─────────────────────────────────────────────────────
    v_pct0  := public._horse_horseshoe_bonus_pct(0);
    v_pct10 := public._horse_horseshoe_bonus_pct(10);
    if v_pct0 <> 0.0 then raise exception 'FAIL level 0 pct not 0: %', v_pct0; end if;
    if v_pct10 <> 0.25 then raise exception 'FAIL level 10 pct not 0.25: %', v_pct10; end if;
    if public._horse_horseshoe_bonus_pct(1) <> 0.01 then
        raise exception 'FAIL level 1 pct not 0.01: %', public._horse_horseshoe_bonus_pct(1);
    end if;

    -- ── Buy a horse, give it headroom, equip a copper shoe ───────────────────
    r := public.buy_horse(v_owner, 'standardbred', 'Clip'); v_h1 := (r->'horse'->>'id')::uuid;
    update public.horses set speed = 40, endurance = 40 where id = v_h1;

    r := public.equip_horseshoe(v_owner, v_h1, 'copper');
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL equip copper: %', r; end if;
    if (select horseshoe from public.horses where id = v_h1) <> 'copper' then
        raise exception 'FAIL horseshoe column not copper';
    end if;

    -- Bad type rejected.
    r := public.equip_horseshoe(v_owner, v_h1, 'platinum');
    if (r->>'error') is distinct from 'bad_horseshoe' then
        raise exception 'FAIL bad horseshoe type: %', r;
    end if;

    -- get_horses surfaces the equipped shoe.
    r := public.get_horses(v_owner);
    if not exists (
        select 1 from json_array_elements(r->'horses') hh
        where (hh->>'id') = v_h1::text and (hh->>'horseshoe') = 'copper'
    ) then
        raise exception 'FAIL get_horses did not surface horseshoe';
    end if;

    -- ── Register into a race with horseshoe level 10 -> snapshot speed +25% ──
    insert into public.races (name, field_size, status, opens_at, closes_at)
    values ('ShoeRace', 8, 'open', now(), now() + interval '5 hours')
    returning id into v_race;
    r := public.register_horse(v_owner, v_race, v_h1, 10);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL register w/ shoe: %', r; end if;

    select speed, endurance into v_snap_speed, v_snap_end
    from public.race_entries where race_id = v_race and horse_id = v_h1;
    -- speed 40 * 1.25 = 50.00 (copper boosts speed); endurance unchanged at 40.
    if v_snap_speed <> 50.00 then
        raise exception 'FAIL copper did not boost snapshot speed to 50: %', v_snap_speed;
    end if;
    if v_snap_end <> 40.00 then
        raise exception 'FAIL endurance should be unchanged by copper: %', v_snap_end;
    end if;

    -- ── Iron shoe boosts endurance instead ───────────────────────────────────
    r := public.buy_horse(v_owner, 'standardbred', 'Clop');
    v_h1 := (r->'horse'->>'id')::uuid;
    update public.horses set speed = 40, endurance = 40 where id = v_h1;
    r := public.equip_horseshoe(v_owner, v_h1, 'iron');
    insert into public.races (name, field_size, status, opens_at, closes_at)
    values ('ShoeRace2', 8, 'open', now(), now() + interval '5 hours')
    returning id into v_race;
    r := public.register_horse(v_owner, v_race, v_h1, 10);
    select speed, endurance into v_snap_speed, v_snap_end
    from public.race_entries where race_id = v_race and horse_id = v_h1;
    if v_snap_end <> 50.00 then raise exception 'FAIL iron endurance not 50: %', v_snap_end; end if;
    if v_snap_speed <> 40.00 then raise exception 'FAIL iron should not touch speed: %', v_snap_speed; end if;

    -- ── No shoe / level 0 -> no boost ────────────────────────────────────────
    r := public.buy_horse(v_owner, 'standardbred', 'Bare');
    v_h1 := (r->'horse'->>'id')::uuid;
    update public.horses set speed = 40, endurance = 40 where id = v_h1;
    insert into public.races (name, field_size, status, opens_at, closes_at)
    values ('ShoeRace3', 8, 'open', now(), now() + interval '5 hours')
    returning id into v_race;
    r := public.register_horse(v_owner, v_race, v_h1, 0);
    select speed into v_snap_speed from public.race_entries where race_id = v_race and horse_id = v_h1;
    if v_snap_speed <> 40.00 then raise exception 'FAIL bare horse boosted: %', v_snap_speed; end if;

    raise notice 'ALL HORSESHOE TESTS PASSED';
end;
$$;

rollback;
