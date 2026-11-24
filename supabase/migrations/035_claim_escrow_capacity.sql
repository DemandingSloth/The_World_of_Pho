-- ============================================================================
-- Marketplace: capacity-aware claim_escrow (leave what doesn't fit in escrow)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Supersedes claim_escrow from 018.
--
-- WHY: some local stores are capped. Tiles ("tile:*") share the inventory slot
-- pool; seeds ("seed:*") and saplings ("sapling:*") share one garden seed pool.
-- The old claim_escrow handed back (and DELETED) the full escrow quantity
-- regardless of whether the player could hold it, so overflow either vanished
-- or exceeded the cap. It also enabled a dupe: list N (escrow holds N) -> buy N
-- more -> cancel the listing (escrow returns N) -> claim adds all N on top ->
-- 2N owned.
--
-- This version takes the player's free space for each capped POOL as an integer
-- budget. The server walks the caller's capped escrow rows and claims only as
-- much as fits, decrementing the matching pool budget as it goes, and LEAVES
-- the remainder in escrow for a later claim (after the player frees space).
-- Doing the allocation server-side keeps it atomic and correct when several
-- keys share one pool (e.g. two seed types, or seeds + saplings) — the client
-- never needs to know escrow contents ahead of time.
--
-- Pool budgets (NULL = that pool is UNCAPPED this call, claim everything):
--   p_tile_space : free tile inventory slots           (gates "tile:*")
--   p_seed_space : free shared seed+sapling slots       (gates "seed:*","sapling:*")
-- Everything else (gems, fruit, presents, resources, polished, tools, item:*)
-- is uncapped and always claimed in full.
--
-- Still honors p_supported_keys (018): unknown-to-this-build keys stay in escrow.
-- Backward compatible: the 018 (text,text[]) and 007 (text) signatures remain
-- for pre-update clients; both behave as fully-uncapped claims.
--
-- Returns json: { ok, items: [ { item_key, quantity }, ... ] }  (quantity = amount
-- actually claimed this call; may be less than what was in escrow).
-- ============================================================================

create or replace function public.claim_escrow(
    p_device_hash    text,
    p_supported_keys text[],
    p_tile_space     bigint,
    p_seed_space     bigint
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account   uuid;
    v_all       boolean := (p_supported_keys is null or array_length(p_supported_keys, 1) is null);
    v_tile_left bigint  := p_tile_space;   -- NULL = uncapped tiles
    v_seed_left bigint  := p_seed_space;   -- NULL = uncapped seeds+saplings
    v_items     jsonb   := '[]'::jsonb;
    r           record;
    v_take      bigint;
    v_cat       text;
begin
    select id into v_account from public.accounts where device_hash = p_device_hash;
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    -- Walk claimable rows oldest-key-first (deterministic), locking them so a
    -- concurrent claim can't double-count. Allocate each against its pool.
    for r in
        select item_key, quantity
        from public.escrow
        where account_id = v_account and quantity > 0
          and (v_all or item_key = any(p_supported_keys))
        order by item_key
        for update
    loop
        v_cat := split_part(r.item_key, ':', 1);

        if v_cat = 'tile' then
            if v_tile_left is null then
                v_take := r.quantity;                     -- uncapped
            else
                v_take := least(r.quantity, greatest(v_tile_left, 0));
                v_tile_left := v_tile_left - v_take;
            end if;
        elsif v_cat = 'seed' or v_cat = 'sapling' then
            if v_seed_left is null then
                v_take := r.quantity;                     -- uncapped
            else
                v_take := least(r.quantity, greatest(v_seed_left, 0));
                v_seed_left := v_seed_left - v_take;
            end if;
        else
            v_take := r.quantity;                         -- uncapped category
        end if;

        if v_take <= 0 then
            continue;  -- no room this call; row stays in escrow untouched
        end if;

        if v_take >= r.quantity then
            delete from public.escrow
            where account_id = v_account and item_key = r.item_key;
        else
            update public.escrow
            set quantity = quantity - v_take
            where account_id = v_account and item_key = r.item_key;
        end if;

        v_items := v_items || jsonb_build_object('item_key', r.item_key, 'quantity', v_take);
    end loop;

    return json_build_object('ok', true, 'items', v_items);
end;
$$;

grant execute on function public.claim_escrow(text, text[], bigint, bigint) to anon, authenticated;
