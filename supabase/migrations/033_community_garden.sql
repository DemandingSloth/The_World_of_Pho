-- ============================================================================
-- Migration 033: Community Guild Garden
-- ============================================================================
-- Adds the shared garden grid and silo storage for gardening-spec guilds.
--
-- Tables:
--   guild_garden_cells  — one row per planted cell in a guild's community garden
--   guild_silo          — per-guild, per-crop silo stock
--
-- RPCs (all security definer, accessible to anon + authenticated):
--   get_guild_garden(p_device_hash, p_guild_id)
--     → { grid: [{row,col,plant_type,plant_time}], silo: [{crop_id,amount}] }
--
--   plant_guild_garden(p_device_hash, p_guild_id, p_row, p_col, p_plant_type)
--     → { ok } or { error }
--     Consumes 1 seed from the calling player's Guild seed reserve (tracked
--     client-side; server just validates cell availability).
--
--   harvest_guild_garden(p_device_hash, p_guild_id, p_row, p_col)
--     → { ok, crop_id, amount, went_to_mission, went_to_silo } or { error }
--     On harvest the crop goes first to any matching active guild mission,
--     remainder fills the silo up to its capacity.
--
-- Error codes shared across RPCs:
--   account_not_found, not_in_guild, not_gardening_guild,
--   cell_out_of_bounds, cell_occupied, cell_empty, not_harvestable,
--   silo_full
-- ============================================================================


-- ── Tables ───────────────────────────────────────────────────────────────────

create table if not exists public.guild_garden_cells (
    id          uuid        primary key default gen_random_uuid(),
    guild_id    uuid        not null references public.guilds(id) on delete cascade,
    row         int         not null,
    col         int         not null,
    plant_type  int         not null,  -- GardenData.PlantType index (0-8)
    plant_time  double precision not null, -- Unix timestamp (seconds)
    planted_by  uuid        references public.accounts(id) on delete set null,
    unique (guild_id, row, col)
);
create index if not exists guild_garden_cells_guild_idx
    on public.guild_garden_cells (guild_id);
alter table public.guild_garden_cells enable row level security;


create table if not exists public.guild_silo (
    guild_id    uuid        not null references public.guilds(id) on delete cascade,
    crop_id     text        not null,  -- e.g. 'beans', 'watermelon'
    amount      int         not null default 0 check (amount >= 0),
    updated_at  timestamptz not null default now(),
    primary key (guild_id, crop_id)
);
alter table public.guild_silo enable row level security;


-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Harvest time (seconds) per plant_type index — mirrors GardenData.PLANT_DEFS.
create or replace function public._guild_garden_harvest_time(p_plant_type int)
returns double precision
language sql
immutable
security definer
set search_path = public
as $$
    select (array[300.0, 600.0, 1200.0, 2400.0, 4800.0,
                  7200.0, 10800.0, 16200.0, 21600.0])[p_plant_type + 1];
$$;
revoke all on function public._guild_garden_harvest_time(int) from anon, authenticated;


-- crop_id string for a plant_type index — mirrors PlayerData.CROP_DEFS.
create or replace function public._guild_garden_crop_id(p_plant_type int)
returns text
language sql
immutable
security definer
set search_path = public
as $$
    select (array['beans','cucumbers','peppers','squash','grapes',
                  'sunflower','cauliflower','pineapple','watermelon'])[p_plant_type + 1];
$$;
revoke all on function public._guild_garden_crop_id(int) from anon, authenticated;


-- Silo capacity = 100 + (guild_silo_capacity upgrade level * 50).
create or replace function public._guild_silo_capacity(p_guild_id uuid)
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
    return 100 + coalesce(v_level, 0) * 50;
end;
$$;
revoke all on function public._guild_silo_capacity(uuid) from anon, authenticated;


-- Grid dimensions for a guild based on community_garden_size upgrade level.
-- Mirrors GuildManager.GARDEN_GRID_LEVELS on the client.
create or replace function public._guild_garden_grid_size(p_guild_id uuid)
returns table(grid_rows int, grid_cols int)
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
    where guild_id = p_guild_id and upgrade_key = 'community_garden_size';
    v_level := coalesce(v_level, 0);

    return query
    select
        (array[5,5,10,10,18,18,27,27,38,38,50])[v_level + 1] as grid_rows,
        (array[5,10,10,18,18,27,27,38,38,50,50])[v_level + 1] as grid_cols;
