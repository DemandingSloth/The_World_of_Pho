-- ============================================================================
-- Migration 076: Race betting + odds + open->betting->resolved lifecycle (Task 7)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 + 074 + 075 already applied.
--
-- Reworks the race lifecycle and adds FIXED-ODDS win betting:
--
-- LIFECYCLE  open -> betting -> resolved  (replaces the old instant
--   open -> closed -> resolved):
--     • open      : registration window. A race opens with a 5-hour hard cap.
--     • betting   : entered the moment the field FILLS to 8, OR when the 5-hour
--                   cap elapses (whichever first). On entry: NPC-backfill empty
--                   lanes, assign the sim seed, compute + store FIXED ODDS per
--                   lane, and set bet_closes_at = now + 3h. Bets allowed now.
--     • resolved  : when bet_closes_at passes -> run the sim, pay out bets,
--                   store the 12h replay. Max total ~8h (5h open + 3h betting).
--   Empty-but-not-full races still fill with NPCs and run (all-NPC races run and
--   accept bets). The old 'closed' status is retired (migrated to 'betting').
--
-- BETTING (fixed odds, WIN only):
--   • Bet with COINS (local) or TOKENS (server) — player's choice per bet.
--   • Only on a race you have NO horse entered in. Multiple bets allowed.
--   • Odds are fixed at field-lock from each lane's strength vs the field.
--     Payout on a win = stake * odds (no extra rake).
-- ============================================================================


-- ── Lifecycle columns + status set ──────────────────────────────────────────────
alter table public.races
    add column if not exists fill_at       timestamptz,   -- when the field locked
    add column if not exists bet_closes_at timestamptz;   -- betting deadline (lock + 3h)

-- Swap the status CHECK to include 'betting' (migrate any legacy 'closed' first).
alter table public.races drop constraint if exists races_status_check;
update public.races set status = 'betting' where status = 'closed';
alter table public.races
    add constraint races_status_check
    check (status in ('open', 'betting', 'resolved'));


-- ── bets ─────────────────────────────────────────────────────────────────────────
-- One row per placed bet. currency: 'coins' (local) | 'tokens' (server). odds is
-- the fixed decimal odds snapshotted at bet time; payout = stake*odds on a win.
-- settled flips true at resolve; won records the outcome; payout the amount paid.
create table if not exists public.bets (
    id         uuid        primary key default gen_random_uuid(),
    race_id    uuid        not null references public.races(id) on delete cascade,
    account_id uuid        not null references public.accounts(id) on delete cascade,
    lane       int         not null,                   -- the lane bet on
    currency   text        not null check (currency in ('coins', 'tokens')),
    stake      bigint      not null check (stake > 0),
    odds       numeric(6,2) not null check (odds >= 1),
    settled    boolean     not null default false,
    won        boolean     not null default false,
    payout     bigint      not null default 0,
    created_at timestamptz not null default now()
);
create index if not exists bets_race_idx on public.bets (race_id);
create index if not exists bets_account_idx on public.bets (account_id, created_at desc);
alter table public.bets enable row level security;  -- RPCs only


-- ── Betting-window length ────────────────────────────────────────────────────────
create or replace function public._race_betting_hours() returns int
language sql immutable as $$ select 3; $$;      -- betting window after field lock
create or replace function public._race_open_cap_hours() returns int
language sql immutable as $$ select 5; $$;      -- hard cap: lock even if not full


-- ── Odds helper: fixed decimal odds for every lane of a race ────────────────────
-- strength Sᵢ = (speed+endurance) * condition_mult(life,life_cap). Implied win
-- chance pᵢ = Sᵢ / ΣS. Decimal odds = clamp(1/pᵢ, 1.20, 20.00), rounded to 2dp.
-- Writes nothing; returns one row per lane. (Payout = stake*odds, so the clamp +
-- the 1/p mapping is the only house edge.)
create or replace function public._race_odds(p_race_id uuid)
returns table (lane int, odds numeric)
language sql
stable
security definer
set search_path = public, extensions
as $$
    with s as (
        select e.lane,
               greatest(0.01,
                   (e.speed + e.endurance) * public._race_condition_mult(e.life, e.life_cap)
               ) as strength
        from public.race_entries e
        where e.race_id = p_race_id
    ),
    tot as (select sum(strength) as total from s)
    select s.lane,
           round(least(20.00, greatest(1.20,
               (select total from tot) / s.strength
           )), 2) as odds
    from s;
$$;
revoke all on function public._race_odds(uuid) from anon, authenticated;


