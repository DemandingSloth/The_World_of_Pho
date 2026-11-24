-- ============================================================================
-- Verification for migration 077 (horse cups) — AFTER 065+074+075+076+077.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL CUP TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_owner  text := 'test_cup_owner';
    v_ao     uuid;
    r        json;
    v_cup    uuid;
    v_hi     uuid;      -- qualifies for Little Cup (tier 1)
    v_strong uuid;      -- over-qualifies (tier 3) -> locked out of tier 1
    v_cnt    int;
    v_first  bigint;
    v_tier   int;
    v_breed  text;
    v_place2 uuid;      -- a 2nd real horse to test top-3 payout
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_owner, 'cup_owner', 'x') returning id into v_ao;

    -- ── Tier table sanity ────────────────────────────────────────────────────
    select count(*) into v_cnt from public._race_cup_tiers();
    if v_cnt <> 3 then raise exception 'FAIL expected 3 cup tiers, got %', v_cnt; end if;
    select first_prize into v_first from public._race_cup_tiers() where tier = 1;
    if v_first <> 1000000 then raise exception 'FAIL little cup first prize: %', v_first; end if;
    select first_prize into v_first from public._race_cup_tiers() where tier = 3;
    if v_first <> 100000000 then raise exception 'FAIL derby cup first prize: %', v_first; end if;
    if public._race_cup_field_size() <> 5 then raise exception 'FAIL cup field size'; end if;

    -- ── Highest-tier mapping ─────────────────────────────────────────────────
    if public._race_cup_tier_for(100)  is not null then raise exception 'FAIL <125 maps to a tier'; end if;
    if public._race_cup_tier_for(150)  <> 1 then raise exception 'FAIL 150 -> tier 1'; end if;
    if public._race_cup_tier_for(300)  <> 2 then raise exception 'FAIL 300 -> tier 2'; end if;
    if public._race_cup_tier_for(500)  <> 3 then raise exception 'FAIL 500 -> tier 3'; end if;

    -- ── Scheduler keeps one OPEN cup per tier ────────────────────────────────
    perform public._horse_advance_races();
    for v_tier in 1..3 loop
        if not exists (select 1 from public.races
                       where status='open' and kind='cup' and tier=v_tier) then
            raise exception 'FAIL no open cup for tier %', v_tier;
        end if;
    end loop;
    -- Open cups must be field size 5.
    select field_size into v_cnt from public.races where status='open' and kind='cup' and tier=1 limit 1;
    if v_cnt <> 5 then raise exception 'FAIL open cup field size: %', v_cnt; end if;

    -- ── A controlled Little Cup (tier 1) ─────────────────────────────────────
    insert into public.races (name, kind, tier, prize_breed, field_size, status, opens_at, closes_at)
    values ('Little Cup', 'cup', 1, 'unicorn', 5, 'open', now(), now() + interval '5 hours')
    returning id into v_cup;

    -- A horse eligible for EXACTLY tier 1 (total ~160).
    r := public.buy_horse(v_owner, 'standardbred', 'Champ'); v_hi := (r->'horse'->>'id')::uuid;
    update public.horses set life = 90, speed = 40, endurance = 30 where id = v_hi; -- 160 -> tier 1

    -- An OVER-qualified horse (total 500 -> tier 3) must be REJECTED from tier 1.
    r := public.buy_horse(v_owner, 'standardbred', 'Beast'); v_strong := (r->'horse'->>'id')::uuid;
    update public.horses set life = 200, speed = 100, endurance = 100 where id = v_strong; -- 400 -> tier 3
    r := public.register_horse(v_owner, v_cup, v_strong);
    if (r->>'error') is distinct from 'cup_tier_mismatch' then
        raise exception 'FAIL over-qualified horse should be locked out of tier 1: %', r;
    end if;
    if (r->>'eligible_tier')::int <> 3 then raise exception 'FAIL eligible_tier echo: %', r; end if;

    -- A too-weak horse (arabian 118) also rejected.
    r := public.buy_horse(v_owner, 'arabian', 'Weak');
    r := public.register_horse(v_owner, v_cup, (r->'horse'->>'id')::uuid);
    if (r->>'error') is distinct from 'cup_tier_mismatch' then
        raise exception 'FAIL weak horse should mismatch: %', r;
    end if;

    -- The tier-1 horse registers fine.
    r := public.register_horse(v_owner, v_cup, v_hi);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL tier-1 register: %', r; end if;

    -- Add a 2nd real tier-1 horse so we can check the 2nd-place prize.
    r := public.buy_horse(v_owner, 'standardbred', 'Runner'); v_place2 := (r->'horse'->>'id')::uuid;
    update public.horses set life = 80, speed = 35, endurance = 25 where id = v_place2; -- 140 -> tier 1
    r := public.register_horse(v_owner, v_cup, v_place2);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL 2nd tier-1 register: %', r; end if;

    -- ── Lock the cup (expire 5h cap). Field backfills to 5. ──────────────────
    update public.races set closes_at = now() - interval '1 min' where id = v_cup;
    perform public._horse_advance_races();
    if (select status from public.races where id = v_cup) <> 'betting' then
        raise exception 'FAIL cup should be betting after cap';
    end if;
    select count(*) into v_cnt from public.race_entries where race_id = v_cup;
    if v_cnt <> 5 then raise exception 'FAIL cup not backfilled to 5: %', v_cnt; end if;

    -- Force the two real horses to dominate (1st + 2nd), then resolve.
    update public.race_entries set speed = 100, endurance = 100, life = 200, life_cap = 200
    where race_id = v_cup and horse_id = v_hi;
    update public.race_entries set speed = 95, endurance = 95, life = 190, life_cap = 190
    where race_id = v_cup and horse_id = v_place2;
    update public.races set bet_closes_at = now() - interval '1 min' where id = v_cup;
    perform public._horse_advance_races();
    if (select status from public.races where id = v_cup) <> 'resolved' then
        raise exception 'FAIL cup not resolved';
    end if;

    -- ── Top-3 coin prizes recorded on real-horse entries ─────────────────────
    -- 1st prize = 1,000,000; 2nd = 500,000.
    select prize_coins into v_first from public.race_entries
    where race_id = v_cup and finish_place = 1;
    if v_first <> 1000000 then raise exception 'FAIL 1st prize: %', v_first; end if;
    select prize_coins into v_first from public.race_entries
    where race_id = v_cup and finish_place = 2;
    if v_first <> 500000 then raise exception 'FAIL 2nd prize: %', v_first; end if;

    -- ── Breed foal granted to the winner (stable had room) ───────────────────
    if not exists (select 1 from public.horses where owner_id = v_ao and breed = 'unicorn') then
        raise exception 'FAIL cup winner did not get a unicorn foal';
    end if;

    -- ── get_my_cup_prizes surfaces the unclaimed coin prizes ─────────────────
    r := public.get_my_cup_prizes(v_owner);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL get_my_cup_prizes: %', r; end if;
    if json_array_length(r->'prizes') < 2 then
        raise exception 'FAIL expected >=2 cup prizes, got %', json_array_length(r->'prizes');
    end if;

    -- ── Room-gated foal: fill the stable, then an NPC-only cup grants no foal ─
    -- (We only assert the room gate indirectly: a 2nd cup won by an NPC grants nothing.)
    insert into public.races (name, kind, tier, prize_breed, field_size, status, opens_at, closes_at)
    values ('Little Cup', 'cup', 1, 'unicorn', 5, 'open', now(), now() + interval '5 hours')
    returning id into v_cup;
    update public.races set closes_at = now() - interval '1 min' where id = v_cup;
    perform public._horse_advance_races();            -- all-NPC backfill
    select count(*) into v_cnt from public.horses where owner_id = v_ao and breed = 'unicorn';
    update public.races set bet_closes_at = now() - interval '1 min' where id = v_cup;
    perform public._horse_advance_races();            -- resolve
    if (select count(*) from public.horses where owner_id = v_ao and breed = 'unicorn') <> v_cnt then
        raise exception 'FAIL NPC-won cup wrongly granted a foal';
    end if;
    -- No prize_coins on NPC placings.
    if exists (select 1 from public.race_entries
               where race_id = v_cup and horse_id is null and prize_coins > 0) then
        raise exception 'FAIL NPC entry got a coin prize';
    end if;

    -- ── get_races surfaces cup tier + band + first prize ─────────────────────
    r := public.get_races(v_owner);
    if not exists (
        select 1 from json_array_elements(r->'races') e
        where (e->>'kind') = 'cup' and (e->>'tier') is not null
          and (e->>'first_prize') is not null and (e->>'min_total') is not null
    ) then
        raise exception 'FAIL get_races did not surface cup tier/band/prize';
    end if;

    raise notice 'ALL CUP TESTS PASSED';
end;
$$;

rollback;
