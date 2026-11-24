-- ============================================================================
-- Migration 054: grant_benjamins — secret-gated Benjamin grant (ALPHA CHEAT)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Supports the alpha tester cheat code that grants Benjamins directly. Because
-- Benjamins are server-authoritative (migration 053), a wide-open mint endpoint
-- would let anyone with the public anon key give themselves unlimited spending
-- power. This RPC therefore requires a SHARED SECRET (baked into the client
-- build) and caps the per-call grant, so a casual anon-key caller can't mint.
--
-- ⚠️  ALPHA-ONLY. Before public release, either drop this function or rotate the
--     secret out of the shipped client. It is intentionally a separate migration
--     so it is easy to find and remove.
--
--   grant_benjamins(device_hash, amount, secret)
--     -> { ok, granted, balance } | { error }
--     errors: account_not_found, bad_secret, invalid_amount
-- ============================================================================

-- The shared secret the client must present. CHANGE THIS before relying on it;
-- treat it as a build-time constant, not a real security boundary (it ships in
-- the client). Rotating it invalidates older alpha builds' cheat.
create or replace function public._benjamin_grant_secret()
returns text
language sql
immutable
as $$
    select 'sloth-alpha-benjamin-2026';
$$;
revoke all on function public._benjamin_grant_secret() from anon, authenticated;

-- Per-call cap: even with a leaked secret, one call can't mint more than this.
-- The tester cheat only ever grants 10, so this is generous headroom.
create or replace function public._benjamin_grant_cap()
returns bigint
language sql
immutable
as $$
    select 1000000::bigint;
$$;
revoke all on function public._benjamin_grant_cap() from anon, authenticated;


create or replace function public.grant_benjamins(
    p_device_hash text,
    p_amount      int,
    p_secret      text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_acct public.accounts%rowtype;
    v_amt  bigint;
begin
    if p_secret is distinct from public._benjamin_grant_secret() then
        return json_build_object('error', 'bad_secret');
    end if;

    select * into v_acct from public.accounts
    where device_hash = p_device_hash
    for update;
    if not found then
        return json_build_object('error', 'account_not_found');
    end if;

    if p_amount is null or p_amount <= 0 then
        return json_build_object('error', 'invalid_amount');
    end if;

    v_amt := least(p_amount::bigint, public._benjamin_grant_cap());

    update public.accounts
    set benjamin_balance = benjamin_balance + v_amt
    where id = v_acct.id;

    insert into public.benjamin_ledger (account_id, delta, reason)
    values (v_acct.id, v_amt, 'cheat_grant');

    return json_build_object(
        'ok',      true,
        'granted', v_amt,
        'balance', v_acct.benjamin_balance + v_amt
    );
end;
$$;
grant execute on function public.grant_benjamins(text, int, text) to anon, authenticated;
