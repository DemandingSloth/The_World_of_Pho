-- ============================================================================
-- Marketplace Task 5: reconcile_account — authoritative token balance read
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Returns the CURRENT server-side token balance (and identity) for a device.
-- The client treats this as the source of truth and never mutates the balance
-- locally. Later milestones will extend this to also return escrowed items.
-- ============================================================================

-- reconcile_account(device_hash) -> { id, username, token_balance } | { error }
create or replace function public.reconcile_account(p_device_hash text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_acct public.accounts%rowtype;
begin
    if p_device_hash is null or length(p_device_hash) < 8 then
        return json_build_object('error', 'invalid_device_hash');
    end if;

    select * into v_acct from public.accounts where device_hash = p_device_hash;
    if not found then
        return json_build_object('error', 'not_found');
    end if;

    return json_build_object(
        'id', v_acct.id,
        'username', v_acct.username,
        'token_balance', v_acct.token_balance
    );
end;
$$;

grant execute on function public.reconcile_account(text) to anon, authenticated;
