-- ============================================================================
-- Migration 099: One username — in-game name == marketplace account name
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 001 (accounts, register_account) and 017 (rename_account).
--
-- Previously the game kept TWO unrelated names: the local name typed at first
-- launch, and a server-generated marketplace name ("BraveOtter042"). This
-- migration lets the player's chosen name BE their account name:
--
--   1. _username_error(name)      — shared server-side rules (length, allowed
--                                   characters, profanity). Applied ONLY to
--                                   new names / renames; existing names are
--                                   grandfathered (never re-validated).
--   2. Case-insensitive uniqueness — "Bob" and "bob" can no longer coexist.
--                                   Any pre-existing case-only duplicates are
--                                   de-duplicated first so the index can build.
--   3. check_username(...)        — "is this name free?" for the name screen.
--   4. register_account_with_name — creates an account with a CHOSEN name.
--                                   If the device already has an account it is
--                                   returned unchanged (the client then adopts
--                                   that online name — online name wins).
--   5. rename_account REWRITTEN    — now enforces the same rules.
--
-- Backwards compatible: register_account(p_device_hash) is left untouched, so
-- older app versions keep working (they still get a generated name).
-- ============================================================================


-- ── 1. Shared username rules ─────────────────────────────────────────────────
-- Returns NULL when the name is acceptable, otherwise an error code:
--   'invalid_length' | 'invalid_chars' | 'profanity'
-- MUST mirror PlayerData.validate_name() on the client.
--
-- Profanity: long, unambiguous words are blocked ANYWHERE in the name; short
-- words that commonly appear inside normal names ("Cassie", "Scrappy",
-- "Dickens") are blocked only as a WHOLE word (split on spaces/_/digits).
create or replace function public._username_error(p_name text)
returns text
language plpgsql
immutable
as $$
declare
    v_name   text := btrim(coalesce(p_name, ''));
    v_lower  text;
    v_word   text;
    v_token  text;
    v_anywhere text[] := array[
        'fuck','shit','bitch','cunt','nigger','nigga','retard','slut','whore',
        'bastard','twat','wank','bollocks','pussy','asshole','dickhead'
    ];
    v_whole text[] := array['ass','damn','dick','cock','fag','piss','crap'];
begin
    if length(v_name) < 2 or length(v_name) > 16 then
        return 'invalid_length';
    end if;
    if v_name !~ '^[A-Za-z0-9 _]+$' then
        return 'invalid_chars';
    end if;

    v_lower := lower(v_name);
    foreach v_word in array v_anywhere loop
        if position(v_word in v_lower) > 0 then
            return 'profanity';
        end if;
    end loop;
    foreach v_token in array regexp_split_to_array(v_lower, '[ _0-9]+') loop
        if v_token = any(v_whole) then
            return 'profanity';
        end if;
    end loop;
    return null;
end;
$$;
revoke all on function public._username_error(text) from anon, authenticated;


-- ── 2. Case-insensitive uniqueness ───────────────────────────────────────────
-- De-duplicate any existing case-only collisions (keep the OLDEST account's
-- name as-is; give later ones a numeric suffix), then add the unique index.
do $$
declare
    r     record;
    v_new text;
begin
    for r in
        select a.id, a.username
        from public.accounts a
        where exists (
            select 1 from public.accounts b
            where lower(b.username) = lower(a.username)
              and (b.created_at, b.id) < (a.created_at, a.id)
        )
    loop
        loop
            v_new := r.username || floor(random() * 10000)::int::text;
            exit when not exists (
                select 1 from public.accounts where lower(username) = lower(v_new));
        end loop;
        update public.accounts set username = v_new where id = r.id;
    end loop;
end;
$$;

create unique index if not exists accounts_username_lower_key
    on public.accounts (lower(username));


