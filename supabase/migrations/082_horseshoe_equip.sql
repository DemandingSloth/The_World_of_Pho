-- ============================================================================
-- Migration 082: Horseshoe equip + race-stat bonus at registration (Task 11b)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 + 077 (+ 078/080 for the latest register path) + 081 applied.
--
-- A horse can wear ONE horseshoe at a time: 'copper' (boosts race SPEED, lighter)
-- or 'iron' (boosts race ENDURANCE, sturdier). The horseshoe is a persistent
-- equip on the horse; the BONUS STRENGTH scales with how many of that horseshoe
-- the OWNER currently holds — exactly like jewelry (count → level 1..10, 1%..25%).
--
-- Horseshoe counts are a LOCAL value (PlayerData, like jewelry), so the client
-- passes the current bonus LEVEL (0..10) to register_horse; the server applies
-- the matching % to the entry SNAPSHOT (speed for copper, endurance for iron),
-- clamped to the 100 ceiling. This is the only place the bonus matters — the sim
-- reads the snapshot — so there's nothing to desync. (Same client-trust model as
-- training scores: a cheater can at most claim level 10, which is bounded.)
-- ============================================================================


-- ── Equip column ────────────────────────────────────────────────────────────────
-- NULL = no shoe. 'copper' | 'iron'.
alter table public.horses
    add column if not exists horseshoe text
        check (horseshoe is null or horseshoe in ('copper', 'iron'));


-- ── Horseshoe bonus curve (mirror of the client JewelryBonus 1%..25% ramp) ──────
-- level 0 -> 0; level 1 -> 1%; level 10 -> 25% (linear between). Returns a
-- fraction (e.g. 0.25 at level 10). Clamped to [0,10].
create or replace function public._horse_horseshoe_bonus_pct(p_level int)
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


-- ── equip_horseshoe ──────────────────────────────────────────────────────────────
-- Sets (or clears) a horse's horseshoe. p_type: 'copper' | 'iron' | null/'' to
-- unequip. The CLIENT asserts it owns at least one of that horseshoe (local
-- inventory); the server just records the choice (the shoe isn't consumed).
-- Returns { ok, horseshoe } | { error }.
--   errors: account_not_found, horse_not_found, not_your_horse, horse_retired,
--           bad_horseshoe
create or replace function public.equip_horseshoe(
    p_device_hash text,
    p_horse_id    uuid,
    p_type        text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_horse   public.horses%rowtype;
    v_type    text;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_type := nullif(btrim(coalesce(p_type, '')), '');
    if v_type is not null and v_type not in ('copper', 'iron') then
        return json_build_object('error', 'bad_horseshoe');
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

    update public.horses set horseshoe = v_type where id = p_horse_id;
    return json_build_object('ok', true, 'horseshoe', coalesce(v_type, ''));
end;
$$;
grant execute on function public.equip_horseshoe(text, uuid, text) to anon, authenticated;


-- ── register_horse REWORKED: bake the horseshoe bonus into the snapshot ─────────
-- Supersedes 077's version (keeps the cup-tier gate from 077). Adds a 4th arg
-- p_horseshoe_level (0..10, the owner's count-derived bonus level, from the
-- client). If the horse wears a horseshoe, the entry snapshot gets +pct of that
-- stat (copper→speed, iron→endurance), clamped to 100. Everything else identical.
-- The old 3-arg signature is dropped so there's one canonical function.
drop function if exists public.register_horse(text, uuid, uuid);

create or replace function public.register_horse(
    p_device_hash     text,
    p_race_id         uuid,
    p_horse_id        uuid,
    p_horseshoe_level int default 0
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
    v_pct       numeric := 0.0;
    v_speed     numeric;
    v_endurance numeric;
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

    -- Cup gate: a horse is LOCKED to its highest eligible tier.
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

    -- HORSESHOE BONUS: bake into the snapshot (copper→speed, iron→endurance).
    v_speed     := v_horse.speed;
    v_endurance := v_horse.endurance;
    if v_horse.horseshoe is not null and coalesce(p_horseshoe_level, 0) > 0 then
        v_pct := public._horse_horseshoe_bonus_pct(p_horseshoe_level);
        if v_horse.horseshoe = 'copper' then
            v_speed := least(100.0, round(v_horse.speed * (1.0 + v_pct), 2));
        elsif v_horse.horseshoe = 'iron' then
            v_endurance := least(100.0, round(v_horse.endurance * (1.0 + v_pct), 2));
        end if;
    end if;

    insert into public.race_entries (
        race_id, lane, is_npc, horse_id, owner_id,
        display_name, breed, speed, endurance, life, life_cap
    ) values (
        p_race_id, v_lane, false, p_horse_id, v_account,
        v_horse.name, v_horse.breed, v_speed, v_endurance,
        v_horse.life, v_horse.life_cap
    ) returning id into v_entry;

    perform public._horse_advance_races();

    return json_build_object(
        'ok', true, 'race_id', p_race_id, 'lane', v_lane,
        'entry', json_build_object(
            'id', v_entry, 'lane', v_lane, 'is_npc', false,
            'horse_id', p_horse_id, 'display_name', v_horse.name, 'breed', v_horse.breed,
            'speed', v_speed, 'endurance', v_endurance,
            'life', v_horse.life, 'life_cap', v_horse.life_cap,
            'horseshoe', coalesce(v_horse.horseshoe, ''), 'horseshoe_pct', v_pct
        )
    );
end;
$$;
grant execute on function public.register_horse(text, uuid, uuid, int) to anon, authenticated;


-- ── get_horses: surface each horse's equipped horseshoe ─────────────────────────
-- Supersedes 065's get_horses (adds 'horseshoe' to each row so the stable UI can
-- show + manage the equip). Everything else identical.
create or replace function public.get_horses(p_device_hash text)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_horses  json;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select coalesce(json_agg(json_build_object(
        'id',        h.id,
        'name',      h.name,
        'breed',     h.breed,
        'life',      h.life,
        'life_cap',  h.life_cap,
        'speed',     h.speed,
        'endurance', h.endurance,
        'status',    h.status,
        'wins',      h.wins,
        'races_run', h.races_run,
        'horseshoe', coalesce(h.horseshoe, '')
    ) order by h.status, h.created_at), '[]'::json)
    into v_horses
    from public.horses h
    where h.owner_id = v_account;

    return json_build_object(
        'capacity', public._horse_stable_capacity(v_account),
        'horses',   v_horses
    );
end;
$$;
grant execute on function public.get_horses(text) to anon, authenticated;
