-- ============================================================================
-- Migration 091: Races deduct life from participating horses
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 078 (latest _horse_resolve_race) applied.
--
-- Previously races never deducted life, so horses could race indefinitely
-- without consequence. This migration adds a life cost to every race a real
-- player horse participates in. The cost scales with field_size (bigger fields
-- = tougher competition = more life lost):
--
--   life_cost = round(8 + (field_size - 5) * 7.0 / 10.0)
--
--   field 5  (cups)    →  10 life
--   field 8  (regular) →  12 life
--   field 10           →  13 life
--
-- A horse whose life reaches 0 after a race is retired to the pasture,
-- its guild-paddock entry is removed (if any), and status is set to 'retired'.
-- NPC entries are never affected.
-- ============================================================================


-- ── Life-cost helper ─────────────────────────────────────────────────────────
create or replace function public._race_life_cost(p_field_size int)
returns numeric
language sql
immutable
as $$
    select round(8.0 + (greatest(5, coalesce(p_field_size, 8)) - 5) * 7.0 / 10.0, 2);
$$;
revoke all on function public._race_life_cost(int) from anon, authenticated;


-- ── _horse_resolve_race REWORKED: deduct life after every race ───────────────
-- Supersedes 078's version. Identical except a new block after recording wins:
-- deducts _race_life_cost(field_size) from each REAL horse that ran, retires
-- any whose life hits 0, and removes them from the paddock.
create or replace function public._horse_resolve_race(p_race_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_race       public.races%rowtype;
    v_sim        jsonb;
    v_order      jsonb;
    v_place      int;
    v_lane       int;
    v_winner_horse uuid;
    v_win_lane   int;
    v_win_owner  uuid;
    b            record;
    v_payout     bigint;
    v_has_tokens boolean;
    v_tier       record;
    v_first      bigint;
    e            record;
    v_prize      bigint;
    v_life_cost  numeric;
    v_new_life   numeric;
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

    -- races_run + wins for real horses (no 're' alias issue since 'e' used below).
    update public.horses h set races_run = races_run + 1
    from public.race_entries re
    where re.race_id = p_race_id and re.horse_id = h.id;

    select horse_id, owner_id into v_winner_horse, v_win_owner
    from public.race_entries
    where race_id = p_race_id and finish_place = 1 and horse_id is not null;
    if v_winner_horse is not null then
        update public.horses set wins = wins + 1 where id = v_winner_horse;
        perform public._record_horse_guild_activity_acct(v_win_owner, 'race_wins', 1);
    end if;

    -- ── LIFE DEDUCTION (new in 091) ───────────────────────────────────────────
    -- Deduct life from every real horse that raced. Scale to field size so
    -- bigger fields cost more. Retire + remove from paddock if life hits 0.
    v_life_cost := public._race_life_cost(v_race.field_size);

    for e in
        select re.horse_id, re.owner_id
        from public.race_entries re
        where re.race_id = p_race_id and re.horse_id is not null
    loop
        -- Lock the horse row and deduct life.
        update public.horses
        set life = greatest(0, round(life - v_life_cost, 2))
        where id = e.horse_id
        returning life into v_new_life;

        if v_new_life is not null and v_new_life <= 0 then
            update public.horses set status = 'retired', life = 0 where id = e.horse_id;
            -- Remove from guild paddock so guildmates can't train a retired horse.
            if to_regclass('public.guild_paddock') is not null then
                delete from public.guild_paddock where horse_id = e.horse_id;
            end if;
        end if;
    end loop;
    -- ── End life deduction ────────────────────────────────────────────────────

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
