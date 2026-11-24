-- ============================================================================
-- Migration 078: Horse-racing guild — 3rd spec + cap-raising upgrades + missions
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 022 (guilds) + 064 (mission key-pool helper) + 065/070 (horse caps).
--
-- Adds a THIRD guild specialization, 'horse', alongside 'gardening' and
-- 'mining'. The horse guild's perks RAISE the two per-account horse caps that
-- were deliberately left as constant SQL functions in 065/070:
--
--   • upgrade 'horse_stable_size'  -> _horse_stable_capacity  (base 5, +1/level)
--   • upgrade 'horse_training_cap' -> _horse_training_session_cap (base 10, +1/lvl)
--
-- Both caps are SERVER-enforced (SECURITY DEFINER, revoked from clients), so the
-- bonus is read live from guild_upgrade_levels for the account's ACTIVE guild,
-- gated by the member's probation (perks_active_at) — never trusted from the
-- client. No purchase_guild_upgrade change is needed: the caps read the level
-- directly (unlike 'capacity', which must materialize onto guilds.capacity).
--
-- Also adds horse-racing GUILD MISSIONS (a 3rd branch in the shared mission
-- key-pool helper): 'race_wins' and 'train_sessions'. These are credited via
-- record_guild_contribution from the race-resolve + train_horse paths (wired in
-- later migrations / the client).
-- ============================================================================


-- ── 1. Allow 'horse' as a specialization ───────────────────────────────────────
alter table public.guilds drop constraint if exists guilds_specialization_check;
alter table public.guilds
    add constraint guilds_specialization_check
    check (specialization in ('gardening', 'mining', 'horse'));