-- ── 3. check_username ────────────────────────────────────────────────────────
-- Is `p_username` acceptable AND free? The caller's own current name counts as
-- available to them. Returns { ok, available, error? }.
create or replace function public.check_username(
    p_device_hash text,
    p_username    text
)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_name text := btrim(coalesce(p_username, ''));
    v_err  text;
begin
    v_err := public._username_error(v_name);
    if v_err is not null then
        return json_build_object('ok', true, 'available', false, 'error', v_err);
    end if;
    if exists (
        select 1 from public.accounts
        where lower(username) = lower(v_name)
          and device_hash is distinct from p_device_hash
    ) then
        return json_build_object('ok', true, 'available', false, 'error', 'username_taken');
    end if;
    return json_build_object('ok', true, 'available', true);
end;
$$;
grant execute on function public.check_username(text, text) to anon, authenticated;


-- ── 4. register_account_with_name ────────────────────────────────────────────
-- Like register_account, but the player chooses the name.
--   • Device already has an account → returned as-is (created:false). The name
--     is NOT changed; the client adopts the online name (online name wins).
--   • Otherwise the name is validated + checked for (case-insensitive)
--     uniqueness, the account is created, and a one-time recovery code returned.
-- Returns { id, username, token_balance, recovery_code, created } | { error }
--   errors: invalid_device_hash, invalid_length, invalid_chars, profanity,
--           username_taken
create or replace function public.register_account_with_name(
    p_device_hash text,
    p_username    text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_existing public.accounts%rowtype;
    v_name     text := btrim(coalesce(p_username, ''));
    v_err      text;
    v_recovery text;
    v_id       uuid;
begin
    if p_device_hash is null or length(p_device_hash) < 8 then
        return json_build_object('error', 'invalid_device_hash');
    end if;

    select * into v_existing from public.accounts where device_hash = p_device_hash;
    if found then
        return json_build_object(
            'id',            v_existing.id,
            'username',      v_existing.username,
            'token_balance', v_existing.token_balance,
            'recovery_code', null,
            'created',       false
        );
    end if;

    v_err := public._username_error(v_name);
    if v_err is not null then
        return json_build_object('error', v_err);
    end if;
    if exists (select 1 from public.accounts where lower(username) = lower(v_name)) then
        return json_build_object('error', 'username_taken');
    end if;

    v_recovery := encode(gen_random_bytes(9), 'base64');
    v_recovery := replace(replace(replace(v_recovery, '/', ''), '+', ''), '=', '');

    begin
        insert into public.accounts (device_hash, username, recovery_hash)
        values (p_device_hash, v_name, crypt(v_recovery, gen_salt('bf')))
        returning id into v_id;
    exception when unique_violation then
        -- Lost a race for the same name (or device) — report it as taken.
        return json_build_object('error', 'username_taken');
    end;

    return json_build_object(
        'id',            v_id,
        'username',      v_name,
        'token_balance', 2000,
        'recovery_code', v_recovery,
        'created',       true
    );
end;
$$;
grant execute on function public.register_account_with_name(text, text) to anon, authenticated;


-- ── 5. rename_account (REWRITTEN: shared rules + race-safe uniqueness) ────────
-- Same signature/return shape as 017. Coin cost stays client-side.
--   errors: account_not_found, invalid_length, invalid_chars, profanity,
--           username_taken
create or replace function public.rename_account(
    p_device_hash  text,
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
    v_err     text;
begin
    select id into v_account from public.accounts where device_hash = p_device_hash for update;
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_err := public._username_error(v_name);
    if v_err is not null then
        return json_build_object('error', v_err);
    end if;

    if exists (
        select 1 from public.accounts
        where lower(username) = lower(v_name) and id <> v_account
    ) then
        return json_build_object('error', 'username_taken');
    end if;

    begin
        update public.accounts set username = v_name where id = v_account;
    exception when unique_violation then
        return json_build_object('error', 'username_taken');
    end;

    return json_build_object('ok', true, 'username', v_name);
end;
$$;
grant execute on function public.rename_account(text, text) to anon, authenticated;
