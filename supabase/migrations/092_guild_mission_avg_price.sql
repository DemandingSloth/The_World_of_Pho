-- ============================================================================
-- Migration 092: Guild deposit missions use AVERAGE item price for generic keys
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 044 (_guild_mission_item_price) applied.
--
-- Previously the generic bucket keys (deposit_produce, deposit_gems, etc.)
-- used the CHEAPEST item in their category for the token-reward calculation
-- (originally intentional — "players may satisfy with cheap items"), but this
-- made generic missions pay far less than their difficulty warranted.
--
-- Now: generic buckets use the AVERAGE price across all items they accept.
--
--   deposit_produce  (all 9 crops + 5 fruits, avg ≈ 64)
--   deposit_fruit    (5 orchard fruits, avg = 151)
--   deposit_gems     (8 unpolished gems, avg = 19)
--   deposit_polished (7 polished gems, avg = 201)
--   deposit_ores     (5 ores/bars/ingots, avg = 886)
--
-- Per-item keys (deposit_beans, deposit_gem_ruby, etc.) are unchanged because
-- they already use the exact price of the single item they ask for.
-- ============================================================================

create or replace function public._guild_mission_item_price(p_key text)
returns int
language sql
immutable
security definer
set search_path = public
as $$
    select coalesce((
        select price from (values
            -- Generic buckets → AVERAGE price across all accepted items.
            -- deposit_produce: 9 crops (2+5+7+12+16+20+24+27+31=144) +
            --                  5 fruits (51+101+151+201+251=755) = 899/14 ≈ 64
            ('deposit_produce',    64),
            -- deposit_fruit: 5 orchard fruits (51+101+151+201+251)/5 = 151
            ('deposit_fruit',      151),
            -- deposit_gems: 8 unpolished (6+8+8+11+16+21+31+51)/8 = 19
            ('deposit_gems',       19),
            -- deposit_polished: 7 polished (76+76+101+151+201+301+501)/7 = 201
            ('deposit_polished',   201),
            -- deposit_ores: 5 ores/bars (76+751+101+1001+2501)/5 = 886
            ('deposit_ores',       886),

            -- Per unpolished gem (unchanged — single item, exact price)
            ('deposit_gem_gold',          6),
            ('deposit_gem_blue_stone',    8),
            ('deposit_gem_pink_stone',    8),
            ('deposit_gem_violet_stone',  11),
            ('deposit_gem_black_pearl',   16),
            ('deposit_gem_emerald',       21),
            ('deposit_gem_ruby',          31),
            ('deposit_gem_diamond',       51),

            -- Per polished gem (unchanged)
            ('deposit_polished_blue_stone',   76),
            ('deposit_polished_pink_stone',   76),
            ('deposit_polished_violet_stone', 101),
            ('deposit_polished_black_pearl',  151),
            ('deposit_polished_emerald',      201),
            ('deposit_polished_ruby',         301),
            ('deposit_polished_diamond',      501),

            -- Per ore / bar / ingot (unchanged)
            ('deposit_ore_iron_ore',      76),
            ('deposit_ore_iron_bar',      751),
            ('deposit_ore_copper_ore',    101),
            ('deposit_ore_copper_ingot',  1001),
            ('deposit_ore_gold_ingot',    2501),

            -- Per garden crop (unchanged)
            ('deposit_beans',        2),
            ('deposit_cucumbers',    5),
            ('deposit_peppers',      7),
            ('deposit_squash',       12),
            ('deposit_grapes',       16),
            ('deposit_sunflower',    20),
            ('deposit_cauliflower',  24),
            ('deposit_pineapple',    27),
            ('deposit_watermelon',   31),

            -- Per orchard fruit (unchanged)
            ('deposit_plum',     51),
            ('deposit_lemon',    101),
            ('deposit_apple',    151),
            ('deposit_banana',   201),
            ('deposit_coconut',  251)
        ) as t(key, price)
        where t.key = p_key
    ), 0);
$$;
revoke all on function public._guild_mission_item_price(text) from anon, authenticated;
