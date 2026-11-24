-- ============================================================================
-- Migration 055: Guild Production Facility (FIFO queue, consumes stockpile)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- The production facility turns pooled STOCKPILE raw materials (migration 052)
-- into high-tier jewelry (the item: catalog defined client-side in ITEM_DEFS).
-- A member enqueues a recipe; the facility consumes the recipe's inputs from the
-- stockpile atomically and schedules the output to finish after a craft time
-- that scales with the facility's parallelism upgrade. Finished items are
-- collected into the collecting member's escrow (claimed into local inventory).
--
-- RECIPE AUTHORITY (hybrid, user choice 2c): recipes live BOTH in GDScript
-- (ITEM_DEFS, for display) and here in guild_production_recipes (authoritative
-- for consumption + timing). The client passes only a recipe_id; the server
-- reads the inputs/time from this table so a tampered client can't forge a
-- cheaper recipe and drain shared guild stock. A GDScript test cross-checks the
-- two so they can't silently drift.
--
-- STOCKPILE INTERACTION: consumption respects the leader's controls from 052 —
-- it refuses while the stockpile is LOCKED, and never spends RESERVED stock
-- (available = amount - reserved).
--
-- Upgrades (bought with upgrade points via the existing purchase_guild_upgrade,
-- which accepts any key, caps level 10):
--   production_capacity : max items queued at once = 3 + level   (3..13)
--   production_parallel : simultaneous crafts (lanes) = 1 + level (1..11)
-- ============================================================================


-- ── Recipe table (authoritative inputs + craft time) ────────────────────────
-- One row per (recipe_id, input item_key). output_item_key is the produced
-- jewelry key ('item:<id>'); craft_seconds is the base craft time for the whole
-- recipe (same on every input row of a recipe — read once).
create table if not exists public.guild_production_recipes (
    recipe_id        text   not null,          -- jewelry id, e.g. 'emerald_necklace'
    input_item_key   text   not null,          -- canonical stockpile key
    qty              int    not null check (qty > 0),
    output_item_key  text   not null,          -- 'item:<recipe_id>'
    craft_seconds    int    not null check (craft_seconds > 0),
    primary key (recipe_id, input_item_key)
);
alter table public.guild_production_recipes enable row level security;  -- no client policies

-- Seed the 8 jewelry recipes (MUST match ITEM_DEFS in player_data.gd; the
-- GDScript test cross-checks). craft_minutes * 60 = craft_seconds.
insert into public.guild_production_recipes
    (recipe_id, input_item_key, qty, output_item_key, craft_seconds)
values
    -- gold_ring: 20 gem:gold + 5 resource:gold_ingot, 20 min
    ('gold_ring',           'gem:gold',             20, 'item:gold_ring',            1200),
    ('gold_ring',           'resource:gold_ingot',   5, 'item:gold_ring',            1200),
    -- blue_stone_necklace: 15 polished:blue_stone + 5 resource:iron_bar, 30 min
    ('blue_stone_necklace', 'polished:blue_stone',  15, 'item:blue_stone_necklace',  1800),
    ('blue_stone_necklace', 'resource:iron_bar',     5, 'item:blue_stone_necklace',  1800),
    -- pink_stone_necklace: 15 polished:pink_stone + 5 resource:iron_bar, 30 min
    ('pink_stone_necklace', 'polished:pink_stone',  15, 'item:pink_stone_necklace',  1800),
    ('pink_stone_necklace', 'resource:iron_bar',     5, 'item:pink_stone_necklace',  1800),
    -- violet_stone_ring: 12 polished:violet_stone + 5 resource:copper_ingot, 45 min
    ('violet_stone_ring',   'polished:violet_stone',12, 'item:violet_stone_ring',    2700),
    ('violet_stone_ring',   'resource:copper_ingot', 5, 'item:violet_stone_ring',    2700),
    -- black_pearl_necklace: 12 polished:black_pearl + 8 resource:copper_ingot, 60 min
    ('black_pearl_necklace','polished:black_pearl', 12, 'item:black_pearl_necklace', 3600),
    ('black_pearl_necklace','resource:copper_ingot', 8, 'item:black_pearl_necklace', 3600),
    -- emerald_necklace: 10 polished:emerald + 8 resource:gold_ingot, 90 min
    ('emerald_necklace',    'polished:emerald',     10, 'item:emerald_necklace',     5400),
    ('emerald_necklace',    'resource:gold_ingot',   8, 'item:emerald_necklace',     5400),
    -- ruby_ring: 10 polished:ruby + 10 resource:gold_ingot, 120 min
    ('ruby_ring',           'polished:ruby',        10, 'item:ruby_ring',            7200),
    ('ruby_ring',           'resource:gold_ingot',  10, 'item:ruby_ring',            7200),
    -- diamond_ring: 8 polished:diamond + 12 resource:gold_ingot, 180 min
    ('diamond_ring',        'polished:diamond',      8, 'item:diamond_ring',         10800),
    ('diamond_ring',        'resource:gold_ingot',  12, 'item:diamond_ring',         10800)
