-- ============================================================================
-- Migration 048: Upgradeable Community Warehouse capacity (mining guilds)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- Migration 047 shipped the community warehouse with its capacity tied to the
-- gardening-only 'guild_silo_capacity' upgrade, so mining guilds could never
-- raise it. This gives the warehouse its own mining-spec upgrade track,
-- 'warehouse_capacity', bought with upgrade points via purchase_guild_upgrade
-- (which already accepts any key and caps level at 10 — no RPC change needed).
--
-- Capacity: base 500 + 250 per level (level 0 = 500, level 10 = 3000),
-- per item type. Matches the display math added in guild_detail_screen.
-- ============================================================================

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
    where guild_id = p_guild_id and upgrade_key = 'warehouse_capacity';
    -- Base 500 + 250 per level, per item type.
    return 500 + coalesce(v_level, 0) * 250;
end;
$$;
revoke all on function public._guild_warehouse_capacity(uuid) from anon, authenticated;