end;
$$;
revoke all on function public._guild_garden_grid_size(uuid) from anon, authenticated;


-- ── get_guild_garden ──────────────────────────────────────────────────────────

create or replace function public.get_guild_garden(
    p_device_hash text,
    p_guild_id    uuid
)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_member  public.guild_members%rowtype;
    v_spec    text;
    v_grid    json;
    v_silo    json;
    v_cap     int;
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
    if v_spec <> 'gardening' then
        return json_build_object('error', 'not_gardening_guild');
    end if;

    v_cap := public._guild_silo_capacity(p_guild_id);

    select coalesce(json_agg(json_build_object(
        'row',        ggc.row,
        'col',        ggc.col,
        'plant_type', ggc.plant_type,
        'plant_time', ggc.plant_time,
        'planted_by', ggc.planted_by
    )), '[]'::json)
    into v_grid
    from public.guild_garden_cells ggc
    where ggc.guild_id = p_guild_id;

    select coalesce(json_agg(json_build_object(
        'crop_id', gs.crop_id,
        'amount',  gs.amount
    )), '[]'::json)
    into v_silo
    from public.guild_silo gs
    where gs.guild_id = p_guild_id;

    return json_build_object(
        'grid',          v_grid,
        'silo',          v_silo,
        'silo_capacity', v_cap
    );
end;
$$;
grant execute on function public.get_guild_garden(text, uuid) to anon, authenticated;


-- ── plant_guild_garden ────────────────────────────────────────────────────────

