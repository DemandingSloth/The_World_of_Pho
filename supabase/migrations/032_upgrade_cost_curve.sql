-- ============================================================================
-- Migration 032: steeper guild upgrade cost curve
-- ============================================================================
-- Old: Fibonacci-ish  1 → 2 → 3 → 5 → 8 → 13 → 20 → 30 → 45 → 65
-- New: aggressive     50 → 250 → 1,250 → 5,000 → 15,000 →
--                     50,000 → 150,000 → 300,000 → 600,000 → 1,000,000
-- ============================================================================

create or replace function public._guild_upgrade_cost(p_level int)
returns int
language sql
immutable
security definer
set search_path = public
as $$
    -- 50 → 250 → 1,250 → 5,000 → 15,000 → 50,000 → 150,000 → 300,000 → 600,000 → 1,000,000
    select (array[50, 250, 1250, 5000, 15000, 50000, 150000, 300000, 600000, 1000000])[least(greatest(p_level, 0), 9) + 1];
$$;
revoke all on function public._guild_upgrade_cost(int) from anon, authenticated;
