-- ============================================================================
-- Migration 047: Community Deep Mine + Warehouse (mining guilds)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Replaces the (stub) community minesweeper for MINING-spec guilds with a shared
-- multi-layer Deep Mine, mirroring the solo DeepMine. Members tap tiles to dig;
-- a dig consumes one of the DIGGING player's shovels (validated client-side, as
-- with the garden's seeds) and may unearth a gem or ore. Unearthed treasure is
-- held "pending" on the tile until collected, then it goes into the guild
-- WAREHOUSE (shared per-guild stock). When every reachable tile+layer is dug and
-- collected, the whole mine regenerates.
--
-- Depth: how DEEP the guild can dig is gated by the 'mine_depth' guild upgrade
-- (bought with upgrade points via the existing purchase_guild_upgrade). Level 0
-- = 1 layer; each level adds one layer up to all 11 at level 10. Deeper layers
-- yield rarer gems, and the bottom 5 layers can yield ores (mirrors solo mine).
--
-- Tables:
--   guild_mine_cells  — per (guild,row,col): how deep it's been dug + any pending
--                       treasure awaiting collection
--   guild_warehouse   — per (guild,item_key): shared gem/ore stock
--
-- RPCs (security definer; anon+authenticated):
--   get_guild_mine(device_hash, guild_id)
--     -> { grid_rows, grid_cols, max_layers, cells:[{row,col,depth,pending}], warehouse:[{item_key,amount}] }
--   dig_guild_mine(device_hash, guild_id, row, col)
--     -> { ok, action:'dig'|'pickup', treasure, depth } | { error }
--   -- (collection is folded into dig: a tap on a tile with pending treasure
--      collects it into the warehouse; otherwise it digs the next layer.)
--
-- The server rolls treasure (authoritative RNG) so the client can't fish for
-- rare drops. Shovel spend is enforced client-side (same trust model as the
-- community garden's seed spend).
-- ============================================================================


-- ── Tables ───────────────────────────────────────────────────────────────────

-- Fixed 10x10 community grid. `depth` = number of layers already dug through at
-- this position (0 = untouched). `pending_treasure` = item id awaiting pickup
-- ('' = none); while non-empty the tile must be collected before digging deeper.
create table if not exists public.guild_mine_cells (
    guild_id          uuid not null references public.guilds(id) on delete cascade,
    row               int  not null,
    col               int  not null,
    depth             int  not null default 0,
    pending_treasure  text not null default '',
    updated_at        timestamptz not null default now(),
    primary key (guild_id, row, col)
);
alter table public.guild_mine_cells enable row level security;

-- Shared guild warehouse: gem/ore stock by canonical item key
-- ('gem:diamond', 'resource:iron_ore', ...).
create table if not exists public.guild_warehouse (
    guild_id   uuid   not null references public.guilds(id) on delete cascade,
    item_key   text   not null,
    amount     bigint not null default 0 check (amount >= 0),
    updated_at timestamptz not null default now(),
    primary key (guild_id, item_key)
);
alter table public.guild_warehouse enable row level security;


-- ── Constants / helpers ───────────────────────────────────────────────────────

-- Grid is a fixed 10x10 for every mining guild.
create or replace function public._guild_mine_grid_rows() returns int
    language sql immutable as $$ select 10; $$;
create or replace function public._guild_mine_grid_cols() returns int
    language sql immutable as $$ select 10; $$;

-- Max reachable layers from the 'mine_depth' upgrade: 1 at level 0, +1 per
-- level, capped at 11 (mirrors solo DeepMine BASE_LAYERS=1, MAX_LAYERS=11).
create or replace function public._guild_mine_max_layers(p_guild_id uuid)
returns int
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_level int := 0;
begin
    select coalesce(level, 0) into v_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'mine_depth';
    return least(1 + coalesce(v_level, 0), 11);
end;
$$;
revoke all on function public._guild_mine_max_layers(uuid) from anon, authenticated;

-- Gem order (common -> rare), index 0..7. Mirrors solo DeepMine.GEM_ORDER.
create or replace function public._guild_mine_gem_order() returns text[]
    language sql immutable as $$
    select array['gold','blue_stone','pink_stone','violet_stone',
                 'black_pearl','emerald','ruby','diamond']; $$;

-- Rolls a treasure for a given 0-based layer index (0 = top). Returns a
-- canonical item key ('gem:<id>' or 'resource:<ore>'), or '' for an empty dig.
-- Mirrors the solo mine: ~40% of layers yield a treasure; deeper = rarer gems;
-- bottom 5 layers can yield ores (iron shallower, copper deeper).
create or replace function public._guild_mine_roll_treasure(p_layer int)
returns text
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_gems       text[] := public._guild_mine_gem_order();
    v_gem_count  int := array_length(v_gems, 1);        -- 8
    v_deepest    int := 10;                             -- bottom layer index (11 layers: 0..10)
    v_ore_min    int := 6;                              -- MAX_LAYERS-5 = 11-5 = 6
    v_find       float := 0.40;                         -- base find chance
    v_ore_chance float;
    v_t          float;
    v_pickable   int;
    v_center     int;
    v_idx        int;
begin
    -- Empty dig?
    if random() >= v_find then
        return '';
    end if;

    -- Ore vs gem on ore-eligible layers (bottom 5).
    if p_layer >= v_ore_min then
        -- Ore chance ramps 0.35 (shallowest ore layer) -> 0.85 (bottom).
        v_t := case when v_deepest > v_ore_min
                    then (p_layer - v_ore_min)::float / (v_deepest - v_ore_min)::float
                    else 1.0 end;
        v_ore_chance := 0.35 + (0.85 - 0.35) * v_t;
        if random() < v_ore_chance then
            -- Copper favors deeper layers; iron the shallower ore layers.
            if random() < (0.15 + 0.70 * v_t) then
                return 'resource:copper_ore';
            else
                return 'resource:iron_ore';
            end if;
        end if;
    end if;

    -- Gem by depth. Top layer -> gold; bottom -> diamond; else spread across the
    -- non-diamond gems with a center near the proportional depth.
    if p_layer <= 0 then
        return 'gem:' || v_gems[1];
    end if;
    if p_layer >= v_deepest then
        return 'gem:' || v_gems[v_gem_count];
    end if;

    v_pickable := v_gem_count - 1;                       -- exclude diamond (indices 1..7 of the array)
    v_center := round((p_layer::float / v_deepest::float) * (v_pickable - 1))::int;
    v_center := least(greatest(v_center, 0), v_pickable - 1);
    -- Simple spread: pick within +/-1 of center (clamped), weighted to center.
    v_idx := v_center + (floor(random() * 3)::int - 1);  -- center-1 .. center+1
    v_idx := least(greatest(v_idx, 0), v_pickable - 1);
    return 'gem:' || v_gems[v_idx + 1];                  -- +1: SQL arrays are 1-based
end;
$$;
revoke all on function public._guild_mine_roll_treasure(int) from anon, authenticated;

-- Warehouse capacity per item key. Flat generous cap for now (reuse the
-- guild_silo_capacity upgrade so investment still helps, like the garden silo).
create or replace function public._guild_warehouse_capacity(p_guild_id uuid)
returns int
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_level int := 0;
begin
    select coalesce(level, 0) into v_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'guild_silo_capacity';
    -- Base 500 + 250 per level (bigger than the garden silo since mining stacks).
    return 500 + coalesce(v_level, 0) * 250;
end;
$$;
revoke all on function public._guild_warehouse_capacity(uuid) from anon, authenticated;


-- ── get_guild_mine ─────────────────────────────────────────────────────────────

create or replace function public.get_guild_mine(
    p_device_hash text,
    p_guild_id    uuid
)
returns json
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_member  public.guild_members%rowtype;
    v_spec    text;
    v_cells   json;
    v_wh      json;
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

    select coalesce(json_agg(json_build_object(
        'row',     gmc.row,
        'col',     gmc.col,
        'depth',   gmc.depth,
        'pending', gmc.pending_treasure
    )), '[]'::json)
    into v_cells
    from public.guild_mine_cells gmc
    where gmc.guild_id = p_guild_id;

    select coalesce(json_agg(json_build_object(
        'item_key', gw.item_key,
        'amount',   gw.amount
    )), '[]'::json)
    into v_wh
    from public.guild_warehouse gw
    where gw.guild_id = p_guild_id and gw.amount > 0;

    return json_build_object(
        'grid_rows',          public._guild_mine_grid_rows(),
        'grid_cols',          public._guild_mine_grid_cols(),
        'max_layers',         public._guild_mine_max_layers(p_guild_id),
        'warehouse_capacity', public._guild_warehouse_capacity(p_guild_id),
        'cells',              v_cells,
        'warehouse',          v_wh
    );
end;
$$;
grant execute on function public.get_guild_mine(text, uuid) to anon, authenticated;


-- ── dig_guild_mine ─────────────────────────────────────────────────────────────
-- A tap on (row,col):
--   • If the tile has pending treasure -> COLLECT it into the warehouse
--     (returns action='pickup'). No shovel.
--   • Else -> DIG the next layer (consumes one shovel, client-side). The server
--     rolls a treasure for that layer; if found it's held pending (returns
--     action='dig', treasure set). If the tile has reached max_layers it can't
--     be dug further.
-- When every reachable tile is fully dug AND has no pending treasure, the whole
-- mine regenerates (all cells reset to depth 0).