-- ── 2. create_guild — accept 'horse' ────────────────────────────────────────────
-- Supersedes 026's version (same body; only the spec guard widens).
create or replace function public.create_guild(
    p_device_hash    text,
    p_name           text,
    p_specialization text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account  uuid;
    v_existing public.guild_members%rowtype;
    v_guild_id uuid;
    v_name     text := trim(p_name);
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_existing := public._guild_active_member(v_account);
    if v_existing.id is not null then
        return json_build_object('error', 'already_in_guild');
    end if;

    if length(v_name) < 3 or length(v_name) > 32 then
        return json_build_object('error', 'invalid_name');
    end if;
    if p_specialization not in ('gardening', 'mining', 'horse') then
        return json_build_object('error', 'invalid_specialization');
    end if;

    if exists (select 1 from public.guilds where lower(name) = lower(v_name)) then
        return json_build_object('error', 'guild_name_taken');
    end if;

    insert into public.guilds (name, specialization, capacity)
    values (v_name, p_specialization, 5)
    returning id into v_guild_id;

    insert into public.guild_members (guild_id, account_id, role, perks_active_at)
    values (v_guild_id, v_account, 'leader', null);

    update public.guilds set leader_id = v_account where id = v_guild_id;

    return json_build_object(
        'ok', true,
        'guild', json_build_object(
            'id',             v_guild_id,
            'name',           v_name,
            'specialization', p_specialization,
            'capacity',       5
        )
    );
exception
    when unique_violation then
        return json_build_object('error', 'guild_name_taken');
end;
$$;
grant execute on function public.create_guild(text, text, text) to anon, authenticated;


-- ── 3. Horse-guild bonus helper ─────────────────────────────────────────────────
-- The level of a horse-guild upgrade for an account's ACTIVE guild, or 0 when the
-- account isn't in a guild, the guild isn't a horse guild, the upgrade isn't
-- bought, or the member is still in perk probation. Shared by both cap functions.
create or replace function public._horse_guild_upgrade_level(
    p_account     uuid,
    p_upgrade_key text
)
returns int
language sql
stable
security definer
set search_path = public
as $$
    select coalesce((
        select gul.level
        from public.guild_members gm
        join public.guilds g on g.id = gm.guild_id
        join public.guild_upgrade_levels gul
          on gul.guild_id = gm.guild_id and gul.upgrade_key = p_upgrade_key
        where gm.account_id = p_account
          and gm.left_at is null
          and g.specialization = 'horse'
          and (gm.perks_active_at is null
               or gm.perks_active_at <= extract(epoch from now()))
        limit 1
    ), 0);
$$;
revoke all on function public._horse_guild_upgrade_level(uuid, text) from anon, authenticated;


-- ── 4. Raise the stable capacity cap (base 5, +1 per 'horse_stable_size' level) ─
-- Supersedes 065's constant. Max +10 -> capacity 15 at level 10.
create or replace function public._horse_stable_capacity(p_account uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
    select 5 + public._horse_guild_upgrade_level(p_account, 'horse_stable_size');
$$;
revoke all on function public._horse_stable_capacity(uuid) from anon, authenticated;


-- ── 5. Raise the training session cap (base 10, +1 per 'horse_training_cap' lvl) ─
-- Supersedes 070's constant. Max +10 -> cap 20.00 at level 10.
create or replace function public._horse_training_session_cap(p_account uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
    select 10.00::numeric
         + public._horse_guild_upgrade_level(p_account, 'horse_training_cap')::numeric;
$$;
revoke all on function public._horse_training_session_cap(uuid) from anon, authenticated;


-- ── 6. Horse-racing guild mission key pool ───────────────────────────────────────
-- Supersedes 064's helper: adds a 'horse' branch. Horse missions are non-deposit
-- "activity" counters credited via record_guild_contribution from the race +
-- training code: race_wins (horses finishing 1st) and train_sessions (completed
-- training sessions by members).
create or replace function public._guild_mission_key_pool(p_spec text)
returns text[]
language sql
immutable
as $$
    select case
        when p_spec = 'gardening' then array[
            'deposit_beans','deposit_cucumbers','deposit_peppers','deposit_squash',
            'deposit_grapes','deposit_sunflower','deposit_cauliflower',
            'deposit_pineapple','deposit_watermelon',
            'deposit_produce','deposit_fruit',
            'deposit_plum','deposit_lemon','deposit_apple','deposit_banana','deposit_coconut'
        ]
        when p_spec = 'horse' then array[
            'race_wins','train_sessions'
        ]
        else array[
            'deposit_polished',
            'deposit_polished_blue_stone','deposit_polished_pink_stone',
            'deposit_polished_violet_stone','deposit_polished_black_pearl',
            'deposit_polished_emerald','deposit_polished_ruby','deposit_polished_diamond',
            'deposit_gem_gold',
            'deposit_ore_iron_bar','deposit_ore_copper_ingot','deposit_ore_gold_ingot'
        ]
    end;
$$;
revoke all on function public._guild_mission_key_pool(text) from anon, authenticated;


-- ── 7. Base targets for the horse mission keys ───────────────────────────────────
-- Supersedes 040's table: appends race_wins / train_sessions. (Full table kept so
-- this single function stays the source of truth.) Horse keys are activity counts,
-- not item deposits, so _guild_reward_tokens_for falls back to the base-reward
-- token table for them (item price = 0).
create or replace function public._guild_mission_base_target(
    p_key        text,
    p_difficulty text
)
returns int
language sql
immutable
security definer
set search_path = public
as $$
    select case p_difficulty
        when 'easy'   then t.easy_target
        when 'medium' then t.medium_target
        else               t.hard_target
    end
    from (values
        -- generic keys (legacy / shared)
        ('gems',                 3,    10,     25),
        ('crops',                3,    10,     25),
        ('expeditions',          1,     3,      8),
        ('deep_mine',           10,    40,    100),
        ('polish',               5,    20,     60),
        ('smelt',                5,    20,     60),
        ('fruit',                5,    20,     60),
        ('chop',                 2,     5,     12),
        ('sell_polished',        3,    10,     30),
        ('sell_bars',            2,     8,     20),
        ('game_easy',            1,     3,      8),
        ('game_medium',          1,     2,      5),
        ('game_hard',            1,     2,      4),
        ('game_brutal',          1,     1,      2),
        ('beat_wolves',          2,     5,     15),
        ('beat_bears',           2,     5,     15),
        ('beat_npcs',            2,     5,     15),
        ('win_terrain',          1,     3,      8),
        ('prospectors',          2,     5,     10),
        ('deposit',              3,    10,     25),
        -- per-crop deposit keys (gardening guilds)
        ('deposit_beans',        5,    20,     50),
        ('deposit_cucumbers',    4,    15,     40),
        ('deposit_peppers',      4,    15,     35),
        ('deposit_squash',       3,    12,     30),
        ('deposit_grapes',       3,    10,     25),
        ('deposit_sunflower',    3,    10,     25),
        ('deposit_cauliflower',  2,     8,     20),
        ('deposit_pineapple',    2,     7,     18),
        ('deposit_watermelon',   2,     6,     15),
        ('deposit_produce',      5,    20,     50),
        ('deposit_fruit',        5,    20,     50),
        ('deposit_plum',         5,    18,     45),
        ('deposit_lemon',        4,    15,     35),
        ('deposit_apple',        3,    12,     30),
        ('deposit_banana',       3,    10,     25),
        ('deposit_coconut',      2,     8,     20),

        -- Mining: generic deposit buckets
        ('deposit_gems',         5,    20,     50),
        ('deposit_polished',     3,    12,     30),
        ('deposit_ores',         5,    20,     50),

        -- Mining: per unpolished gem
        ('deposit_gem_gold',          8,    30,     75),
        ('deposit_gem_blue_stone',    6,    24,     60),
        ('deposit_gem_pink_stone',    6,    24,     60),
        ('deposit_gem_violet_stone',  5,    20,     50),
        ('deposit_gem_black_pearl',   4,    16,     40),
        ('deposit_gem_emerald',       4,    14,     35),
        ('deposit_gem_ruby',          3,    12,     30),
        ('deposit_gem_diamond',       2,     8,     20),

        -- Mining: per polished gem
        ('deposit_polished_blue_stone',   4,    15,     35),
        ('deposit_polished_pink_stone',   4,    15,     35),
        ('deposit_polished_violet_stone', 3,    12,     30),
        ('deposit_polished_black_pearl',  3,    10,     25),
        ('deposit_polished_emerald',      3,    10,     25),
        ('deposit_polished_ruby',         2,     8,     20),
        ('deposit_polished_diamond',      2,     6,     15),

        -- Mining: per ore / bar / ingot
        ('deposit_ore_iron_ore',      6,    24,     60),
        ('deposit_ore_iron_bar',      3,    12,     30),
        ('deposit_ore_copper_ore',    5,    20,     50),
        ('deposit_ore_copper_ingot',  3,    10,     25),
        ('deposit_ore_gold_ingot',    2,     8,     20),

        -- ── Horse guild: activity counters ───────────────────────────────
        ('race_wins',            2,     5,     12),   -- horses finishing 1st
        ('train_sessions',       5,    20,     50)    -- completed training sessions
    ) as t(key, easy_target, medium_target, hard_target)
    where t.key = p_key;
$$;
revoke all on function public._guild_mission_base_target(text, text) from anon, authenticated;


-- ── 8. Credit a horse-guild activity to the member's active guild missions ──────
-- Thin wrapper the horse code calls: resolves the caller's active guild and, if
-- it's a horse guild, credits p_amount toward p_base_key missions. No-op (ok)
-- otherwise, so it's safe to fire-and-forget from every train/race for everyone.
create or replace function public.record_horse_guild_activity(
    p_device_hash text,
    p_base_key    text,
    p_amount      int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_member  public.guild_members%rowtype;
    v_spec    text;
begin
    if p_amount is null or p_amount <= 0 then
        return json_build_object('ok', true);
    end if;
    if p_base_key not in ('race_wins', 'train_sessions') then
        return json_build_object('ok', true);
    end if;

    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('ok', true);
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null then
        return json_build_object('ok', true);
    end if;

    select specialization into v_spec from public.guilds where id = v_member.guild_id;
    if v_spec is distinct from 'horse' then
        return json_build_object('ok', true);
    end if;

    -- Delegate to the shared contribution path (handles probation + completion).
    -- Pass the 5th arg ('') EXPLICITLY: a 4-arg and a 5-arg (p_item_key default
    -- '') overload both exist, so a 4-arg call is ambiguous ("not unique").
    return public.record_guild_contribution(p_device_hash, v_member.guild_id, p_base_key, p_amount, '');
end;
$$;
grant execute on function public.record_horse_guild_activity(text, text, int) to anon, authenticated;


-- ── 9. train_horse — credit the horse guild's 'train_sessions' mission ──────────
-- Supersedes 073's version. Identical body plus ONE hook: after recording a
-- successful session, fire record_horse_guild_activity('train_sessions', 1) so a
-- horse-guild member's training counts toward guild missions. (No-op if the
-- player isn't in a horse guild.)
create or replace function public.train_horse(
    p_device_hash text,
    p_horse_id    uuid,
    p_kind        text,
    p_score       int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account   uuid;
    v_horse     public.horses%rowtype;
    v_today     date := (now() at time zone 'utc')::date;
    v_last      date;
    v_cap       numeric;
    v_gain      numeric;
    v_stat      text;
    v_ceiling   numeric;
    v_current   numeric;
    v_new       numeric;
    v_life_cost int := 0;
    v_new_life  numeric;
    v_new_cap   numeric;
    v_retired   boolean := false;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    if p_kind not in ('sprint', 'hurdle', 'groom') then
        return json_build_object('error', 'invalid_kind');
    end if;

    select * into v_horse from public.horses where id = p_horse_id for update;
    if not found then
        return json_build_object('error', 'horse_not_found');
    end if;
    if v_horse.owner_id <> v_account then
        return json_build_object('error', 'not_your_horse');
    end if;
    if v_horse.status <> 'active' then
        return json_build_object('error', 'horse_retired');
    end if;

    if p_kind = 'groom' then
        select trained_day into v_last
        from public.horse_training
        where horse_id = p_horse_id and kind = p_kind;
        if v_last is not null and v_last >= v_today then
            return json_build_object('error', 'already_trained');
        end if;
    end if;

    v_cap  := public._horse_training_session_cap(v_account);
    v_gain := public._horse_training_gain(p_score, v_cap);

    if p_kind = 'groom' then
        v_stat    := 'life_cap';
        v_ceiling := 200;
        if v_horse.life_cap >= v_ceiling then
            return json_build_object('error', 'at_ceiling', 'stat', v_stat, 'ceiling', v_ceiling);
        end if;
        v_gain    := greatest(0.50, round(v_gain / 2.0, 2));
        v_new_life := least(v_ceiling, round(v_horse.life + v_gain, 2));
        v_new_cap  := greatest(v_horse.life_cap, v_new_life);
        v_gain     := round(v_new_life - v_horse.life, 2);
        update public.horses
        set life = v_new_life, life_cap = v_new_cap
        where id = p_horse_id;
    else
        if p_kind = 'sprint' then
            v_stat := 'speed';      v_ceiling := 100; v_current := v_horse.speed;
        else
            v_stat := 'endurance';  v_ceiling := 100; v_current := v_horse.endurance;
        end if;
        if v_current >= v_ceiling then
            return json_build_object('error', 'at_ceiling', 'stat', v_stat, 'ceiling', v_ceiling);
        end if;
        v_new  := least(v_ceiling, round(v_current + v_gain, 2));
        v_gain := round(v_new - v_current, 2);
        if p_kind = 'sprint' then
            update public.horses set speed = v_new where id = p_horse_id;
        else
            update public.horses set endurance = v_new where id = p_horse_id;
        end if;

        v_life_cost := public._horse_training_life_cost(p_score);
        v_new_life  := round(v_horse.life - v_life_cost, 2);
        if v_new_life <= 0 then
            v_new_life := 0;
            v_retired  := true;
            update public.horses set life = 0, status = 'retired' where id = p_horse_id;
        else
            update public.horses set life = v_new_life where id = p_horse_id;
        end if;
    end if;

    insert into public.horse_training (horse_id, kind, trained_day, sessions, updated_at)
    values (p_horse_id, p_kind, v_today, 1, now())
    on conflict (horse_id, kind) do update
        set trained_day = excluded.trained_day,
            sessions = public.horse_training.sessions + 1,
            updated_at = now();

    -- Horse-guild mission credit (no-op unless the owner is in a horse guild).
    perform public.record_horse_guild_activity(p_device_hash, 'train_sessions', 1);

    select * into v_horse from public.horses where id = p_horse_id;

    return json_build_object(
        'ok', true,
        'kind', p_kind,
        'stat', v_stat,
        'gain', v_gain,
        'life_cost', v_life_cost,
        'retired', v_retired,
        'horse', json_build_object(
            'id', v_horse.id, 'name', v_horse.name, 'breed', v_horse.breed,
            'life', v_horse.life, 'life_cap', v_horse.life_cap,
            'speed', v_horse.speed, 'endurance', v_horse.endurance,
            'status', v_horse.status, 'wins', v_horse.wins, 'races_run', v_horse.races_run
        )
    );
end;
$$;
grant execute on function public.train_horse(text, uuid, text, int) to anon, authenticated;


-- ── 10. Account-based horse-guild credit (for server-side race resolution) ──────
-- _horse_resolve_race runs from the lazy scheduler WITHOUT a device_hash, so it
-- can't use record_horse_guild_activity (which resolves by device_hash). This
-- internal variant credits by account_id directly: if the account is in a horse
-- guild (perks active), credit p_amount toward p_base_key missions. Mirrors the
-- probation + mission-completion logic of record_guild_contribution.
create or replace function public._record_horse_guild_activity_acct(
    p_account  uuid,
    p_base_key text,
    p_amount   int
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_member   public.guild_members%rowtype;
    v_spec     text;
    v_mission  record;
    v_new_prog int;
begin
    if p_account is null or p_amount is null or p_amount <= 0 then
        return;
    end if;
    if p_base_key not in ('race_wins', 'train_sessions') then
        return;
    end if;

    v_member := public._guild_active_member(p_account);
    if v_member.id is null then
        return;
    end if;
    -- Probation guard.
    if v_member.perks_active_at is not null
       and v_member.perks_active_at > extract(epoch from now()) then
        return;
    end if;

    select specialization into v_spec from public.guilds where id = v_member.guild_id;
    if v_spec is distinct from 'horse' then
        return;
    end if;

    for v_mission in
        select id, target, progress
        from public.guild_missions
        where guild_id = v_member.guild_id
          and base_mission_key = p_base_key
          and status = 'active'
        order by spawned_at asc, id asc
        for update
    loop
        insert into public.guild_contributions (mission_id, account_id, amount, updated_at)
        values (v_mission.id, p_account, p_amount, now())
        on conflict (mission_id, account_id)
        do update set amount = public.guild_contributions.amount + excluded.amount,
                      updated_at = now();

        v_new_prog := least(v_mission.progress + p_amount, v_mission.target);
        update public.guild_missions set progress = v_new_prog where id = v_mission.id;
        if v_new_prog >= v_mission.target then
            perform public._complete_guild_mission(v_mission.id);
        end if;
    end loop;
end;
$$;
revoke all on function public._record_horse_guild_activity_acct(uuid, text, int) from anon, authenticated;


-- ── 11. _horse_resolve_race — credit the horse guild's 'race_wins' mission ──────
-- Supersedes 077's version. Identical body plus ONE hook: when a real player
-- horse wins (1st place), credit its owner's horse-guild 'race_wins' mission by 1.
create or replace function public._horse_resolve_race(p_race_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_race    public.races%rowtype;
    v_sim     jsonb;
    v_order   jsonb;
    v_place   int;
    v_lane    int;
    v_winner_horse uuid;
    v_win_lane int;
    v_win_owner uuid;
    b         record;
    v_payout  bigint;
    v_has_tokens boolean;
    v_tier    record;
    v_first   bigint;
    e         record;
    v_prize   bigint;
begin
    select * into v_race from public.races where id = p_race_id for update;
    if not found or v_race.status <> 'betting' then
        return;
    end if;

    v_sim := public._race_run_sim(p_race_id);
    if v_sim is null then
        return;
    end if;
    v_order := v_sim->'order';

    v_place := 1;
    for v_lane in select (value::text)::int from jsonb_array_elements(v_order)
    loop
        update public.race_entries set finish_place = v_place
        where race_id = p_race_id and lane = v_lane;
        v_place := v_place + 1;
    end loop;

    update public.horses h set races_run = races_run + 1
    from public.race_entries re
    where re.race_id = p_race_id and re.horse_id = h.id;

    select horse_id, owner_id into v_winner_horse, v_win_owner
    from public.race_entries
    where race_id = p_race_id and finish_place = 1 and horse_id is not null;
    if v_winner_horse is not null then
        update public.horses set wins = wins + 1 where id = v_winner_horse;
        -- Horse-guild mission credit for a real win (no-op unless owner is in a
        -- horse guild with perks active).
        perform public._record_horse_guild_activity_acct(v_win_owner, 'race_wins', 1);
    end if;

    select lane into v_win_lane from public.race_entries
    where race_id = p_race_id and finish_place = 1;

    select exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'accounts' and column_name = 'tokens'
    ) into v_has_tokens;

    for b in select * from public.bets where race_id = p_race_id and not settled for update loop
        if b.lane = v_win_lane then
            v_payout := (b.stake::numeric * b.odds)::bigint;
            update public.bets set settled = true, won = true, payout = v_payout where id = b.id;
            if b.currency = 'tokens' and v_has_tokens then
                execute 'update public.accounts set tokens = coalesce(tokens,0) + $1 where id = $2'
                    using v_payout, b.account_id;
            end if;
        else
            update public.bets set settled = true, won = false, payout = 0 where id = b.id;
        end if;
    end loop;

    if v_race.kind = 'cup' and v_race.tier is not null then
        select * into v_tier from public._race_cup_tiers() where tier = v_race.tier;
        if found then
            v_first := v_tier.first_prize;
            for e in
                select * from public.race_entries
                where race_id = p_race_id and horse_id is not null
                  and finish_place in (1, 2, 3)
            loop
                v_prize := case e.finish_place
                    when 1 then v_first
                    when 2 then (v_first / 2)
                    when 3 then (v_first / 4)
                    else 0 end;
                update public.race_entries set prize_coins = v_prize where id = e.id;
            end loop;

            if v_win_owner is not null and v_race.prize_breed is not null then
                perform public._horse_grant_prize(v_win_owner, v_race.prize_breed, v_race.name);
            end if;
        end if;
    end if;

    update public.races
    set status = 'resolved',
        run_at = now(),
        replay_expires_at = now() + interval '12 hours',
        results_json = v_sim
    where id = p_race_id;
end;
$$;
revoke all on function public._horse_resolve_race(uuid) from anon, authenticated;
