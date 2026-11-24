-- ============================================================================
-- Marketplace Task 12: price-history daily rollup + get_price_history RPC
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Every completed purchase is already logged in public.purchases. For charting
-- we want compact, stable daily buckets per item rather than scanning raw rows.
--
-- This migration adds:
--   1. price_history_daily  -- one row per (item_key, day): min/max/avg/last
--                              price (volume-weighted avg) + total volume.
--   2. _record_price_point() -- upserts a sale into today's bucket. Called from
--                              buy_listing.
--   3. A backfill from any existing purchases so charts aren't empty.
--   4. get_price_history(item_key, days) -- returns the daily series for a chart.
--
-- Prices here are marketplace-token prices (unit_price from listings).
-- ============================================================================

-- ── 1. Rollup table ──────────────────────────────────────────────────────────
create table if not exists public.price_history_daily (
    item_key    text        not null,
    day         date        not null,
    -- volume-weighted average kept incrementally: avg = sum_price_qty / volume
    sum_price_qty numeric    not null default 0,   -- Σ(unit_price * quantity)
    volume        bigint     not null default 0,   -- Σ quantity
    min_price     bigint     not null,
    max_price     bigint     not null,
    last_price    bigint     not null,
    last_at       timestamptz not null default now(),
    primary key (item_key, day)
);
alter table public.price_history_daily enable row level security;  -- functions only

-- ── 2. Upsert one sale into today's bucket ────────────────────────────────────
-- SECURITY DEFINER + not granted to clients; only server functions call it.
create or replace function public._record_price_point(
    p_item_key text,
    p_unit_price bigint,
    p_quantity int,
    p_at timestamptz default now()
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_day date := (p_at at time zone 'utc')::date;
begin
    insert into public.price_history_daily
        (item_key, day, sum_price_qty, volume, min_price, max_price, last_price, last_at)
    values
        (p_item_key, v_day, p_unit_price::numeric * p_quantity, p_quantity,
         p_unit_price, p_unit_price, p_unit_price, p_at)
    on conflict (item_key, day) do update set
        sum_price_qty = public.price_history_daily.sum_price_qty + (p_unit_price::numeric * p_quantity),
        volume        = public.price_history_daily.volume + p_quantity,
        min_price     = least(public.price_history_daily.min_price, p_unit_price),
        max_price     = greatest(public.price_history_daily.max_price, p_unit_price),
        -- only advance "last" if this sale is at/after the stored last_at
        last_price    = case when p_at >= public.price_history_daily.last_at
                             then p_unit_price else public.price_history_daily.last_price end,
        last_at       = greatest(public.price_history_daily.last_at, p_at);
end;
$$;

revoke all on function public._record_price_point(text, bigint, int, timestamptz) from anon, authenticated;

-- ── 3. Backfill from existing purchases (idempotent-ish) ──────────────────────
-- Rebuild the whole table from purchases so re-running this migration is safe.
truncate public.price_history_daily;
insert into public.price_history_daily
    (item_key, day, sum_price_qty, volume, min_price, max_price, last_price, last_at)
select
    p.item_key,
    (p.created_at at time zone 'utc')::date as day,
    sum(p.unit_price::numeric * p.quantity)  as sum_price_qty,
    sum(p.quantity)                          as volume,
    min(p.unit_price)                        as min_price,
    max(p.unit_price)                        as max_price,
    (array_agg(p.unit_price order by p.created_at desc))[1] as last_price,
    max(p.created_at)                        as last_at
from public.purchases p
group by p.item_key, (p.created_at at time zone 'utc')::date;

-- ── 4. Read RPC for the chart ────────────────────────────────────────────────
-- get_price_history(item_key, days) -> json array, oldest -> newest:
--   [{ day, avg_price, min_price, max_price, last_price, volume }, ...]
-- days is clamped to [1, 90]. Returns only days that had sales.
create or replace function public.get_price_history(
    p_item_key text,
    p_days     int default 30
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
    v_days   int := least(greatest(coalesce(p_days, 30), 1), 90);
    v_cutoff date := (now() at time zone 'utc')::date - (v_days - 1);
    v_result json;
begin
    select coalesce(json_agg(row_to_json(t) order by t.day asc), '[]'::json)
    into v_result
    from (
        select
            h.day,
            round(h.sum_price_qty / nullif(h.volume, 0))::bigint as avg_price,
            h.min_price,
            h.max_price,
            h.last_price,
            h.volume
        from public.price_history_daily h
        where h.item_key = p_item_key and h.day >= v_cutoff
    ) t;

    return v_result;
end;
$$;

grant execute on function public.get_price_history(text, int) to anon, authenticated;
