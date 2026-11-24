-- ============================================================================
-- Marketplace Task 3: accounts table + register/restore RPC functions
-- ============================================================================
-- Run this in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Design:
--  * The `accounts` table is LOCKED DOWN with Row Level Security so the
--    publishable/anon key CANNOT read or write it directly. All access goes
--    through the SECURITY DEFINER functions below, which validate input and
--    control exactly what is returned.
--  * Identity is device-based: the client sends a salted device hash. No email,
--    no password. A recovery code (returned once, stored only as a hash) lets a
--    player restore their account on a new device.
--  * New accounts start with 2000 tokens (mirrors the game's starting gold).
-- ============================================================================

-- Needed for gen_random_bytes() and crypt()/gen_salt() (password-style hashing).
-- On Supabase, pgcrypto lives in the `extensions` schema, so the functions below
-- include `extensions` in their search_path to find these unqualified.
create extension if not exists pgcrypto with schema extensions;

-- ── accounts table ──────────────────────────────────────────────────────────
create table if not exists public.accounts (
    id            uuid        primary key default gen_random_uuid(),
    device_hash   text        not null unique,
    username      text        not null unique,
    token_balance bigint      not null default 2000,
    recovery_hash text        not null,
    created_at    timestamptz not null default now()
);

-- Lock the table: RLS on, and NO policies => the anon/publishable key gets zero
-- direct access. Only SECURITY DEFINER functions (which run as the table owner)
-- can touch it.
alter table public.accounts enable row level security;
-- (Intentionally no CREATE POLICY statements — direct client access is denied.)

-- ── Helper: generate a random, friendly username ────────────────────────────
-- Form: Adjective + Noun + 3 digits, e.g. "BraveOtter042". Retried on collision
-- by the caller.
create or replace function public._gen_username()
returns text
language plpgsql
as $$
declare
    adjectives text[] := array[
        'Brave','Swift','Clever','Lucky','Mighty','Sly','Bold','Calm','Keen','Wise',
        'Fierce','Jolly','Nimble','Quiet','Royal','Sunny','Witty','Zesty','Cosmic','Frosty'
    ];
    nouns text[] := array[
        'Otter','Falcon','Sloth','Tiger','Panda','Raven','Fox','Wolf','Bear','Hawk',
        'Koala','Lynx','Moose','Newt','Owl','Puma','Quail','Seal','Toad','Yak'
    ];
begin
    return adjectives[1 + floor(random() * array_length(adjectives, 1))::int]
         || nouns[1 + floor(random() * array_length(nouns, 1))::int]
         || lpad(floor(random() * 1000)::int::text, 3, '0');
end;
$$;

-- ── register_account(device_hash) ───────────────────────────────────────────
-- Idempotent-ish: if the device already has an account, returns it WITHOUT a
-- recovery code (the code is only shown once, at first creation). Otherwise
-- creates a new account with a unique username, 2000 tokens, and a fresh
-- recovery code (returned in plaintext ONCE; stored only as a hash).
--
-- Returns json: { id, username, token_balance, recovery_code (nullable), created }
create or replace function public.register_account(p_device_hash text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_existing   public.accounts%rowtype;
    v_username   text;
    v_recovery   text;
    v_tries      int := 0;
    v_id         uuid;
begin
    if p_device_hash is null or length(p_device_hash) < 8 then
        return json_build_object('error', 'invalid_device_hash');
    end if;

    -- Already registered on this device? Return the account, no recovery code.
    select * into v_existing from public.accounts where device_hash = p_device_hash;
    if found then
        return json_build_object(
            'id', v_existing.id,
            'username', v_existing.username,
            'token_balance', v_existing.token_balance,
            'recovery_code', null,
            'created', false
        );
    end if;

    -- Generate a unique username (retry a few times on collision).
    loop
        v_username := public._gen_username();
        exit when not exists (select 1 from public.accounts where username = v_username);
        v_tries := v_tries + 1;
        if v_tries > 10 then
            -- Fall back to a guaranteed-unique suffix.
            v_username := v_username || floor(random() * 100000)::int::text;
            exit;
        end if;
    end loop;

    -- Plaintext recovery code shown once; store only a bcrypt hash of it.
    v_recovery := encode(gen_random_bytes(9), 'base64');
    v_recovery := replace(replace(replace(v_recovery, '/', ''), '+', ''), '=', '');

    insert into public.accounts (device_hash, username, recovery_hash)
    values (p_device_hash, v_username, crypt(v_recovery, gen_salt('bf')))
    returning id into v_id;

    return json_build_object(
        'id', v_id,
        'username', v_username,
        'token_balance', 2000,
        'recovery_code', v_recovery,
        'created', true
    );
end;
$$;

-- ── restore_account(recovery_code) ──────────────────────────────────────────
-- Given a recovery code, finds the matching account and returns it. Does NOT
-- rebind the device here (that's a later step if needed) — it just proves the
-- code is valid and returns the account identity + balance.
--
-- Returns json: { id, username, token_balance } or { error }
create or replace function public.restore_account(p_recovery_code text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_acct public.accounts%rowtype;
begin
    if p_recovery_code is null or length(p_recovery_code) < 4 then
        return json_build_object('error', 'invalid_recovery_code');
    end if;

    -- crypt() with the stored hash as salt recomputes and compares.
    select * into v_acct
    from public.accounts
    where recovery_hash = crypt(p_recovery_code, recovery_hash)
    limit 1;

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

-- ── Grants ──────────────────────────────────────────────────────────────────
-- Allow the anon/publishable role (and authenticated) to CALL the functions,
-- but not touch the table directly. The functions run as definer (table owner).
grant execute on function public.register_account(text) to anon, authenticated;
grant execute on function public.restore_account(text)  to anon, authenticated;
-- Internal helper: no direct client access needed.
revoke all on function public._gen_username() from anon, authenticated;