create or replace function public.plant_guild_garden(
    p_device_hash text,
    p_guild_id    uuid,
    p_row         int,
    p_col         int,
    p_plant_type  int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_member  public.guild_members%rowtype;
    v_spec    text;
    v_dims    record;
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
    if v_spec <> 'gardening' then
        return json_build_object('error', 'not_gardening_guild');
    end if;

    -- Validate plant_type range.
    if p_plant_type < 0 or p_plant_type > 8 then
        return json_build_object('error', 'invalid_plant_type');
    end if;

    -- Validate cell is within the guild's current grid dimensions.
    select * into v_dims from public._guild_garden_grid_size(p_guild_id);
    if p_row < 0 or p_row >= v_dims.grid_rows
       or p_col < 0 or p_col >= v_dims.grid_cols then
        return json_build_object('error', 'cell_out_of_bounds');
    end if;

    -- Insert; conflict = already occupied.
    insert into public.guild_garden_cells
        (guild_id, row, col, plant_type, plant_time, planted_by)
    values
        (p_guild_id, p_row, p_col, p_plant_type,
         extract(epoch from now()), v_account)
    on conflict (guild_id, row, col) do nothing;

    if not found then
        return json_build_object('error', 'cell_occupied');
    end if;

    return json_build_object('ok', true);
end;
$$;
grant execute on function public.plant_guild_garden(text, uuid, int, int, int) to anon, authenticated;


-- ── harvest_guild_garden ──────────────────────────────────────────────────────

create or replace function public.harvest_guild_garden(
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
    v_account        uuid;
    v_member         public.guild_members%rowtype;
    v_spec           text;
    v_cell           public.guild_garden_cells%rowtype;
    v_harvest_time   double precision;
    v_elapsed        double precision;
    v_crop_id        text;
    v_silo_cap       int;
    v_current_silo   int;
    v_silo_space     int;
    v_mission        record;
    v_new_prog       int;
    v_mission_amount int := 0;
    v_silo_amount    int := 0;
    v_mission_key    text;
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
    if v_spec <> 'gardening' then
        return json_build_object('error', 'not_gardening_guild');
    end if;

    -- Lock and fetch the cell.
    select * into v_cell
    from public.guild_garden_cells
    where guild_id = p_guild_id and row = p_row and col = p_col
    for update;

    if not found then
        return json_build_object('error', 'cell_empty');
    end if;

    -- Check maturity.
    v_harvest_time := public._guild_garden_harvest_time(v_cell.plant_type);
    v_elapsed      := extract(epoch from now()) - v_cell.plant_time;
    if v_elapsed < v_harvest_time then
        return json_build_object('error', 'not_harvestable',
            'remaining', (v_harvest_time - v_elapsed)::int);
    end if;

    v_crop_id := public._guild_garden_crop_id(v_cell.plant_type);

    -- Remove the cell (harvested).
    delete from public.guild_garden_cells
    where guild_id = p_guild_id and row = p_row and col = p_col;

    -- 1. Try to fulfil an active mission first.
    v_mission_key := 'deposit_' || v_crop_id;
    for v_mission in
        select id, target, progress
        from public.guild_missions
        where guild_id         = p_guild_id
          and base_mission_key = v_mission_key
          and status           = 'active'
        for update
        limit 1
    loop
        v_mission_amount := 1;

        -- Upsert contribution row.
        insert into public.guild_contributions
            (mission_id, account_id, amount, updated_at)
        values
            (v_mission.id, v_account, 1, now())
        on conflict (mission_id, account_id)
        do update set
            amount     = public.guild_contributions.amount + 1,
            updated_at = now();

        -- Advance mission progress.
        v_new_prog := least(v_mission.progress + 1, v_mission.target);
        update public.guild_missions
        set progress = v_new_prog
        where id = v_mission.id;

        if v_new_prog >= v_mission.target then
            perform public._complete_guild_mission(v_mission.id);
        end if;
    end loop;

    -- 2. Remainder (if not taken by a mission) goes to the silo.
    if v_mission_amount = 0 then
        v_silo_cap := public._guild_silo_capacity(p_guild_id);

        select coalesce(amount, 0) into v_current_silo
        from public.guild_silo
        where guild_id = p_guild_id and crop_id = v_crop_id;
        v_current_silo := coalesce(v_current_silo, 0);

        v_silo_space := v_silo_cap - v_current_silo;
        if v_silo_space > 0 then
            v_silo_amount := 1;
            insert into public.guild_silo (guild_id, crop_id, amount, updated_at)
            values (p_guild_id, v_crop_id, 1, now())
            on conflict (guild_id, crop_id)
            do update set
                amount     = least(public.guild_silo.amount + 1, v_silo_cap),
                updated_at = now();
        end if;
    end if;

    return json_build_object(
        'ok',              true,
        'crop_id',         v_crop_id,
        'went_to_mission', v_mission_amount > 0,
        'went_to_silo',    v_silo_amount > 0
    );
end;
$$;
grant execute on function public.harvest_guild_garden(text, uuid, int, int) to anon, authenticated;


-- ── deposit_silo_to_mission ───────────────────────────────────────────────────
-- Transfers `p_amount` of `p_crop_id` from the guild silo into the active
-- matching mission (if any). Called when the player manually deposits silo stock.

create or replace function public.deposit_silo_to_mission(
    p_device_hash text,
    p_guild_id    uuid,
    p_crop_id     text,
    p_amount      int
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account      uuid;
    v_member       public.guild_members%rowtype;
    v_current_silo int;
    v_deduct       int;
    v_mission      record;
    v_new_prog     int;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then return json_build_object('error', 'account_not_found'); end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    if p_amount <= 0 then return json_build_object('error', 'invalid_amount'); end if;

    -- Lock silo row.
    select coalesce(amount, 0) into v_current_silo
    from public.guild_silo
    where guild_id = p_guild_id and crop_id = p_crop_id
    for update;

    if v_current_silo is null or v_current_silo <= 0 then
        return json_build_object('error', 'silo_empty');
    end if;

    v_deduct := least(p_amount, v_current_silo);

    -- Deduct from silo.
    update public.guild_silo
    set amount = amount - v_deduct, updated_at = now()
    where guild_id = p_guild_id and crop_id = p_crop_id;

    -- Apply to matching active mission.
    for v_mission in
        select id, target, progress
        from public.guild_missions
        where guild_id         = p_guild_id
          and base_mission_key = ('deposit_' || p_crop_id)
          and status           = 'active'
        for update
        limit 1
    loop
        insert into public.guild_contributions
            (mission_id, account_id, amount, updated_at)
        values
            (v_mission.id, v_account, v_deduct, now())
        on conflict (mission_id, account_id)
        do update set
            amount     = public.guild_contributions.amount + v_deduct,
            updated_at = now();

        v_new_prog := least(v_mission.progress + v_deduct, v_mission.target);
        update public.guild_missions
        set progress = v_new_prog
        where id = v_mission.id;

        if v_new_prog >= v_mission.target then
            perform public._complete_guild_mission(v_mission.id);
        end if;
    end loop;

    return json_build_object('ok', true, 'deposited', v_deduct);
end;
$$;
grant execute on function public.deposit_silo_to_mission(text, uuid, text, int) to anon, authenticated;
