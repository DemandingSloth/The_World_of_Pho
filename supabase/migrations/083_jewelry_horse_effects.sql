-- ============================================================================
-- Migration 083: Jewelry horse effects (Task 11c)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 + 070 + 073 + 078 (train_horse) + 082 (register_horse) applied.
--
-- Equipped jewelry does DOUBLE DUTY — it keeps its economy bonus AND grants a
-- horse effect, scaled by how many of that jewelry the player OWNS (same curve
-- as every jewelry bonus). Jewelry is equipped on the PLAYER, so these buffs
-- apply to ALL the player's horses while equipped (an effective-stats layer; the
-- DB base stats are never mutated). Reverses the moment it's unequipped.
--
--   TRAINING boosts (per kind), applied AFTER the session cap so they can push a
--   single session's gain ABOVE the base cap (hard stat ceiling still clamps):
--     violet_stone_ring    -> sprint (speed)
--     blue_stone_necklace  -> hurdle (endurance)
--     black_pearl_necklace -> groom
--   Server receives p_train_mult (>=1.0, client-trusted like the score) and
--   multiplies the capped gain by it, then clamps to the stat ceiling.
--
--   RACE buffs, baked into the entry SNAPSHOT at registration (so the sim honors
--   the persistent effective stats):
--     emerald_necklace     -> +% speed, endurance AND life  (across the board)
--     pink_stone_necklace  -> +% life_cap (effective max life, hard cap 200)
--   Server receives p_emerald_level / p_pink_level (0..10) and applies the
--   matching % to the snapshot.
--
-- Trust model: jewelry counts live client-side (local), so the client sends the
-- resolved multiplier / levels. This matches training (already trusts the score)
-- and horseshoes (migration 082). All values are bounded (mult clamp, level 0..10).
-- ============================================================================


-- ── Jewelry level -> fraction (mirror of the client JewelryBonus 1%..25% ramp) ──
-- Reused by register_horse for emerald/pink. (Same shape as _horse_horseshoe_bonus_pct.)
create or replace function public._horse_jewelry_bonus_pct(p_level int)
returns numeric
language sql
immutable
as $$
    select case
        when coalesce(p_level, 0) <= 0 then 0.0::numeric
        else round(
            (1.0 + (25.0 - 1.0) * (least(greatest(p_level, 1), 10) - 1)::numeric / 9.0) / 100.0,
            4)
    end;
$$;