on conflict (recipe_id, input_item_key) do update
    set qty = excluded.qty,
        output_item_key = excluded.output_item_key,
        craft_seconds = excluded.craft_seconds;


-- ── Production queue ──────────────────────────────────────────────────────────
-- One row per queued/active craft. status: 'active' | 'collected'.
-- finish_at is computed at enqueue from the facility's parallelism (see
-- enqueue_production). A row stays 'active' until collected after finish_at.
create table if not exists public.guild_production_queue (
    id           uuid        primary key default gen_random_uuid(),
    guild_id     uuid        not null references public.guilds(id) on delete cascade,
    recipe_id    text        not null,
    output_item_key text     not null,
    enqueued_at  timestamptz not null default now(),
    finish_at    timestamptz not null,
    status       text        not null default 'active' check (status in ('active', 'collected')),
    enqueued_by  uuid        references public.accounts(id) on delete set null
);
create index if not exists guild_production_queue_guild_active_idx
    on public.guild_production_queue (guild_id) where status = 'active';
alter table public.guild_production_queue enable row level security;  -- no client policies


-- ── Capacity / parallelism helpers ───────────────────────────────────────────
create or replace function public._guild_production_capacity(p_guild_id uuid)
returns int
language plpgsql stable security definer set search_path = public
as $$
declare v_level int := 0;
begin
    select coalesce(level, 0) into v_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'production_capacity';
    return 3 + coalesce(v_level, 0);     -- 3 slots base, up to 13 at level 10
end;
$$;
revoke all on function public._guild_production_capacity(uuid) from anon, authenticated;

create or replace function public._guild_production_parallel(p_guild_id uuid)
returns int
language plpgsql stable security definer set search_path = public
as $$
declare v_level int := 0;
begin
    select coalesce(level, 0) into v_level
    from public.guild_upgrade_levels
    where guild_id = p_guild_id and upgrade_key = 'production_parallel';
    return 1 + coalesce(v_level, 0);     -- 1 lane base, up to 11 at level 10
end;
$$;
revoke all on function public._guild_production_parallel(uuid) from anon, authenticated;


