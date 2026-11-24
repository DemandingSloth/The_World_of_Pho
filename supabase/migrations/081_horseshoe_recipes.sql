-- ============================================================================
-- Migration 081: Horseshoe guild-production recipes (Task 11a)
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 055 (guild_production_recipes + enqueue/collect) already applied.
--
-- Horseshoes are guild-produced + storefront-sold EXACTLY like jewelry (they
-- carry `jewelry: true` client-side so the produce → collect → list → buy →
-- claim loop and the `item:<id>` storefront keys all work with zero RPC
-- changes). This migration only SEEDS their production recipes; the equip +
-- race-bonus logic is migration 082.
--
-- Recipes (MUST mirror ITEM_DEFS in player_data.gd — the GDScript test
-- cross-checks). craft_minutes * 60 = craft_seconds:
--   copper_horseshoe : 4 × resource:copper_ingot, 10 min  (lighter → Speed)
--   iron_horseshoe   : 4 × resource:iron_bar,     15 min  (sturdier → Endurance)
--
-- Production is NOT specialization-gated (migration 055's enqueue_production has
-- no spec check), so ANY guild can craft horseshoes — matching jewelry.
-- ============================================================================

insert into public.guild_production_recipes
    (recipe_id, input_item_key, qty, output_item_key, craft_seconds)
values
    ('copper_horseshoe', 'resource:copper_ingot', 4, 'item:copper_horseshoe', 600),
    ('iron_horseshoe',   'resource:iron_bar',     4, 'item:iron_horseshoe',   900)
on conflict (recipe_id, input_item_key) do update
    set qty = excluded.qty,
        output_item_key = excluded.output_item_key,
        craft_seconds = excluded.craft_seconds;
