-- ============================================================================
-- Migration 095: Batch-plant guild garden
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- batch_plant_guild_garden(device_hash, guild_id, cells)
--
-- Plants multiple cells in one transaction instead of one RPC per cell.
-- The client sends a JSON array of { "row": int, "col": int, "plant_type": int }
-- objects. The server processes them inside a single transaction:
--   • All the same auth / spec checks that plant_guild_garden does.
--   • Each cell is attempted with INSERT ... ON CONFLICT DO NOTHING, so an
--     already-occupied cell is silently skipped (not an error). This makes the
--     call idempotent: if the client fires a row twice only the first write
--     sticks — the second returns the same cell in the "skipped" list.
--   • The whole batch succeeds or fails atomically (any unexpected error rolls
--     everything back). Skipped (occupied) cells do NOT cause a rollback.
--
-- Returns:
--   { ok: true,
--     planted: [{ row, col, plant_type }],   -- cells that were written
--     skipped: [{ row, col }]                 -- cells already occupied
--   }
-- Errors (same codes as plant_guild_garden):
--   account_not_found, not_in_guild, not_gardening_guild,
--   invalid_cells (null / not an array), cell_out_of_bounds
-- ============================================================================

create or replace function public.batch_plant_guild_garden(
    p_device_hash text,
    p_guild_id    uuid,
    p_cells       jsonb      -- [{"row":0,"col":0,"plant_type":2}, ...]
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account   uuid;
    v_member    public.guild_members%rowtype;
    v_spec      text;
    v_grid      record;   -- (rows, cols) from _guild_garden_grid_size
    v_cell      jsonb;
    v_row       int;
    v_col       int;
    v_ptype     int;
    v_inserted  int;
    v_planted   jsonb := '[]'::jsonb;
    v_skipped   jsonb := '[]'::jsonb;
    v_now       double precision;
begin
    -- ── Auth ──────────────────────────────────────────────────────────────────
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    -- ── Specialization check (gardening guilds only) ───────────────────────
    select coalesce(specialization, '') into v_spec
    from public.guilds where id = p_guild_id;
    if v_spec <> 'gardening' then
        return json_build_object('error', 'not_gardening_guild');
    end if;

    -- ── Validate input ────────────────────────────────────────────────────────
    if p_cells is null or jsonb_typeof(p_cells) <> 'array' then
        return json_build_object('error', 'invalid_cells');
    end if;

    -- ── Grid bounds (same helper as plant_guild_garden) ───────────────────────
    select rows, cols into v_grid
    from public._guild_garden_grid_size(p_guild_id);

    v_now := extract(epoch from now());

    -- ── Per-cell inserts ──────────────────────────────────────────────────────
    for v_cell in select * from jsonb_array_elements(p_cells)
    loop
        v_row   := (v_cell->>'row')::int;
        v_col   := (v_cell->>'col')::int;
        v_ptype := (v_cell->>'plant_type')::int;

        -- Bounds check (rather than a hard error, skip out-of-bounds cells
        -- gracefully — the client already validated but this guards against
        -- stale data after a grid-size upgrade).
        if v_row < 0 or v_row >= v_grid.rows or v_col < 0 or v_col >= v_grid.cols then
            v_skipped := v_skipped || jsonb_build_object('row', v_row, 'col', v_col);
            continue;
        end if;

        -- Plant-type sanity (0–8 matching PLANT_DEFS on the client).
        if v_ptype < 0 or v_ptype > 8 then
            v_skipped := v_skipped || jsonb_build_object('row', v_row, 'col', v_col);
            continue;
        end if;

        -- Try insert; silently skip occupied cells (ON CONFLICT DO NOTHING).
        insert into public.guild_garden_cells
            (guild_id, row, col, plant_type, plant_time, planted_by)
        values
            (p_guild_id, v_row, v_col, v_ptype, v_now, v_account)
        on conflict (guild_id, row, col) do nothing;

        get diagnostics v_inserted = row_count;

        if v_inserted > 0 then
            v_planted := v_planted || jsonb_build_object(
                'row', v_row, 'col', v_col, 'plant_type', v_ptype);
        else
            v_skipped := v_skipped || jsonb_build_object('row', v_row, 'col', v_col);
        end if;
    end loop;

    return json_build_object(
        'ok',      true,
        'planted', v_planted,
        'skipped', v_skipped
    );
end;
$$;
grant execute on function public.batch_plant_guild_garden(text, uuid, jsonb) to anon, authenticated;
