-- ============================================================================
-- Migration 107: Horse prestige paths — training cap + stable size
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 078 (_horse_stable_capacity / _horse_training_session_cap with the
-- horse-guild upgrades).
--
-- Two new prestige paths are enforced here because training gains and stable
-- room are server-authoritative:
--
--   Master Trainer (horse_training_cap): the most stat points ONE training
--     session can earn. Base 10 -> 11 at L1 ... 50 at L10.
--       L:   1  2  3  4  5  6  7  8  9  10
--       cap: 11 13 16 19 23 27 32 38 44 50   (bonus = cap - 10)
--     MUST match PlayerData.HORSE_TRAINING_CAP_BY_LEVEL.
--
--   Bigger Barn (horse_stable_size): +1 stable slot per level (+10 at L10).
--
-- Both stack with the horse guild's upgrades (still +1 per guild level).
--
-- Prestige itself is tracked in the player's save, so the client reports its
-- levels via set_horse_prestige(). The server clamps them to 0..10 and does the
-- level -> bonus mapping itself.
-- ============================================================================


-- ── Storage ─────────────────────────────────────────────────────────────────
alter table public.accounts
    add column if not exists prestige_training_level int not null default 0,
    add column if not exists prestige_stable_level   int not null default 0;


-- ── Level -> training cap bonus (points above the base 10) ──────────────────
create or replace function public._horse_prestige_training_bonus(p_level int)
returns numeric
language sql
immutable
as $$
    select (array[0, 1, 3, 6, 9, 13, 17, 22, 28, 34, 40])
           [least(greatest(coalesce(p_level, 0), 0), 10) + 1]::numeric;
$$;


-- ── set_horse_prestige ──────────────────────────────────────────────────────
-- Returns { ok, training_level, stable_level, training_cap, capacity } | { error }
create or replace function public.set_horse_prestige(
    p_device_hash    text,
    p_training_level int,
    p_stable_level   int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_train   int := least(greatest(coalesce(p_training_level, 0), 0), 10);
    v_stable  int := least(greatest(coalesce(p_stable_level, 0), 0), 10);
begin
    select id into v_account from public.accounts where device_hash = p_device_hash;
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    update public.accounts
    set prestige_training_level = v_train,
        prestige_stable_level   = v_stable
    where id = v_account;

    return json_build_object('ok', true,
        'training_level', v_train,
        'stable_level',   v_stable,
        'training_cap',   public._horse_training_session_cap(v_account),
        'capacity',       public._horse_stable_capacity(v_account));
end;
$$;
grant execute on function public.set_horse_prestige(text, int, int) to anon, authenticated;


-- ── Stable capacity (supersedes 078): base 5 + guild upgrade + prestige ─────
create or replace function public._horse_stable_capacity(p_account uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
    select 5
         + public._horse_guild_upgrade_level(p_account, 'horse_stable_size')
         + coalesce((select prestige_stable_level from public.accounts
                     where id = p_account), 0);
$$;
revoke all on function public._horse_stable_capacity(uuid) from anon, authenticated;


-- ── Training session cap (supersedes 078): base 10 + guild + prestige ───────
create or replace function public._horse_training_session_cap(p_account uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
    select 10.00::numeric
         + public._horse_guild_upgrade_level(p_account, 'horse_training_cap')::numeric
         + public._horse_prestige_training_bonus(
               (select prestige_training_level from public.accounts where id = p_account));
$$;
revoke all on function public._horse_training_session_cap(uuid) from anon, authenticated;
