-- ============================================================================
-- Marketplace: forward-compatible claim_escrow (only claim keys the client knows)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Supersedes claim_escrow from 007.
--
-- WHY: item types are added over time and players are NOT all on the same APK.
-- If an out-of-date client claims escrow containing an item its build doesn't
-- understand, the old function deleted it anyway -> permanent loss. This version
-- lets the client pass the set of item keys it SUPPORTS; only those rows are
-- claimed (deleted + returned). Unknown-to-this-build items STAY in escrow,
-- waiting for a future updated client to claim them. The client also filters
-- listings it doesn't recognize, so it can't buy unknown items in the first
-- place — escrow only holds unknowns from edge cases (e.g. seller cancels a
-- now-newer item), and those are safely preserved.
--
-- Backward compatible: if p_supported_keys is NULL or empty, behaves like the
-- original (claims everything) so pre-update clients keep working.
--
-- Returns json: { ok, items: [ { item_key, quantity }, ... ] }
-- ============================================================================

create or replace function public.claim_escrow(
    p_device_hash text,
    p_supported_keys text[] default null
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_items   json;
    v_all     boolean := (p_supported_keys is null or array_length(p_supported_keys, 1) is null);
begin
    select id into v_account from public.accounts where device_hash = p_device_hash;
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    -- Atomically capture + remove ONLY the escrow rows this client can accept
    -- (or all rows when no supported list was provided). Unknown items are left
    -- in escrow for a later, updated client.
    with removed as (
        delete from public.escrow
        where account_id = v_account and quantity > 0
          and (v_all or item_key = any(p_supported_keys))
        returning item_key, quantity
    )
    select coalesce(json_agg(json_build_object('item_key', item_key, 'quantity', quantity)), '[]'::json)
    into v_items
    from removed;

    return json_build_object('ok', true, 'items', v_items);
end;
$$;

grant execute on function public.claim_escrow(text, text[]) to anon, authenticated;
