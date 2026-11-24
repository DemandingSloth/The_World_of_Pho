-- ============================================================================
-- Verification for migration 056 (guild leaderboards) — RUN AFTER 056.
-- ============================================================================
-- Transactional; ROLLS BACK. Builds throwaway accounts/guilds/memberships with
-- known scores and asserts ranking, score SUM across memberships, current/most-
-- recent guild-name resolution, and the guild ranking. Success -> notice
-- "ALL LEADERBOARD TESTS PASSED".
--
-- NOTE: this asserts the RELATIVE ordering + values of the TEST rows among the
-- live results (your real data may add other rows), by locating the test rows
-- within the returned arrays rather than assuming they're the global top.
-- ============================================================================

begin;

do $$
declare
    v_ga uuid; v_gb uuid;             -- two guilds
    v_a uuid; v_b uuid; v_c uuid;     -- three accounts
    v_hash_a text := 'test_lb_a';
    v_hash_b text := 'test_lb_b';
    v_hash_c text := 'test_lb_c';
    r json;
    players json;
    guilds  json;
    v_a_score bigint;
    v_a_guild text;
    v_found boolean;
    e json;
begin
    -- ── Setup: 2 guilds with distinct upgrade_points ────────────────────────
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash_a, 'test_lb_alice', 'x') returning id into v_a;
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash_b, 'test_lb_bob', 'x') returning id into v_b;
    insert into public.accounts (device_hash, username, recovery_hash)
    values (v_hash_c, 'test_lb_carol', 'x') returning id into v_c;

    insert into public.guilds (name, specialization, leader_id, upgrade_points)
    values ('test_lb_guild_A', 'mining', v_a, 9999999) returning id into v_ga;
    insert into public.guilds (name, specialization, leader_id, upgrade_points)
    values ('test_lb_guild_B', 'gardening', v_b, 8888888) returning id into v_gb;

    -- Alice: was in guild B (left), now active in guild A. Score SUMS both.
    insert into public.guild_members (guild_id, account_id, role, left_at, lifetime_upgrade_points)
    values (v_gb, v_a, 'member', now() - interval '1 day', 500);
    insert into public.guild_members (guild_id, account_id, role, lifetime_upgrade_points)
    values (v_ga, v_a, 'leader', 1000);     -- active -> current guild = A
    -- Alice total score = 1500, current guild = test_lb_guild_A.

    -- Bob: active in guild B, score 1200.
    insert into public.guild_members (guild_id, account_id, role, lifetime_upgrade_points)
    values (v_gb, v_b, 'leader', 1200);

    -- Carol: active in guild A, score 300.
    insert into public.guild_members (guild_id, account_id, role, lifetime_upgrade_points)
    values (v_ga, v_c, 'member', 300);

    -- ── not_in_guild guard: a member-less account can't read ────────────────
    -- (Use a fresh account with NO membership.)
    declare
        v_d uuid; v_hash_d text := 'test_lb_d';
    begin
        insert into public.accounts (device_hash, username, recovery_hash)
        values (v_hash_d, 'test_lb_dave', 'x') returning id into v_d;
        r := public.get_player_leaderboard(v_hash_d, 25);
        if (r->>'error') is distinct from 'not_in_guild' then
            raise exception 'FAIL not_in_guild guard: %', r;
        end if;
    end;

    -- ── Player leaderboard: find our 3 test players, check scores+guild ─────
    r := public.get_player_leaderboard(v_hash_a, 100);
    players := r->'players';
    if players is null then
        raise exception 'FAIL player leaderboard null: %', r;
    end if;

    -- Locate Alice; assert score 1500 and current guild A.
    v_found := false;
    for e in select * from json_array_elements(players) loop
        if (e->>'username') = 'test_lb_alice' then
            v_found := true;
            if (e->>'score')::bigint <> 1500 then
                raise exception 'FAIL alice score: expected 1500 (1000+500), got %', e;
            end if;
            if (e->>'guild_name') <> 'test_lb_guild_A' then
                raise exception 'FAIL alice guild (current=A): %', e;
            end if;
            if (e->>'is_you') <> 'true' then
                raise exception 'FAIL alice is_you (she is the caller): %', e;
            end if;
        end if;
    end loop;
    if not v_found then raise exception 'FAIL alice missing from leaderboard'; end if;

    -- Bob present with score 1200, guild B, not "you".
    v_found := false;
    for e in select * from json_array_elements(players) loop
        if (e->>'username') = 'test_lb_bob' then
            v_found := true;
            if (e->>'score')::bigint <> 1200 then raise exception 'FAIL bob score: %', e; end if;
            if (e->>'guild_name') <> 'test_lb_guild_B' then raise exception 'FAIL bob guild: %', e; end if;
            if (e->>'is_you') <> 'false' then raise exception 'FAIL bob is_you should be false: %', e; end if;
        end if;
    end loop;
    if not v_found then raise exception 'FAIL bob missing'; end if;

    -- Ordering: within the test trio, Alice(1500) ranks above Bob(1200) above Carol(300).
    declare
        pos_alice int := -1; pos_bob int := -1; pos_carol int := -1; i int := 0;
    begin
        for e in select * from json_array_elements(players) loop
            if (e->>'username') = 'test_lb_alice' then pos_alice := i; end if;
            if (e->>'username') = 'test_lb_bob'   then pos_bob := i; end if;
            if (e->>'username') = 'test_lb_carol' then pos_carol := i; end if;
            i := i + 1;
        end loop;
        if not (pos_alice < pos_bob and pos_bob < pos_carol) then
            raise exception 'FAIL player ordering: alice=%, bob=%, carol=%', pos_alice, pos_bob, pos_carol;
        end if;
    end;

    -- ── Guild leaderboard: A (9999999) ranks above B (8888888) ──────────────
    r := public.get_guild_leaderboard(v_hash_a, 100);
    guilds := r->'guilds';
    declare
        pos_a int := -1; pos_b int := -1; j int := 0; found_a boolean := false;
    begin
        for e in select * from json_array_elements(guilds) loop
            if (e->>'name') = 'test_lb_guild_A' then
                pos_a := j; found_a := true;
                if (e->>'upgrade_points')::bigint <> 9999999 then
                    raise exception 'FAIL guild A points: %', e;
                end if;
                if (e->>'is_yours') <> 'true' then
                    raise exception 'FAIL guild A is_yours (caller alice is in A): %', e;
                end if;
            end if;
            if (e->>'name') = 'test_lb_guild_B' then pos_b := j; end if;
            j := j + 1;
        end loop;
        if not found_a then raise exception 'FAIL guild A missing'; end if;
        if not (pos_a < pos_b) then
            raise exception 'FAIL guild ordering: A=%, B=%', pos_a, pos_b;
        end if;
    end;

    raise notice 'ALL LEADERBOARD TESTS PASSED';
end;
$$;

rollback;