-- ── enqueue_production ────────────────────────────────────────────────────────
-- Any active member may enqueue. Validates the recipe, checks queue capacity,
-- then consumes the recipe inputs from the stockpile ATOMICALLY (refuses if the
-- stockpile is locked or any input lacks enough AVAILABLE = amount-reserved
-- stock), and schedules the craft. finish_at is set from the facility's parallel
-- lanes: the new craft starts when a lane frees up (the parallel-th earliest
-- finish among active crafts), or now() if a lane is idle.
-- Returns { ok, queue_id, finish_at } or { error }.
create or replace function public.enqueue_production(
    p_device_hash text,
    p_guild_id    uuid,
    p_recipe_id   text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account   uuid;
    v_member    public.guild_members%rowtype;
    v_locked    boolean;
    v_craft     int;
    v_output    text;
    v_cap       int;
    v_active    int;
    v_parallel  int;
    v_start     timestamptz;
    v_finish    timestamptz;
    v_id        uuid;
    r           record;
    v_avail     bigint;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    -- Recipe must exist. Read craft time + output (same on every input row).
    select craft_seconds, output_item_key into v_craft, v_output
    from public.guild_production_recipes
    where recipe_id = p_recipe_id
    limit 1;
    if v_craft is null then
        return json_build_object('error', 'invalid_recipe');
    end if;

    -- Stockpile lock blocks spending shared stock.
    select coalesce(stockpile_locked, false) into v_locked from public.guilds where id = p_guild_id;
    if v_locked then
        return json_build_object('error', 'stockpile_locked');
    end if;

    -- Capacity: count active crafts.
    v_cap := public._guild_production_capacity(p_guild_id);
    select count(*) into v_active
    from public.guild_production_queue
    where guild_id = p_guild_id and status = 'active';
    if v_active >= v_cap then
        return json_build_object('error', 'facility_full', 'capacity', v_cap);
    end if;

    -- Verify + lock every input row has enough AVAILABLE (amount - reserved).
    for r in
        select input_item_key, qty
        from public.guild_production_recipes
        where recipe_id = p_recipe_id
    loop
        select coalesce(amount, 0) - coalesce(reserved, 0) into v_avail
        from public.guild_stockpile
        where guild_id = p_guild_id and item_key = r.input_item_key
        for update;
        if coalesce(v_avail, 0) < r.qty then
            return json_build_object('error', 'insufficient_stock',
                'item_key', r.input_item_key, 'need', r.qty, 'have', coalesce(v_avail, 0));
        end if;
    end loop;

    -- All inputs available — deduct them.
    for r in
        select input_item_key, qty
        from public.guild_production_recipes
        where recipe_id = p_recipe_id
    loop
        update public.guild_stockpile
        set amount = amount - r.qty, updated_at = now()
        where guild_id = p_guild_id and item_key = r.input_item_key;
    end loop;

    -- Schedule: start when a lane frees. With v_parallel lanes, the new craft
    -- starts at the v_parallel-th earliest finish among active crafts (0 if a
    -- lane is idle, i.e. active < parallel).
    v_parallel := public._guild_production_parallel(p_guild_id);
    if v_active < v_parallel then
        v_start := now();
    else
        -- The (v_parallel)-th soonest finish_at frees the next lane.
        select finish_at into v_start
        from public.guild_production_queue
        where guild_id = p_guild_id and status = 'active'
        order by finish_at asc
        offset (v_parallel - 1) limit 1;
        if v_start is null or v_start < now() then
            v_start := now();
        end if;
    end if;
    v_finish := v_start + make_interval(secs => v_craft);

    insert into public.guild_production_queue
        (guild_id, recipe_id, output_item_key, finish_at, enqueued_by)
    values (p_guild_id, p_recipe_id, v_output, v_finish, v_account)
    returning id into v_id;

    return json_build_object(
        'ok',        true,
        'queue_id',  v_id,
        'finish_at', extract(epoch from v_finish)
    );
end;
$$;
grant execute on function public.enqueue_production(text, uuid, text) to anon, authenticated;


-- ── get_guild_production ──────────────────────────────────────────────────────
-- Any active member may view. Returns the active queue (with server times) plus
-- the facility's capacity + parallel for the UI.
--   { capacity, parallel, now, items:[{id, recipe_id, output_item_key,
--     enqueued_at, finish_at, ready}] }
create or replace function public.get_guild_production(
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
    v_items   json;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    select coalesce(json_agg(json_build_object(
        'id',              q.id,
        'recipe_id',       q.recipe_id,
        'output_item_key', q.output_item_key,
        'enqueued_at',     extract(epoch from q.enqueued_at),
        'finish_at',       extract(epoch from q.finish_at),
        'ready',           (q.finish_at <= now())
    ) order by q.finish_at asc), '[]'::json)
    into v_items
    from public.guild_production_queue q
    where q.guild_id = p_guild_id and q.status = 'active';

    return json_build_object(
        'capacity', public._guild_production_capacity(p_guild_id),
        'parallel', public._guild_production_parallel(p_guild_id),
        'now',      extract(epoch from now()),
        'items',    v_items
    );
end;
$$;
grant execute on function public.get_guild_production(text, uuid) to anon, authenticated;


-- ── collect_production ────────────────────────────────────────────────────────
-- Any active member may collect. Moves every FINISHED (finish_at <= now) active
-- craft into the COLLECTING member's escrow (claimed into local inventory next
-- marketplace open), marks them 'collected'. Returns { ok, collected:[{item_key,
-- count}], total }.
create or replace function public.collect_production(
    p_device_hash text,
    p_guild_id    uuid
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_account uuid;
    v_member  public.guild_members%rowtype;
    r         record;
    v_counts  jsonb := '{}'::jsonb;
    v_total   int := 0;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    for r in
        select id, output_item_key
        from public.guild_production_queue
        where guild_id = p_guild_id and status = 'active' and finish_at <= now()
        for update
    loop
        perform public._escrow_add(v_account, r.output_item_key, 1);
        update public.guild_production_queue set status = 'collected' where id = r.id;
        v_counts := jsonb_set(
            v_counts,
            array[r.output_item_key],
            to_jsonb(coalesce((v_counts ->> r.output_item_key)::int, 0) + 1)
        );
        v_total := v_total + 1;
    end loop;

    return json_build_object('ok', true, 'collected', v_counts, 'total', v_total);
end;
$$;
grant execute on function public.collect_production(text, uuid) to anon, authenticated;
