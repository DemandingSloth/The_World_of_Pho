-- ============================================================================
-- Verification for migration 079 (guild paddock / shared training)
-- ============================================================================
-- AFTER 065 + 067 + 070 + 073 + 078 + 079. Transactional; ROLLS BACK.
-- Success -> notice "ALL PADDOCK TESTS PASSED".
-- ============================================================================

begin;

do $$
declare
    v_owner    text := 'test_pad_owner';
    v_mate     text := 'test_pad_mate';
    v_outsider text := 'test_pad_out';
    v_ao       uuid;
    v_am       uuid;
    v_ax       uuid;
    v_guild    uuid;
    r          json;
    v_h1       uuid;   -- owner's horse (paddocked)
    v_speed0   numeric;
    v_speed1   numeric;
    v_cnt      int;
begin
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_owner, 'pad_owner', 'x') returning id into v_ao;
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_mate, 'pad_mate', 'x') returning id into v_am;
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_outsider, 'pad_out', 'x') returning id into v_ax;

    -- Owner creates a horse guild; mate joins it.
    r := public.create_guild(v_owner, 'Paddock Pals', 'horse');
    select id into v_guild from public.guilds where lower(name) = lower('Paddock Pals');
    insert into public.guild_members (guild_id, account_id, role, perks_active_at)
    values (v_guild, v_am, 'member', null);

    -- Owner buys a horse (standardbred base 90/9/8) and bumps speed for headroom.
    r := public.buy_horse(v_owner, 'standardbred', 'Dobbin'); v_h1 := (r->'horse'->>'id')::uuid;
    update public.horses set speed = 20 where id = v_h1;

    -- ── Outsider (no horse guild) can't deposit anything ─────────────────────
    r := public.buy_horse(v_outsider, 'arabian', 'Nomad');
    r := public.deposit_to_paddock(v_outsider, (r->'horse'->>'id')::uuid);
    if (r->>'error') is distinct from 'not_horse_guild' then
        raise exception 'FAIL outsider deposit should be not_horse_guild: %', r;
    end if;

    -- ── Deposit the owner's horse ────────────────────────────────────────────
    r := public.deposit_to_paddock(v_owner, v_h1);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL deposit: %', r; end if;
    r := public.deposit_to_paddock(v_owner, v_h1);
    if (r->>'error') is distinct from 'already_paddocked' then
        raise exception 'FAIL double deposit: %', r;
    end if;

    -- ── Paddock listing shows the horse for both members ─────────────────────
    r := public.get_guild_paddock(v_mate);
    if json_array_length(r->'horses') <> 1 then
        raise exception 'FAIL mate should see 1 paddock horse: %', r;
    end if;

    -- ── Mate trains the owner's horse (sprint) -> gain lands on the OWNER ─────
    select speed into v_speed0 from public.horses where id = v_h1;
    r := public.train_paddock_horse(v_mate, v_h1, 'sprint', 50);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL mate train: %', r; end if;
    select speed into v_speed1 from public.horses where id = v_h1;
    if v_speed1 <= v_speed0 then
        raise exception 'FAIL sprint did not raise owner horse speed: % -> %', v_speed0, v_speed1;
    end if;

    -- ── Mate can't sprint it AGAIN today (per-trainer cooldown) ──────────────
    r := public.train_paddock_horse(v_mate, v_h1, 'sprint', 50);
    if (r->>'error') is distinct from 'already_trained' then
        raise exception 'FAIL mate second sprint should be already_trained: %', r;
    end if;

    -- ── But the OWNER can still sprint it today (separate trainer) ───────────
    r := public.train_paddock_horse(v_owner, v_h1, 'sprint', 50);
    if (r->>'ok') is distinct from 'true' then
        raise exception 'FAIL owner sprint same day should be allowed: %', r;
    end if;

    -- ── get_guild_paddock reflects the mate's used sprint slot ───────────────
    r := public.get_guild_paddock(v_mate);
    if (r->'horses'->0->>'can_sprint')::boolean <> false then
        raise exception 'FAIL mate can_sprint should be false after training';
    end if;
    if (r->'horses'->0->>'can_hurdle')::boolean <> true then
        raise exception 'FAIL mate can_hurdle should still be true';
    end if;

    -- ── Withdraw: only the owner may, and it clears the paddock ──────────────
    r := public.withdraw_from_paddock(v_mate, v_h1);
    if (r->>'error') is distinct from 'not_your_horse' then
        raise exception 'FAIL mate withdraw should be not_your_horse: %', r;
    end if;
    r := public.withdraw_from_paddock(v_owner, v_h1);
    if (r->>'ok') is distinct from 'true' then raise exception 'FAIL owner withdraw: %', r; end if;
    select count(*) into v_cnt from public.guild_paddock where horse_id = v_h1;
    if v_cnt <> 0 then raise exception 'FAIL horse still paddocked after withdraw'; end if;

    raise notice 'ALL PADDOCK TESTS PASSED';
end;
$$;

rollback;
