-- ============================================================================
-- Migration 105: Restore an online account to THIS device with a recovery code
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 001 (accounts + recovery_hash).
--
-- restore_account (001) only VERIFIED a recovery code; it never moved the
-- account to the new device, so a player who lost their phone / reinstalled
-- couldn't get back in. This adds:
--
--   restore_account_to_device(p_recovery_code, p_device_hash)
--     • Finds the account whose recovery code matches.
--     • If another account is currently linked to this device (e.g. the one
--       auto-created after the reinstall), it is UNLINKED (device_hash set to
--       'detached:<id>') — kept, not deleted, so nothing is destroyed.
--     • Links the recovered account to this device.
--   Returns { ok, id, username, token_balance, replaced_account } | { error }
--     errors: invalid_recovery_code, invalid_device_hash, not_found
--
-- The recovery code keeps working afterwards (same code, same account).
-- ============================================================================

create or replace function public.restore_account_to_device(
    p_recovery_code text,
    p_device_hash   text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_code     text := btrim(coalesce(p_recovery_code, ''));
    v_acct     public.accounts%rowtype;
    v_replaced uuid;
begin
    if length(v_code) < 4 then
        return json_build_object('error', 'invalid_recovery_code');
    end if;
    if p_device_hash is null or length(p_device_hash) < 8 then
        return json_build_object('error', 'invalid_device_hash');
    end if;

    -- crypt() with the stored hash as salt recomputes and compares.
    select * into v_acct
    from public.accounts
    where recovery_hash = crypt(v_code, recovery_hash)
    limit 1
    for update;
    if not found then
        return json_build_object('error', 'not_found');
    end if;

    if v_acct.device_hash is distinct from p_device_hash then
        -- Free this device from whatever account currently holds it.
        update public.accounts
        set device_hash = 'detached:' || id::text
        where device_hash = p_device_hash and id <> v_acct.id
        returning id into v_replaced;

        update public.accounts set device_hash = p_device_hash where id = v_acct.id;
    end if;

    return json_build_object(
        'ok',               true,
        'id',               v_acct.id,
        'username',         v_acct.username,
        'token_balance',    v_acct.token_balance,
        'replaced_account', v_replaced
    );
end;
$$;
grant execute on function public.restore_account_to_device(text, text) to anon, authenticated;