create or replace function public.dig_guild_mine(
    p_device_hash text,
    p_guild_id    uuid,
    p_row         int,
    p_col         int
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
    v_remaining  int;
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

        -- Clear the pending flag (collected, or discarded if warehouse full).
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

    -- Roll the treasure for the layer being dug (0-based layer = current depth).
    v_treasure := public._guild_mine_roll_treasure(v_depth);

    -- Advance the cell depth; store any treasure as pending.
    insert into public.guild_mine_cells (guild_id, row, col, depth, pending_treasure, updated_at)
    values (p_guild_id, p_row, p_col, v_depth + 1, v_treasure, now())
    on conflict (guild_id, row, col)
    do update set depth = v_depth + 1, pending_treasure = v_treasure, updated_at = now();

    -- If nothing was found and this dig completed the mine, regenerate.
    if v_treasure = '' then
        perform public._guild_mine_regen_if_done(p_guild_id);
    end if;

    return json_build_object('ok', true, 'action', 'dig',
        'treasure', v_treasure, 'depth', v_depth + 1);
end;
$$;
grant execute on function public.dig_guild_mine(text, uuid, int, int) to anon, authenticated;


-- Regenerates the mine (clears all cells back to depth 0) once every reachable
-- tile is fully dug AND no tile has pending treasure. Internal.
create or replace function public._guild_mine_regen_if_done(p_guild_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_rows       int := public._guild_mine_grid_rows();
    v_cols       int := public._guild_mine_grid_cols();
    v_max_layers int := public._guild_mine_max_layers(p_guild_id);
    v_dug_full   int;
    v_pending    int;
begin
    -- Count cells fully dug to max depth, and any pending treasure.
    select
        count(*) filter (where depth >= v_max_layers),
        count(*) filter (where pending_treasure <> '')
    into v_dug_full, v_pending
    from public.guild_mine_cells
    where guild_id = p_guild_id;

    -- Fully done only when EVERY grid position exists, is dug to max, and nothing
    -- is pending. (A position with no row yet is undug, so not done.)
    if v_dug_full >= (v_rows * v_cols) and coalesce(v_pending, 0) = 0 then
        delete from public.guild_mine_cells where guild_id = p_guild_id;
    end if;
end;
$$;
revoke all on function public._guild_mine_regen_if_done(uuid) from anon, authenticated;
