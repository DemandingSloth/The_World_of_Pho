-- ============================================================================
-- Migration 051: Community mine honors the player's multi-layer dig prestige
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- The solo Deep Mine lets a player's "mine_multi_layer" prestige drill through
-- several layers per shovel in one tap, stopping at the FIRST layer that yields
-- a treasure (empty layers are drilled past for free). The community mine dug
-- exactly one layer per tap, ignoring that prestige.
--
-- dig_guild_mine now takes p_dig_depth (how many layers this player may drill in
-- one dig = 1 + their mine_multi_layer level, passed by the client). A dig
-- drills DOWN from the cell's current depth up to p_dig_depth layers, OR until
-- it unearths a treasure, OR until it hits the guild's unlocked max_layers —
-- whichever comes first. Rarity still keys off the ABSOLUTE layer index, so the
-- guild's unlocked depth still gates how deep (and how rare) anyone can go.
--
-- Backward compatible: p_dig_depth defaults to 1, so an older client (or a
-- pickup tap) behaves exactly as before. Pickups are unchanged.
-- ============================================================================

-- Drop the old 4-arg version from migration 047 so only one dig_guild_mine
-- remains (the new 5-arg one with a default keeps old 4-arg CALLS working).
drop function if exists public.dig_guild_mine(text, uuid, int, int);

create or replace function public.dig_guild_mine(
    p_device_hash text,
    p_guild_id    uuid,
    p_row         int,
    p_col         int,
    p_dig_depth   int default 1
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account    uuid;
    v_member     public.guild_members%rowtype;
    v_spec       text;
    v_rows       int := public._guild_mine_grid_rows();
    v_cols       int := public._guild_mine_grid_cols();
    v_max_layers int;
    v_cell       public.guild_mine_cells%rowtype;
    v_depth      int := 0;
    v_pending    text := '';
    v_treasure   text := '';
    v_cap        int;
    v_cur        bigint;
    v_budget     int;     -- how many layers this dig may still drill
    v_layer      int;     -- absolute layer index being dug (0-based)
    v_dug        int := 0; -- layers actually drilled this dig
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    select specialization into v_spec from public.guilds where id = p_guild_id;
    if v_spec <> 'mining' then
        return json_build_object('error', 'not_mining_guild');
    end if;

    if p_row < 0 or p_row >= v_rows or p_col < 0 or p_col >= v_cols then
        return json_build_object('error', 'cell_out_of_bounds');
    end if;

    v_max_layers := public._guild_mine_max_layers(p_guild_id);

    -- Lock (or create) the cell row.
    select * into v_cell
    from public.guild_mine_cells
    where guild_id = p_guild_id and row = p_row and col = p_col
    for update;

    if found then
        v_depth   := v_cell.depth;
        v_pending := v_cell.pending_treasure;
    end if;

    -- ── Pickup: collect pending treasure into the warehouse. ──────────────────
    if v_pending <> '' then
        v_cap := public._guild_warehouse_capacity(p_guild_id);
        select coalesce(amount, 0) into v_cur
        from public.guild_warehouse
        where guild_id = p_guild_id and item_key = v_pending;
        v_cur := coalesce(v_cur, 0);

        if v_cur < v_cap then
            insert into public.guild_warehouse (guild_id, item_key, amount, updated_at)
            values (p_guild_id, v_pending, 1, now())
            on conflict (guild_id, item_key)
            do update set amount = least(public.guild_warehouse.amount + 1, v_cap),
                          updated_at = now();
        end if;

        update public.guild_mine_cells
        set pending_treasure = '', updated_at = now()
        where guild_id = p_guild_id and row = p_row and col = p_col;

        perform public._guild_mine_regen_if_done(p_guild_id);

        return json_build_object('ok', true, 'action', 'pickup',
            'treasure', v_pending, 'stored', (v_cur < v_cap));
    end if;

    -- ── Dig: must have an undug layer left. ───────────────────────────────────
    if v_depth >= v_max_layers then
        return json_build_object('error', 'fully_dug');
    end if;

    -- Layers this dig may drill: the player's allowance (>=1), capped by how many
    -- unlocked layers remain beneath this cell.
    v_budget := greatest(coalesce(p_dig_depth, 1), 1);
    v_budget := least(v_budget, v_max_layers - v_depth);

    -- Drill down one layer at a time; stop at the first treasure found.
    v_treasure := '';
    while v_dug < v_budget loop
        v_layer := v_depth + v_dug;                 -- absolute 0-based layer
        v_dug := v_dug + 1;
        v_treasure := public._guild_mine_roll_treasure(v_layer);
        exit when v_treasure <> '';                 -- stop at the first treasure
    end loop;

    -- Advance the cell by however many layers were drilled; hold any treasure.
    insert into public.guild_mine_cells (guild_id, row, col, depth, pending_treasure, updated_at)
    values (p_guild_id, p_row, p_col, v_depth + v_dug, v_treasure, now())
    on conflict (guild_id, row, col)
    do update set depth = v_depth + v_dug, pending_treasure = v_treasure, updated_at = now();

    -- If nothing was found and this dig completed the mine, regenerate.
    if v_treasure = '' then
        perform public._guild_mine_regen_if_done(p_guild_id);
    end if;

    return json_build_object('ok', true, 'action', 'dig',
        'treasure', v_treasure, 'depth', v_depth + v_dug, 'layers_dug', v_dug);
end;
$$;
grant execute on function public.dig_guild_mine(text, uuid, int, int, int) to anon, authenticated;
