-- ============================================================================
-- Marketplace Task 10: claim_escrow — hand escrowed items to the client once
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Items bought (or returned from a cancelled listing) accrue in public.escrow.
-- claim_escrow atomically reads the caller's escrow, DELETES it server-side, and
-- returns the claimed amounts so the client adds them to the local save exactly
-- once. If the client crashes after the server deletes but before adding
-- locally, at most one claim's worth could be lost — acceptable for this game,
-- and rare. (A stricter two-phase claim can be added later if needed.)
--
-- Returns json: { ok, items: [ { item_key, quantity }, ... ] }
-- ============================================================================

create or replace function public.claim_escrow(p_device_hash text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_items   json;
begin
    select id into v_account from public.accounts where device_hash = p_device_hash;
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    -- Atomically capture and remove this account's escrow rows.
    with removed as (
        delete from public.escrow
        where account_id = v_account and quantity > 0
        returning item_key, quantity
    )
    select coalesce(json_agg(json_build_object('item_key', item_key, 'quantity', quantity)), '[]'::json)
    into v_items
    from removed;

    return json_build_object('ok', true, 'items', v_items);
end;
$$;

grant execute on function public.claim_escrow(text) to anon, authenticated;