-- ── Store odds on entries (snapshot at field-lock) ──────────────────────────────
alter table public.race_entries
    add column if not exists odds numeric(6,2);


-- ── _horse_advance_races REWORKED: open->betting->resolved + odds + payout ──────
-- Supersedes migration 075's version.
create or replace function public._horse_advance_races()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_race     record;
    v_field    int := public._race_field_size();
    v_filled   int;
    v_lane     int;
    v_npc      record;
    v_open_cnt int;
    v_mins     int := public._race_registration_minutes();
    v_odds     record;
begin
    -- 1) LOCK: any open race that has FILLED, or hit its 5-hour hard cap, moves
    --    to 'betting'. Backfill NPCs, assign seed, store odds, open the 3h window.
    for v_race in
        select r.* from public.races r
        where r.status = 'open'
          and ( (select count(*) from public.race_entries e where e.race_id = r.id) >= v_field
                or r.closes_at <= now() )
        for update
    loop
        -- Backfill empty lanes with NPC horses up to the field size.
        select count(*) into v_filled from public.race_entries where race_id = v_race.id;
        v_lane := 0;
        while v_filled < v_field loop
            while exists (select 1 from public.race_entries
                          where race_id = v_race.id and lane = v_lane) loop
                v_lane := v_lane + 1;
            end loop;
            select * into v_npc from public._race_npc_entry_stats();
            insert into public.race_entries (
                race_id, lane, is_npc, horse_id, owner_id,
                display_name, breed, speed, endurance, life, life_cap
            ) values (
                v_race.id, v_lane, true, null, null,
                public._race_npc_name(), v_npc.breed, v_npc.speed, v_npc.endurance,
                v_npc.life, v_npc.life
            );
            v_filled := v_filled + 1;
            v_lane := v_lane + 1;
        end loop;

        -- Lock field: seed + 3h betting window.
        update public.races
        set status = 'betting',
            seed = (floor(random() * 9223372036854775806) + 1)::bigint,
            fill_at = now(),
            bet_closes_at = now() + make_interval(hours => public._race_betting_hours())
        where id = v_race.id;

        -- Snapshot fixed odds per lane.
        for v_odds in select * from public._race_odds(v_race.id) loop
            update public.race_entries
            set odds = v_odds.odds
            where race_id = v_race.id and lane = v_odds.lane;
        end loop;
    end loop;

    -- 2) RESOLVE: betting races whose 3h window has elapsed run the sim + pay out.
    for v_race in
        select id from public.races
        where status = 'betting' and bet_closes_at is not null and bet_closes_at <= now()
    loop
        perform public._horse_resolve_race(v_race.id);   -- (redefined below to also pay bets)
    end loop;

    -- 3) Purge replays past their 12h window (keep the race row + placements).
    update public.races
    set results_json = null
    where status = 'resolved'
      and replay_expires_at is not null
      and replay_expires_at <= now()
      and results_json is not null;

    -- 4) Keep the target number of open races available (5h hard cap each).
    select count(*) into v_open_cnt from public.races where status = 'open';
    while v_open_cnt < public._race_open_target() loop
        insert into public.races (name, kind, field_size, opens_at, closes_at)
        values ('Daily Dash', 'regular', v_field, now(),
                now() + make_interval(hours => public._race_open_cap_hours()));
        v_open_cnt := v_open_cnt + 1;
    end loop;
end;
$$;
revoke all on function public._horse_advance_races() from anon, authenticated;


-- ── _horse_resolve_race REWORKED: resolve 'betting' races + settle bets ─────────
-- Supersedes migration 075's version. Resolves a race in 'betting' status, then
-- settles every bet: winners (bet lane == 1st place) get payout = stake*odds in
-- their currency; losers get 0. TOKENS are credited server-side (accounts.tokens
-- if that column exists); COINS are credited client-side on the player's next
-- get_my_bets poll (the bet row carries the won/payout so the client can apply).
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
    b         record;
    v_payout  bigint;
    v_has_tokens boolean;
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

    -- Real-horse records.
    update public.horses h set races_run = races_run + 1
    from public.race_entries e
    where e.race_id = p_race_id and e.horse_id = h.id;

    select horse_id into v_winner_horse
    from public.race_entries
    where race_id = p_race_id and finish_place = 1 and horse_id is not null;
    if v_winner_horse is not null then
        update public.horses set wins = wins + 1 where id = v_winner_horse;
    end if;

    -- Winning lane (1st place).
    select lane into v_win_lane from public.race_entries
    where race_id = p_race_id and finish_place = 1;

    -- Does accounts have a tokens column? (credit server-side if so.)
    select exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'accounts' and column_name = 'tokens'
    ) into v_has_tokens;

    -- Settle bets.
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

    update public.races
    set status = 'resolved',
        run_at = now(),
        replay_expires_at = now() + interval '12 hours',
        results_json = v_sim
    where id = p_race_id;
