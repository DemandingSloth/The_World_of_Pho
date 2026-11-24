-- ============================================================================
-- Marketplace: get_escrow — read-only peek at the caller's held items
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- WHY: escrow is the only place items can exist "invisibly" — a buy that didn't
-- fully fit local storage, a partial cancel's returned portion before it's
-- claimed, or items an out-of-date build can't yet accept. To honor the design
-- rule "a player can always see what they own", the client surfaces escrow in
-- the My Listings tab ("Held items"). This function returns escrow WITHOUT
-- removing anything (claim_escrow is the one that deletes/claims).
--
-- Returns json: { ok, items: [ { item_key, quantity }, ... ] }
-- ============================================================================

create or replace function public.get_escrow(p_device_hash text)
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

    select coalesce(json_agg(json_build_object('item_key', item_key, 'quantity', quantity)
             order by item_key), '[]'::json)
    into v_items
    from public.escrow
    where account_id = v_account and quantity > 0;

    return json_build_object('ok', true, 'items', v_items);
end;
$$;

grant execute on function public.get_escrow(text) to anon, authenticated;
