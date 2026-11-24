-- ============================================================================
-- Migration 097: Gardening guild food recipes
-- ============================================================================
-- Run in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Requires 055 (production), 096 (category column + spec gate).
--
-- Seeds the 13 food recipes into guild_production_recipes with category='recipe'
-- so they are craftable ONLY by gardening guilds (enforced by 096's gate).
-- Each recipe requires 10 of every listed ingredient; craft_seconds = 1800 (30
-- min). output_item_key = 'item:<recipe_id>' (they ride the jewelry produce →
-- collect → guild_jewelry_inventory → storefront loop, same as jewelry).
--
-- MUST stay in lockstep with ITEM_DEFS in player_data.gd and SEED_RECIPES in
-- tests/test_guild_production.gd (the recipe-sync test).
-- ============================================================================

insert into public.guild_production_recipes
    (recipe_id, input_item_key, qty, output_item_key, craft_seconds, category)
values
    -- Sparkling Grape Juice: 10 grapes + 10 lemon
    ('sparkling_grape_juice', 'crop:grapes',  10, 'item:sparkling_grape_juice', 1800, 'recipe'),
    ('sparkling_grape_juice', 'fruit:lemon',  10, 'item:sparkling_grape_juice', 1800, 'recipe'),
    -- Sun-Dried Trail Mix: 10 sunflower + 10 banana
    ('sun_dried_trail_mix',   'crop:sunflower', 10, 'item:sun_dried_trail_mix', 1800, 'recipe'),
    ('sun_dried_trail_mix',   'fruit:banana',   10, 'item:sun_dried_trail_mix', 1800, 'recipe'),
    -- Summer Melon Salad: 10 watermelon + 10 cucumbers + 10 lemon
    ('summer_melon_salad',    'crop:watermelon', 10, 'item:summer_melon_salad', 1800, 'recipe'),
    ('summer_melon_salad',    'crop:cucumbers',  10, 'item:summer_melon_salad', 1800, 'recipe'),
    ('summer_melon_salad',    'fruit:lemon',     10, 'item:summer_melon_salad', 1800, 'recipe'),
    -- Stuffed Roasted Peppers: 10 peppers + 10 beans + 10 squash
    ('stuffed_roasted_peppers', 'crop:peppers', 10, 'item:stuffed_roasted_peppers', 1800, 'recipe'),
    ('stuffed_roasted_peppers', 'crop:beans',   10, 'item:stuffed_roasted_peppers', 1800, 'recipe'),
    ('stuffed_roasted_peppers', 'crop:squash',  10, 'item:stuffed_roasted_peppers', 1800, 'recipe'),
    -- Spiced Plum Jam: 10 plum + 10 peppers
    ('spiced_plum_jam', 'fruit:plum',    10, 'item:spiced_plum_jam', 1800, 'recipe'),
    ('spiced_plum_jam', 'crop:peppers',  10, 'item:spiced_plum_jam', 1800, 'recipe'),
    -- Roasted Cauliflower & Squash Soup: 10 cauliflower + 10 squash
    ('roasted_cauliflower_squash_soup', 'crop:cauliflower', 10, 'item:roasted_cauliflower_squash_soup', 1800, 'recipe'),
    ('roasted_cauliflower_squash_soup', 'crop:squash',      10, 'item:roasted_cauliflower_squash_soup', 1800, 'recipe'),
    -- Smoked Apple Glaze: 10 apple + 10 lemon
    ('smoked_apple_glaze', 'fruit:apple', 10, 'item:smoked_apple_glaze', 1800, 'recipe'),
    ('smoked_apple_glaze', 'fruit:lemon', 10, 'item:smoked_apple_glaze', 1800, 'recipe'),
    -- Tropical Oat & Fruit Mash: 10 pineapple + 10 coconut + 10 banana
    ('tropical_oat_fruit_mash', 'fruit:pineapple', 10, 'item:tropical_oat_fruit_mash', 1800, 'recipe'),
    ('tropical_oat_fruit_mash', 'fruit:coconut',   10, 'item:tropical_oat_fruit_mash', 1800, 'recipe'),
    ('tropical_oat_fruit_mash', 'fruit:banana',    10, 'item:tropical_oat_fruit_mash', 1800, 'recipe'),
    -- Coconut Water Hydration: 10 coconut
    ('coconut_water_hydration', 'fruit:coconut', 10, 'item:coconut_water_hydration', 1800, 'recipe'),
    -- Sweet Banana Crisp: 10 banana + 10 sunflower
    ('sweet_banana_crisp', 'fruit:banana',    10, 'item:sweet_banana_crisp', 1800, 'recipe'),
    ('sweet_banana_crisp', 'crop:sunflower',  10, 'item:sweet_banana_crisp', 1800, 'recipe'),
    -- Citrus Melon Lemonade: 10 lemon + 10 watermelon
    ('citrus_melon_lemonade', 'fruit:lemon',      10, 'item:citrus_melon_lemonade', 1800, 'recipe'),
    ('citrus_melon_lemonade', 'crop:watermelon',  10, 'item:citrus_melon_lemonade', 1800, 'recipe'),
    -- Curried Veggie Bowl: 10 cauliflower + 10 beans + 10 peppers + 10 squash
    ('curried_veggie_bowl', 'crop:cauliflower', 10, 'item:curried_veggie_bowl', 1800, 'recipe'),
    ('curried_veggie_bowl', 'crop:beans',       10, 'item:curried_veggie_bowl', 1800, 'recipe'),
    ('curried_veggie_bowl', 'crop:peppers',     10, 'item:curried_veggie_bowl', 1800, 'recipe'),
    ('curried_veggie_bowl', 'crop:squash',      10, 'item:curried_veggie_bowl', 1800, 'recipe'),
    -- Spiced Pho Noodle Bowl: 10 beans + 10 peppers + 10 cauliflower + 10 lemon
    ('spiced_pho_noodle_bowl', 'crop:beans',       10, 'item:spiced_pho_noodle_bowl', 1800, 'recipe'),
    ('spiced_pho_noodle_bowl', 'crop:peppers',     10, 'item:spiced_pho_noodle_bowl', 1800, 'recipe'),
    ('spiced_pho_noodle_bowl', 'crop:cauliflower', 10, 'item:spiced_pho_noodle_bowl', 1800, 'recipe'),
    ('spiced_pho_noodle_bowl', 'fruit:lemon',      10, 'item:spiced_pho_noodle_bowl', 1800, 'recipe')
on conflict (recipe_id, input_item_key) do update
    set qty = excluded.qty,
        output_item_key = excluded.output_item_key,
        craft_seconds = excluded.craft_seconds,
        category = excluded.category;
