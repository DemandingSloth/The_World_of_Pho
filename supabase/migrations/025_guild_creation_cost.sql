-- ============================================================================
-- Migration 025: guild creation cost RPC
-- ============================================================================
-- Adds a lightweight public function the client calls before creating a guild
-- to learn how many guilds currently exist and what the creation cost is.
--
-- Cost formula (matches client-side):
--   cost = 1_000_000_000 × (1 + 0.1 × guild_count)
--
-- Returns json: { guild_count: int, cost: float }
-- ============================================================================

create or replace function public.get_guild_creation_cost()
returns json
language sql
stable
security definer
set search_path = public
as $$
    select json_build_object(
        'guild_count', count(*)::int,
        'cost',        (1000000000.0 * (1.0 + 0.1 * count(*)::float))::bigint
    )
    from public.guilds;
$$;
grant execute on function public.get_guild_creation_cost() to anon, authenticated;