-- ── train_horse REWORKED: post-cap training multiplier (supersedes 078) ─────────
-- Identical to 078 EXCEPT a new p_train_mult (>=1.0) multiplies the gain AFTER
-- the session cap, before the hard-ceiling clamp. mult 1.0 = unchanged behavior.
create or replace function public.train_horse(
    p_device_hash text,
    p_horse_id    uuid,
    p_kind        text,
    p_score       int,
    p_train_mult  numeric default 1.0
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
    v_mult      numeric;
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

    -- Capped gain, THEN the jewelry multiplier (clamped to a sane 1.0..5.0).
    v_cap  := public._horse_training_session_cap(v_account);
    v_gain := public._horse_training_gain(p_score, v_cap);
    v_mult := least(greatest(coalesce(p_train_mult, 1.0), 1.0), 5.0);
    v_gain := round(v_gain * v_mult, 2);

    if p_kind = 'groom' then
        v_stat    := 'life_cap';
        v_ceiling := 200;
        if v_horse.life_cap >= v_ceiling then
            return json_build_object('error', 'at_ceiling', 'stat', v_stat, 'ceiling', v_ceiling);
        end if;
        -- Groom still halves its (now jewelry-boosted) gain, min 0.50.
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

    perform public.record_horse_guild_activity(p_device_hash, 'train_sessions', 1);

    select * into v_horse from public.horses where id = p_horse_id;

    return json_build_object(
        'ok', true,
        'kind', p_kind, 'stat', v_stat, 'gain', v_gain,
        'life_cost', v_life_cost, 'retired', v_retired,
        'horse', json_build_object(
            'id', v_horse.id, 'name', v_horse.name, 'breed', v_horse.breed,
            'life', v_horse.life, 'life_cap', v_horse.life_cap,
            'speed', v_horse.speed, 'endurance', v_horse.endurance,
            'status', v_horse.status, 'wins', v_horse.wins, 'races_run', v_horse.races_run
        )
    );
end;
$$;
grant execute on function public.train_horse(text, uuid, text, int, numeric) to anon, authenticated;


-- ── register_horse REWORKED: fold emerald + pink buffs into the snapshot ────────
-- Supersedes 082's version. Adds p_emerald_level (across-the-board %) and
-- p_pink_level (life_cap %), applied to the entry snapshot AFTER the horseshoe
-- boost. Emerald raises speed+endurance+life; pink raises life_cap (hard cap 200).
-- Hard ceilings: speed/endurance 100, life/life_cap 200.
drop function if exists public.register_horse(text, uuid, uuid, int);

create or replace function public.register_horse(
    p_device_hash     text,
    p_race_id         uuid,
    p_horse_id        uuid,
    p_horseshoe_level int default 0,
    p_emerald_level   int default 0,
    p_pink_level      int default 0
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account   uuid;
    v_horse     public.horses%rowtype;
    v_race      public.races%rowtype;
    v_count     int;
    v_lane      int := 0;
    v_entry     uuid;
    v_total     numeric;
    v_eligible  int;
    v_hs_pct    numeric := 0.0;
    v_em_pct    numeric := 0.0;
    v_pk_pct    numeric := 0.0;
    v_speed     numeric;
    v_endurance numeric;
    v_life      numeric;
    v_life_cap  numeric;
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
        return json_build_object('error', 'race_closed');
    end if;

    -- Start from the horse's base stats, then layer the equipped buffs.
    v_speed     := v_horse.speed;
    v_endurance := v_horse.endurance;
    v_life      := v_horse.life;
    v_life_cap  := v_horse.life_cap;

    -- Emerald: across-the-board % to speed, endurance, life (NOT life_cap).
    if coalesce(p_emerald_level, 0) > 0 then
        v_em_pct := public._horse_jewelry_bonus_pct(p_emerald_level);
        v_speed     := round(v_speed     * (1.0 + v_em_pct), 2);
        v_endurance := round(v_endurance * (1.0 + v_em_pct), 2);
        v_life      := round(v_life      * (1.0 + v_em_pct), 2);
    end if;

    -- Pink: % to life_cap (and let life ride up to the new cap if it was full).
    if coalesce(p_pink_level, 0) > 0 then
        v_pk_pct := public._horse_jewelry_bonus_pct(p_pink_level);
        v_life_cap := round(v_life_cap * (1.0 + v_pk_pct), 2);
    end if;

    -- Horseshoe: copper->speed, iron->endurance (on top of emerald).
    if v_horse.horseshoe is not null and coalesce(p_horseshoe_level, 0) > 0 then
        v_hs_pct := public._horse_horseshoe_bonus_pct(p_horseshoe_level);
        if v_horse.horseshoe = 'copper' then
            v_speed := round(v_speed * (1.0 + v_hs_pct), 2);
        elsif v_horse.horseshoe = 'iron' then
            v_endurance := round(v_endurance * (1.0 + v_hs_pct), 2);
        end if;
    end if;

    -- Hard ceilings.
    v_speed     := least(100.0, v_speed);
    v_endurance := least(100.0, v_endurance);
    v_life_cap  := least(200.0, v_life_cap);
    v_life      := least(v_life, v_life_cap);   -- life can't exceed its (buffed) cap

    -- Cup gate uses the horse's BASE stat-total (buffs don't change tier).
    if v_race.kind = 'cup' and v_race.tier is not null then
        v_total := v_horse.life + v_horse.speed + v_horse.endurance;
        v_eligible := public._race_cup_tier_for(v_total);
        if v_eligible is null or v_eligible <> v_race.tier then
            return json_build_object(
                'error', 'cup_tier_mismatch',
                'race_tier', v_race.tier,
                'eligible_tier', v_eligible,
                'stat_total', v_total
            );
        end if;
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
        v_horse.name, v_horse.breed, v_speed, v_endurance, v_life, v_life_cap
    ) returning id into v_entry;

    perform public._horse_advance_races();

    return json_build_object(
        'ok', true, 'race_id', p_race_id, 'lane', v_lane,
        'entry', json_build_object(
            'id', v_entry, 'lane', v_lane, 'is_npc', false,
            'horse_id', p_horse_id, 'display_name', v_horse.name, 'breed', v_horse.breed,
            'speed', v_speed, 'endurance', v_endurance,
            'life', v_life, 'life_cap', v_life_cap,
            'horseshoe', coalesce(v_horse.horseshoe, '')
        )
    );
end;
$$;
grant execute on function public.register_horse(text, uuid, uuid, int, int, int) to anon, authenticated;
