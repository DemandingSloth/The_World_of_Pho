-- ============================================================================
-- Marketplace: rename_account — change an account's online username
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- The client validates length/characters/profanity locally (using the in-game
-- word filter) BEFORE calling this. The server is authoritative for UNIQUENESS
-- (usernames are `unique`), checked case-insensitively so "Slothy" and "slothy"
-- can't both exist. The coin cost is handled entirely client-side (local coins);
-- this function only performs the availability check + rename.
--
-- Returns json:
--   { ok, username }                      on success
--   { error: account_not_found }          no account for this device
--   { error: invalid }                    empty/too long name
--   { error: username_taken }             already in use by someone else
-- ============================================================================

create or replace function public.rename_account(
    p_device_hash text,
    p_new_username text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
    v_account uuid;
    v_name    text := btrim(coalesce(p_new_username, ''));
begin
    select id into v_account from public.accounts where device_hash = p_device_hash for update;
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    -- Basic server-side sanity (client does the richer format/profanity check).
    if length(v_name) < 2 or length(v_name) > 16 then
        return json_build_object('error', 'invalid');
    end if;

    -- Uniqueness (case-insensitive), excluding the caller's own current name.
    if exists (
        select 1 from public.accounts
        where lower(username) = lower(v_name) and id <> v_account
    ) then
        return json_build_object('error', 'username_taken');
    end if;

    update public.accounts set username = v_name where id = v_account;

    return json_build_object('ok', true, 'username', v_name);
end;
$$;

grant execute on function public.rename_account(text, text) to anon, authenticated;
