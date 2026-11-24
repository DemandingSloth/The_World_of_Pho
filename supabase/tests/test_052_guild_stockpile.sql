-- ============================================================================
-- Verification script for migration 052 (Guild Stockpile) — RUN AFTER 052.
-- ============================================================================
-- Paste into the Supabase SQL editor and Run. It wraps everything in a
-- transaction that ROLLS BACK at the end, so it creates NO permanent data: a
-- throwaway leader account, member account, and guild are made, every RPC is
-- exercised, each result is asserted, and then the whole thing is undone.
--
-- On success you'll see a single notice: "ALL STOCKPILE TESTS PASSED".
-- On any failed assertion it raises an exception naming the check that failed.
-- Either way, nothing is committed.
-- ============================================================================

begin;

do $$
declare
    v_leader_hash text := 'test_sp_leader_hash';
    v_member_hash text := 'test_sp_member_hash';
    v_leader_id   uuid;
    v_member_id   uuid;
    v_guild_id    uuid;
    r             json;
begin
    -- ── Setup: two accounts, a guild, two memberships ───────────────────────
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_leader_hash, 'test_sp_leader', 'x') returning id into v_leader_id;
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_member_hash, 'test_sp_member', 'x') returning id into v_member_id;

    insert into public.guilds (name, specialization, leader_id)
    values ('test_sp_guild', 'mining', v_leader_id) returning id into v_guild_id;

    insert into public.guild_members (guild_id, account_id, role)
    values (v_guild_id, v_leader_id, 'leader');
    insert into public.guild_members (guild_id, account_id, role)
    values (v_guild_id, v_member_id, 'member');

    -- ── Capacity helper: level 0 == 50,000 ──────────────────────────────────
    if public._guild_stockpile_capacity(v_guild_id) <> 50000 then
        raise exception 'FAIL capacity@lvl0: expected 50000, got %',
            public._guild_stockpile_capacity(v_guild_id);
    end if;

    -- Bump to level 10 and expect 500,000.
    insert into public.guild_upgrade_levels (guild_id, upgrade_key, level)
    values (v_guild_id, 'stockpile_capacity', 10);
    if public._guild_stockpile_capacity(v_guild_id) <> 500000 then
        raise exception 'FAIL capacity@lvl10: expected 500000, got %',
            public._guild_stockpile_capacity(v_guild_id);
    end if;
    -- Reset to level 0 for the clamp test below.
    update public.guild_upgrade_levels set level = 0
      where guild_id = v_guild_id and upgrade_key = 'stockpile_capacity';

    -- ── Deposit (member) increments ─────────────────────────────────────────
    r := public.deposit_to_stockpile(v_member_hash, v_guild_id, 'resource:iron_ore', 100);
    if (r->>'ok') is distinct from 'true' or (r->>'deposited')::int <> 100
       or (r->>'amount')::bigint <> 100 then
        raise exception 'FAIL deposit#1: %', r;
    end if;

    -- Second deposit of the same key accumulates.
    r := public.deposit_to_stockpile(v_member_hash, v_guild_id, 'resource:iron_ore', 50);
    if (r->>'amount')::bigint <> 150 then
        raise exception 'FAIL deposit#2 accumulate: %', r;
    end if;

    -- ── Capacity clamp: depositing past 50,000 stores only up to the cap ────
    r := public.deposit_to_stockpile(v_member_hash, v_guild_id, 'resource:iron_ore', 999999);
    if (r->>'amount')::bigint <> 50000 then
        raise exception 'FAIL capacity clamp: expected amount 50000, got %', r;
    end if;
    -- deposited should be 50000 - 150 = 49850.
    if (r->>'deposited')::bigint <> 49850 then
        raise exception 'FAIL clamp deposited: expected 49850, got %', r;
    end if;

    -- A further deposit at full cap returns stockpile_full / deposited 0.
    r := public.deposit_to_stockpile(v_member_hash, v_guild_id, 'resource:iron_ore', 10);
    if (r->>'error') is distinct from 'stockpile_full' then
        raise exception 'FAIL full guard: expected stockpile_full, got %', r;
    end if;

    -- ── Invalid item key rejected ───────────────────────────────────────────
    r := public.deposit_to_stockpile(v_member_hash, v_guild_id, 'item:diamond_ring', 1);
    if (r->>'error') is distinct from 'invalid_item' then
        raise exception 'FAIL invalid_item guard (jewelry): %', r;
    end if;
    r := public.deposit_to_stockpile(v_member_hash, v_guild_id, 'nocolon', 1);
    if (r->>'error') is distinct from 'invalid_item' then
        raise exception 'FAIL invalid_item guard (malformed): %', r;
    end if;

    -- ── View (member) returns the item + unlocked + capacity ────────────────
    r := public.get_guild_stockpile(v_member_hash, v_guild_id);
    if (r->>'locked') is distinct from 'false' then
        raise exception 'FAIL view locked default: %', r;
    end if;
    if (r->>'capacity')::bigint <> 50000 then
        raise exception 'FAIL view capacity: %', r;
    end if;

    -- ── Leader lock: non-leader cannot lock ─────────────────────────────────
    r := public.set_stockpile_lock(v_member_hash, v_guild_id, true);
    if (r->>'error') is distinct from 'not_leader' then
        raise exception 'FAIL non-leader lock guard: %', r;
    end if;

    -- Leader CAN lock.
    r := public.set_stockpile_lock(v_leader_hash, v_guild_id, true);
    if (r->>'ok') is distinct from 'true' or (r->>'locked') is distinct from 'true' then
        raise exception 'FAIL leader lock: %', r;
    end if;

    -- Withdrawal refused while locked.
    r := public.withdraw_from_stockpile(v_leader_hash, v_guild_id, 'resource:iron_ore', 10);
    if (r->>'error') is distinct from 'stockpile_locked' then
        raise exception 'FAIL locked-withdraw guard: %', r;
    end if;

    -- Unlock for the rest of the tests.
    r := public.set_stockpile_lock(v_leader_hash, v_guild_id, false);

    -- ── Reserve: non-leader cannot reserve ──────────────────────────────────
    r := public.reserve_stockpile(v_member_hash, v_guild_id, 'resource:iron_ore', 100);
    if (r->>'error') is distinct from 'not_leader' then
        raise exception 'FAIL non-leader reserve guard: %', r;
    end if;

    -- Leader reserves 49,000; reserve is clamped to <= amount (50,000) so OK.
    r := public.reserve_stockpile(v_leader_hash, v_guild_id, 'resource:iron_ore', 49000);
    if (r->>'reserved')::bigint <> 49000 then
        raise exception 'FAIL reserve set: %', r;
    end if;

    -- Reserving MORE than on hand clamps to amount (50,000).
    r := public.reserve_stockpile(v_leader_hash, v_guild_id, 'resource:iron_ore', 999999);
    if (r->>'reserved')::bigint <> 50000 then
        raise exception 'FAIL reserve clamp-to-amount: %', r;
    end if;

    -- Pull reservation back to 49,000 so 1,000 is withdrawable.
    r := public.reserve_stockpile(v_leader_hash, v_guild_id, 'resource:iron_ore', 49000);

    -- ── Withdraw: cannot dip into reserved (available = 50000-49000 = 1000) ──
    r := public.withdraw_from_stockpile(v_leader_hash, v_guild_id, 'resource:iron_ore', 5000);
    if (r->>'withdrawn')::bigint <> 1000 then
        raise exception 'FAIL withdraw respects reserve: expected 1000, got %', r;
    end if;
    if (r->>'amount')::bigint <> 49000 then
        raise exception 'FAIL withdraw remaining amount: expected 49000, got %', r;
    end if;

    -- Nothing left available (all 49,000 reserved) -> nothing_available.
    r := public.withdraw_from_stockpile(v_leader_hash, v_guild_id, 'resource:iron_ore', 1);
    if (r->>'error') is distinct from 'nothing_available' then
        raise exception 'FAIL withdraw nothing_available: %', r;
    end if;

    -- Withdrawn stock was escrowed to the leader (1000 iron ore).
    if not exists (
        select 1 from public.escrow
        where account_id = v_leader_id and item_key = 'resource:iron_ore' and quantity = 1000
    ) then
        raise exception 'FAIL withdraw escrow: leader did not receive 1000 iron ore in escrow';
    end if;

    raise notice 'ALL STOCKPILE TESTS PASSED';
end;
$$;

rollback;
