-- ============================================================================
-- Migration 093: Guild production batch size upgrade
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 055 (guild_production_queue + enqueue_production + collect) +
--           062 (collect -> guild_jewelry_inventory) applied.
--
-- Adds a BATCH SIZE upgrade: a single production slot can now produce N items
-- in the SAME time that it used to produce 1. The timer is unchanged — you
-- just get more output per slot per craft.
--
--   upgrade key: 'production_batch_size'
--   level 0  →  max batch = 1  (unchanged behaviour)
--   level 1  →  max batch = 10
--   level 2  →  max batch = 50
--   level 3  →  max batch = 100
--   level 4  →  max batch = 250
--   level 5  →  max batch = 500
--   level 6  →  max batch = 1,000
--   level 7  →  max batch = 2,500
--   level 8  →  max batch = 5,000
--   level 9  →  max batch = 7,500
--   level 10 →  max batch = 10,000
--
-- Schema change: `guild_production_queue` gets a `quantity int default 1` column
-- so each slot knows how many items to produce when collected.
--
-- RPC changes:
--   enqueue_production : new p_qty int default 1 param. Multiplies all stockpile
--                        inputs by qty, stores qty on the queue row.
--   collect_production : uses q.quantity instead of hardcoded 1 when crediting
--                        the guild jewelry inventory.
--   get_guild_production: surfaces quantity per queue row.
-- ============================================================================


-- ── 1. Add quantity column to queue ──────────────────────────────────────────
alter table public.guild_production_queue
    add column if not exists quantity int not null default 1 check (quantity >= 1);


-- ── 2. Batch-size helper ─────────────────────────────────────────────────────
create or replace function public._guild_production_batch_size(p_guild_id uuid)
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
    where guild_id = p_guild_id and upgrade_key = 'production_batch_size';
    v_level := coalesce(v_level, 0);
    -- Per-level max batch: [1, 10, 50, 100, 250, 500, 1000, 2500, 5000, 7500, 10000]
    return (array[1, 10, 50, 100, 250, 500, 1000, 2500, 5000, 7500, 10000])[
        least(greatest(v_level, 0), 10) + 1];
end;
$$;
revoke all on function public._guild_production_batch_size(uuid) from anon, authenticated;


-- ── 3. enqueue_production REWORKED: accepts p_qty, multiplies inputs ─────────
-- Supersedes 055's version. Added p_qty int default 1. Validates qty <=
-- _guild_production_batch_size; multiplies every input by qty; stores qty on
-- the queue row. Timer is unchanged (same craft_seconds regardless of qty).
create or replace function public.enqueue_production(
    p_device_hash text,
    p_guild_id    uuid,
    p_recipe_id   text,
    p_qty         int default 1
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
    v_max_batch int;
    v_qty       int;
begin
    v_account := public._guild_resolve_account(p_device_hash);
    if v_account is null then
        return json_build_object('error', 'account_not_found');
    end if;

    v_member := public._guild_active_member(v_account);
    if v_member.id is null or v_member.guild_id <> p_guild_id then
        return json_build_object('error', 'not_in_guild');
    end if;

    -- Clamp qty to [1, batch_size_max].
    v_max_batch := public._guild_production_batch_size(p_guild_id);
    v_qty := greatest(1, least(coalesce(p_qty, 1), v_max_batch));

    select craft_seconds, output_item_key into v_craft, v_output
    from public.guild_production_recipes
    where recipe_id = p_recipe_id
    limit 1;
    if v_craft is null then
        return json_build_object('error', 'invalid_recipe');
    end if;

    select coalesce(stockpile_locked, false) into v_locked from public.guilds where id = p_guild_id;
    if v_locked then
        return json_build_object('error', 'stockpile_locked');
    end if;

    v_cap := public._guild_production_capacity(p_guild_id);
    select count(*) into v_active
    from public.guild_production_queue
    where guild_id = p_guild_id and status = 'active';
    if v_active >= v_cap then
        return json_build_object('error', 'facility_full', 'capacity', v_cap);
    end if;

    -- Verify every input has enough stock (qty × recipe input).
    for r in
        select input_item_key, qty
        from public.guild_production_recipes
        where recipe_id = p_recipe_id
    loop
        select coalesce(amount, 0) - coalesce(reserved, 0) into v_avail
        from public.guild_stockpile
        where guild_id = p_guild_id and item_key = r.input_item_key
        for update;
        if coalesce(v_avail, 0) < r.qty * v_qty then
            return json_build_object('error', 'insufficient_stock',
                'item_key', r.input_item_key,
                'need', r.qty * v_qty,
                'have', coalesce(v_avail, 0));
        end if;
    end loop;

    -- Deduct qty × each input.
    for r in
        select input_item_key, qty
        from public.guild_production_recipes
        where recipe_id = p_recipe_id
    loop
        update public.guild_stockpile
        set amount = amount - (r.qty * v_qty), updated_at = now()
        where guild_id = p_guild_id and item_key = r.input_item_key;
    end loop;

    v_parallel := public._guild_production_parallel(p_guild_id);
    if v_active < v_parallel then
        v_start := now();
    else
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
        (guild_id, recipe_id, output_item_key, finish_at, enqueued_by, quantity)
    values (p_guild_id, p_recipe_id, v_output, v_finish, v_account, v_qty)
    returning id into v_id;

    return json_build_object(
        'ok',        true,
        'queue_id',  v_id,
        'finish_at', extract(epoch from v_finish),
        'quantity',  v_qty
    );
end;
$$;
grant execute on function public.enqueue_production(text, uuid, text, int) to anon, authenticated;


-- ── 4. collect_production REWORKED: uses q.quantity ──────────────────────────
-- Supersedes 062's version. Uses q.quantity instead of 1 when adding to the
-- guild jewelry inventory. Everything else identical.
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
        select id, output_item_key, coalesce(quantity, 1) as qty
        from public.guild_production_queue
        where guild_id = p_guild_id and status = 'active' and finish_at <= now()
        for update
    loop
        -- Credit qty items to the shared guild jewelry pool.
        perform public._guild_jewelry_add(p_guild_id, r.output_item_key, r.qty);
        update public.guild_production_queue set status = 'collected' where id = r.id;
        v_counts := jsonb_set(
            v_counts,
            array[r.output_item_key],
            to_jsonb(coalesce((v_counts ->> r.output_item_key)::int, 0) + r.qty)
        );
        v_total := v_total + r.qty;
    end loop;

    return json_build_object('ok', true, 'collected', v_counts, 'total', v_total);
end;
$$;
grant execute on function public.collect_production(text, uuid) to anon, authenticated;


-- ── 5. get_guild_production REWORKED: surface quantity + batch_size ───────────
-- Supersedes 055's version. Adds quantity per queue row and batch_size to the
-- response so the UI can show "×5" and pre-fill the qty input.
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
        'quantity',        coalesce(q.quantity, 1),
        'enqueued_at',     extract(epoch from q.enqueued_at),
        'finish_at',       extract(epoch from q.finish_at),
        'ready',           (q.finish_at <= now())
    ) order by q.finish_at asc), '[]'::json)
    into v_items
    from public.guild_production_queue q
    where q.guild_id = p_guild_id and q.status = 'active';

    return json_build_object(
        'capacity',   public._guild_production_capacity(p_guild_id),
        'parallel',   public._guild_production_parallel(p_guild_id),
        'batch_size', public._guild_production_batch_size(p_guild_id),
        'now',        extract(epoch from now()),
        'items',      v_items
    );
end;
$$;
grant execute on function public.get_guild_production(text, uuid) to anon, authenticated;