end;
$$;
revoke all on function public._horse_resolve_race(uuid) from anon, authenticated;


-- ── register_horse: only while OPEN (status rename closed->betting) ─────────────
-- Supersedes 075's version: the "race not open" error now triggers on betting
-- too (field locked), and the one-race rule checks open+betting.
create or replace function public.register_horse(
    p_device_hash text,
    p_race_id     uuid,
    p_horse_id    uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_horse   public.horses%rowtype;
    v_race    public.races%rowtype;
    v_count   int;
    v_lane    int := 0;
    v_entry   uuid;
begin
    perform public._horse_advance_races();

    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
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

    select * into v_race from public.races where id = p_race_id for update;
    if not found then
        return json_build_object('error', 'race_not_found');
    end if;
    if v_race.status <> 'open' then
        return json_build_object('error', 'race_closed');  -- betting/resolved: locked
    end if;

    select count(*) into v_count from public.race_entries where race_id = p_race_id;
    if v_count >= v_race.field_size then
        return json_build_object('error', 'race_full');
    end if;

    if exists (select 1 from public.race_entries
               where race_id = p_race_id and horse_id = p_horse_id) then
        return json_build_object('error', 'already_entered');
    end if;

    if exists (
        select 1 from public.race_entries e
        join public.races r on r.id = e.race_id
        where e.horse_id = p_horse_id and r.status in ('open', 'betting')
    ) then
        return json_build_object('error', 'horse_in_race');
    end if;

    while exists (select 1 from public.race_entries
                  where race_id = p_race_id and lane = v_lane) loop
        v_lane := v_lane + 1;
    end loop;

    insert into public.race_entries (
        race_id, lane, is_npc, horse_id, owner_id,
        display_name, breed, speed, endurance, life, life_cap
    ) values (
        p_race_id, v_lane, false, p_horse_id, v_account,
        v_horse.name, v_horse.breed, v_horse.speed, v_horse.endurance,
        v_horse.life, v_horse.life_cap
    ) returning id into v_entry;

    -- If that entry filled the field, lock it right away (seed + odds + window).
    perform public._horse_advance_races();

    return json_build_object(
        'ok', true, 'race_id', p_race_id, 'lane', v_lane,
        'entry', json_build_object(
            'id', v_entry, 'lane', v_lane, 'is_npc', false,
            'horse_id', p_horse_id, 'display_name', v_horse.name, 'breed', v_horse.breed,
            'speed', v_horse.speed, 'endurance', v_horse.endurance,
            'life', v_horse.life, 'life_cap', v_horse.life_cap
        )
    );
end;
$$;
grant execute on function public.register_horse(text, uuid, uuid) to anon, authenticated;


-- ── place_bet: win bet on a lane of a BETTING race you have no horse in ─────────
-- Snapshots the lane's fixed odds. For TOKENS, debits accounts.tokens server-side
-- (if the column exists); for COINS, the client debits locally after this ok.
-- Returns { ok, bet_id, lane, odds, stake, currency } | { error }.
--   errors: account_not_found, race_not_found, not_betting, bad_lane, bad_stake,
--           bad_currency, own_race, insufficient_tokens
create or replace function public.place_bet(
    p_device_hash text,
    p_race_id     uuid,
    p_lane        int,
    p_currency    text,
    p_stake       bigint
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_race    public.races%rowtype;
    v_odds    numeric;
    v_bet     uuid;
    v_has_tokens boolean;
    v_bal     bigint;
begin
    perform public._horse_advance_races();

    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;
    if p_currency not in ('coins', 'tokens') then
        return json_build_object('error', 'bad_currency');
    end if;
    if p_stake is null or p_stake <= 0 then
        return json_build_object('error', 'bad_stake');
    end if;

    select * into v_race from public.races where id = p_race_id for update;
    if not found then
        return json_build_object('error', 'race_not_found');
    end if;
    if v_race.status <> 'betting' or v_race.bet_closes_at <= now() then
        return json_build_object('error', 'not_betting');
    end if;

    -- Can't bet on a race your own horse is entered in.
    if exists (select 1 from public.race_entries
               where race_id = p_race_id and owner_id = v_account) then
        return json_build_object('error', 'own_race');
    end if;

    -- Validate the lane + fetch its snapshot odds.
    select odds into v_odds from public.race_entries
    where race_id = p_race_id and lane = p_lane;
    if v_odds is null then
        return json_build_object('error', 'bad_lane');
    end if;

    -- Tokens: debit server-side now (if the column exists).
    if p_currency = 'tokens' then
        select exists (
            select 1 from information_schema.columns
            where table_schema='public' and table_name='accounts' and column_name='tokens'
        ) into v_has_tokens;
        if v_has_tokens then
            execute 'select coalesce(tokens,0) from public.accounts where id=$1'
                into v_bal using v_account;
            if v_bal < p_stake then
                return json_build_object('error', 'insufficient_tokens');
            end if;
            execute 'update public.accounts set tokens = tokens - $1 where id=$2'
                using p_stake, v_account;
        end if;
    end if;

    insert into public.bets (race_id, account_id, lane, currency, stake, odds)
    values (p_race_id, v_account, p_lane, p_currency, p_stake, v_odds)
    returning id into v_bet;

    return json_build_object(
        'ok', true, 'bet_id', v_bet, 'lane', p_lane,
        'odds', v_odds, 'stake', p_stake, 'currency', p_currency
    );
end;
$$;
grant execute on function public.place_bet(text, uuid, int, text, bigint) to anon, authenticated;


-- ── get_my_bets: the caller's bets (optionally for one race) ────────────────────
-- Advances the schedule first (so just-run races settle). Returns bets newest
-- first with their settle state + payout, so the client can credit COIN winnings
-- locally (and show results). Settled coin wins are flagged `coin_credit` so the
-- client applies each payout exactly once (track applied bet_ids locally).
--   { ok, bets:[{ id, race_id, lane, currency, stake, odds, settled, won,
--                 payout, race_status }] }
create or replace function public.get_my_bets(
    p_device_hash text,
    p_race_id     uuid default null
)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_bets    json;
begin
    perform public._horse_advance_races();
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select coalesce(json_agg(json_build_object(
        'id', b.id, 'race_id', b.race_id, 'lane', b.lane, 'currency', b.currency,
        'stake', b.stake, 'odds', b.odds, 'settled', b.settled, 'won', b.won,
        'payout', b.payout, 'race_status', r.status
    ) order by b.created_at desc), '[]'::json)
    into v_bets
    from public.bets b
    join public.races r on r.id = b.race_id
    where b.account_id = v_account
      and (p_race_id is null or b.race_id = p_race_id);

    return json_build_object('ok', true, 'bets', v_bets);
end;
$$;
grant execute on function public.get_my_bets(text, uuid) to anon, authenticated;


-- ── get_races: now surfaces status (open/betting), odds, bet_closes_at ──────────
-- Supersedes 074's get_races. Returns open + betting races (not resolved) with
-- per-lane odds (null until betting) and the betting deadline. mine_in_race lets
-- the UI disable betting on races the caller is entered in.
create or replace function public.get_races(p_device_hash text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_races   json;
begin
    perform public._horse_advance_races();
    v_account := public._horse_resolve_account(p_device_hash);

    select coalesce(json_agg(rj order by rj_order), '[]'::json) into v_races
    from (
        select
            r.bet_closes_at as rj_order_bc, r.closes_at as rj_order,
            json_build_object(
                'id', r.id, 'name', r.name, 'kind', r.kind, 'status', r.status,
                'field_size', r.field_size, 'opens_at', r.opens_at,
                'closes_at', r.closes_at, 'bet_closes_at', r.bet_closes_at,
                'mine_in_race', exists (
                    select 1 from public.race_entries e
                    where e.race_id = r.id and e.owner_id = v_account),
                'entries', coalesce((
                    select json_agg(json_build_object(
                        'lane', e.lane, 'is_npc', e.is_npc,
                        'display_name', e.display_name, 'breed', e.breed,
                        'speed', e.speed, 'endurance', e.endurance, 'life', e.life,
                        'odds', e.odds, 'horse_id', e.horse_id,
                        'mine', (e.owner_id is not null and e.owner_id = v_account)
                    ) order by e.lane)
                    from public.race_entries e where e.race_id = r.id
                ), '[]'::json)
            ) as rj
        from public.races r
        where r.status in ('open', 'betting')
    ) sub;

    return json_build_object('now', now(), 'races', v_races);
end;
$$;
grant execute on function public.get_races(text) to anon, authenticated;
