-- ============================================================================
-- Migration 068: Horse feed (Horse Racing — Task 4)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Adds the "feed a horse" action. Feed is a LOCAL stackable consumable (bought
-- with coins into the player's inventory, exactly like a Marketplace tool — the
-- SERVER does NOT track feed quantity). This RPC only performs the one piece
-- that must be authoritative: raising a horse's current `life` toward its
-- `life_cap`. The client decrements its local feed stock ONLY AFTER this
-- succeeds, mirroring the buy_horse / Money Gun trust model.
--
-- `life` is the horse's condition. Racing (Task 5+) drains it; feed restores it.
-- Grooming (training, migration 067) raises the `life_cap`; feed never exceeds
-- the cap. One feed restores a fixed FEED_RESTORE amount, clamped to the cap.
-- ============================================================================


-- ── Feed restore amount (authoritative) ────────────────────────────────────────
-- A single feed restores this much `life` (clamped to life_cap). Kept as a
-- function so the amount is a single server-side source of truth to tune later.
create or replace function public._horse_feed_restore()
returns int
language sql
immutable
as $$
    select 25;
$$;


-- ── feed_horse ──────────────────────────────────────────────────────────────────
-- Restores one of the caller's horses' `life` toward life_cap by the fixed feed
-- amount. Works for active horses (retired horses in the pasture don't race, so
-- they can't be fed — keeps the pasture a pure retirement). The client holds the
-- feed item locally and only consumes it after this returns ok.
-- Returns { ok, restored, life, life_cap, horse:{...} } | { error }.
--   errors: account_not_found, horse_not_found, not_your_horse, horse_retired,
--           already_full
create or replace function public.feed_horse(
    p_device_hash text,
    p_horse_id    uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account  uuid;
    v_horse    public.horses%rowtype;
    v_restore  int := public._horse_feed_restore();
    v_new      int;
    v_gained   int;
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
    if v_horse.status <> 'active' then
        return json_build_object('error', 'horse_retired');
    end if;
    if v_horse.life >= v_horse.life_cap then
        return json_build_object('error', 'already_full', 'life', v_horse.life, 'life_cap', v_horse.life_cap);
    end if;

    v_new    := least(v_horse.life_cap, v_horse.life + v_restore);
    v_gained := v_new - v_horse.life;

    update public.horses set life = v_new where id = p_horse_id;
    v_horse.life := v_new;

    return json_build_object(
        'ok', true,
        'restored', v_gained,
        'life', v_horse.life,
        'life_cap', v_horse.life_cap,
        'horse', json_build_object(
            'id', v_horse.id, 'name', v_horse.name, 'breed', v_horse.breed,
            'life', v_horse.life, 'life_cap', v_horse.life_cap,
            'speed', v_horse.speed, 'endurance', v_horse.endurance,
            'status', v_horse.status, 'wins', v_horse.wins, 'races_run', v_horse.races_run
        )
    );
end;
$$;
grant execute on function public.feed_horse(text, uuid) to anon, authenticated;
