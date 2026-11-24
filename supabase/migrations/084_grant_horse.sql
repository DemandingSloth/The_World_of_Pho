-- ============================================================================
-- Migration 084: grant_horse — coin-free, room-gated horse grant (Task 11d)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 065 (horses + _horse_breed_stats + _horse_stable_capacity) applied.
--
-- A present can drop a HORSE. Horses are server-side, so a free grant needs an
-- RPC. grant_horse creates a horse of ANY breed (including the mythical cup
-- breeds pegasus/centaur/unicorn — presents are the other way to get them) at
-- the breed's base stats, FREE (no coin charge), but ONLY if the stable has
-- room. No room -> 'stable_full' (the caller/UI should fall back to another
-- reward so the present isn't wasted). Mirrors _horse_grant_prize (migration
-- 077) but is a callable RPC and accepts any valid breed.
--   returns { ok, horse:{...} } | { error: account_not_found, invalid_breed,
--             stable_full }
-- ============================================================================

create or replace function public.grant_horse(
    p_device_hash text,
    p_breed       text,
    p_name        text default null
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_stats   record;
    v_name    text;
    v_count   int;
    v_cap     int;
    v_id      uuid;
begin
    v_account := public._horse_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    select * into v_stats from public._horse_breed_stats(p_breed);
    if not found then
        return json_build_object('error', 'invalid_breed');
    end if;

    -- Room check (active horses only).
    select count(*) into v_count
    from public.horses where owner_id = v_account and status = 'active';
    v_cap := public._horse_stable_capacity(v_account);
    if v_count >= v_cap then
        return json_build_object('error', 'stable_full', 'capacity', v_cap);
    end if;

    -- Name: trimmed 1..24, else a sensible default from the breed.
    v_name := nullif(btrim(coalesce(p_name, '')), '');
    if v_name is null or length(v_name) > 24 then
        v_name := left(initcap(p_breed) || ' Gift', 24);
    end if;

    insert into public.horses (owner_id, name, breed, life, life_cap, speed, endurance)
    values (v_account, v_name, p_breed, v_stats.life, v_stats.life, v_stats.speed, v_stats.endurance)
    returning id into v_id;

    return json_build_object(
        'ok', true,
        'horse', json_build_object(
            'id', v_id, 'name', v_name, 'breed', p_breed,
            'life', v_stats.life, 'life_cap', v_stats.life,
            'speed', v_stats.speed, 'endurance', v_stats.endurance,
            'status', 'active', 'wins', 0, 'races_run', 0
        )
    );
end;
$$;
grant execute on function public.grant_horse(text, text, text) to anon, authenticated;
