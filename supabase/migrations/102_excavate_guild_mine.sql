-- ============================================================================
-- Migration 102: Excavator for the community (guild) Deep Mine
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- excavate_guild_mine(device_hash, guild_id, start_row, row_count, dig_depth)
--
-- One call clears whole rows, mirroring the personal mine's excavator
-- (DeepMine.excavate_row):
--   • Starts at start_row and clears up to row_count consecutive rows that still
--     have a diggable tile (rows with nothing left don't count toward the total).
--   • Tiles holding unbanked treasure are SKIPPED (bank first, same rule as the
--     shovel). Treasure found by the excavator is held as pending, banked later.
--   • Each tile drills down up to dig_depth layers, stopping at the first
--     treasure, with the excavator's rougher 20% find rate (shovel = 40%).
--   • No shovels are used.
--
-- Ownership of the excavator is a LOCAL (client) unlock, like shovels, so the
-- client gates the button; the server only clamps row_count / dig_depth.
--
-- Returns { ok, rows_cleared, tiles,
--           dug:[{row,col,depth,treasure,layers_dug}] } | { error }
-- ============================================================================


-- Treasure roll at an arbitrary find chance. _guild_mine_roll_treasure already
-- applies a 0.40 find check internally, so pre-filter by (find / 0.40) to land
-- on the requested overall chance without duplicating the gem/ore table.
create or replace function public._guild_mine_roll_treasure_at(p_layer int, p_find float)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
begin
    if random() >= least(greatest(p_find, 0.0) / 0.40, 1.0) then
        return '';
    end if;
    return public._guild_mine_roll_treasure(p_layer);
end;
$$;
revoke all on function public._guild_mine_roll_treasure_at(int, float) from anon, authenticated;


create or replace function public.excavate_guild_mine(
    p_device_hash text,
    p_guild_id    uuid,
    p_start_row   int,
    p_row_count   int default 1,
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
    v_find       float := 0.20;      -- excavator find rate (shovel is 0.40)
    v_want_rows  int;
    v_depth_per  int;
    v_cleared    int := 0;
    v_tiles      int := 0;
    v_r          int;
    v_c          int;
    v_row_dug    boolean;
    v_depth      int;
    v_pending    text;
    v_budget     int;
    v_dug        int;
    v_treasure   text;
    v_out        jsonb := '[]'::jsonb;
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

    if p_start_row is null or p_start_row < 0 or p_start_row >= v_rows then
        return json_build_object('error', 'cell_out_of_bounds');
    end if;

    v_max_layers := public._guild_mine_max_layers(p_guild_id);
    v_want_rows  := least(greatest(coalesce(p_row_count, 1), 1), v_rows);
    v_depth_per  := least(greatest(coalesce(p_dig_depth, 1), 1), v_max_layers);

    -- Lock this guild's existing cells so concurrent shovel digs / excavations
    -- serialize against this sweep.
    perform 1 from public.guild_mine_cells
    where guild_id = p_guild_id for update;

    v_r := p_start_row;
    while v_cleared < v_want_rows and v_r < v_rows loop
        v_row_dug := false;
        for v_c in 0 .. v_cols - 1 loop
            select coalesce(depth, 0), coalesce(pending_treasure, '')
            into v_depth, v_pending
            from public.guild_mine_cells
            where guild_id = p_guild_id and row = v_r and col = v_c;
            v_depth   := coalesce(v_depth, 0);
            v_pending := coalesce(v_pending, '');

            -- Skip tiles with unbanked treasure or nothing left to dig.
            if v_pending <> '' or v_depth >= v_max_layers then
                continue;
            end if;

            v_budget   := least(v_depth_per, v_max_layers - v_depth);
            v_dug      := 0;
            v_treasure := '';
            while v_dug < v_budget loop
                v_treasure := public._guild_mine_roll_treasure_at(v_depth + v_dug, v_find);
                v_dug := v_dug + 1;
                exit when v_treasure <> '';
            end loop;

            insert into public.guild_mine_cells (guild_id, row, col, depth, pending_treasure, updated_at)
            values (p_guild_id, v_r, v_c, v_depth + v_dug, v_treasure, now())
            on conflict (guild_id, row, col)
            do update set depth = v_depth + v_dug, pending_treasure = v_treasure, updated_at = now();

            v_tiles   := v_tiles + 1;
            v_row_dug := true;
            v_out := v_out || jsonb_build_object(
                'row', v_r, 'col', v_c, 'depth', v_depth + v_dug,
                'treasure', v_treasure, 'layers_dug', v_dug);
        end loop;
        if v_row_dug then
            v_cleared := v_cleared + 1;
        end if;
        v_r := v_r + 1;
    end loop;

    -- If this sweep finished the whole mine with nothing pending, regenerate.
    perform public._guild_mine_regen_if_done(p_guild_id);

    return json_build_object(
        'ok', true,
        'rows_cleared', v_cleared,
        'tiles', v_tiles,
        'dug', v_out
    );
end;
$$;
grant execute on function public.excavate_guild_mine(text, uuid, int, int, int) to anon, authenticated;
