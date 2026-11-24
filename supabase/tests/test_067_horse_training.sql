-- ============================================================================
-- Verification for migration 067 (horse training) — RUN AFTER 065 + 067.
-- ============================================================================
-- Transactional; ROLLS BACK. Success -> notice "ALL TRAINING TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_hash   text := 'test_train_owner';
    v_acct   uuid;
    r        json;
    v_id     uuid;
    v_id2    uuid;
    v_speed0 int;
    v_end0   int;
    v_cap0   int;
    v_today  date := (now() at time zone 'utc')::date;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash, 'train_owner', 'x') returning id into v_acct;

    -- ── Gain curve helper: 0 -> 1 (floor), 100 -> max, clamps out-of-range ──
    if public._horse_training_gain(0, 3)   <> 1 then raise exception 'FAIL gain score 0'; end if;
    if public._horse_training_gain(100, 3) <> 3 then raise exception 'FAIL gain score 100 max3'; end if;
    if public._horse_training_gain(100, 5) <> 5 then raise exception 'FAIL gain score 100 max5'; end if;
    if public._horse_training_gain(-50, 3) <> 1 then raise exception 'FAIL gain negative clamps to 1'; end if;
    if public._horse_training_gain(999, 3) <> 3 then raise exception 'FAIL gain >100 clamps to max'; end if;
    -- 50/100 * 3 = 1.5 -> ceil -> 2
    if public._horse_training_gain(50, 3)  <> 2 then raise exception 'FAIL gain mid score3'; end if;

    -- ── Buy a thoroughbred (80/10/6) to train ────────────────────────────────
    r := public.buy_horse(v_hash, 'thoroughbred', 'Trainee');
    v_id := (r->'horse'->>'id')::uuid;
    v_speed0 := (r->'horse'->>'speed')::int;      -- 10
    v_end0   := (r->'horse'->>'endurance')::int;  -- 6
    v_cap0   := (r->'horse'->>'life_cap')::int;   -- 80

    -- ── Invalid kind rejected ────────────────────────────────────────────────
    r := public.train_horse(v_hash, v_id, 'yoga', 100);
    if (r->>'error') is distinct from 'invalid_kind' then
        raise exception 'FAIL invalid_kind: %', r;
    end if;

    -- ── sprint raises speed by server-decided gain (score 100 -> +3) ─────────
    r := public.train_horse(v_hash, v_id, 'sprint', 100);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL sprint: %', r; end if;
    if (r->>'stat') is distinct from 'speed' then raise exception 'FAIL sprint stat: %', r; end if;
    if (r->>'gain')::int <> 3 then raise exception 'FAIL sprint gain: %', r; end if;
    if (r->'horse'->>'speed')::int <> v_speed0 + 3 then
        raise exception 'FAIL speed after sprint: %', r;
    end if;

    -- ── Second sprint same day blocked ───────────────────────────────────────
    r := public.train_horse(v_hash, v_id, 'sprint', 100);
    if (r->>'error') is distinct from 'already_trained' then
        raise exception 'FAIL sprint cooldown: %', r;
    end if;

    -- ── hurdle is independent of sprint (still allowed same day) ─────────────
    r := public.train_horse(v_hash, v_id, 'hurdle', 0);  -- poor run -> +1
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL hurdle: %', r; end if;
    if (r->>'gain')::int <> 1 then raise exception 'FAIL hurdle gain floor: %', r; end if;
    if (r->'horse'->>'endurance')::int <> v_end0 + 1 then
        raise exception 'FAIL endurance after hurdle: %', r;
    end if;

    -- ── groom raises life_cap AND tops life up toward the new cap ────────────
    -- First knock life down below cap so we can see the top-up.
    update public.horses set life = 40 where id = v_id;
    r := public.train_horse(v_hash, v_id, 'groom', 100);  -- +5 cap
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL groom: %', r; end if;
    if (r->>'stat') is distinct from 'life_cap' then raise exception 'FAIL groom stat: %', r; end if;
    if (r->'horse'->>'life_cap')::int <> v_cap0 + 5 then
        raise exception 'FAIL life_cap after groom: %', r;
    end if;
    -- life was 40, below old cap; groom should NOT lower it, and keeps it <= new cap.
    if (r->'horse'->>'life')::int < 40 then
        raise exception 'FAIL groom lowered life: %', r;
    end if;
    if (r->'horse'->>'life')::int > (r->'horse'->>'life_cap')::int then
        raise exception 'FAIL life exceeds cap: %', r;
    end if;

    -- ── Ceiling: push speed to 100, next sprint reports at_ceiling ───────────
    update public.horses set speed = 100 where id = v_id;
    delete from public.horse_training where horse_id = v_id and kind = 'sprint';  -- clear cooldown
    r := public.train_horse(v_hash, v_id, 'sprint', 100);
    if (r->>'error') is distinct from 'at_ceiling' then
        raise exception 'FAIL at_ceiling: %', r;
    end if;

    -- ── Clamp near ceiling: speed 99, +3 gain clamps to +1 (-> 100) ──────────
    update public.horses set speed = 99 where id = v_id;
    delete from public.horse_training where horse_id = v_id and kind = 'sprint';
    r := public.train_horse(v_hash, v_id, 'sprint', 100);
    if (r->>'gain')::int <> 1 then raise exception 'FAIL clamp gain near ceiling: %', r; end if;
    if (r->'horse'->>'speed')::int <> 100 then raise exception 'FAIL speed clamp to 100: %', r; end if;

    -- ── Retired horse can't train ────────────────────────────────────────────
    r := public.buy_horse(v_hash, 'arabian', 'Oldie');
    v_id2 := (r->'horse'->>'id')::uuid;
    update public.horses set status = 'retired' where id = v_id2;
    r := public.train_horse(v_hash, v_id2, 'sprint', 100);
    if (r->>'error') is distinct from 'horse_retired' then
        raise exception 'FAIL train retired: %', r;
    end if;

    -- ── Not your horse ───────────────────────────────────────────────────────
    insert into public.accounts (device_hash, username, recovery_hash)
    values ('test_train_other', 'train_other', 'x');
    r := public.train_horse('test_train_other', v_id, 'hurdle', 100);
    if (r->>'error') is distinct from 'not_your_horse' then
        raise exception 'FAIL train not-your-horse: %', r;
    end if;

    -- ── get_training_status: v_id trained sprint+hurdle+groom today ──────────
    -- sprint cooldown was cleared & re-trained above, so all three are used today.
    r := public.get_training_status(v_hash);
    if (r->>'day')::date <> v_today then raise exception 'FAIL status day: %', r; end if;
    -- Find v_id's row and confirm all three unavailable (false).
    declare
        v_found boolean := false;
        elem    json;
    begin
        for elem in select * from json_array_elements(r->'horses') loop
            if (elem->>'horse_id')::uuid = v_id then
                v_found := true;
                if (elem->>'sprint')::boolean <> false then raise exception 'FAIL status sprint should be used: %', elem; end if;
                if (elem->>'hurdle')::boolean <> false then raise exception 'FAIL status hurdle should be used: %', elem; end if;
                if (elem->>'groom')::boolean  <> false then raise exception 'FAIL status groom should be used: %', elem; end if;
            end if;
        end loop;
        if not v_found then raise exception 'FAIL status missing trainee row'; end if;
    end;

    raise notice 'ALL TRAINING TESTS PASSED';
end;
$$;

rollback;
