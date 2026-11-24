-- ============================================================================
-- Migration 096: Guild production specialization gate
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 055 (production) + 081 (horseshoe recipes) + 093 (batch size).
--
-- Gates guild production by the guild's specialization:
--   recipe    recipes  -> only 'gardening' guilds
--   jewelry   recipes  -> only 'mining' guilds
--   horseshoe recipes  -> 'mining' OR 'horse' guilds
--
-- Adds a `category` column to guild_production_recipes (authoritative source),
-- backfills existing rows (horseshoes -> 'horseshoe', everything else ->
-- 'jewelry'; the gardening food recipes added in 097 will set 'recipe'), and
-- supersedes enqueue_production (the 093 version) with a spec check. All other
-- behaviour (batch qty, stock checks, scheduling) is preserved verbatim.
-- ============================================================================


-- ── 1. Category column + backfill ────────────────────────────────────────────
alter table public.guild_production_recipes
    add column if not exists category text not null default 'jewelry';

-- Horseshoes are the only non-jewelry rows at this point.
update public.guild_production_recipes
    set category = 'horseshoe'
    where recipe_id in ('copper_horseshoe', 'iron_horseshoe');

-- Everything else stays 'jewelry' (the default). The 097 migration inserts the
-- food recipes with category='recipe'.


-- ── 2. Specialization gate helper ────────────────────────────────────────────
-- Returns true if a guild with specialization v_spec may craft a recipe of
-- category v_cat.
create or replace function public._guild_spec_can_produce(v_spec text, v_cat text)
returns boolean
language sql
immutable
as $$
    select case v_cat
        when 'recipe'    then v_spec = 'gardening'
        when 'jewelry'   then v_spec = 'mining'
        when 'horseshoe' then v_spec in ('mining', 'horse')
        else false
    end;
$$;
revoke all on function public._guild_spec_can_produce(text, text) from anon, authenticated;


-- ── 3. enqueue_production + spec gate (supersedes 093) ───────────────────────
-- Identical to the 093 version EXCEPT it reads the recipe's category + the
-- guild's specialization and rejects a mismatch with 'wrong_guild_spec'.
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
    v_category  text;
    v_spec      text;
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

    -- Recipe must exist. Read craft time + output + category (same on every row).
    select craft_seconds, output_item_key, category
        into v_craft, v_output, v_category
    from public.guild_production_recipes
    where recipe_id = p_recipe_id
    limit 1;
    if v_craft is null then
        return json_build_object('error', 'invalid_recipe');
    end if;

    -- Specialization gate: the guild must be allowed to craft this category.
    select coalesce(specialization, '') into v_spec
    from public.guilds where id = p_guild_id;
    if not public._guild_spec_can_produce(v_spec, coalesce(v_category, 'jewelry')) then
        return json_build_object('error', 'wrong_guild_spec',
            'category', v_category, 'specialization', v_spec);
    end if;

    -- Clamp qty to [1, batch_size_max].
    v_max_batch := public._guild_production_batch_size(p_guild_id);
    v_qty := greatest(1, least(coalesce(p_qty, 1), v_max_batch));

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
