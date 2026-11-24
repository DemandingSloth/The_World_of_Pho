-- ============================================================================
-- Migration 071: TESTING — uncap training + new buyback rate
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 + 067 + 070 already applied.
--
-- Two changes:
--
-- 1) TEMPORARY testing convenience: redefines train_horse WITHOUT the
--    once-per-UTC-day-per-kind cooldown, so a horse can be trained repeatedly
--    while we tune the mini-games. Everything else (fractional gain, session
--    cap, stat ceilings) is unchanged from migration 070. The cooldown logic is
--    kept INLINE but commented out — RE-ENABLE by re-running migration 070, or
--    by uncommenting the marked block below and re-running this file.
--
-- 2) New BUYBACK (sell) rate = HALF the current buy price:
--       buy  = stat_total * 100000     (unchanged)
--       sell = stat_total * 50000      (was stat_total^2 * 10000)
--    i.e. a horse sells for half of what an equivalent one costs to buy now.
--    (stat_total = round(life + speed + endurance); stats are fractional.)
-- ============================================================================


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
    v_account  uuid;
    v_horse    public.horses%rowtype;
    v_today    date := (now() at time zone 'utc')::date;
    v_last     date;
    v_cap      numeric;
    v_gain     numeric;
    v_stat     text;
    v_ceiling  numeric;
    v_current  numeric;
    v_new      numeric;
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

    -- ──[ DAILY CAP: groom only, for now ]──────────────────────────────────────
    -- sprint + hurdle are UNCAPPED for testing (train them repeatedly). groom is
    -- functional + tuned, so it KEEPS the once-per-UTC-day cooldown.
    -- To re-enable the cap for ALL kinds later, drop the `p_kind = 'groom'`
    -- guard (or re-run migration 070, which caps every kind).
    if p_kind = 'groom' then
        select trained_day into v_last
        from public.horse_training
        where horse_id = p_horse_id and kind = p_kind;
        if v_last is not null and v_last >= v_today then
            return json_build_object('error', 'already_trained');
        end if;
    end if;
    -- ──────────────────────────────────────────────────────────────────────────

    -- Pick the stat + ceiling for the kind.
    if p_kind = 'sprint' then
        v_stat := 'speed';      v_ceiling := 100; v_current := v_horse.speed;
    elsif p_kind = 'hurdle' then
        v_stat := 'endurance';  v_ceiling := 100; v_current := v_horse.endurance;
    else -- groom
        v_stat := 'life_cap';   v_ceiling := 200; v_current := v_horse.life_cap;
    end if;

    if v_current >= v_ceiling then
        return json_build_object('error', 'at_ceiling', 'stat', v_stat, 'ceiling', v_ceiling);
    end if;

    -- gain = round(score/10 + 1, 2), capped by the session cap. GROOM gives too
    -- much life, so its final gain is HALVED: 100% (score 90) -> +5.00, and the
    -- minimum (score 0) -> +0.50. Then clamped so the stat stays <= ceiling.
    v_cap  := public._horse_training_session_cap(v_account);
    v_gain := public._horse_training_gain(p_score, v_cap);
    if p_kind = 'groom' then
        v_gain := greatest(0.50, round(v_gain / 2.0, 2));
    end if;
    v_new  := least(v_ceiling, round(v_current + v_gain, 2));
    v_gain := round(v_new - v_current, 2);

    if p_kind = 'sprint' then
        update public.horses set speed = v_new where id = p_horse_id;
    elsif p_kind = 'hurdle' then
        update public.horses set endurance = v_new where id = p_horse_id;
    else -- groom: raise life_cap, and top `life` up toward the new cap.
        update public.horses
        set life_cap = v_new,
            life = least(v_new, greatest(life, v_new))
        where id = p_horse_id;
    end if;

    -- Still record sessions (harmless; the cooldown read above is what's off).
    insert into public.horse_training (horse_id, kind, trained_day, sessions, updated_at)
    values (p_horse_id, p_kind, v_today, 1, now())
    on conflict (horse_id, kind) do update
        set trained_day = excluded.trained_day,
            sessions = public.horse_training.sessions + 1,
            updated_at = now();

    select * into v_horse from public.horses where id = p_horse_id;

    return json_build_object(
        'ok', true,
        'kind', p_kind,
        'stat', v_stat,
        'gain', v_gain,
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


-- ── sell_horse (new buyback rate: half the current buy price) ────────────────────
-- sell = round(life+speed+endurance) * 50000  (= half of stat_total * 100000).
-- Supersedes migration 065's sell_horse (which was stat_total^2 * 10000).
create or replace function public.sell_horse(
    p_device_hash text,
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
    v_total   int;
    v_price   bigint;
begin
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

    -- Half the current buy price. stat_total rounded (stats are numeric now).
    v_total := round(v_horse.life + v_horse.speed + v_horse.endurance)::int;
    v_price := v_total::bigint * 50000;

    delete from public.horses where id = p_horse_id;

    return json_build_object('ok', true, 'price', v_price);
end;
$$;
grant execute on function public.sell_horse(text, uuid) to anon, authenticated;
