extends Node

## Autoload: PlayerData
## Persistent player profile — name, level, coins, and tile inventory.
## Saved to user://player_save.cfg

const SAVE_PATH := "user://player_save.cfg"
const DEFAULT_NAME := "Player"
const DEFAULT_COINS := 2000
const DEFAULT_LEVEL := 1


## ── Number Formatting ────────────────────────────────────────────
## Formats a Number amount for display. Accepts both int and float.
## Examples: 1500 -> "1,500", 25000 -> "25K", 1500000 -> "1.5M"
static func format_number(amount: Variant) -> String:
	var numeric_val: float = float(amount)
	var negative: bool = numeric_val < 0.0
	var abs_amount: float = abs(numeric_val)
	var result: String

	if abs_amount >= 1_000_000_000_000.0:
		var val: float = abs_amount / 1_000_000_000_000.0
		result = _format_abbreviated(val, "T")
	elif abs_amount >= 1_000_000_000.0:
		var val: float = abs_amount / 1_000_000_000.0
		result = _format_abbreviated(val, "B")
	elif abs_amount >= 1_000_000.0:
		var val: float = abs_amount / 1_000_000.0
		result = _format_abbreviated(val, "M")
	elif abs_amount >= 100_000.0:
		var val: float = abs_amount / 1_000.0
		result = _format_abbreviated(val, "K")
	else:
		result = _add_commas(int(abs_amount))

	if negative:
		return "-" + result
	return result


## Formats a coin amount for display, appending a "c" suffix ONLY when the number
## is NOT abbreviated. Abbreviated values already end in a letter (K/M/B/T), so
## adding "c" (e.g. "250Kc") reads as confusing — those are returned as-is.
## Examples: 1500 -> "1,500c", 250000 -> "250K", 1500000 -> "1.5M".
static func format_coins(amount: Variant) -> String:
	var s := format_number(amount)
	## If it ends in an abbreviation suffix, don't append "c".
	var last := s.substr(s.length() - 1) if s.length() > 0 else ""
	if last in ["K", "M", "B", "T"]:
		return s
	return s + "c"


## Helper: format abbreviated value with 1 decimal place if under 100, otherwise whole number.
static func _format_abbreviated(val: float, suffix: String) -> String:
	if val < 100.0:
		return "%.1f%s" % [val, suffix]
	else:
		return "%d%s" % [int(val), suffix]


## Helper: add commas to numbers under 100K for readability.
static func _add_commas(amount: int) -> String:
	var s: String = str(amount)
	var result: String = ""
	var count: int = 0
	for i in range(s.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			result = "," + result
		result = s[i] + result
		count += 1
	return result
	
## Coin rewards per difficulty
const REWARD_EASY   := 50
const REWARD_MEDIUM := 200
const REWARD_HARD   := 500
const REWARD_BRUTAL := 1200

## Max tiles per purchase
const MAX_PURCHASE_QTY := 50

## Chest level (0-9) at/above which the "hard" chest bonus rewards (saplings +
## prospectors) are granted. 8 = Lv.9 chest and up (the top tier).
const HARD_CHEST_LEVEL := 8

## Max inventory size (base + purchased upgrades)
const BASE_INVENTORY := 50
const STORAGE_UPGRADE_SLOTS := 10  ## Slots per upgrade purchase
const STORAGE_UPGRADE_COST := 1000  ## Coins per upgrade
const MAX_STORAGE_UPGRADES := 100  ## Max purchases (50 + 10*10 = 150 max)
var storage_upgrades: int = 0  ## How many upgrades purchased

## Convenience property for current max inventory (used everywhere)
var MAX_INVENTORY: int:
	get: return BASE_INVENTORY + (storage_upgrades * STORAGE_UPGRADE_SLOTS)

## Autosave interval (seconds)
const AUTOSAVE_INTERVAL := 30.0

signal data_changed
signal save_corrupted

## Flag indicating corruption was detected on last load.
## UI can check this on ready to display a notification to the player.
var corruption_detected: bool = false

## Guards against infinite recursion if the backup save is ALSO corrupt:
## _handle_corrupted_save -> restore backup -> load_data -> corrupt -> ...
var _attempted_backup_restore: bool = false

var player_name: String = DEFAULT_NAME
var level: int = DEFAULT_LEVEL
## Highest level ever reached (a high-water mark). Never decreases when XP is
## spent on prestige — only rises when `level` sets a new record. Shown on the
## home screen as "current/peak".
var peak_level: int = DEFAULT_LEVEL
var coins: int = DEFAULT_COINS
var has_set_name: bool = false  ## True after player sets name on first launch
## True once the online-market Sell tab has shown the new suggested token prices
## once. The FIRST time it's shown, the suggested price overrides any existing
## listing price (a one-time nudge toward the new pricing); after that, an
## existing listing's price auto-fills as normal.
var market_suggested_pricing_seen: bool = false
## Watermark (unix secs) of the newest guild_reward token-ledger entry we've
## already granted XP for. Guild missions pay tokens; we award XP = tokens × 5
## for them exactly once by only counting ledger rows newer than this mark.
var guild_reward_xp_watermark: float = 0.0
var name_changes: int = 0  ## How many times the name has been changed (for scaling cost)

## ── Tutorial State ─────────────────────────────────────────────
var tutorial_completed: bool = false      ## True after tutorial finishes or is skipped
var tutorial_step_index: int = -1         ## Current step (-1 = not started, 0+ = in progress)
var tutorial_home_dismissed: bool = false ## True once the tutorial button on home screen is tapped

## Name change cost (scales 50% per change)
const NAME_CHANGE_BASE_COST := 100000
const NAME_CHANGE_SCALE := 1.5

## Persistent inventory — Array of dictionaries: { "type": Piece.Type, "direction": int }
## We store lightweight data so pieces can be reconstructed
var inventory: Array = []

## Shop pool — randomly generated stock that refreshes every 3 hours.
## Dictionary: { piece_type (int) -> quantity available (int) }
var shop_pool: Dictionary = {}
## Timestamp (Unix) when the current shop pool was generated.
var shop_pool_timestamp: float = 0.0
## Shop pool refresh interval: 3 hours in seconds.
const SHOP_REFRESH_INTERVAL := 10800.0
## Shop pool size range
const SHOP_POOL_MIN := 50
const SHOP_POOL_MAX := 75

## ── Tools ──────────────────────────────────────────────────────
enum ToolType { MAGNIFYING_GLASS, SCYTHE, TRACTOR, SHOVEL }

const TOOL_DEFS: Array[Dictionary] = [
	{ "id": 0, "name": "Magnifying Glass", "description": "Reveals the 3×3 area around a clicked mine tile.", "price": 150,  "weight": 10, "permanent": false, "sprite": "res://Assets/magnify_glass.png" },
	{ "id": 1, "name": "Scythe",           "description": "Harvest a 3×3 square in the garden. Single use.",      "price": 500, "weight": 1,  "permanent": false, "restock_min": 1, "restock_max": 5, "sprite": "res://Assets/Scythe.png"        },
	{ "id": 2, "name": "Tractor",          "description": "Toggle: harvest an entire row in the garden.",      "price": 5000, "weight": 1,  "permanent": true,  "sprite": "res://Assets/tractor.png"       },
	{ "id": 3, "name": "Shovel",           "description": "Remove a planted crop without harvesting. Use in deep mines to dig.",         "price": 10,   "weight": 20, "permanent": false, "sprite": "res://Assets/Shovel.png"        },
]

const TOOL_SHOP_REFRESH_INTERVAL := 10800.0
const TOOL_SHOP_POOL_MIN := 20
const TOOL_SHOP_POOL_MAX := 35
var tool_shop_pool: Dictionary = {}  ## tool id (int) -> quantity
var tool_shop_timestamp: float = 0.0
var tools: Dictionary = {}           ## tool id (int) -> quantity owned

## ── Items ───────────────────────────────────────────────────────
const DIAMOND_RING_SELL_PRICE := 500_000

## ── Jewelry (guild-produced; see JEWELRY_IDS / jewelry helpers) ──────────────
## Each jewelry item is produced by the Guild Production Facility (Stage 3) from
## stockpiled gems + bars (`recipe`: canonical_item_key -> qty), carries a single
## passive `bonus` keyed by gem type (behavior wired in Stage 3b), and sells for
## `sell_price`. `craft_minutes` is the base production time per unit (Stage 3).
## Sprites: only diamond_ring.png exists today; the rest reuse it as a placeholder
## (drop e.g. res://Assets/emerald_necklace.png later and update the path).
## IMPORTANT: jewelry entries carry `jewelry: true` and NO `fruit_index`, so the
## fruit/jewelry split in ItemKeyRegistry keys off those markers (not the index).
const ITEM_DEFS: Array[Dictionary] = [
	{
		"id": "diamond_ring",
		"name": "Diamond Ring",
		"description": "A rare ring that boosts crop growth speed by 25%.",
		"sell_price": 500_000,
		"sprite": "res://Assets/diamond_ring.png",
		"stackable": true,
		"jewelry": true,
		"gem": "diamond",
		"recipe": {"polished:diamond": 8, "resource:gold_ingot": 12},
		"craft_minutes": 180,
		## Existing effect (crop growth speed). The bonus key names the gem-typed
		## effect the Stage-3b resolver applies.
		"effect": "growth_bonus",
		"effect_value": 0.25,
		"bonus": "growth_speed",
		"slot": "ring",
	},
	{
		"id": "gold_ring",
		"name": "Gold Ring",
		"description": "A gleaming gold ring. Boosts all sell values.",
		"sell_price": 250_000,
		"sprite": "res://Assets/gold_ring.png",
		"stackable": true,
		"jewelry": true,
		"gem": "gold",
		## Gold is not polishable, so this uses raw gems.
		"recipe": {"gem:gold": 20, "resource:gold_ingot": 5},
		"craft_minutes": 20,
		"bonus": "all_sell_value",
		"slot": "ring",
	},
	{
		"id": "blue_stone_necklace",
		"name": "Blue Stone Necklace",
		"description": "A cool blue necklace. Improves your luck on chests and gives crops a chance to yield double.",
		"sell_price": 400_000,
		"sprite": "res://Assets/blue_stone_necklace.png",
		"stackable": true,
		"jewelry": true,
		"gem": "blue_stone",
		"recipe": {"polished:blue_stone": 15, "resource:iron_bar": 5},
		"craft_minutes": 30,
		"bonus": "chest_luck",
		"slot": "necklace",
	},
	{
		## ID kept as *_necklace for backend/recipe compatibility (migration 055);
		## the art + player-facing name/slot are a RING (artist's final render).
		"id": "pink_stone_necklace",
		"name": "Pink Stone Ring",
		"description": "A sweet pink ring that sends you loving messages.",
		"sell_price": 400_000,
		"sprite": "res://Assets/polished_pink_stone_ring.png",
		"stackable": true,
		"jewelry": true,
		"gem": "pink_stone",
		"recipe": {"polished:pink_stone": 15, "resource:iron_bar": 5},
		"craft_minutes": 30,
		"bonus": "loving_messages",
		"slot": "ring",
	},
	{
		"id": "violet_stone_ring",
		"name": "Violet Stone Ring",
		"description": "A regal violet ring. Boosts XP gains.",
		"sell_price": 600_000,
		"sprite": "res://Assets/polished_violet_ring.png",
		"stackable": true,
		"jewelry": true,
		"gem": "violet_stone",
		"recipe": {"polished:violet_stone": 12, "resource:copper_ingot": 5},
		"craft_minutes": 45,
		"bonus": "xp_gain",
		"slot": "ring",
	},
	{
		## ID kept as *_necklace for backend/recipe compatibility (migration 055);
		## the art + player-facing name/slot are a RING (artist's final render).
		"id": "black_pearl_necklace",
		"name": "Black Pearl Ring",
		"description": "A lustrous black pearl ring. Boosts the daily bonus.",
		"sell_price": 900_000,
		"sprite": "res://Assets/black_pearl_ring.png",
		"stackable": true,
		"jewelry": true,
		"gem": "black_pearl",
		"recipe": {"polished:black_pearl": 12, "resource:copper_ingot": 8},
		"craft_minutes": 60,
		"bonus": "daily_bonus",
		"slot": "ring",
	},
	{
		"id": "emerald_necklace",
		"name": "Emerald Necklace",
		"description": "A brilliant emerald necklace. Increases coin gains.",
		"sell_price": 1_400_000,
		"sprite": "res://Assets/polished_emerald_necklace.png",
		"stackable": true,
		"jewelry": true,
		"gem": "emerald",
		"recipe": {"polished:emerald": 10, "resource:gold_ingot": 8},
		"craft_minutes": 90,
		"bonus": "coin_gain",
		"slot": "necklace",
	},
	{
		"id": "ruby_ring",
		"name": "Ruby Ring",
		"description": "A fiery ruby ring. Improves odds of finding rarer gems.",
		"sell_price": 2_500_000,
		"sprite": "res://Assets/polished_ruby_ring.png",
		"stackable": true,
		"jewelry": true,
		"gem": "ruby",
		"recipe": {"polished:ruby": 10, "resource:gold_ingot": 10},
		"craft_minutes": 120,
		"bonus": "rarer_gems",
		"slot": "ring",
	},
	{
		## HORSESHOES — guild-produced + storefront-sold like jewelry (so they
		## carry `jewelry: true` for the produce→list→buy→claim loop), but their
		## `slot` is "horse" (NOT ring/necklace), so they do NOT occupy the three
		## jewelry equip slots. They equip to a HORSE (server-side, migration 082)
		## and boost that horse's race stats, scaled by how many you OWN (same
		## count→level curve as jewelry bonuses). Copper = lighter = SPEED; iron =
		## sturdier = ENDURANCE.
		"id": "copper_horseshoe",
		"name": "Copper Horseshoe",
		"description": "A light copper shoe. Equipped to a horse, it boosts its race Speed and raises the most Sprint training can earn (stronger the more you own).",
		"sell_price": 300_000,
		"sprite": "res://Assets/copper_ingot.png",
		"stackable": true,
		"jewelry": true,
		"horseshoe": true,
		"horse_stat": "speed",
		"slot": "horse",
		"recipe": {"resource:copper_ingot": 4},
		"craft_minutes": 10,
	},
	{
		"id": "iron_horseshoe",
		"name": "Iron Horseshoe",
		"description": "A sturdy iron shoe. Equipped to a horse, it boosts its race Endurance and raises the most Hurdle training can earn (stronger the more you own).",
		"sell_price": 300_000,
		"sprite": "res://Assets/iron_bar.png",
		"stackable": true,
		"jewelry": true,
		"horseshoe": true,
		"horse_stat": "endurance",
		"slot": "horse",
		"recipe": {"resource:iron_bar": 4},
		"craft_minutes": 15,
	},
	## ── Food Recipes (gardening-guild produced; USED locally for a timed boost) ──
	## These ride the guild produce→collect→storefront loop (jewelry:true) but are
	## NOT wearable — recipe_item:true + category:"recipe" mark them so they're
	## gated to gardening guilds (migration 096) and surfaced in the Food tab.
	## Each requires 10 of every ingredient. craft_minutes=30 (= craft_seconds
	## 1800 in migration 097). token_value = Σ(ingredient token value) × 10 — the
	## storefront recommended price; sell_price (coins) = token_value × 100.
	## `boost`: {effect, value, duration (sec)} or {effect, value, uses (count)}.
	{
		"id": "sparkling_grape_juice", "name": "Sparkling Grape Juice",
		"description": "Crisp, bubbly, and refreshing. +20% chance to double-harvest crops for 30 min.",
		"sell_price": 115_000, "token_value": 1_150,
		"sprite": "res://Assets/Recipes/sparkling_grape_juice.png",
		"stackable": true, "jewelry": true, "recipe_item": true, "category": "recipe",
		"recipe": {"crop:grapes": 10, "fruit:lemon": 10}, "craft_minutes": 30,
		"boost": {"effect": "double_crop_chance", "value": 0.20, "duration": 1800},
	},
	{
		"id": "sun_dried_trail_mix", "name": "Sun-Dried Trail Mix",
		"description": "Crunchy energy snack. Newly planted crops grow 15% faster for 45 min.",
		"sell_price": 219_000, "token_value": 2_190,
		"sprite": "res://Assets/Recipes/sun_dried_trail_mix.png",
		"stackable": true, "jewelry": true, "recipe_item": true, "category": "recipe",
		"recipe": {"crop:sunflower": 10, "fruit:banana": 10}, "craft_minutes": 30,
		"boost": {"effect": "fast_sprout", "value": 0.15, "duration": 2700},
	},
	{
		"id": "summer_melon_salad", "name": "Summer Melon Salad",
		"description": "Light and hydrating. +1 guaranteed extra crop per harvested tile for 20 min.",
		"sell_price": 134_000, "token_value": 1_340,
		"sprite": "res://Assets/Recipes/summer_melon_salad.png",
		"stackable": true, "jewelry": true, "recipe_item": true, "category": "recipe",
		"recipe": {"crop:watermelon": 10, "crop:cucumbers": 10, "fruit:lemon": 10}, "craft_minutes": 30,
		"boost": {"effect": "bountiful_yield", "value": 1, "duration": 1200},
	},
	{
		"id": "stuffed_roasted_peppers", "name": "Stuffed Roasted Peppers",
		"description": "Hearty and spicy. Prevents fails in Mining Expeditions for 20 min.",
		"sell_price": 18_000, "token_value": 180,
		"sprite": "res://Assets/Recipes/stuffed_roasted_peppers.png",
		"stackable": true, "jewelry": true, "recipe_item": true, "category": "recipe",
		"recipe": {"crop:peppers": 10, "crop:beans": 10, "crop:squash": 10}, "craft_minutes": 30,
		"boost": {"effect": "miner_stamina", "value": 1, "duration": 1200},
	},
	{
		"id": "spiced_plum_jam", "name": "Spiced Plum Jam",
		"description": "A sweet spread with a kick. +15% chance of rare raw gems, ores, or Black Pearls for 1 hr.",
		"sell_price": 56_000, "token_value": 560,
		"sprite": "res://Assets/Recipes/spicy_plum_jam.png",
		"stackable": true, "jewelry": true, "recipe_item": true, "category": "recipe",
		"recipe": {"fruit:plum": 10, "crop:peppers": 10}, "craft_minutes": 30,
		"boost": {"effect": "deep_prospector", "value": 0.15, "duration": 3600},
	},
	{
		"id": "roasted_cauliflower_squash_soup", "name": "Roasted Cauliflower & Squash Soup",
		"description": "Warm comfort food that sharpens focus. −25% Gem Saw processing time for 30 min.",
		"sell_price": 34_000, "token_value": 340,
		"sprite": "res://Assets/Recipes/roasted_cauliflower_and_squash_soup.png",
		"stackable": true, "jewelry": true, "recipe_item": true, "category": "recipe",
		"recipe": {"crop:cauliflower": 10, "crop:squash": 10}, "craft_minutes": 30,
		"boost": {"effect": "precision_cutting", "value": 0.25, "duration": 1800},
	},
	{
		"id": "smoked_apple_glaze", "name": "Smoked Apple Glaze",
		"description": "A sweet, tangy glaze for workshop stamina. −20% Foundry smelting time for 45 min.",
		"sell_price": 250_000, "token_value": 2_500,
		"sprite": "res://Assets/Recipes/smoked_apple_glaze.png",
		"stackable": true, "jewelry": true, "recipe_item": true, "category": "recipe",
		"recipe": {"fruit:apple": 10, "fruit:lemon": 10}, "craft_minutes": 30,
		"boost": {"effect": "furnace_fuel", "value": 0.20, "duration": 2700},
	},
	{
		"id": "tropical_oat_fruit_mash", "name": "Tropical Oat & Fruit Mash",
		"description": "A favorite treat. +25% XP & stat gains from Speed/Endurance training for 15 min.",
		"sell_price": 476_000, "token_value": 4_760,
		"sprite": "res://Assets/Recipes/tropical_oat_and_fruit_mash.png",
		"stackable": true, "jewelry": true, "recipe_item": true, "category": "recipe",
		"recipe": {"fruit:pineapple": 10, "fruit:coconut": 10, "fruit:banana": 10}, "craft_minutes": 30,
		"boost": {"effect": "equestrian_spark", "value": 0.25, "duration": 900},
	},
	{
		"id": "coconut_water_hydration", "name": "Coconut Water Hydration",
		"description": "Pure, electrolyte-packed coconut water. Grooming gives +50% life/vitality recovery for 1 hr.",
		"sell_price": 250_000, "token_value": 2_500,
		"sprite": "res://Assets/Recipes/coconut_water_hydration.png",
		"stackable": true, "jewelry": true, "recipe_item": true, "category": "recipe",
		"recipe": {"fruit:coconut": 10}, "craft_minutes": 30,
		"boost": {"effect": "grooming_bliss", "value": 0.50, "duration": 3600},
	},
	{
		"id": "sweet_banana_crisp", "name": "Sweet Banana Crisp",
		"description": "Crisp snack packed with natural energy. +10% race prize money (next 3 races).",
		"sell_price": 219_000, "token_value": 2_190,
		"sprite": "res://Assets/Recipes/sweet_banana_crisp.png",
		"stackable": true, "jewelry": true, "recipe_item": true, "category": "recipe",
		"recipe": {"fruit:banana": 10, "crop:sunflower": 10}, "craft_minutes": 30,
		"boost": {"effect": "jockeys_luck", "value": 0.10, "uses": 3},
	},
	{
		"id": "citrus_melon_lemonade", "name": "Citrus Melon Lemonade",
		"description": "Bright and thirst-quenching. +15% high-tier gem drop while panning for 30 min.",
		"sell_price": 130_000, "token_value": 1_300,
		"sprite": "res://Assets/Recipes/citrus_melon_lemonade.png",
		"stackable": true, "jewelry": true, "recipe_item": true, "category": "recipe",
		"recipe": {"fruit:lemon": 10, "crop:watermelon": 10}, "craft_minutes": 30,
		"boost": {"effect": "eagle_eye", "value": 0.15, "duration": 1800},
	},
	{
		"id": "curried_veggie_bowl", "name": "Curried Veggie Bowl",
		"description": "A rich dish that impresses buyers. Double Online Special Mission rewards for 1 hr.",
		"sell_price": 41_000, "token_value": 410,
		"sprite": "res://Assets/Recipes/curried_veggie_bowl.png",
		"stackable": true, "jewelry": true, "recipe_item": true, "category": "recipe",
		"recipe": {"crop:cauliflower": 10, "crop:beans": 10, "crop:peppers": 10, "crop:squash": 10}, "craft_minutes": 30,
		"boost": {"effect": "traders_tongue", "value": 2.0, "duration": 3600},
	},
	{
		"id": "spiced_pho_noodle_bowl", "name": "Spiced Pho Noodle Bowl",
		"description": "A steaming, aromatic bowl that sharpens the mind. +1 to each non-pawn tile placed (next 3 Pho games).",
		"sell_price": 130_000, "token_value": 1_300,
		"sprite": "res://Assets/Recipes/spiced_pho_noodle_bowl.png",
		"stackable": true, "jewelry": true, "recipe_item": true, "category": "recipe",
		"recipe": {"crop:beans": 10, "crop:peppers": 10, "crop:cauliflower": 10, "fruit:lemon": 10}, "craft_minutes": 30,
		"boost": {"effect": "pho_focus", "value": 1, "uses": 3},
	},
	{
		"id": "plum",
		"name": "Plum",
		"description": "Sweet and juicy plum harvested from the Orchard.",
		"sell_price": 500,
		"sprite": "res://Assets/Plants/orchard_fruit.png",
		"fruit_index": 0,
		"stackable": true,
	},
	{
		"id": "lemon",
		"name": "Lemon",
		"description": "Bright and tangy lemon harvested from the Orchard.",
		"sell_price": 1000,
		"sprite": "res://Assets/Plants/orchard_fruit.png",
		"fruit_index": 1,
		"stackable": true,
	},
	{
		"id": "apple",
		"name": "Apple",
		"description": "Crisp red apple harvested from the Orchard.",
		"sell_price": 1500,
		"sprite": "res://Assets/Plants/orchard_fruit.png",
		"fruit_index": 2,
		"stackable": true,
	},
	{
		"id": "banana",
		"name": "Banana",
		"description": "Delicious ripe banana harvested from the Orchard.",
		"sell_price": 2000,
		"sprite": "res://Assets/Plants/orchard_fruit.png",
		"fruit_index": 3,
		"stackable": true,
	},
	{
		"id": "coconut",
		"name": "Coconut",
		"description": "Tropical coconut harvested from the Orchard.",
		"sell_price": 2500,
		"sprite": "res://Assets/Plants/orchard_fruit.png",
		"fruit_index": 4,
		"stackable": true,
	},
]

## ── Resource Items (wood, sticks, ores, bars) ───────────────────
## Stored in the same `fruits` item store (a generic item-id -> count map), but
## their sell value scales with a different prestige line depending on
## "value_group": "misc" (wood/sticks) uses misc_value; "gem" (ores/bars/ingots)
## rides the shared gem_profit line. Sprites come from the ores sheet
## (OreSprites), except gold which keeps its Gold Panning sprite.
const RESOURCE_DEFS: Array[Dictionary] = [
	{
		"id": "wood",
		"name": "Wood",
		"description": "Lumber harvested from orchard trees. Craft into sticks or sell.",
		"sell_price": 500,
		"ore_sprite": "wood",
		"value_group": "misc",
	},
	{
		"id": "stick",
		"name": "Stick",
		"description": "Crafted from wood (1 wood -> 2 sticks).",
		"sell_price": 250,
		"ore_sprite": "stick",
		"value_group": "misc",
	},
	{
		"id": "iron_ore",
		"name": "Iron Ore",
		"description": "Raw iron ore. Smelt in the Workshop Foundry into an iron bar.",
		"sell_price": 750,
		"ore_sprite": "iron_ore",
		"value_group": "gem",
	},
	{
		"id": "iron_bar",
		"name": "Iron Bar",
		"description": "Refined iron, smelted from ore in the Foundry.",
		"sell_price": 7_500,
		"ore_sprite": "iron_bar",
		"value_group": "gem",
	},
	{
		"id": "copper_ore",
		"name": "Copper Ore",
		"description": "Raw copper ore. Smelt in the Workshop Foundry into a copper ingot.",
		"sell_price": 1_000,
		"ore_sprite": "copper_ore",
		"value_group": "gem",
	},
	{
		"id": "copper_ingot",
		"name": "Copper Ingot",
		"description": "Refined copper, smelted from ore in the Foundry.",
		"sell_price": 10_000,
		"ore_sprite": "copper_ingot",
		"value_group": "gem",
	},
	{
		"id": "gold_ingot",
		"name": "Gold Ingot",
		"description": "Refined gold, smelted from gold in the Foundry.",
		"sell_price": 25_000,
		"ore_sprite": "gold_ingot",
		"value_group": "gem",
	},
]

## ── Presents (Christmas Conifer output) ─────────────────────────
## Presents are 8 collectible variants. Each SAVE is randomly assigned ONE
## variant (present_variant, 0..7) at first production — the Christmas Conifer
## only ever produces that variant. Presents are stored in the generic `fruits`
## item store under ids "present_0".."present_7". They sell for PRESENT_SELL_VALUE
## and can be USED to grant one random tradeable item each (see use_present).
## Sprite sheet: res://Assets/present.png — 256x106, 8 cells (4 cols x 2 rows),
## each 64x53. Variant index -> (row = idx/4, col = idx%4).
const PRESENT_COUNT := 8
const PRESENT_SELL_VALUE := 500_000
const PRESENT_SHEET_PATH := "res://Assets/present.png"

## The save's assigned present variant (0..7). -1 = not yet assigned; assigned
## on first present production so it's stable for the life of the save.
var present_variant: int = -1

## Item id for a present variant (0..7), e.g. "present_3".
static func present_id(variant: int) -> String:
	return "present_%d" % variant

## True if an item id is a present.
static func is_present_id(item_id: String) -> bool:
	return item_id.begins_with("present_")


## Ore/bar smelting recipes for the Foundry: ore item id -> bar item id.
## Gold is special: the raw material is the gemstone "gold" (not a resource item).
const SMELT_RECIPES := {
	"iron_ore": "iron_bar",
	"copper_ore": "copper_ingot",
}

## Smelted-bar item ids (foundry outputs). Selling any of these credits the
## SELL_BARS mission.
const SMELTED_BAR_IDS: Array[String] = ["iron_bar", "copper_ingot", "gold_ingot"]

var diamond_ring_count: int = 0

## Guild-produced jewelry inventory (everything EXCEPT the diamond ring, which
## keeps its legacy `diamond_ring_count` for save compatibility). Maps jewelry
## id -> count, e.g. { "emerald_necklace": 2 }.
var jewelry: Dictionary = {}

## Food recipe inventory (gardening-guild produced, used locally for a timed
## boost). Maps recipe id -> count. Kept SEPARATE from `jewelry` so wearable /
## equip logic never sees recipes, even though both ride the server produce loop
## and arrive as "item:<id>" escrow claims. Routed here by the market bridge.
var recipes: Dictionary = {}

## ── WonderStone + WonderVessels (local rare material + duplicators) ──────────
## WonderStone: a rare material that drops from Lv10 chests, watermelon harvest,
## and the deepest two deep-mine layers. Spent to craft WonderVessels.
const WONDERSTONE_COIN_VALUE := 1_000_000
const WONDERSTONE_TOKEN_VALUE := 250_000
var wonderstone_count: int = 0

## WonderVessel tiers (index 0 = tier 1). mode: "add" (output = input + n) or
## "mult" (output = input*n + input, i.e. input*(n+1)). x = per-vessel cost unit
## (coins + WonderStones + per-base-resource qty). types = distinct item types
## the vessel can duplicate; cap = max input qty PER type.
const WONDERVESSEL_DEFS: Array[Dictionary] = [
	{"tier": 1,  "x": 1,             "types": 1,  "cap": 1,       "mode": "add",  "n": 1},
	{"tier": 2,  "x": 10,            "types": 2,  "cap": 1,       "mode": "add",  "n": 2},
	{"tier": 3,  "x": 100,           "types": 3,  "cap": 1,       "mode": "add",  "n": 3},
	{"tier": 4,  "x": 1_000,         "types": 1,  "cap": 100,     "mode": "mult", "n": 2},
	{"tier": 5,  "x": 10_000,        "types": 3,  "cap": 150,     "mode": "mult", "n": 2},
	{"tier": 6,  "x": 100_000,       "types": 5,  "cap": 250,     "mode": "mult", "n": 2},
	{"tier": 7,  "x": 1_000_000,     "types": 1,  "cap": 500,     "mode": "mult", "n": 3},
	{"tier": 8,  "x": 10_000_000,    "types": 3,  "cap": 15_000,  "mode": "mult", "n": 3},
	{"tier": 9,  "x": 100_000_000,   "types": 5,  "cap": 100_000, "mode": "mult", "n": 3},
	{"tier": 10, "x": 1_000_000_000, "types": 10, "cap": 1_000_000,"mode": "mult", "n": 5},
]
## tier (int) -> count owned.
var wonder_vessels: Dictionary = {}

## Items that can NEVER be placed in a WonderVessel (unique / special).
const VESSEL_EXCLUDED_KEYS := ["tool:tractor", "item:excavator", "item:benjamin_gun"]

## ── Jewelry count/add/remove (routes diamond_ring to its legacy counter) ─────

func get_jewelry_count(item_id: String) -> int:
	if item_id == "diamond_ring":
		return diamond_ring_count
	return int(jewelry.get(item_id, 0))


func add_jewelry(item_id: String, qty: int = 1) -> void:
	if qty <= 0:
		return
	if item_id == "diamond_ring":
		add_diamond_ring(qty)
		return
	jewelry[item_id] = int(jewelry.get(item_id, 0)) + qty
	save_data()
	data_changed.emit()


func remove_jewelry(item_id: String, qty: int = 1) -> bool:
	if qty <= 0:
		return false
	if item_id == "diamond_ring":
		if diamond_ring_count < qty:
			return false
		diamond_ring_count -= qty
		save_data()
		data_changed.emit()
		return true
	if int(jewelry.get(item_id, 0)) < qty:
		return false
	jewelry[item_id] = int(jewelry[item_id]) - qty
	if jewelry[item_id] <= 0:
		jewelry.erase(item_id)
	save_data()
	data_changed.emit()
	return true


## ── Jewelry equipment slots (Stage 3b) ──────────────────────────
## Three personal equip slots. Only EQUIPPED jewelry grants its bonus; the bonus
## strength scales with how many of that item the player currently HOLDS (see
## the JewelryBonus autoload). Equipping does NOT consume the item — it stays in
## inventory (sellable/tradeable); the bonus reads the live held count and goes
## inactive if the count hits 0. A given jewelry type may occupy only ONE slot.
##   equipped_ring     — a ring-slot jewelry id, or ""
##   equipped_necklace — a necklace-slot jewelry id, or ""
##   equipped_misc     — any jewelry id (ring or necklace), or ""
var equipped_ring: String = ""
var equipped_necklace: String = ""
var equipped_misc: String = ""

signal jewelry_equipment_changed()

## Returns the slot-type a jewelry id belongs to: "ring" | "necklace" | "".
func jewelry_slot_type(item_id: String) -> String:
	return str(get_jewelry_def(item_id).get("slot", ""))


## The three equipped ids as a dict {ring, necklace, misc}.
func equipped_jewelry() -> Dictionary:
	return {"ring": equipped_ring, "necklace": equipped_necklace, "misc": equipped_misc}


## True if a jewelry id is currently equipped in any slot.
func is_jewelry_equipped(item_id: String) -> bool:
	if item_id == "":
		return false
	return item_id == equipped_ring or item_id == equipped_necklace or item_id == equipped_misc


## Equips a jewelry id into a slot ("ring" | "necklace" | "misc"). Validates the
## item exists, is owned (>=1), and fits the slot (ring/necklace slots only take
## their own type; misc takes either). Enforces NO DUPLICATES: if the item is
## already in another slot, it's removed from that slot first. Returns true on
## success. Pass item_id "" to clear the slot.
func equip_jewelry(slot: String, item_id: String) -> bool:
	if slot not in ["ring", "necklace", "misc"]:
		return false

	## Clearing a slot.
	if item_id == "":
		_set_equip_slot(slot, "")
		save_data()
		jewelry_equipment_changed.emit()
		data_changed.emit()
		return true

	if not is_jewelry_id(item_id):
		return false
	if get_jewelry_count(item_id) <= 0:
		return false

	var st := jewelry_slot_type(item_id)
	if slot == "ring" and st != "ring":
		return false
	if slot == "necklace" and st != "necklace":
		return false
	## misc accepts either ring or necklace (st is "ring"/"necklace").

	## No duplicates: if this item is already in a DIFFERENT slot, clear it there.
	if equipped_ring == item_id and slot != "ring":
		equipped_ring = ""
	if equipped_necklace == item_id and slot != "necklace":
		equipped_necklace = ""
	if equipped_misc == item_id and slot != "misc":
		equipped_misc = ""

	_set_equip_slot(slot, item_id)
	save_data()
	jewelry_equipment_changed.emit()
	data_changed.emit()
	return true


func _set_equip_slot(slot: String, item_id: String) -> void:
	match slot:
		"ring":     equipped_ring = item_id
		"necklace": equipped_necklace = item_id
		"misc":     equipped_misc = item_id


## Loads + validates a saved equip-slot id. require_slot_type "" means any
## jewelry (misc slot). Returns "" if the saved value is invalid for the slot.
func _load_equip_slot(config: ConfigFile, key: String, require_slot_type: String) -> String:
	var id := str(config.get_value("items", key, ""))
	if id == "" or not is_jewelry_id(id):
		return ""
	if require_slot_type != "" and jewelry_slot_type(id) != require_slot_type:
		return ""
	return id


## Clears any equipped slot whose item the player no longer owns (count 0).
## Call after a sale/removal so a sold-out item stops granting its bonus.
func prune_equipped_jewelry() -> void:
	var changed := false
	for slot in ["ring", "necklace", "misc"]:
		var id := str(equipped_jewelry()[slot])
		if id != "" and get_jewelry_count(id) <= 0:
			_set_equip_slot(slot, "")
			changed = true
	if changed:
		save_data()
		jewelry_equipment_changed.emit()
		data_changed.emit()


## Money Gun (server-authoritative; mirrored here for synchronous UI gating such
## as the prestige-row visibility). The SERVER owns the real values — these are a
## cache updated by MoneyGun.refresh(). money_gun_owned also persists locally so
## the prestige row can gate before the first server fetch of a session.
var money_gun_owned: bool = false
var money_gun_level: int = 0
## Dictionary: fruit_id (String) -> count (int)
var fruits: Dictionary = {}

## Persisted UI preferences for the Marketplace/Inventory (per-tab qty + sort
## selections), so they survive leaving the screen and app restarts. Keyed by a
## short string like "qty_tiles" / "sort_gems" -> int. Free-form; screens own
## the keys.
var market_prefs: Dictionary = {}

## Reads a saved marketplace UI pref (int) with a default.
func get_market_pref(key: String, default_value: int) -> int:
	return int(market_prefs.get(key, default_value))

## Writes a marketplace UI pref and persists it. No-op if unchanged.
func set_market_pref(key: String, value: int) -> void:
	if int(market_prefs.get(key, -999999999)) == value:
		return
	market_prefs[key] = value
	save_data()

## ── Harvested Crops (garden output) ─────────────────────────────
## Crops are now HELD items: harvesting adds one to this store instead of
## auto-selling. They're sold in the Marketplace, where the garden-profit
## prestige is applied to the sale price (get_crop_sell_value). `base_price` is
## the per-crop sell value at prestige L0 — it equals the crop's old garden
## harvest `reward`, so selling one crop pays exactly what auto-harvest used to.
## `plant_type` matches GardenData.PlantType. `sprite` is the <crop>_collected
## art shown in the Inventory and Marketplace.
const CROP_DEFS: Array[Dictionary] = [
	{ "id": "beans",       "name": "Beans",       "plant_type": 0, "base_price": 15,  "sprite": "res://Assets/Plants/beans_collected.png" },
	{ "id": "cucumbers",   "name": "Cucumbers",   "plant_type": 1, "base_price": 36,  "sprite": "res://Assets/Plants/cucumbers_collected.png" },
	{ "id": "peppers",     "name": "Peppers",     "plant_type": 2, "base_price": 60,  "sprite": "res://Assets/Plants/peppers_collected.png" },
	{ "id": "squash",      "name": "Squash",      "plant_type": 3, "base_price": 105, "sprite": "res://Assets/Plants/Squash_collected.png" },
	{ "id": "grapes",      "name": "Grapes",      "plant_type": 4, "base_price": 150, "sprite": "res://Assets/Plants/grapes_collected.png" },
	{ "id": "sunflower",   "name": "Sunflower",   "plant_type": 5, "base_price": 195, "sprite": "res://Assets/Plants/sunflower_collected.png" },
	{ "id": "cauliflower", "name": "Cauliflower", "plant_type": 6, "base_price": 225, "sprite": "res://Assets/Plants/cauliflower_collected.png" },
	{ "id": "pineapple",   "name": "Pineapple",   "plant_type": 7, "base_price": 264, "sprite": "res://Assets/Plants/pineapple_collected.png" },
	{ "id": "watermelon",  "name": "Watermelon",  "plant_type": 8, "base_price": 300, "sprite": "res://Assets/Plants/Watermelon_collected.png" },
]

## Dictionary: crop_id (String) -> count (int)
var crops: Dictionary = {}

signal diamond_ring_awarded  ## Emitted when a ring drops from harvest


## ── Prospectors ────────────────────────────────────────────────
## Gem types ordered by sell value (cheapest first). Each prospector produces 1 gem/5 min.
const PROSPECTOR_GEM_ORDER: Array = [
	{"gem_type": "gold", "value": 50},
	{"gem_type": "blue_stone", "value": 75},
	{"gem_type": "pink_stone", "value": 75},
	{"gem_type": "violet_stone", "value": 100},
	{"gem_type": "black_pearl", "value": 150},
	{"gem_type": "emerald", "value": 200},
	{"gem_type": "ruby", "value": 300},
	{"gem_type": "diamond", "value": 500},
]

const PROSPECTOR_BASE_COST := 100000        ## Cost of the cheapest (gold) prospector
const PROSPECTOR_TIER_INCREMENT := 50000    ## Each tier costs 50k more
const PROSPECTOR_PRICE_SCALE := 0.15        ## 15% price increase per additional owned
const PROSPECTOR_INTERVAL := 1800.0          ## 30 minutes in seconds
const PROSPECTOR_MAX_OFFLINE := 86400.0     ## 24 hours max offline accrual

## Dictionary: gem_type (String) -> count owned (int)
var prospectors: Dictionary = {}
## Unix timestamp of last prospector collection tick
var prospector_last_tick: float = 0.0

## ── Gemstone Inventory ─────────────────────────────────────────
## Stores gem counts compactly: { "gold": 95, "blue_stone": 12, ... }
## Value per gem is looked up from PROSPECTOR_GEM_ORDER at runtime.
var gemstones: Dictionary = {}  ## gem_type (String) -> count (int)

## Get how many of a gem type the player owns.
func get_gem_count(gem_type: String) -> int:
	return gemstones.get(gem_type, 0)

## Get the sell value for a gem type (from PROSPECTOR_GEM_ORDER).
## Null-safe guild gem-sell perk factor (1.0 when no guild / perk). Applied to
## raw gems, polished gems, and gem-group ores/bars so the guild "Gem Sell
## Value" upgrade actually boosts payouts, not just the display.
func _guild_gem_perk() -> float:
	if get_node_or_null("/root/GuildManager") == null:
		return 1.0
	return GuildManager.gem_sell_perk_mult()


## Equipped-jewelry sell multiplier (gold "all_sell_value" + emerald "coin_gain",
## count-scaled; 1.0 when none equipped). Applied to every sell-value source so
## the bonus shows in both the displayed price and the actual payout. Null-safe.
func _jewelry_sell_mult() -> float:
	if get_node_or_null("/root/JewelryBonus") == null:
		return 1.0
	return JewelryBonus.sell_value_multiplier()


func get_gem_value(gem_type: String) -> int:
	for def in PROSPECTOR_GEM_ORDER:
		if def["gem_type"] == gem_type:
			return int(def["value"] * get_gem_profit_multiplier() * _guild_gem_perk())
	return 0


## Effective COIN sell price of a gem = base value × equipped-jewelry sell
## multiplier. Kept separate from get_gem_value so XP (which uses get_gem_value
## as a "base value") is NOT inflated by the jewelry sell bonus.
func get_gem_sell_price(gem_type: String) -> int:
	return int(get_gem_value(gem_type) * _jewelry_sell_mult())

## Add gems to the compact inventory.
func add_gemstones(gem_type: String, qty: int = 1) -> void:
	gemstones[gem_type] = gemstones.get(gem_type, 0) + qty
	save_data()
	data_changed.emit()
	## Notify MissionBoard regardless of gem source
	for _i in range(qty):
		MissionBoard.on_gem_collected(gem_type)

## Sell one gem. Returns true on success.
func sell_gem(gem_type: String) -> bool:
	if gemstones.get(gem_type, 0) <= 0:
		return false
	## Coins use the jewelry-boosted sell price; XP uses the base value.
	var price := get_gem_sell_price(gem_type)
	var base := get_gem_value(gem_type)
	gemstones[gem_type] -= 1
	if gemstones[gem_type] <= 0:
		gemstones.erase(gem_type)
	coins += price
	award_xp(base / 2)  ## award_xp handles save + level-up + data_changed
	return true

## Sell all gems of a type. Returns count sold.
func sell_all_gems(gem_type: String) -> int:
	var count: int = gemstones.get(gem_type, 0)
	if count <= 0:
		return 0
	var price := get_gem_sell_price(gem_type)
	var base := get_gem_value(gem_type)
	gemstones.erase(gem_type)
	coins += price * count
	award_xp((base * count) / 2)  ## award_xp handles save + level-up + data_changed
	return count


## ── Polished Gems (Workshop saw output) ─────────────────────────
## Gems can be cut/polished in the Workshop saw into a polished version worth
## 10x the base value. Gold is intentionally NOT polishable — it will go to the
## future Foundry (for gold bars) along with ores.
const POLISHED_VALUE_MULTIPLIER := 10

## Gem types that can be polished in the saw (everything except gold).
const POLISHABLE_GEMS: Array[String] = [
	"blue_stone", "pink_stone", "violet_stone",
	"black_pearl", "emerald", "ruby", "diamond",
]

## Polished gem counts: { gem_type -> count }.
var polished_gems: Dictionary = {}

## True if a gem type can be polished (gold cannot).
func is_polishable(gem_type: String) -> bool:
	return POLISHABLE_GEMS.has(gem_type)

func get_polished_gem_count(gem_type: String) -> int:
	return polished_gems.get(gem_type, 0)

## Sell value of a polished gem: 10x the uncut base value, scaled by gem prestige.
func get_polished_gem_value(gem_type: String) -> int:
	for def in PROSPECTOR_GEM_ORDER:
		if def["gem_type"] == gem_type:
			return int(def["value"] * POLISHED_VALUE_MULTIPLIER * get_gem_profit_multiplier() * _guild_gem_perk())
	return 0


## Effective COIN sell price of a polished gem = base value × jewelry sell mult.
## Separate from get_polished_gem_value so XP isn't inflated.
func get_polished_gem_sell_price(gem_type: String) -> int:
	return int(get_polished_gem_value(gem_type) * _jewelry_sell_mult())

func add_polished_gems(gem_type: String, qty: int = 1) -> void:
	if qty <= 0:
		return
	polished_gems[gem_type] = polished_gems.get(gem_type, 0) + qty
	save_data()
	data_changed.emit()

## Sell one polished gem. Returns true on success.
func sell_polished_gem(gem_type: String) -> bool:
	if polished_gems.get(gem_type, 0) <= 0:
		return false
	var price := get_polished_gem_sell_price(gem_type)
	var base := get_polished_gem_value(gem_type)
	polished_gems[gem_type] -= 1
	if polished_gems[gem_type] <= 0:
		polished_gems.erase(gem_type)
	coins += price
	award_xp(base / 2)
	if get_node_or_null("/root/MissionBoard") != null:
		MissionBoard.on_polished_gems_sold(1)
	return true

## Sell all polished gems of a type. Returns count sold.
func sell_all_polished_gems(gem_type: String) -> int:
	var count: int = polished_gems.get(gem_type, 0)
	if count <= 0:
		return 0
	var price := get_polished_gem_sell_price(gem_type)
	var base := get_polished_gem_value(gem_type)
	polished_gems.erase(gem_type)
	coins += price * count
	award_xp((base * count) / 2)
	if get_node_or_null("/root/MissionBoard") != null:
		MissionBoard.on_polished_gems_sold(count)
	return count

## Get how many prospectors the player owns for a gem type.
func get_prospector_count(gem_type: String) -> int:
	return prospectors.get(gem_type, 0)

## Get the base cost for a prospector tier (by gem type index in order).
func get_prospector_tier_cost(gem_type: String) -> int:
	for i in range(PROSPECTOR_GEM_ORDER.size()):
		if PROSPECTOR_GEM_ORDER[i]["gem_type"] == gem_type:
			return PROSPECTOR_BASE_COST + (i * PROSPECTOR_TIER_INCREMENT)
	return PROSPECTOR_BASE_COST

## Get the current purchase price for the next prospector of a given type.
## Price scales by 15% per one already owned.
func get_prospector_price(gem_type: String) -> int:
	var base := get_prospector_tier_cost(gem_type)
	var owned := get_prospector_count(gem_type)
	var price := float(base)
	for j in range(owned):
		price *= (1.0 + PROSPECTOR_PRICE_SCALE)
	price *= get_prospector_cost_multiplier()
	## Guild "Prospector Cost" perk (−5%/level; lower = cheaper).
	if get_node_or_null("/root/GuildManager") != null:
		price *= GuildManager.prospector_cost_perk_mult()
	return int(price)

## Grants prospectors for free (from chest rewards). Unlike buy_prospector,
## no coins are spent and no XP awarded. Still updates achievement tracking.
func add_prospectors(gem_type: String, qty: int = 1) -> void:
	if qty <= 0:
		return
	prospectors[gem_type] = get_prospector_count(gem_type) + qty
	if prospector_last_tick <= 0.0:
		prospector_last_tick = TrustedClock.now()
	save_data()
	data_changed.emit()
	if get_node_or_null("/root/Achievements") != null:
		var total_owned := 0
		for gt in prospectors:
			total_owned += prospectors[gt]
		Achievements.record_prospector_purchase(total_owned)


## Purchase a prospector. Returns true on success.
func buy_prospector(gem_type: String) -> bool:
	var price := get_prospector_price(gem_type)
	if coins < price:
		return false
	coins -= price
	prospectors[gem_type] = get_prospector_count(gem_type) + 1
	if prospector_last_tick <= 0.0:
		prospector_last_tick = TrustedClock.now()
	save_data()
	data_changed.emit()

	# Award XP proportional to the price paid (10% of cost as XP)
	var xp_reward := int(price * 0.1)
	award_xp(xp_reward)

	# Track prospector achievements
	var total_owned := 0
	for gt in prospectors:
		total_owned += prospectors[gt]
	Achievements.record_prospector_purchase(total_owned)

	## Mission tracking: acquiring prospectors (Mines category mission).
	if get_node_or_null("/root/MissionBoard") != null:
		MissionBoard.on_prospector_acquired(1)

	return true

## Seconds until the next prospector production tick.
func get_prospector_next_tick_remaining() -> float:
	var effective_interval: float = maxf(PROSPECTOR_INTERVAL * get_prospector_time_multiplier(), 0.01)
	if prospector_last_tick <= 0.0:
		return effective_interval
	var elapsed := TrustedClock.now() - prospector_last_tick
	if elapsed <= 0.0:
		return effective_interval
	var remainder := fmod(elapsed, effective_interval)
	if remainder <= 0.0:
		return effective_interval
	return effective_interval - remainder


## Advances PlayerData's time-based systems by the given number of hours, used by
## the Workshop hourglass. Shifts timestamps back so elapsed-time calculations
## behave as if that much time passed: prospectors accrue, shop/tool restock
## timers shrink. The daily bonus cooldown is intentionally NOT affected.
## Returns prospector gems collected from the skipped time.
func advance_time_hours(hours: float) -> Dictionary:
	var seconds := hours * 3600.0
	if prospector_last_tick > 0.0:
		prospector_last_tick -= seconds
	if shop_pool_timestamp > 0.0:
		shop_pool_timestamp -= seconds
	if tool_shop_timestamp > 0.0:
		tool_shop_timestamp -= seconds
	## Apply the effects of the skipped time immediately.
	var collected := collect_prospector_gems()
	_check_shop_pool_refresh()
	_check_tool_shop_refresh()
	save_data()
	data_changed.emit()
	return collected


## Collect offline/accumulated prospector gems. Call on app start or screen enter.
## Returns the total gems added (Dictionary: gem_type -> count).
func collect_prospector_gems() -> Dictionary:
	var collected: Dictionary = {}
	if prospector_last_tick <= 0.0:
		prospector_last_tick = TrustedClock.now()
		return collected

	var now := TrustedClock.now()
	var elapsed := now - prospector_last_tick
	if elapsed < 0.0:
		prospector_last_tick = now
		return collected

	# Cap at 24 hours. Remainder is taken from the capped window so leftover
	# time beyond the cap cannot be collected again on the next visit.
	elapsed = minf(elapsed, PROSPECTOR_MAX_OFFLINE)

	var effective_interval: float = maxf(PROSPECTOR_INTERVAL * get_prospector_time_multiplier(), 0.01)
	var ticks := int(elapsed / effective_interval)
	var remainder := elapsed - float(ticks) * effective_interval
	prospector_last_tick = now - remainder
	if ticks <= 0:
		return collected

	for gem_def in PROSPECTOR_GEM_ORDER:
		var gt: String = gem_def["gem_type"]
		var count: int = get_prospector_count(gt)
		if count <= 0:
			continue
		var produced := count * ticks
		gemstones[gt] = gemstones.get(gt, 0) + produced
		collected[gt] = produced

	if not collected.is_empty():
		save_data()
		data_changed.emit()
		## Notify MissionBoard for each gem type produced (bulk, not per-gem loop)
		for gt in collected:
			for _i in range(collected[gt]):
				MissionBoard.on_gem_collected(gt)
	return collected


func has_diamond_ring() -> bool:
	return diamond_ring_count > 0


func add_diamond_ring(qty: int = 1) -> void:
	diamond_ring_count += qty
	save_data()
	diamond_ring_awarded.emit()
	data_changed.emit()


func sell_diamond_ring() -> bool:
	if diamond_ring_count <= 0:
		return false
	diamond_ring_count -= 1
	coins += DIAMOND_RING_SELL_PRICE
	## Selling anything grants XP = half the coin value.
	## award_xp handles save + level-up + data_changed.
	award_xp(DIAMOND_RING_SELL_PRICE / 2)
	return true


## Effective sell value of a jewelry item (base sell_price × jewelry sell bonus).
func get_jewelry_sell_value(item_id: String) -> int:
	var def := get_jewelry_def(item_id)
	if def.is_empty():
		return 0
	return int(int(def.get("sell_price", 0)) * _jewelry_sell_mult())


## Sells `qty` of a jewelry item for coins (+jewelry sell bonus) + XP. Routes the
## diamond ring through its legacy counter. Returns true on success.
func sell_jewelry(item_id: String, qty: int = 1) -> bool:
	if qty <= 0:
		return false
	var owned := get_jewelry_count(item_id)
	if owned < qty:
		return false
	var base_unit := int(get_jewelry_def(item_id).get("sell_price", 0))
	if item_id == "diamond_ring":
		diamond_ring_count -= qty
	else:
		jewelry[item_id] = int(jewelry.get(item_id, 0)) - qty
		if jewelry[item_id] <= 0:
			jewelry.erase(item_id)
	var base_total := base_unit * qty
	coins += int(base_total * _jewelry_sell_mult())
	award_xp(base_total / 2)  ## handles save + level-up + data_changed
	## Selling the last of an equipped piece clears its slot so it stops
	## granting a bonus.
	prune_equipped_jewelry()
	return true


## ── Fruit Inventory Helpers ─────────────────────────────────────

func get_fruit_count(fruit_id: String) -> int:
	return fruits.get(fruit_id, 0)


## Adds fruit to inventory. Pass defer=true to skip the disk save + signal (for
## bulk operations like Orchard "Harvest All"); call flush_bulk_adds() once when
## the batch is done to persist and notify listeners a single time.
func add_fruit(fruit_id: String, qty: int = 1, defer: bool = false) -> void:
	if qty <= 0:
		return
	fruits[fruit_id] = fruits.get(fruit_id, 0) + qty
	if defer:
		return
	save_data()
	data_changed.emit()


## Effective per-fruit sell value: base price × orchard-profit prestige × any
## Business District fruit bonus (Smoothie / Lemonaid). Single source of truth so
## the UI display and the actual payout always match.
func get_fruit_sell_value(fruit_id: String) -> int:
	var price := 0
	for def in ITEM_DEFS:
		if def["id"] == fruit_id:
			price = int(def["sell_price"])
			break
	if price <= 0:
		return 0
	var mult := get_fruit_profit_multiplier()
	if get_node_or_null("/root/BusinessDistrict") != null:
		mult *= BusinessDistrict.fruit_sell_multiplier(fruit_id)
	return int(price * mult)


## Effective COIN price of a fruit = base sell value × jewelry sell mult.
## Separate from get_fruit_sell_value so XP (coin-derived) isn't inflated by the
## jewelry bonus — matching the gem coin/XP split.
func get_fruit_sell_price(fruit_id: String) -> int:
	return int(get_fruit_sell_value(fruit_id) * _jewelry_sell_mult())


func sell_fruit(fruit_id: String, qty: int = 1) -> bool:
	var owned := get_fruit_count(fruit_id)
	if owned < qty or qty <= 0:
		return false
	var unit := get_fruit_sell_value(fruit_id)
	if unit <= 0:
		return false
	fruits[fruit_id] = owned - qty
	var base_total := unit * qty
	## Coins get the jewelry sell bonus; XP is from the base (pre-jewelry) coins.
	coins += int(base_total * _jewelry_sell_mult())
	## award_xp handles save + level-up + data_changed.
	award_xp(base_total / 2)
	return true


func sell_all_fruit(fruit_id: String) -> int:
	var owned := get_fruit_count(fruit_id)
	if owned <= 0:
		return 0
	if sell_fruit(fruit_id, owned):
		return owned
	return 0


## Normal orchard fruits accepted in guild deposit missions (presents excluded).
const ORCHARD_FRUIT_IDS: Array[String] = ["plum", "lemon", "apple", "banana", "coconut"]

func is_orchard_fruit(id: String) -> bool:
	return id in ORCHARD_FRUIT_IDS

func get_fruit_def(fruit_id: String) -> Dictionary:
	for def in ITEM_DEFS:
		if def.get("id", "") == fruit_id:
			return def
	return {}

func get_total_fruit_count() -> int:
	var total := 0
	for fid in ORCHARD_FRUIT_IDS:
		total += get_fruit_count(fid)
	return total

## Removes `qty` of a fruit from inventory without selling (used for guild mission deposits).
func consume_fruit(fruit_id: String, qty: int = 1) -> bool:
	var owned := get_fruit_count(fruit_id)
	if owned < qty or qty <= 0:
		return false
	fruits[fruit_id] = owned - qty
	if fruits[fruit_id] <= 0:
		fruits.erase(fruit_id)
	save_data()
	data_changed.emit()
	return true


## ── Harvested Crops (garden output) ─────────────────────────────
## Held items sold in the Marketplace. The garden-profit prestige is applied to
## the SALE price here (get_crop_sell_value), not to the harvest anymore.

## Returns the CROP_DEFS entry for a crop id, or {} if not a crop.
func get_crop_def(crop_id: String) -> Dictionary:
	for def in CROP_DEFS:
		if def["id"] == crop_id:
			return def
	return {}

## Maps a GardenData.PlantType index to its crop id, or "" if out of range.
func get_crop_id_for_plant_type(plant_type: int) -> String:
	for def in CROP_DEFS:
		if int(def["plant_type"]) == plant_type:
			return str(def["id"])
	return ""

func get_crop_count(crop_id: String) -> int:
	return crops.get(crop_id, 0)

## Per-crop sell value: base price scaled by the garden-profit prestige.
func get_crop_sell_value(crop_id: String) -> int:
	var def := get_crop_def(crop_id)
	if def.is_empty():
		return 0
	var mult := get_garden_profit_multiplier()
	if get_node_or_null("/root/BusinessDistrict") != null:
		mult *= BusinessDistrict.crop_sell_multiplier(crop_id)
	## Guild "Crop Sell Value" perk (+5%/level), including a linked guild's.
	if get_node_or_null("/root/GuildManager") != null:
		mult *= GuildManager.crop_sell_perk_mult()
	return int(int(def["base_price"]) * mult)


## Effective COIN price of a crop = base sell value × jewelry sell mult.
## Separate from get_crop_sell_value so coin-derived XP isn't inflated.
func get_crop_sell_price(crop_id: String) -> int:
	return int(get_crop_sell_value(crop_id) * _jewelry_sell_mult())

## Adds harvested crops to the held store. Called by the Garden on harvest.
## Adds harvested crops. Pass defer=true to skip the per-call disk save + signal
## during a batch (e.g. Garden.harvest_batch, which saves/emits once at the end).
func add_crop(crop_id: String, qty: int = 1, defer: bool = false) -> void:
	if qty <= 0 or get_crop_def(crop_id).is_empty():
		return
	crops[crop_id] = crops.get(crop_id, 0) + qty
	if defer:
		return
	save_data()
	data_changed.emit()

## Adds crops by GardenData.PlantType index (convenience for the Garden).
func add_crop_by_plant_type(plant_type: int, qty: int = 1, defer: bool = false) -> void:
	var cid := get_crop_id_for_plant_type(plant_type)
	if cid != "":
		add_crop(cid, qty, defer)

## Removes `qty` of a crop from the held store without granting coins.
## Used for guild mission deposits. Returns true if the crop was consumed.
func consume_crop(crop_id: String, qty: int = 1) -> bool:
	var owned := get_crop_count(crop_id)
	if owned < qty or qty <= 0:
		return false
	crops[crop_id] = owned - qty
	if crops[crop_id] <= 0:
		crops.erase(crop_id)
	save_data()
	data_changed.emit()
	return true


## ── Unified Crop & Orchard Fruit Helpers (Guild Missions) ────────

const CROP_IDS: Array[String] = [
	"beans", "cucumbers", "peppers", "squash",
	"grapes", "sunflower", "cauliflower", "pineapple", "watermelon"
]

const PRODUCE_IDS: Array[String] = [
	"beans", "cucumbers", "peppers", "squash",
	"grapes", "sunflower", "cauliflower", "pineapple", "watermelon",
	"plum", "lemon", "apple", "banana", "coconut"
]

func is_garden_crop(id: String) -> bool:
	return not get_crop_def(id).is_empty()

func is_produce(id: String) -> bool:
	return is_garden_crop(id) or is_orchard_fruit(id)

func get_total_produce_count() -> int:
	var total := 0
	for pid in PRODUCE_IDS:
		total += get_crop_or_fruit_count(pid)
	return total

func get_crop_or_fruit_def(item_id: String) -> Dictionary:
	var cdef := get_crop_def(item_id)
	if not cdef.is_empty():
		return cdef
	return get_fruit_def(item_id)

func get_crop_or_fruit_count(item_id: String) -> int:
	if is_orchard_fruit(item_id) or get_crop_def(item_id).is_empty():
		return get_fruit_count(item_id)
	return get_crop_count(item_id)

func consume_crop_or_fruit(item_id: String, qty: int = 1) -> bool:
	if is_orchard_fruit(item_id) or get_crop_def(item_id).is_empty():
		return consume_fruit(item_id, qty)
	return consume_crop(item_id, qty)

func add_crop_or_fruit(item_id: String, qty: int = 1) -> void:
	if is_orchard_fruit(item_id) or get_crop_def(item_id).is_empty():
		add_fruit(item_id, qty)
	else:
		add_crop(item_id, qty)


## Sells `qty` of a crop at the prestige-scaled value. Returns true on success.
func sell_crop(crop_id: String, qty: int = 1) -> bool:
	var owned := get_crop_count(crop_id)
	if owned < qty or qty <= 0:
		return false
	var unit_value := get_crop_sell_value(crop_id)
	if unit_value <= 0:
		return false
	crops[crop_id] = owned - qty
	if crops[crop_id] <= 0:
		crops.erase(crop_id)
	var base_total := unit_value * qty
	## Coins get the jewelry sell bonus; XP is from the base (pre-jewelry) coins.
	coins += int(base_total * _jewelry_sell_mult())
	## award_xp handles save + level-up + data_changed.
	award_xp(base_total / 2)
	return true

## Sells all owned crops of a type. Returns count sold.
func sell_all_crop(crop_id: String) -> int:
	var owned := get_crop_count(crop_id)
	if owned <= 0:
		return 0
	if sell_crop(crop_id, owned):
		return owned
	return 0


## ── Marketplace inventory bridge (by canonical item-key) ────────
## Used by the online marketplace to count/remove/add items uniformly across all
## stores (gems, resources, crops, fruit, tiles, tools, diamond ring), keyed by
## the ItemKeyRegistry canonical string (e.g. "gem:diamond", "tile:pawn").

## How many of a canonical item-key the player currently owns locally.
func market_count_owned(item_key: String) -> int:
	var parts := ItemKeyRegistry.split_key(item_key)
	var cat: String = parts[0]
	var id: String = parts[1]
	match cat:
		"gem":      return get_gem_count(id)
		"resource": return get_item_count(id)
		"crop":     return get_crop_count(id)
		"fruit":    return get_fruit_count(id)
		"item":
			if is_recipe_id(id):
				return get_recipe_count(id)
			return get_jewelry_count(id) if is_jewelry_id(id) else 0
		"tile":
			var pt := _piece_type_from_key_id(id)
			return count_in_inventory(pt) if pt != -1 else 0
		"tool":
			var tid := _tool_id_from_key_id(id)
			return get_tool_count(tid) if tid != -1 else 0
		"seed":
			var pt := _plant_type_from_key_id(id)
			if pt != -1 and get_node_or_null("/root/Garden") != null:
				return Garden.get_seed_count(pt)
			return 0
		"polished":
			return get_polished_gem_count(id)
		"present":
			return get_present_count(int(id)) if id.is_valid_int() else 0
		"sapling":
			var tt := _tree_type_from_key_id(id)
			if tt != -1 and get_node_or_null("/root/Orchard") != null:
				return Orchard.get_sapling_count(tt)
			return 0
		"material":
			return wonderstone_count if id == "wonderstone" else 0
		"vessel":
			return get_vessel_count(int(id)) if id.is_valid_int() else 0
	return 0

## Remaining LOCAL storage space for an item key, or -1 if the category is
## uncapped (gems, resources, crops, fruit, polished, tools, presents, diamond
## ring, AND seeds/saplings). Only Pho tiles are capped — they share the
## inventory slot pool (MAX_INVENTORY). The online marketplace (buy clamp +
## escrow claim) uses this so a capped store can't be overfilled.
func market_storage_space_for(item_key: String) -> int:
	match ItemKeyRegistry.category_of(item_key):
		"tile":
			return maxi(MAX_INVENTORY - get_inventory_size(), 0)
		## Seeds and saplings are UNCAPPED now — treat as unlimited (-1) so the
		## online market buy-clamp and escrow claim never gate them. (Tiles above
		## remain capped by MAX_INVENTORY.)
		_:
			return -1  ## uncapped

## Removes `qty` of a canonical item-key from local inventory (no coins/XP).
## Returns true if the full amount was removed. Called ONLY after the server
## confirms the listing (server-authoritative escrow).
func market_remove_owned(item_key: String, qty: int) -> bool:
	if qty <= 0:
		return false
	## Safety net: never let a non-tradeable item (e.g. the unique Tractor) leave
	## inventory into a listing, even if a bad/old client requests it.
	if not ItemKeyRegistry.is_tradeable(item_key):
		return false
	if market_count_owned(item_key) < qty:
		return false
	var parts := ItemKeyRegistry.split_key(item_key)
	var cat: String = parts[0]
	var id: String = parts[1]
	match cat:
		"gem":
			gemstones[id] = get_gem_count(id) - qty
			if gemstones[id] <= 0:
				gemstones.erase(id)
		"resource", "fruit":
			fruits[id] = fruits.get(id, 0) - qty
			if fruits[id] <= 0:
				fruits.erase(id)
		"crop":
			crops[id] = crops.get(id, 0) - qty
			if crops[id] <= 0:
				crops.erase(id)
		"item":
			## Food recipes route to their own store; jewelry (incl. diamond_ring
			## legacy counter) otherwise. remove_* save + emit internally.
			if is_recipe_id(id):
				if not remove_recipe(id, qty):
					return false
			elif is_jewelry_id(id):
				if not remove_jewelry(id, qty):
					return false
			else:
				return false
		"tile":
			var pt := _piece_type_from_key_id(id)
			if pt == -1:
				return false
			_market_remove_tiles(pt, qty)
		"tool":
			var tid := _tool_id_from_key_id(id)
			if tid == -1:
				return false
			tools[tid] = get_tool_count(tid) - qty
			if tools[tid] <= 0:
				tools.erase(tid)
		"seed":
			var pt := _plant_type_from_key_id(id)
			if pt == -1 or get_node_or_null("/root/Garden") == null:
				return false
			## add_seeds with a negative amount removes + clamps + saves.
			Garden.add_seeds(pt, -qty)
		"polished":
			polished_gems[id] = get_polished_gem_count(id) - qty
			if polished_gems[id] <= 0:
				polished_gems.erase(id)
		"present":
			if not id.is_valid_int():
				return false
			var pid := present_id(int(id))
			fruits[pid] = int(fruits.get(pid, 0)) - qty
			if fruits[pid] <= 0:
				fruits.erase(pid)
		"sapling":
			var tt := _tree_type_from_key_id(id)
			if tt == -1 or get_node_or_null("/root/Orchard") == null:
				return false
			## Payout-free removal (coins/XP are NOT credited for listing).
			Orchard.remove_saplings(tt, qty)
		"material":
			if id != "wonderstone" or wonderstone_count < qty:
				return false
			wonderstone_count -= qty
		"vessel":
			if not id.is_valid_int() or get_vessel_count(int(id)) < qty:
				return false
			var vt := int(id)
			wonder_vessels[vt] = get_vessel_count(vt) - qty
			if wonder_vessels[vt] <= 0:
				wonder_vessels.erase(vt)
		_:
			return false
	save_data()
	data_changed.emit()
	return true

## Adds `qty` of a canonical item-key to local inventory (no coins/XP). Used when
## claiming purchased/returned items out of server escrow into the local save.
func market_add_owned(item_key: String, qty: int) -> bool:
	if qty <= 0:
		return false
	## Safety net: refuse to add a non-tradeable/unique item (e.g. a second
	## Tractor). Should be unreachable now that listing is guarded, but protects
	## buyers if a bad legacy listing is claimed.
	if not ItemKeyRegistry.is_tradeable(item_key):
		return false
	var parts := ItemKeyRegistry.split_key(item_key)
	var cat: String = parts[0]
	var id: String = parts[1]
	match cat:
		"gem":
			gemstones[id] = get_gem_count(id) + qty
		"resource", "fruit":
			fruits[id] = fruits.get(id, 0) + qty
		"crop":
			crops[id] = crops.get(id, 0) + qty
		"item":
			## Food recipes -> recipes store; jewelry -> jewelry dict (diamond_ring
			## keeps its legacy counter).
			if is_recipe_id(id):
				recipes[id] = int(recipes.get(id, 0)) + qty
			elif is_jewelry_id(id):
				if id == "diamond_ring":
					diamond_ring_count += qty
				else:
					jewelry[id] = int(jewelry.get(id, 0)) + qty
			else:
				return false
		"tile":
			var pt := _piece_type_from_key_id(id)
			if pt == -1:
				return false
			for i in range(qty):
				inventory.append({"type": int(pt), "direction": 0})
		"tool":
			var tid := _tool_id_from_key_id(id)
			if tid == -1:
				return false
			tools[tid] = get_tool_count(tid) + qty
		"seed":
			var pt := _plant_type_from_key_id(id)
			if pt == -1 or get_node_or_null("/root/Garden") == null:
				return false
			Garden.add_seeds(pt, qty)
		"polished":
			polished_gems[id] = get_polished_gem_count(id) + qty
		"present":
			if not id.is_valid_int():
				return false
			## Buying/claiming a present variant adds it directly — this does NOT
			## touch present_variant (that's only your Conifer's produced type).
			var pid := present_id(int(id))
			fruits[pid] = int(fruits.get(pid, 0)) + qty
			## Achievement: holding all 8 present variants at once.
			if get_node_or_null("/root/Achievements") != null:
				Achievements.record_presents_checked()
		"sapling":
			var tt := _tree_type_from_key_id(id)
			if tt == -1 or get_node_or_null("/root/Orchard") == null:
				return false
			Orchard.add_saplings(tt, qty)
		"material":
			if id != "wonderstone":
				return false
			wonderstone_count += qty
		"vessel":
			if not id.is_valid_int():
				return false
			var vt := int(id)
			wonder_vessels[vt] = get_vessel_count(vt) + qty
		_:
			return false
	save_data()
	data_changed.emit()
	return true

## Removes `count` tiles of a piece type from the inventory array (no payout).
## Single O(n) filtered rebuild rather than repeated remove_at().
func _market_remove_tiles(piece_type: int, count: int) -> void:
	var new_inventory: Array = []
	var removed := 0
	for item in inventory:
		if removed < count and int(item.get("type", -1)) == int(piece_type):
			removed += 1
			continue
		new_inventory.append(item)
	inventory = new_inventory

## Maps a tile key id (Piece.Type name, lowercased) back to the enum int, or -1.
func _piece_type_from_key_id(name: String) -> int:
	var names := Piece.Type.keys()
	for i in range(names.size()):
		if str(names[i]).to_lower() == name:
			return i
	return -1

## Maps a tool key slug back to the TOOL_DEFS int id, or -1.
func _tool_id_from_key_id(slug: String) -> int:
	for tid in ItemKeyRegistry.TOOL_SLUGS:
		if str(ItemKeyRegistry.TOOL_SLUGS[tid]) == slug:
			return int(tid)
	return -1

## Maps a seed key id (GardenData.PlantType name, lowercased) back to the enum
## int, or -1. Seeds live in the Garden autoload, not PlayerData.
func _plant_type_from_key_id(name: String) -> int:
	if get_node_or_null("/root/Garden") == null:
		return -1
	var names = Garden.PlantType.keys()
	for i in range(names.size()):
		if str(names[i]).to_lower() == name:
			return i
	return -1

## Maps a sapling key id (Orchard TREE_DEFS stable id, e.g. "plum") back to the
## TreeType int (index into TREE_DEFS), or -1. Saplings live in Orchard.
func _tree_type_from_key_id(tree_id: String) -> int:
	if get_node_or_null("/root/Orchard") == null:
		return -1
	for i in range(Orchard.TREE_DEFS.size()):
		if str(Orchard.TREE_DEFS[i].get("id", "")) == tree_id:
			return i
	return -1


## ── Resource Items (wood/sticks/ores/bars) ──────────────────────
## These share the generic `fruits` item store (id -> count) but scale with a
## per-item prestige line via `value_group`.

## Returns the RESOURCE_DEFS entry for an id, or {} if not a resource item.
func get_resource_def(item_id: String) -> Dictionary:
	for def in RESOURCE_DEFS:
		if def["id"] == item_id:
			return def
	return {}


## ── Jewelry helpers (guild-produced item: entries in ITEM_DEFS) ──────────────
## Jewelry entries are the ITEM_DEFS rows marked `jewelry: true` (they have a
## `recipe`, a `gem` type, and a `bonus`). Fruit entries (with `fruit_index`)
## and any future item: entries are excluded.

## Returns the ITEM_DEFS entry for a jewelry id, or {} if not jewelry.
func get_jewelry_def(item_id: String) -> Dictionary:
	for def in ITEM_DEFS:
		if def.get("jewelry", false) and str(def.get("id", "")) == item_id:
			return def
	return {}


## True if an item id names a jewelry item.
func is_jewelry_id(item_id: String) -> bool:
	return not get_jewelry_def(item_id).is_empty()


## All WEARABLE jewelry item ids, in ITEM_DEFS order. Excludes food recipes
## (recipe_item:true) which carry jewelry:true only to ride the produce loop —
## they are NOT equippable and must not appear in the jewelry/equip UI.
func jewelry_ids() -> Array[String]:
	var out: Array[String] = []
	for def in ITEM_DEFS:
		if def.get("jewelry", false) and not def.get("recipe_item", false):
			out.append(str(def["id"]))
	return out


## ── Horseshoes (guild-produced; carry jewelry:true but slot:"horse") ─────────
## Horseshoes ride the jewelry produce/list/claim loop (jewelry:true) but equip
## to a HORSE, not the personal jewelry slots. These helpers let horse systems
## enumerate them and let the jewelry-equip UI exclude them (slot != ring/necklace).

## The ITEM_DEFS entry for a horseshoe id, or {} if not a horseshoe.
func get_horseshoe_def(item_id: String) -> Dictionary:
	for def in ITEM_DEFS:
		if def.get("horseshoe", false) and str(def.get("id", "")) == item_id:
			return def
	return {}


## True if an item id names a horseshoe.
func is_horseshoe_id(item_id: String) -> bool:
	return not get_horseshoe_def(item_id).is_empty()


## All horseshoe item ids, in ITEM_DEFS order.
func horseshoe_ids() -> Array[String]:
	var out: Array[String] = []
	for def in ITEM_DEFS:
		if def.get("horseshoe", false):
			out.append(str(def["id"]))
	return out


## ── Guild production specialization gating (client mirror of migration 096) ──
## Production category for a producible item id: "recipe" (food), "horseshoe",
## or "jewelry". Mirrors the server's guild_production_recipes.category so the
## production dropdown only offers what the guild can actually craft.
func recipe_category(item_id: String) -> String:
	var def := {}
	for d in ITEM_DEFS:
		if str(d.get("id", "")) == item_id:
			def = d
			break
	if def.is_empty():
		return ""
	if bool(def.get("recipe_item", false)) or str(def.get("category", "")) == "recipe":
		return "recipe"
	if bool(def.get("horseshoe", false)) or str(def.get("category", "")) == "horseshoe":
		return "horseshoe"
	if bool(def.get("jewelry", false)):
		return "jewelry"
	return ""

## True if a guild of `spec` (gardening/mining/horse) may craft `category`.
func _spec_can_produce(spec: String, category: String) -> bool:
	match category:
		"recipe":    return spec == "gardening"
		"jewelry":   return spec == "mining"
		"horseshoe": return spec == "mining" or spec == "horse"
	return false

## Producible item ids a guild of the given specialization may craft, in
## ITEM_DEFS order. Used to build the production dropdown.
func producible_ids_for_spec(spec: String) -> Array[String]:
	var out: Array[String] = []
	for def in ITEM_DEFS:
		var id := str(def.get("id", ""))
		if id == "":
			continue
		var cat := recipe_category(id)
		if cat != "" and _spec_can_produce(spec, cat):
			out.append(id)
	return out


## ── Food recipes (gardening-guild produced, used for timed boosts) ──────────

## ITEM_DEFS entry for a recipe id, or {} if not a recipe.
func get_recipe_def(item_id: String) -> Dictionary:
	for def in ITEM_DEFS:
		if def.get("recipe_item", false) and str(def.get("id", "")) == item_id:
			return def
	return {}

## True if an item id names a food recipe.
func is_recipe_id(item_id: String) -> bool:
	return not get_recipe_def(item_id).is_empty()

## All recipe item ids, in ITEM_DEFS order.
func recipe_ids() -> Array[String]:
	var out: Array[String] = []
	for def in ITEM_DEFS:
		if def.get("recipe_item", false):
			out.append(str(def["id"]))
	return out

func get_recipe_count(item_id: String) -> int:
	return int(recipes.get(item_id, 0))

func add_recipe(item_id: String, qty: int = 1) -> void:
	if qty <= 0:
		return
	recipes[item_id] = int(recipes.get(item_id, 0)) + qty
	save_data()
	data_changed.emit()

func remove_recipe(item_id: String, qty: int = 1) -> bool:
	if qty <= 0 or int(recipes.get(item_id, 0)) < qty:
		return false
	recipes[item_id] = int(recipes.get(item_id, 0)) - qty
	if recipes[item_id] <= 0:
		recipes.erase(item_id)
	save_data()
	data_changed.emit()
	return true

## Recommended storefront token value for a recipe (Σ ingredient token ×10).
func get_recipe_token_value(item_id: String) -> int:
	return int(get_recipe_def(item_id).get("token_value", 0))

## Coin sell value for a recipe (local marketplace).
func get_recipe_sell_value(item_id: String) -> int:
	return int(get_recipe_def(item_id).get("sell_price", 0))

## Sells `qty` of a recipe at its coin sell value. Credits coins (+jewelry sell
## bonus) and XP, mirroring the other sell helpers. Returns true on success.
func sell_recipe(item_id: String, qty: int = 1) -> bool:
	var owned := get_recipe_count(item_id)
	if qty <= 0 or owned < qty:
		return false
	var unit := get_recipe_sell_value(item_id)
	recipes[item_id] = owned - qty
	if recipes[item_id] <= 0:
		recipes.erase(item_id)
	var base_total := unit * qty
	coins += int(base_total * _jewelry_sell_mult())
	award_xp(base_total / 2)  ## handles save + level-up + data_changed
	return true


## ── Recipe boosts (temporary per-player buffs from using a recipe) ──────────
## active_boosts: effect_id -> { "value": float, "expires_at": float }  (timed)
##                         OR -> { "value": float, "remaining": int }   (counted)
## Timed boosts expire by wall clock; counted boosts decrement on consume_boost_use.
var active_boosts: Dictionary = {}

signal boosts_changed

## Emits a signal + persists. Pruning happens lazily on read.
func _boosts_touched() -> void:
	save_data()
	boosts_changed.emit()
	data_changed.emit()

## Removes any timed boost whose expiry has passed. Returns true if any changed.
func _prune_expired_boosts() -> bool:
	var now := TrustedClock.now()
	var changed := false
	for effect in active_boosts.keys():
		var b: Dictionary = active_boosts[effect]
		if b.has("expires_at") and now >= float(b["expires_at"]):
			active_boosts.erase(effect)
			changed = true
	return changed

## True if the named boost is currently active (prunes expired first).
func boost_active(effect: String) -> bool:
	if _prune_expired_boosts():
		_boosts_touched()
	if not active_boosts.has(effect):
		return false
	var b: Dictionary = active_boosts[effect]
	if b.has("remaining"):
		return int(b["remaining"]) > 0
	return true

## The magnitude of an active boost, or 0.0 if inactive.
func boost_value(effect: String) -> float:
	if not boost_active(effect):
		return 0.0
	return float(active_boosts[effect].get("value", 0.0))

## Consumes one "use" of a counted boost (e.g. per race / per Pho game). No-op
## for timed boosts. Returns true if a use was consumed.
func consume_boost_use(effect: String) -> bool:
	if not boost_active(effect):
		return false
	var b: Dictionary = active_boosts[effect]
	if not b.has("remaining"):
		return false
	b["remaining"] = int(b["remaining"]) - 1
	if int(b["remaining"]) <= 0:
		active_boosts.erase(effect)
	else:
		active_boosts[effect] = b
	_boosts_touched()
	return true

## Seconds left on a timed boost (0 if inactive/counted).
func boost_seconds_remaining(effect: String) -> int:
	if not boost_active(effect):
		return 0
	var b: Dictionary = active_boosts[effect]
	if not b.has("expires_at"):
		return 0
	return maxi(0, int(float(b["expires_at"]) - TrustedClock.now()))

## Uses `qty` of a recipe: consumes them and (re)applies the recipe's boost.
## Timed boosts REFRESH (restart the duration); counted boosts ADD uses. Using
## more than one at once stacks duration/uses accordingly. Returns a summary:
## { used: int, effect: String, name: String } or { used: 0 } if none/unknown.
func use_recipe(item_id: String, qty: int = 1) -> Dictionary:
	var def := get_recipe_def(item_id)
	if def.is_empty():
		return {"used": 0}
	var owned := get_recipe_count(item_id)
	var n: int = mini(maxi(qty, 0), owned)
	if n <= 0:
		return {"used": 0}
	var boost: Dictionary = def.get("boost", {})
	var effect := str(boost.get("effect", ""))
	if effect == "":
		return {"used": 0}

	## Consume the recipes.
	recipes[item_id] = owned - n
	if recipes[item_id] <= 0:
		recipes.erase(item_id)

	var value := float(boost.get("value", 0.0))
	if boost.has("uses"):
		## Counted boost — add n × uses to the remaining count.
		var add_uses := int(boost["uses"]) * n
		var cur := 0
		if active_boosts.has(effect) and active_boosts[effect].has("remaining"):
			cur = int(active_boosts[effect]["remaining"])
		active_boosts[effect] = {"value": value, "remaining": cur + add_uses}
	else:
		## Timed boost — extend from the later of (now, current expiry) by n × duration.
		var dur := float(boost.get("duration", 0)) * n
		var now := TrustedClock.now()
		var base := now
		if active_boosts.has(effect) and active_boosts[effect].has("expires_at"):
			base = maxf(now, float(active_boosts[effect]["expires_at"]))
		active_boosts[effect] = {"value": value, "expires_at": base + dur}

	_boosts_touched()
	return {"used": n, "effect": effect, "name": str(def.get("name", item_id))}


## Recipe effects whose benefit is paid by the SERVER. They must be activated
## online first (the server records the window), then consumed locally.
const SERVER_BOOST_EFFECTS := ["traders_tongue"]


## UI entry point for using recipes. Server-backed boosts (Trader's Tongue)
## open their window on the server BEFORE the recipe is consumed — so going
## offline never wastes a recipe — and the local timer is synced to the
## server's end time. All other recipes behave exactly like use_recipe().
## Returns use_recipe's summary, or { used: 0, error: String } on failure.
func use_recipe_checked(item_id: String, qty: int = 1) -> Dictionary:
	var def := get_recipe_def(item_id)
	var effect := str((def.get("boost", {}) as Dictionary).get("effect", ""))
	if not effect in SERVER_BOOST_EFFECTS:
		return use_recipe(item_id, qty)

	var n: int = mini(maxi(qty, 0), get_recipe_count(item_id))
	if n <= 0:
		return {"used": 0}
	if get_node_or_null("/root/MarketplaceAccount") == null \
			or not MarketplaceAccount.has_account():
		return {"used": 0, "error": "Connect to the internet to use this recipe — its boost applies to online missions."}

	var res: Dictionary = await MarketplaceAccount.activate_mission_boost(n)
	if not res.get("ok", false):
		return {"used": 0, "error": str(res.get("error", "Couldn't activate the boost."))}

	var summary := use_recipe(item_id, n)
	## Match the local countdown to the server's authoritative end time.
	if int(summary.get("used", 0)) > 0 and active_boosts.has(effect):
		active_boosts[effect]["expires_at"] = float(res.get("boost_until", 0.0))
		_boosts_touched()
	return summary


## ── WonderStone helpers ─────────────────────────────────────────

func get_wonderstone_count() -> int:
	return wonderstone_count

func add_wonderstone(qty: int = 1, defer: bool = false) -> void:
	if qty <= 0:
		return
	wonderstone_count += qty
	if defer:
		return
	save_data()
	data_changed.emit()

func remove_wonderstone(qty: int = 1) -> bool:
	if qty <= 0 or wonderstone_count < qty:
		return false
	wonderstone_count -= qty
	save_data()
	data_changed.emit()
	return true

## Sells `qty` WonderStones at WONDERSTONE_COIN_VALUE each (+jewelry sell bonus),
## awarding XP. Returns true on success.
func sell_wonderstone(qty: int = 1) -> bool:
	if qty <= 0 or wonderstone_count < qty:
		return false
	wonderstone_count -= qty
	var base_total := WONDERSTONE_COIN_VALUE * qty
	coins += int(base_total * _jewelry_sell_mult())
	award_xp(base_total / 2)  ## handles save + level-up + data_changed
	return true


## ── WonderVessel helpers ────────────────────────────────────────

## Def for a tier (1..10), or {} if out of range.
func get_vessel_def(tier: int) -> Dictionary:
	if tier >= 1 and tier <= WONDERVESSEL_DEFS.size():
		return WONDERVESSEL_DEFS[tier - 1]
	return {}

func get_vessel_count(tier: int) -> int:
	return int(wonder_vessels.get(tier, 0))

func add_vessel(tier: int, qty: int = 1) -> void:
	if qty <= 0 or get_vessel_def(tier).is_empty():
		return
	wonder_vessels[tier] = get_vessel_count(tier) + qty
	save_data()
	data_changed.emit()

func remove_vessel(tier: int, qty: int = 1) -> bool:
	if qty <= 0 or get_vessel_count(tier) < qty:
		return false
	wonder_vessels[tier] = get_vessel_count(tier) - qty
	if wonder_vessels[tier] <= 0:
		wonder_vessels.erase(tier)
	save_data()
	data_changed.emit()
	return true

## Token value of a vessel tier = WonderStone token value × 10 × tier.
func get_vessel_token_value(tier: int) -> int:
	return WONDERSTONE_TOKEN_VALUE * 10 * tier

## Coin value of a vessel (for the local marketplace) = WonderStone coin × 10 × tier.
func get_vessel_sell_value(tier: int) -> int:
	return WONDERSTONE_COIN_VALUE * 10 * tier

## Sells `qty` vessels of `tier` at the vessel coin value each (+jewelry sell
## bonus), awarding XP. Returns true on success.
func sell_vessel(tier: int, qty: int = 1) -> bool:
	if qty <= 0 or get_vessel_count(tier) < qty:
		return false
	wonder_vessels[tier] = get_vessel_count(tier) - qty
	if wonder_vessels[tier] <= 0:
		wonder_vessels.erase(tier)
	var base_total := get_vessel_sell_value(tier) * qty
	coins += int(base_total * _jewelry_sell_mult())
	award_xp(base_total / 2)  ## handles save + level-up + data_changed
	return true

## Every BASE resource key a WonderVessel craft consumes X of: all raw gems,
## all polished gems, all crops, all orchard fruits, wood, sticks, iron ore,
## copper ore, gold. (Bars/ingots are a flat 1 each — see vessel_resource_cost.)
func _vessel_base_resource_keys() -> Array:
	var keys: Array = []
	for def in PROSPECTOR_GEM_ORDER:
		keys.append("gem:%s" % str(def["gem_type"]))
	for gt in POLISHABLE_GEMS:
		keys.append("polished:%s" % str(gt))
	for cdef in CROP_DEFS:
		keys.append("crop:%s" % str(cdef["id"]))
	for fid in ORCHARD_FRUIT_IDS:
		keys.append("fruit:%s" % fid)
	keys.append("resource:wood")
	keys.append("resource:stick")
	keys.append("resource:iron_ore")
	keys.append("resource:copper_ore")
	## Note: raw gold is already included as "gem:gold" via PROSPECTOR_GEM_ORDER.
	return keys

## Full input cost for crafting ONE vessel of `tier`:
##   { "coins": X, "wonderstone": X, "<resource_key>": X..., bars: 1 each }
func vessel_resource_cost(tier: int) -> Dictionary:
	var def := get_vessel_def(tier)
	if def.is_empty():
		return {}
	var x := int(def["x"])
	var cost: Dictionary = {"coins": x, "wonderstone": x}
	for key in _vessel_base_resource_keys():
		cost[key] = x
	## One of each refined bar/ingot (flat, not ×X).
	cost["resource:iron_bar"] = 1
	cost["resource:copper_ingot"] = 1
	cost["resource:gold_ingot"] = 1
	return cost

## True if the player can afford one vessel of `tier` (coins + all resources +
## WonderStones). `times` checks affordability for crafting `times` vessels.
func can_craft_vessel(tier: int, times: int = 1) -> bool:
	var cost := vessel_resource_cost(tier)
	if cost.is_empty() or times <= 0:
		return false
	for key in cost:
		var need := int(cost[key]) * times
		var have := 0
		if key == "coins":
			have = coins
		elif key == "wonderstone":
			have = wonderstone_count
		else:
			have = market_count_owned(key)
		if have < need:
			return false
	return true

## Returns the shortfalls for crafting one vessel of `tier`: an Array of
## { key, label, need, have, short } for every input the player lacks (coins,
## WonderStones, each resource). Empty when the tier is already affordable.
func vessel_missing_for_tier(tier: int) -> Array:
	var out: Array = []
	var cost := vessel_resource_cost(tier)
	if cost.is_empty():
		return out
	for key in cost:
		var need := int(cost[key])
		var have := 0
		if key == "coins":
			have = coins
		elif key == "wonderstone":
			have = wonderstone_count
		else:
			have = market_count_owned(key)
		if have < need:
			out.append({
				"key": key,
				"label": _vessel_input_label(key),
				"need": need,
				"have": have,
				"short": need - have,
			})
	return out

## Human label for a vessel input key (coins / wonderstone / canonical item key).
func _vessel_input_label(key: String) -> String:
	if key == "coins":
		return "Coins"
	if key == "wonderstone":
		return "WonderStones"
	return ItemKeyRegistry.display_name(key)

## The lowest vessel tier the player cannot YET afford, or 0 if all tiers are
## affordable. Used to show a "what you're missing for the next tier" hint.
func next_unaffordable_vessel_tier() -> int:
	for tier in range(1, WONDERVESSEL_DEFS.size() + 1):
		if not can_craft_vessel(tier, 1):
			return tier
	return 0

## Crafts `times` vessels of `tier`, deducting all inputs. Returns true on success.
func craft_vessel(tier: int, times: int = 1) -> bool:
	if not can_craft_vessel(tier, times):
		return false
	var cost := vessel_resource_cost(tier)
	for key in cost:
		var amt := int(cost[key]) * times
		if key == "coins":
			coins -= amt
		elif key == "wonderstone":
			wonderstone_count -= amt
		else:
			market_remove_owned(key, amt)
	wonder_vessels[tier] = get_vessel_count(tier) + times
	save_data()
	data_changed.emit()
	return true

## True if an item key may be placed in a WonderVessel (tradeable + not excluded).
func vessel_key_allowed(item_key: String) -> bool:
	if item_key in VESSEL_EXCLUDED_KEYS:
		return false
	## WonderVessels can never duplicate other WonderVessels.
	if item_key.begins_with("%s:" % ItemKeyRegistry.CAT_VESSEL):
		return false
	return ItemKeyRegistry.is_tradeable(item_key)

## Uses one vessel of `tier` on `adds` = { item_key -> qty }. For each entry the
## player must own >= qty; qty is clamped to the tier cap; distinct types clamped
## to the tier's `types`. Grants the extra copies (original kept) per the tier's
## mode/n. Consumes one vessel. Returns { ok, granted: {item_key -> extra}, error? }.
func use_vessel(tier: int, adds: Dictionary) -> Dictionary:
	var def := get_vessel_def(tier)
	if def.is_empty():
		return {"ok": false, "error": "bad_tier"}
	if get_vessel_count(tier) <= 0:
		return {"ok": false, "error": "none_owned"}
	var cap := int(def["cap"])
	var max_types := int(def["types"])
	var mode := str(def["mode"])
	var n := int(def["n"])

	## Validate + clamp the requested adds.
	var valid: Dictionary = {}
	for key in adds:
		if valid.size() >= max_types:
			break
		if not vessel_key_allowed(key):
			continue
		var want: int = mini(int(adds[key]), cap)
		if want <= 0:
			continue
		if market_count_owned(key) < want:
			return {"ok": false, "error": "not_enough", "item_key": key}
		valid[key] = want
	if valid.is_empty():
		return {"ok": false, "error": "no_items"}

	## Grant the EXTRA copies (the player keeps their originals).
	var granted: Dictionary = {}
	for key in valid:
		var input: int = valid[key]
		var extra := 0
		if mode == "mult":
			extra = input * n  ## output = input*n + input -> extra = input*n
		else:
			extra = n          ## output = input + n -> extra = n
		if extra > 0 and market_add_owned(key, extra):
			granted[key] = extra

	## Consume the vessel.
	wonder_vessels[tier] = get_vessel_count(tier) - 1
	if wonder_vessels[tier] <= 0:
		wonder_vessels.erase(tier)
	save_data()
	data_changed.emit()
	return {"ok": true, "granted": granted}


func get_item_count(item_id: String) -> int:
	return fruits.get(item_id, 0)

## Adds a resource/misc item. Pass defer=true to skip the disk save + signal for
## bulk operations; call flush_bulk_adds() once when done.
func add_item(item_id: String, qty: int = 1, defer: bool = false) -> void:
	if qty <= 0:
		return
	fruits[item_id] = fruits.get(item_id, 0) + qty
	if defer:
		return
	save_data()
	data_changed.emit()

## Persists inventory and emits data_changed once, after a series of deferred
## add_fruit/add_item/add_present calls (see their `defer` param). Cheap no-op to
## call even if nothing was deferred.
func flush_bulk_adds() -> void:
	save_data()
	data_changed.emit()

## Sell-value multiplier for a resource item, chosen by its value group:
##   "misc" -> misc_value prestige, "gem" -> shared gem_profit line.
func get_resource_sell_multiplier(item_id: String) -> float:
	var def := get_resource_def(item_id)
	if def.is_empty():
		return 1.0
	match str(def.get("value_group", "misc")):
		## Ores / bars / ingots ride the gem line — include the guild gem perk.
		"gem":  return get_gem_profit_multiplier() * _guild_gem_perk()
		_:      return get_misc_profit_multiplier()

## Effective per-unit sell value for a resource item (base * prestige mult).
func get_resource_sell_value(item_id: String) -> int:
	var def := get_resource_def(item_id)
	if def.is_empty():
		return 0
	return int(int(def["sell_price"]) * get_resource_sell_multiplier(item_id))


## Effective COIN price of a resource item = base sell value × jewelry sell mult.
## Separate from get_resource_sell_value so coin-derived XP isn't inflated.
func get_resource_sell_price(item_id: String) -> int:
	return int(get_resource_sell_value(item_id) * _jewelry_sell_mult())

func sell_item(item_id: String, qty: int = 1) -> bool:
	var def := get_resource_def(item_id)
	if def.is_empty():
		return false
	var owned := get_item_count(item_id)
	if owned < qty or qty <= 0:
		return false
	var unit_value := get_resource_sell_value(item_id)
	if unit_value <= 0:
		return false
	fruits[item_id] = owned - qty
	if fruits[item_id] <= 0:
		fruits.erase(item_id)
	var base_total := unit_value * qty
	## Coins get the jewelry sell bonus; XP is from the base (pre-jewelry) coins.
	coins += int(base_total * _jewelry_sell_mult())
	## award_xp handles save + level-up + data_changed.
	award_xp(base_total / 2)
	## Mission progress: selling smelted bars credits the SELL_BARS mission.
	if item_id in SMELTED_BAR_IDS and get_node_or_null("/root/MissionBoard") != null:
		MissionBoard.on_bars_sold(qty)
	return true

func sell_all_item(item_id: String) -> int:
	var owned := get_item_count(item_id)
	if owned <= 0:
		return 0
	if sell_item(item_id, owned):
		return owned
	return 0

## ── Presents ────────────────────────────────────────────────────

## Ensures this save has a present variant assigned (0..7). Assigned once, then
## stable. Called before producing a present.
func ensure_present_variant() -> int:
	if present_variant < 0 or present_variant >= PRESENT_COUNT:
		present_variant = randi() % PRESENT_COUNT
		save_data()
	return present_variant

## Grants `qty` presents of THIS save's assigned variant (from the Christmas
## Conifer — the only source). Stored in the generic item store.
func add_present(qty: int = 1, defer: bool = false) -> void:
	if qty <= 0:
		return
	var v := ensure_present_variant()
	var id := present_id(v)
	fruits[id] = fruits.get(id, 0) + qty
	if defer:
		return
	save_data()
	data_changed.emit()
	## Achievement: holding all 8 present variants at once.
	if get_node_or_null("/root/Achievements") != null:
		Achievements.record_presents_checked()

## How many of a given present variant the player owns.
func get_present_count(variant: int) -> int:
	return fruits.get(present_id(variant), 0)

## Sell value of a present (flat; presents aren't prestige-scaled).
func get_present_sell_value() -> int:
	return PRESENT_SELL_VALUE

## Returns the present sprite (AtlasTexture) for a variant 0..7 from the 4x2
## sheet (each cell 64x53). Cached. Returns null if the sheet isn't available.
var _present_sheet: Texture2D = null
var _present_atlas_cache: Dictionary = {}
func get_present_texture(variant: int) -> Texture2D:
	if variant < 0 or variant >= PRESENT_COUNT:
		return null
	if _present_atlas_cache.has(variant):
		return _present_atlas_cache[variant]
	if _present_sheet == null:
		if not ResourceLoader.exists(PRESENT_SHEET_PATH):
			return null
		_present_sheet = load(PRESENT_SHEET_PATH)
	if _present_sheet == null:
		return null
	var cols := 4
	var cell_w := float(_present_sheet.get_width()) / float(cols)     ## 256/4 = 64
	var cell_h := float(_present_sheet.get_height()) / 2.0            ## 106/2 = 53
	var col := variant % cols
	var row := variant / cols
	var atlas := AtlasTexture.new()
	atlas.atlas = _present_sheet
	atlas.region = Rect2(col * cell_w, row * cell_h, cell_w, cell_h)
	_present_atlas_cache[variant] = atlas
	return atlas

## Sells `qty` presents of a variant at PRESENT_SELL_VALUE each. Returns true on
## success. (Presents are flat-valued, not prestige-scaled.)
func sell_present(variant: int, qty: int = 1) -> bool:
	var id := present_id(variant)
	var owned := int(fruits.get(id, 0))
	if owned < qty or qty <= 0:
		return false
	fruits[id] = owned - qty
	if fruits[id] <= 0:
		fruits.erase(id)
	var total := PRESENT_SELL_VALUE * qty
	coins += total
	award_xp(total / 2)
	return true

func sell_all_present(variant: int) -> int:
	var owned := get_present_count(variant)
	if owned <= 0:
		return 0
	if sell_present(variant, owned):
		return owned
	return 0

## USES `qty` presents of a variant: consumes them and grants, per present, one
## random TRADEABLE item — never another present, never the Tractor/Excavator
## (the Excavator isn't a tradeable key; the Tractor is excluded by is_tradeable).
## Returns { used: int, granted: { item_key -> count } } for the UI to summarize.
func use_present(variant: int, qty: int = 1) -> Dictionary:
	var id := present_id(variant)
	var owned := int(fruits.get(id, 0))
	var n: int = mini(maxi(qty, 0), owned)
	if n <= 0:
		return { "used": 0, "granted": {} }

	## Build the reward pool once: every tradeable key except presents.
	var pool: Array = []
	for k in ItemKeyRegistry.all_keys():
		if ItemKeyRegistry.is_tradeable(k) and not is_present_id(ItemKeyRegistry.id_of(k)):
			pool.append(k)
	if pool.is_empty():
		return { "used": 0, "granted": {} }

	## Consume the presents first.
	fruits[id] = owned - n
	if fruits[id] <= 0:
		fruits.erase(id)

	## Grant one random item per present used.
	var granted: Dictionary = {}
	for _i in range(n):
		var key: String = pool[randi() % pool.size()]
		if market_add_owned(key, 1):  ## market_add_owned saves + emits each time
			granted[key] = int(granted.get(key, 0)) + 1
	save_data()
	data_changed.emit()
	return { "used": n, "granted": granted }


## Crafts sticks from wood: consumes 1 wood, yields 2 sticks. `batches` lets the
## player craft multiple at once (clamped to wood owned). Returns sticks made.
func craft_sticks(batches: int = 1) -> int:
	var wood := get_item_count("wood")
	var n: int = mini(maxi(batches, 0), wood)
	if n <= 0:
		return 0
	fruits["wood"] = wood - n
	if fruits["wood"] <= 0:
		fruits.erase("wood")
	fruits["stick"] = fruits.get("stick", 0) + n * 2
	save_data()
	data_changed.emit()
	return n * 2


## ── Cheat Codes ─────────────────────────────────────────────────
## Registry of cheat codes. Each entry maps a code string to a Callable reward.
## Add new codes here to extend the system.
var _CHEAT_CODES: Dictionary = {
	"SlothLovesFreeStuff": func(): add_diamond_ring(),
	## One-time fix for the old 1–10%/hr Steady Learner runaway: removes 10T XP.
	"SlothXpRollback": func(): _rollback_xp(10_000_000_000_000),
	## ── Jewelry grants: one of each produced ring/necklace ─────────────
	## For testing the equip bonuses + Guild Fronts without crafting them.
	"SlothsGoldRing":      func(): _grant_jewelry(["gold_ring"]),
	"SlothsBlueStone":     func(): _grant_jewelry(["blue_stone_necklace"]),
	"SlothsPinkStone":     func(): _grant_jewelry(["pink_stone_necklace"]),
	"SlothsVioletRing":    func(): _grant_jewelry(["violet_stone_ring"]),
	"SlothsBlackPearl":    func(): _grant_jewelry(["black_pearl_necklace"]),
	"SlothsEmerald":       func(): _grant_jewelry(["emerald_necklace"]),
	"SlothsRubyRing":      func(): _grant_jewelry(["ruby_ring"]),
	"SlothsDiamondRing":   func(): _grant_jewelry(["diamond_ring"]),
	## One of EVERY jewelry item at once.
	"SlothsJewelryBox":    func(): _grant_jewelry(jewelry_ids()),
	## Money Gun alpha cheats (server-authoritative; fire-and-forget async).
	##   SlothPrintsMoney  — grants the Money Gun (skips the 500B coin cost).
	##   SlothMakeItRain   — grants 10 Benjamins (secret-gated grant RPC).
	"SlothPrintsMoney": func(): _cheat_grant_money_gun(),
	"SlothMakeItRain": func(): _cheat_grant_benjamins(10),
	"SlothsStarterPack": func(): _grant_starter_pack(),
	"SlothsFatStacks": func(): _grant_cash(1000000),
	"SlothsMassiveGiveaway": func(): _grant_cash(1000000000),
	"SlothsFreshStart": func(): sloths_fresh_start(),
	"SlothsPocketChange": func(): _grant_cash(1400000),
	"SlothsGoldenAcorn": func(): _grant_cash(2900000),
	"SlothsLazyLoot": func(): _grant_cash(3100000),
	"SlothsTreeVault": func(): _grant_cash(4900000),
	"SlothsHiddenStash": func(): _grant_cash(5700000),
	"SlothsBranchBonus": func(): _grant_cash(6900000),
	"SlothsCanopyCash": func(): _grant_cash(7800000),
	"SlothsJungleJackpot": func(): _grant_cash(8900000),
	"SlothsRainforestRiches": func(): _grant_cash(9100000),
	"SlothsNapTimeNestEgg": func(): _grant_cash(10500000),
	"SlothsSlowBurnBounty": func(): _grant_cash(11800000),
	"SlothsMossyMoney": func(): _grant_cash(12900000),
	"SlothsChilledCoins": func(): _grant_cash(13500000),
	"SlothsHangoutHoard": func(): _grant_cash(14800000),
	"SlothsComfyCapital": func(): _grant_cash(15900000),
	"SlothsTreehouseTreasures": func(): _grant_cash(16400000),
	"SlothsBarkBounty": func(): _grant_cash(17800000),
	"SlothsSnoozeFund": func(): _grant_cash(18900000),
	"SlothsPillowPayout": func(): _grant_cash(19500000),
	"SlothsDreamDollars": func(): _grant_cash(20800000),
	"SlothsHammockHeist": func(): _grant_cash(21900000),
	"SlothsSnackStash": func(): _grant_cash(22400000),
	"SlothsMellowMillions": func(): _grant_cash(23900000),
	"SlothsYawnYield": func(): _grant_cash(24100000),
	"SlothsRestingRichness": func(): _grant_cash(25900000),
	"SlothsCozyCoins": func(): _grant_cash(26800000),
	"SlothsSnuggleStash": func(): _grant_cash(27500000),
	"SlothsLethargicLoot": func(): _grant_cash(28900000),
	"SlothsSleepySurprise": func(): _grant_cash(29100000),
	"SlothsPeacefulPayout": func(): _grant_cash(30500000),
	"SlothsTranquilTreasures": func(): _grant_cash(31900000),
	"SlothsQuietQuarters": func(): _grant_cash(32800000),
	"SlothsCalmCapital": func(): _grant_cash(33900000),
	"SlothsGentleGold": func(): _grant_cash(34100000),
	"SlothsSoftStack": func(): _grant_cash(35800000),
	"SlothsSereneSavings": func(): _grant_cash(36900000),
	"SlothsEasyEarnings": func(): _grant_cash(37500000),
	"SlothsPlacidVault": func(): _grant_cash(38900000),
	"SlothsUntroubledTreasure": func(): _grant_cash(39100000),
	"SlothsStaticStash": func(): _grant_cash(40800000),
	"SlothsSedentarySupply": func(): _grant_cash(41900000),
	"SlothsMotionlessMoney": func(): _grant_cash(42500000),
	"SlothsPassivePayout": func(): _grant_cash(43900000),
	"SlothsInertInheritance": func(): _grant_cash(44100000),
	"SlothsDormantDollars": func(): _grant_cash(45800000),
	"SlothsLatentLoot": func(): _grant_cash(46900000),
	"SlothsStagnantStacks": func(): _grant_cash(47500000),
	"SlothsIdleIncome": func(): _grant_cash(48900000),
	"SlothsStillnessStash": func(): _grant_cash(49100000),
	"SlothsHeavyHandout": func(): _grant_cash(50800000),
	"SlothsGiantGrant": func(): _grant_cash(51900000),
	"SlothsMassiveMoney": func(): _grant_cash(52500000),
	"SlothsColossalCoins": func(): _grant_cash(53900000),
	"SlothsHugeHoard": func(): _grant_cash(54100000),
	"SlothsEnormousEarnings": func(): _grant_cash(55800000),
	"SlothsGiganticGold": func(): _grant_cash(56900000),
	"SlothsTremendousTreasures": func(): _grant_cash(57500000),
	"SlothsMonumentalMillions": func(): _grant_cash(58900000),
	"SlothsMammothMoney": func(): _grant_cash(59100000),
	"SlothsImmenseIncome": func(): _grant_cash(60800000),
	"SlothsVastVault": func(): _grant_cash(61900000),
	"SlothsBroadBounty": func(): _grant_cash(62500000),
	"SlothsExpansiveEstate": func(): _grant_cash(63900000),
	"SlothsGrandGain": func(): _grant_cash(64100000),
	"SlothsMajorMillions": func(): _grant_cash(65800000),
	"SlothsPrimePayout": func(): _grant_cash(66900000),
	"SlothsSupremeStash": func(): _grant_cash(67500000),
	"SlothsUltimateYield": func(): _grant_cash(68900000),
	"SlothsInfiniteIncome": func(): _grant_cash(69100000),
	"SlothsLimitlessLoot": func(): _grant_cash(70800000),
	"SlothsBoundlessBounty": func(): _grant_cash(71900000),
	"SlothsUnendingEarnings": func(): _grant_cash(72500000),
	"SlothsCoutureCapital": func(): _grant_cash(73900000),
	"SlothsRoyalRiches": func(): _grant_cash(74100000),
	"SlothsKingpinKitties": func(): _grant_cash(75800000),
	"SlothsEmperorEstate": func(): _grant_cash(76900000),
	"SlothsDynastyDollars": func(): _grant_cash(77500000),
	"SlothsSovereignSupply": func(): _grant_cash(78900000),
	"SlothsMonarchMoney": func(): _grant_cash(79100000),
	"SlothsRegalRiches": func(): _grant_cash(80800000),
	"SlothsImperialIncome": func(): _grant_cash(81900000),
	"SlothsNobleNestEgg": func(): _grant_cash(82500000),
	"SlothsAristocratAssets": func(): _grant_cash(83900000),
	"SlothsEliteEarnings": func(): _grant_cash(84100000),
	"SlothsPrestigePayout": func(): _grant_cash(85800000),
	"SlothsOpulentOffer": func(): _grant_cash(86900000),
	"SlothsLuxuriousLoot": func(): _grant_cash(87500000),
	"SlothsGrandioseGold": func(): _grant_cash(88900000),
	"SlothsSumptuousSavings": func(): _grant_cash(89100000),
	"SlothsLavishLoot": func(): _grant_cash(90800000),
	"SlothsBountifulBank": func(): _grant_cash(91900000),
	"SlothsPlentifulPayout": func(): _grant_cash(92500000),
	"SlothsAbundantAssets": func(): _grant_cash(93900000),
	"SlothsCopiousCapital": func(): _grant_cash(94100000),
	"SlothsProfusePayout": func(): _grant_cash(95800000),
	"SlothsOverflowingOption": func(): _grant_cash(96900000),
	"SlothsRichRewards": func(): _grant_cash(975000000),
	"SlothsBillionaireBounty": func(): _grant_cash(989000000),
	## ── Seed cheat codes ──────────────────────────────────────
	"BeanBunch": func(): _grant_seeds(0, 256),
	"PickleBarrel": func(): _grant_seeds(1, 256),
	"PepperStash": func(): _grant_seeds(2, 256),
	"SquashTheComp": func(): _grant_seeds(3, 256),
	"GrapesOfWrath": func(): _grant_seeds(4, 256),
	"SunflowerPower": func(): _grant_seeds(5, 256),
	"CauliflowerCloud": func(): _grant_seeds(6, 256),
	"PineappleExpress": func(): _grant_seeds(7, 256),
	"WatermelonWave": func(): _grant_seeds(8, 256),
	## ── Orchard Sapling cheat codes ───────────────────────────
	"PlumGrove": func(): _grant_saplings(0, 10),
	"LemonGrove": func(): _grant_saplings(1, 10),
	"AppleGrove": func(): _grant_saplings(2, 10),
	"BananaGrove": func(): _grant_saplings(3, 10),
	"CoconutGrove": func(): _grant_saplings(4, 10),
	"OrchardOverload": func(): _grant_all_saplings(10),
	"SlothsOrchardPack": func(): _grant_all_saplings(10),
	## ── Resource cheat codes (wood, sticks, ores, bars) ───────
	## Each grants 10 of a single resource item (with the chest popup).
	"TimberHaul": func(): _grant_items(["wood"], 10),
	"StickBundle": func(): _grant_items(["stick"], 10),
	"IronVein": func(): _grant_items(["iron_ore"], 10),
	"IronStack": func(): _grant_items(["iron_bar"], 10),
	"CopperVein": func(): _grant_items(["copper_ore"], 10),
	"CopperStack": func(): _grant_items(["copper_ingot"], 10),
	"GoldStack": func(): _grant_items(["gold_ingot"], 10),
	## ── Resource pack codes ───────────────────────────────────
	## Grant 10 of each ore, each bar, or everything.
	"SlothsOrePack": func(): _grant_items(["iron_ore", "copper_ore"], 10),
	"SlothsBarPack": func(): _grant_items(["iron_bar", "copper_ingot", "gold_ingot"], 10),
	"SlothsResourcePack": func(): _grant_items(["wood", "stick", "iron_ore", "iron_bar", "copper_ore", "copper_ingot", "gold_ingot"], 10),
	## ── Alpha seeding cheats: 10,000,000 of a single bar/ingot ─────────
	## For stocking the base account to list on the market. Repeatable (see
	## REPEATABLE_CODES) so you can stack them for even larger stockpiles.
	"SlothsIronMountain":   func(): _grant_items(["iron_bar"], 10_000_000),
	"SlothsCopperMountain": func(): _grant_items(["copper_ingot"], 10_000_000),
	## ── Debug: marketplace backend connectivity test ─────────────
	## Pings Supabase and shows the result as a notification banner.
	"SlothPingMarket": func(): _debug_ping_marketplace(),
	## Registers (or re-fetches) this device's marketplace account. Shows the
	## one-time recovery-code popup if a brand-new account is created.
	"SlothRegisterMarket": func(): _debug_register_marketplace(),
	## Test listing flow: lists 1 Iron Bar at 100 tokens (grant some with
	## "IronStack" first). Deducts locally only if the server accepts.
	"SlothListTest": func(): _debug_list_test(),
	## Admin override: the NEXT online name change skips the 50M coin cost.
	## Then open the online market and use "✏ Change Name".
	"FreeNameChange": func(): _grant_free_name_change(),
	## Test/QA: pops a random Valentine's Valor message banner (to check the
	## long-message scrolling notification). Repeatable.
	"SlothValentine": func(): _debug_valentine_message(),
	## Grants 1 present of this save's assigned variant (repeatable for testing).
	"SlothPresent": func(): add_present(1),
	## ── Recipes / WonderStone / WonderVessels (testing) ───────────────
	## Each recipe code grants 10 of that recipe. "SlothsRecipeBox" grants 10
	## of EVERY recipe at once. All repeatable (see REPEATABLE_CODES).
	"SlothsGrapeJuice":   func(): _grant_recipes(["sparkling_grape_juice"], 10),
	"SlothsTrailMix":     func(): _grant_recipes(["sun_dried_trail_mix"], 10),
	"SlothsMelonSalad":   func(): _grant_recipes(["summer_melon_salad"], 10),
	"SlothsStuffedPeppers": func(): _grant_recipes(["stuffed_roasted_peppers"], 10),
	"SlothsPlumJam":      func(): _grant_recipes(["spicy_plum_jam"], 10),
	"SlothsSquashSoup":   func(): _grant_recipes(["roasted_cauliflower_and_squash_soup"], 10),
	"SlothsAppleGlaze":   func(): _grant_recipes(["smoked_apple_glaze"], 10),
	"SlothsFruitMash":    func(): _grant_recipes(["tropical_oat_and_fruit_mash"], 10),
	"SlothsCoconutWater": func(): _grant_recipes(["coconut_water_hydration"], 10),
	"SlothsBananaCrisp":  func(): _grant_recipes(["sweet_banana_crisp"], 10),
	"SlothsMelonLemonade": func(): _grant_recipes(["citrus_melon_lemonade"], 10),
	"SlothsVeggieBowl":   func(): _grant_recipes(["curried_veggie_bowl"], 10),
	"SlothsPhoBowl":      func(): _grant_recipes(["spiced_pho_noodle_bowl"], 10),
	"SlothsRecipeBox":    func(): _grant_recipes(recipe_ids(), 10),
	## WonderStones — grant 20 (one Lv10-chest's worth) per use.
	"SlothsWonderStones": func(): _grant_wonderstone(20),
	## WonderVessels — one of a given tier. "SlothsVesselSet" grants one of each.
	"SlothsVessel1":  func(): _grant_vessel(1),
	"SlothsVessel2":  func(): _grant_vessel(2),
	"SlothsVessel3":  func(): _grant_vessel(3),
	"SlothsVessel4":  func(): _grant_vessel(4),
	"SlothsVessel5":  func(): _grant_vessel(5),
	"SlothsVessel6":  func(): _grant_vessel(6),
	"SlothsVessel7":  func(): _grant_vessel(7),
	"SlothsVessel8":  func(): _grant_vessel(8),
	"SlothsVessel9":  func(): _grant_vessel(9),
	"SlothsVessel10": func(): _grant_vessel(10),
	"SlothsVesselSet": func(): _grant_vessel_set(),
}


## Debug helper: lists 1 "resource:iron_bar" at 100 tokens to exercise the
## list-and-deduct flow (Marketplace Task 8). Reports via banner.
func _debug_list_test() -> void:
	if get_node_or_null("/root/MarketplaceAccount") == null:
		return
	_run_list_test()


func _run_list_test() -> void:
	var before := market_count_owned("resource:iron_bar")
	if before < 1:
		if get_node_or_null("/root/GameNotification") != null:
			GameNotification.show_message("List test", "No Iron Bars — use IronStack first.")
		return
	var res: Dictionary = await MarketplaceAccount.list_and_deduct("resource:iron_bar", 1, 100, 3)
	if get_node_or_null("/root/GameNotification") == null:
		return
	if res.get("ok", false):
		var after := market_count_owned("resource:iron_bar")
		GameNotification.show_message("Listed ✅", "Iron Bar listed. Local: %d → %d" % [before, after])
	else:
		GameNotification.show_message("List failed ❌", str(res.get("error", "unknown")))


## Debug helper: registers this device's marketplace account and reports the
## result. Wired to the SlothRegisterMarket cheat (Marketplace Task 4).
func _debug_register_marketplace() -> void:
	if get_node_or_null("/root/MarketplaceAccount") == null:
		if get_node_or_null("/root/GameNotification") != null:
			GameNotification.show_message("Marketplace", "MarketplaceAccount autoload not found.")
		return
	_run_marketplace_register()


func _run_marketplace_register() -> void:
	## Registers with the player's OWN name (unified identity, migration 099),
	## or returns the existing account — whose name then becomes the local name.
	var res: Dictionary = await MarketplaceAccount.register_with_name(player_name)
	if res.get("ok", false) and MarketplaceAccount.username != "" \
			and MarketplaceAccount.username != player_name:
		adopt_online_name(MarketplaceAccount.username)
	if get_node_or_null("/root/GameNotification") == null:
		return
	if res.get("ok", false):
		if bool(res.get("created", false)):
			GameNotification.show_message("Marketplace ✅", "Account created: %s" % MarketplaceAccount.username)
		else:
			GameNotification.show_message("Marketplace ✅", "Signed in as %s (%d tokens)" % [
				MarketplaceAccount.username, MarketplaceAccount.token_balance])
	else:
		GameNotification.show_message("Marketplace ❌", str(res.get("error", "Registration failed")))


## Debug helper: pings the Supabase backend and surfaces the outcome via a
## Test/QA helper for the SlothValentine cheat: pops a random Valentine's Valor
## message banner so the long-message scrolling notification can be checked.
func _debug_valentine_message() -> void:
	if get_node_or_null("/root/GameNotification") == null:
		return
	var msg := "You are exactly where you belong, moving through life with a grace all your own."
	if get_node_or_null("/root/BusinessDistrict") != null \
			and not BusinessDistrict.VALENTINE_MESSAGES.is_empty():
		var pool: Array = BusinessDistrict.VALENTINE_MESSAGES
		msg = str(pool[randi() % pool.size()])
	GameNotification.show_message("💚 The Valentine's Valor", msg)


## Admin override for the FreeNameChange cheat: flags MarketplaceAccount so the
## next online name change skips the 50M coin cost. One-shot (consumed on use).
func _grant_free_name_change() -> void:
	if get_node_or_null("/root/MarketplaceAccount") != null:
		MarketplaceAccount.free_name_change = true
	if get_node_or_null("/root/GameNotification") != null:
		GameNotification.show_message("Free Name Change",
			"Your next name change is free. Open Settings → Change Name.")


## notification banner. Wired to the SlothPingMarket cheat code for manual
## connectivity testing (Marketplace Task 2).
func _debug_ping_marketplace() -> void:
	if get_node_or_null("/root/SupabaseClient") == null:
		if get_node_or_null("/root/GameNotification") != null:
			GameNotification.show_message("Marketplace", "SupabaseClient autoload not found.")
		return
	if not SupabaseClient.is_configured():
		if get_node_or_null("/root/GameNotification") != null:
			GameNotification.show_message("Marketplace not configured", SupabaseClient.debug_status())
		return
	## Fire-and-forget async ping; report when it resolves.
	_run_marketplace_ping()


func _run_marketplace_ping() -> void:
	var res: Dictionary = await SupabaseClient.ping()
	if get_node_or_null("/root/GameNotification") == null:
		return
	if res.get("ok", false):
		GameNotification.show_message("Marketplace ✅", "Connected to Supabase (status %d)." % int(res.get("status", 0)))
	else:
		GameNotification.show_message("Marketplace ❌", str(res.get("error", "Unknown error")))

## Tracks which codes have been redeemed (persisted in save file).
var redeemed_codes: Array[String] = []

## Lifetime coins granted via SlothsCashStash (persisted). Cap is 25,000,000.
const CASH_STASH_LIFETIME_CAP: int = 25_000_000
var cash_stash_lifetime_granted: int = 0


## Attempts to redeem a cheat code. Returns a message string.
## Empty string means success; non-empty means error.
## Debug/utility codes that can be entered repeatedly. They are NOT recorded in
## redeemed_codes and never persist, so they work unlimited times on any device
## (handy for testing where the save file isn't reachable, e.g. Android).
const REPEATABLE_CODES: Array[String] = ["SlothPingMarket", "SlothRegisterMarket", "SlothListTest", "FreeNameChange", "SlothValentine", "SlothPresent", "SlothPrintsMoney", "SlothMakeItRain", "SlothsIronMountain", "SlothsCopperMountain", "SlothsGoldRing", "SlothsBlueStone", "SlothsPinkStone", "SlothsVioletRing", "SlothsBlackPearl", "SlothsEmerald", "SlothsRubyRing", "SlothsDiamondRing", "SlothsJewelryBox"]

func redeem_code(code: String) -> String:
	if not _CHEAT_CODES.has(code):
		return "Invalid code."
	## Repeatable debug codes bypass the one-time redemption tracking entirely.
	if code in REPEATABLE_CODES:
		var repeat_fn: Callable = _CHEAT_CODES[code]
		repeat_fn.call()
		return ""
	if code in redeemed_codes:
		return "Code already redeemed."
	# Execute the reward
	var reward_fn: Callable = _CHEAT_CODES[code]
	reward_fn.call()
	redeemed_codes.append(code)
	save_data()
	return ""
func sloths_fresh_start() -> String:
	redeemed_codes = [] as Array[String]
	save_data()
	return "Codes Reset."
	
## Attempts to redeem the SlothsCashStash code with a player-chosen amount.
## Returns -1 on hard error (invalid code/cap reached/bad amount).
## Returns the actual amount granted on success (may be less than requested if clamped).
## Callers should compare returned value to requested amount to detect partial grants.
func redeem_cash_stash(code: String, amount: int) -> int:
	if code != "SlothsCashStash":
		return -1
	if cash_stash_lifetime_granted >= CASH_STASH_LIFETIME_CAP:
		return -1
	if amount < 1 or amount > 5_000_000:
		return -1
	## Clamp so we never exceed the lifetime cap
	var actual := mini(amount, CASH_STASH_LIFETIME_CAP - cash_stash_lifetime_granted)
	cash_stash_lifetime_granted += actual
	_grant_cash(actual)
	save_data()
	return actual

## Grants 256 of the specified seed type (plant_type index from GardenData.PlantType).
func _grant_seeds(plant_type: int, qty: int = 256) -> void:
	Garden.add_seeds(plant_type, qty, true)
	var crop_name: String = Garden.PLANT_DEFS[plant_type]["name"] if plant_type < Garden.PLANT_DEFS.size() else "Seeds"
	var rewards: Array = [{"type": "seed", "plant_type": plant_type, "quantity": qty}]
	ChestPopup.enqueue(get_tree(), 2, rewards, "Seed Stash!", "Here's %d %s seeds" % [qty, crop_name])


## Grants the specified quantity of saplings for a tree type.
func _grant_saplings(tree_type: int, qty: int = 10) -> void:
	if get_node_or_null("/root/Orchard") != null:
		get_node("/root/Orchard").add_saplings(tree_type, qty, true)
	var tree_name: String = "Sapling"
	if get_node_or_null("/root/Orchard") != null:
		var def: Dictionary = get_node("/root/Orchard").get_tree_def(tree_type)
		tree_name = def.get("name", "Sapling")
	var rewards: Array = [{"type": "sapling", "tree_type": tree_type, "quantity": qty}]
	ChestPopup.enqueue(get_tree(), 2, rewards, "Sapling Stash!", "Here's %d %s saplings" % [qty, tree_name])


## Grants 10 of each sapling type.
func _grant_all_saplings(qty_each: int = 10) -> void:
	var rewards: Array = []
	if get_node_or_null("/root/Orchard") != null:
		var orchard = get_node("/root/Orchard")
		for t in range(orchard.TREE_DEFS.size()):
			orchard.add_saplings(t, qty_each, false)
			rewards.append({"type": "sapling", "tree_type": t, "quantity": qty_each})
		orchard.orchard_updated.emit()
	ChestPopup.enqueue(get_tree(), 4, rewards, "Orchard Pack!", "Here's %d of each tree sapling!" % qty_each)


## Grants `qty_each` of each resource item id in `item_ids` (wood/sticks/ores/
## bars), then shows the chest popup with each item, mirroring the other packs.
func _grant_items(item_ids: Array, qty_each: int = 10) -> void:
	var rewards: Array = []
	for item_id in item_ids:
		var iid := str(item_id)
		fruits[iid] = fruits.get(iid, 0) + qty_each
		rewards.append({"type": "resource", "item_id": iid, "quantity": qty_each})
	save_data()
	data_changed.emit()
	ChestPopup.enqueue(get_tree(), 4, rewards, "Resource Pack!", "Here's %d of each!" % qty_each)


## Grants `qty_each` of each JEWELRY item id (produced rings/necklaces), via the
## canonical 'item:' store so counts/equipping work. ChestPopup has no 'item'
## reward renderer, so we report the grant with a notification instead.
func _grant_jewelry(item_ids: Array, qty_each: int = 1) -> void:
	var names: Array[String] = []
	for item_id in item_ids:
		var iid := str(item_id)
		market_add_owned("item:%s" % iid, qty_each)
		names.append(str(get_jewelry_def(iid).get("name", iid)))
	save_data()
	data_changed.emit()
	if get_node_or_null("/root/GameNotification") != null:
		var label := names[0] if names.size() == 1 else "%d jewelry items" % names.size()
		GameNotification.show_message("Jewelry granted", "Added %s — equip from Inventory → Jewelry." % label)


## Cheat: grants `qty_each` of each recipe id into the recipes store. Reports via
## a notification (ChestPopup has no recipe renderer).
func _grant_recipes(item_ids: Array, qty_each: int = 10) -> void:
	var names: Array[String] = []
	for rid in item_ids:
		var def := get_recipe_def(str(rid))
		if def.is_empty():
			continue
		recipes[str(rid)] = int(recipes.get(str(rid), 0)) + qty_each
		names.append(str(def.get("name", rid)))
	save_data()
	data_changed.emit()
	if get_node_or_null("/root/GameNotification") != null:
		var label := names[0] if names.size() == 1 else "%d recipes" % names.size()
		GameNotification.show_message("Recipes granted",
			"Added %d× %s — use them from the Marketplace Food tab." % [qty_each, label])


## Cheat: grants `qty` WonderStones. Reports via a notification.
func _grant_wonderstone(qty: int = 20) -> void:
	wonderstone_count += qty
	save_data()
	data_changed.emit()
	if get_node_or_null("/root/GameNotification") != null:
		GameNotification.show_message("WonderStones granted",
			"Added %d WonderStones — craft WonderVessels from Inventory." % qty)


## Cheat: grants one WonderVessel of `tier`. Reports via a notification.
func _grant_vessel(tier: int, qty: int = 1) -> void:
	if get_vessel_def(tier).is_empty():
		return
	wonder_vessels[tier] = get_vessel_count(tier) + qty
	save_data()
	data_changed.emit()
	if get_node_or_null("/root/GameNotification") != null:
		GameNotification.show_message("WonderVessel granted",
			"Added %d× WonderVessel (Tier %d)." % [qty, tier])


## Cheat: grants one WonderVessel of every tier (1..10).
func _grant_vessel_set() -> void:
	for tier in range(1, WONDERVESSEL_DEFS.size() + 1):
		wonder_vessels[tier] = get_vessel_count(tier) + 1
	save_data()
	data_changed.emit()
	if get_node_or_null("/root/GameNotification") != null:
		GameNotification.show_message("WonderVessels granted",
			"Added one of every WonderVessel tier (1–10).")


## Money Gun alpha cheats. The grants touch SERVER state (gun ownership /
## Benjamin balance), so they fire the async MoneyGun RPC helpers without
## awaiting — a notification reports the outcome (same fire-and-forget pattern
## as the marketplace debug cheats).
func _cheat_grant_money_gun() -> void:
	if get_node_or_null("/root/MoneyGun") != null:
		MoneyGun.cheat_grant_gun()
	elif get_node_or_null("/root/GameNotification") != null:
		GameNotification.show_message("Money Gun", "Money Gun system unavailable.")


func _cheat_grant_benjamins(amount: int) -> void:
	if get_node_or_null("/root/MoneyGun") != null:
		MoneyGun.cheat_grant_benjamins(amount)
	elif get_node_or_null("/root/GameNotification") != null:
		GameNotification.show_message("Benjamins", "Money Gun system unavailable.")


## Grants coins based on amount entered
func _grant_cash(amount) -> void:
	var rewards: Array = []
	# Grant 1m coins
	coins += amount
	rewards.append({"type": "coins", "amount": amount})
		
	save_data()
	data_changed.emit()
	
	# Show chest popup with level 5 animation (index 5)
	ChestPopup.enqueue(get_tree(), 5, rewards, "Fat Stacks of Cash", "Spend Wisely")
	
## Grants the Starter Pack: 5 of each player tile, 5 of each seed, and 500 coins.
## Shows a chest 5 animation with all rewards listed.
func _grant_starter_pack() -> void:
	var rewards: Array = []

	# Grant 5 of each non-enemy tile type
	var excluded := [Piece.Type.CLAW, Piece.Type.BITE]
	for t in Piece.Type.values():
		if t in excluded:
			continue
		var def = PieceRegistry.get_def(t as Piece.Type)
		if def == null or def.display_name == null or def.display_name == "":
			continue
		var dir: int = int(PieceDefinition.Direction.NONE)
		if def.effect_direction != PieceDefinition.Direction.NONE:
			dir = int(def.effect_direction)
		for i in range(5):
			inventory.append({"type": int(t), "direction": dir})
		rewards.append({"type": "piece", "piece_type": t, "count": 5})

	# Grant 5 of each seed type
	for plant_type in range(GardenData.PLANT_DEFS.size()):
		Garden.add_seeds(plant_type, 5, false)
		rewards.append({"type": "seed", "plant_type": plant_type, "quantity": 5})

	# Grant 500 coins
	coins += 500
	rewards.append({"type": "coins", "amount": 500})

	save_data()
	data_changed.emit()

	# Show chest popup with level 5 animation (index 5)
	ChestPopup.enqueue(get_tree(), 5, rewards, "Starter Pack", "Welcome to The World of Pho!")




## ── Daily Bonus ────────────────────────────────────────────────
## Daily bonus is an EXPONENTIAL curve (reworked from the old linear 1000/day).
## Main reward = DAILY_BONUS_BASE * DAILY_GROWTH_RATE^(day-1), clamped to
## DAILY_BONUS_MAX. The rate is chosen so the main reward grows from the day-1
## base (100,000) to the 1B cap at exactly day 365:
##   DAILY_GROWTH_RATE = (DAILY_BONUS_MAX / DAILY_BONUS_BASE)^(1/364)
##                     = 10000^(1/364) ≈ 1.025626  (about +2.56%/day)
## Reference main-reward points: day1=100,000; day20≈161,730; day60≈444,991;
## day180≈9.27M; day364≈975M; day365=1,000,000,000 (cap). A flat week bonus
## (DAILY_BONUS_WEEK_BONUS per completed 7-day period) is added on top.
const DAILY_BONUS_BASE := 100000           ## Day-1 main reward (coins)
const DAILY_BONUS_MAX := 1_000_000_000      ## Hard cap on the MAIN reward (reached day 365)
const DAILY_BONUS_WEEK_BONUS := 100000      ## Extra flat bonus every completed 7 days
const DAILY_GROWTH_RATE := 1.025625974372752  ## 10000^(1/364); +~2.56% per streak day
const DAILY_RESET_HOURS := 24         ## Hours between claims (resets at 24h)
const DAILY_GRACE_HOURS := 48         ## Hours before streak resets (miss a day = reset)

var daily_streak: int = 0             ## Current consecutive days claimed
var daily_last_claim: float = 0.0     ## Unix timestamp of last daily claim

## ── In-App Notification Settings ────────────────────────────────
## Per-category toggles for the in-app notification banners. Default on.
var notify_daily_bonus: bool = true   ## Banner when the daily bonus is claimable
var notify_garden: bool = true        ## Banner when a garden row is mostly ready
var notify_orchard: bool = true       ## Banner when an orchard tree has fruit ready
var notify_workshop: bool = true      ## Banner when the Workshop saw has polished gems ready
var notify_foundry: bool = true       ## Banner when the Workshop foundry has bars ready
var notify_missions: bool = true      ## Banner when a mission is ready to claim

## Notification thresholds: alert only once the ready count reaches this many.
## Saw/foundry: number of processed items (10/50/100). Orchard: number of ready
## trees (10/50/100). Garden: number of ready rows (1/5/10, or 0 = full garden).
var notify_saw_threshold: int = 10
var notify_foundry_threshold: int = 10
var notify_garden_threshold: int = 1   ## 0 means "the whole garden"
var notify_orchard_threshold: int = 10

## Daily "message of the day" banner — fires once per day at a random time.
var motd_last_shown_day: int = -1     ## Day index the MOTD was last shown on

## ── Active Campaign Run State ───────────────────────────────────
## Persists gauntlet progress across battle scenes. The battle scene (and its
## GameManager/CampaignManager) is destroyed and recreated on every
## battle→result→battle transition, so the run's progress must live somewhere
## that survives those transitions. Kept in-memory for the session.
var active_campaign: Dictionary = {}  ## { enemy_sequence, current_battle, wins, losses, enemy_count, terrain }

## ── Marketplace Refresh (daily limited) ─────────────────────────
## Players may pay to refresh shop stock a limited number of times per day.
## Base allowance is 3/day; prestige ("Merchant's Ledger") adds more.
const MARKET_REFRESH_COST := 500      ## Coins per refresh (unchanged)
const MARKET_REFRESH_BASE := 3        ## Free-to-buy refreshes per day (base)
## Prestige bonus refreshes per level (index 0 = level 1 ... index 9 = level 10).
## Ranges from +1 at the first prestige level up to +25 at the tenth.
const MARKET_REFRESH_PRESTIGE_BONUS: Array[int] = [1, 4, 7, 10, 13, 16, 19, 22, 24, 25]
var market_refreshes_used: int = 0    ## Refreshes purchased in the current day
var market_refresh_day: int = -1      ## Day index the counter applies to

## ── Mission Board Refresh (daily limited) ───────────────────────
## Players may pay to reroll a single mission a limited number of times per day.
## Base allowance is 3/day (shared across all difficulties); prestige adds more.
const MISSION_REFRESH_COST := 500     ## Coins per mission reroll
const MISSION_REFRESH_BASE := 3       ## Free-to-buy rerolls per day (base)
## Prestige bonus rerolls per level (index 0 = level 1 ... index 9 = level 10).
## Ranges from +1 at the first prestige level up to +25 at the tenth.
const MISSION_REFRESH_PRESTIGE_BONUS: Array[int] = [1, 4, 7, 10, 13, 16, 19, 22, 24, 25]
var mission_refreshes_used: int = 0   ## Mission rerolls purchased in the current day
var mission_refresh_day: int = -1     ## Day index the counter applies to

## Rarity weights for shop pool generation (higher = more common).
## Scaled inversely to price/power.
const SHOP_WEIGHTS := {
	Piece.Type.PAWN: 25,
	Piece.Type.SOLDIER: 20,
	Piece.Type.SAIL: 12,
	Piece.Type.WIND: 10,
	Piece.Type.MAGE: 8,
	Piece.Type.SHIELD: 8,
	Piece.Type.TREE: 6,
	Piece.Type.SLEEP: 5,
	Piece.Type.DRUID: 4,
	Piece.Type.CLERGY: 4,
	Piece.Type.DOME: 3,
	Piece.Type.BLACK_HOLE: 2,
	Piece.Type.WATCHTOWER: 4,
	Piece.Type.KING: 1,
}

## Stores the result of offline prospector collection on startup (gem_type -> count).
## main.gd reads this to show a popup, then clears it.
var offline_prospector_haul: Dictionary = {}

## XP / level thresholds — scales with level
var xp: int = 0                  ## Current progress XP (can be spent)
var lifetime_xp: int = 0         ## Total XP earned all-time (never decreases)
const XP_BASE := 1000            ## XP needed for level 2 (doubles each level)

## ── Prestige Upgrades ────────────────────────────────────────────
## Guild membership (cached locally; authoritative copy is server-side).
## guild_id   — UUID of the guild this player belongs to, or "" if none.
## guild_role — "leader" | "member" | "" when not in a guild.
var guild_id: String = ""
var guild_role: String = ""

## Each upgrade has 10 levels. Stored as { upgrade_id -> current_level (0-10) }
var prestige_levels: Dictionary = {}

## One-time flag: whether the prestige-repricing migration has run for this save
## (see _migrate_prestige_repricing). Persisted so it only happens once.
var prestige_reprice_migrated: bool = false

## One-time flag: whether the 100B prestige-recalculation migration has run for
## this save (see _migrate_prestige_100b). Persisted so it only happens once.
var prestige_100b_migrated: bool = false

## One-time flag: whether the 100B migration straggler pass has run (catches
## tracks that were missed in the initial 100B migration).
var prestige_100b_v2_migrated: bool = false

## XP cost for each prestige level (index 0 = level 1 cost, index 9 = level 10 cost)
## The ORIGINAL shared prestige curve (10k → 5M). Frozen here purely so the
## one-time repricing migration below can still reconstruct what players paid
## under the very first pricing, independent of later live-curve changes. Do
## NOT use this for live costs — see PRESTIGE_XP_COSTS.
const PRESTIGE_XP_COSTS_LEGACY: Array[int] = [
	10_000, 30_000, 80_000, 200_000, 500_000,
	1_000_000, 1_800_000, 2_800_000, 4_000_000, 5_000_000
]

## Pre-100B override curves, frozen for the level-recalculation migration below.
## These are what the Deep Mine / Orchard / Auto-Collect tracks charged right
## BEFORE the 100B retune, so we can reconstruct exactly what each player paid.
const PRESTIGE_XP_COSTS_DEEP_MINE_LEGACY: Array[int] = [
	1_000_000, 1_500_000, 2_250_000, 3_400_000, 5_000_000,
	7_500_000, 11_000_000, 16_000_000, 24_000_000, 35_000_000
]
const PRESTIGE_XP_COSTS_ORCHARD_LEGACY: Array[int] = [
	500_000, 750_000, 1_100_000, 1_700_000, 2_500_000,
	3_800_000, 5_600_000, 8_400_000, 12_600_000, 19_000_000
]
const PRESTIGE_XP_COSTS_AUTO_COLLECT_LEGACY: Array[int] = [
	10_000_000, 15_000_000, 22_000_000, 33_000_000, 50_000_000,
	75_000_000, 110_000_000, 160_000_000, 240_000_000, 350_000_000
]

## Maps each track to the curve it charged BEFORE the 100B retune. Tracks not
## listed used the shared PRESTIGE_XP_COSTS_LEGACY (10k → 5M). Used only by the
## level-recalculation migration to reconstruct prior spend.
const PRESTIGE_PRE_100B_OVERRIDES: Dictionary = {
	"mine_layers": PRESTIGE_XP_COSTS_DEEP_MINE_LEGACY,
	"mine_multi_layer": PRESTIGE_XP_COSTS_DEEP_MINE_LEGACY,
	"excavator_rows": PRESTIGE_XP_COSTS_DEEP_MINE_LEGACY,
	"mine_auto_collect": PRESTIGE_XP_COSTS_AUTO_COLLECT_LEGACY,
	"fruit_profit": PRESTIGE_XP_COSTS_ORCHARD_LEGACY,
}

## Geometric scale across 10 levels (default for most tracks). Retuned so the
## top level costs 100B XP — a true long-haul goal that keeps mid/high-level
## players (e.g. billions of XP) still working through the tree rather than
## maxing everything at once.
const PRESTIGE_XP_COSTS: Array[int] = [
	1_000_000, 5_000_000, 20_000_000, 75_000_000, 250_000_000,
	800_000_000, 3_000_000_000, 10_000_000_000, 35_000_000_000, 100_000_000_000
]

## Deep Mine prestige tracks are the priciest — start higher and top out at 250B.
const PRESTIGE_XP_COSTS_DEEP_MINE: Array[int] = [
	5_000_000, 20_000_000, 70_000_000, 220_000_000, 650_000_000,
	1_800_000_000, 5_000_000_000, 18_000_000_000, 60_000_000_000, 250_000_000_000
]

## Orchard prestige track(s): a touch cheaper than the default, topping out at 60B.
const PRESTIGE_XP_COSTS_ORCHARD: Array[int] = [
	500_000, 2_500_000, 10_000_000, 40_000_000, 140_000_000,
	450_000_000, 1_600_000_000, 6_000_000_000, 22_000_000_000, 60_000_000_000
]

## Deep Mine auto-collect: the premium unlock — the most expensive track, 300B at max.
const PRESTIGE_XP_COSTS_AUTO_COLLECT: Array[int] = [
	10_000_000, 40_000_000, 130_000_000, 400_000_000, 1_200_000_000,
	3_500_000_000, 10_000_000_000, 30_000_000_000, 90_000_000_000, 300_000_000_000
]

## Per-track cost curve overrides. Tracks not listed use PRESTIGE_XP_COSTS.
const PRESTIGE_COST_OVERRIDES: Dictionary = {
	## Deep Mine
	"mine_layers": PRESTIGE_XP_COSTS_DEEP_MINE,
	"mine_multi_layer": PRESTIGE_XP_COSTS_DEEP_MINE,
	"excavator_rows": PRESTIGE_XP_COSTS_DEEP_MINE,
	"mine_auto_collect": PRESTIGE_XP_COSTS_AUTO_COLLECT,
	## Orchard
	"fruit_profit": PRESTIGE_XP_COSTS_ORCHARD,
}

## Returns the cost curve (Array of 10 XP costs) for a given upgrade id.
func _prestige_cost_curve(upgrade_id: String) -> Array:
	return PRESTIGE_COST_OVERRIDES.get(upgrade_id, PRESTIGE_XP_COSTS)

## XP cost for a specific level index (0-9) of an upgrade, honoring per-track
## curve overrides. Clamps the index to the valid range.
func prestige_cost_for_level(upgrade_id: String, level_index: int) -> int:
	var curve := _prestige_cost_curve(upgrade_id)
	var idx := clampi(level_index, 0, curve.size() - 1)
	return int(curve[idx])


## Cumulative XP cost to own `levels` levels of a track under a given curve
## (sum of curve[0 .. levels-1]).
func _cumulative_prestige_cost(curve: Array, levels: int) -> int:
	var total: int = 0
	var n := clampi(levels, 0, curve.size())
	for i in range(n):
		total += int(curve[i])
	return total


## One-time migration for prestige tracks whose price curve was raised after
## players had already bought levels at the OLD (cheaper) shared price.
##
## Before the repricing, every track used the shared PRESTIGE_XP_COSTS curve.
## For each retuned track we reconstruct what the player actually paid under the
## OLD curve for their current level, then find the highest level that same
## amount buys under the NEW curve. Any excess is refunded to spendable xp, so
## the player effectively re-pays the new price and keeps only the levels they
## could truly afford. Runs exactly once (guarded by prestige_reprice_migrated).
func _migrate_prestige_repricing() -> void:
	if prestige_reprice_migrated:
		return
	## Tracks that were retuned, mapped to the OLD curve they were bought under.
	## (All retuned tracks previously used the shared original curve — see
	## PRESTIGE_XP_COSTS_LEGACY.)
	var retuned_ids := PRESTIGE_COST_OVERRIDES.keys()
	var refund: int = 0
	for id in retuned_ids:
		var current_level: int = int(prestige_levels.get(id, 0))
		if current_level <= 0:
			continue
		var old_curve: Array = PRESTIGE_XP_COSTS_LEGACY
		var new_curve: Array = _prestige_cost_curve(id)
		## What they paid under the old shared price for this level.
		var old_paid: int = _cumulative_prestige_cost(old_curve, current_level)
		## Highest level that same spend now buys under the new (pricier) curve.
		var affordable: int = 0
		while affordable < current_level and _cumulative_prestige_cost(new_curve, affordable + 1) <= old_paid:
			affordable += 1
		if affordable < current_level:
			prestige_levels[id] = affordable
			refund += old_paid - _cumulative_prestige_cost(new_curve, affordable)
	if refund > 0:
		## Return the over-refunded (never actually earned extra) portion to the
		## spendable pool so the player can re-spend it toward the new prices.
		xp += refund
	prestige_reprice_migrated = true


## Returns the curve a track charged BEFORE the 100B retune, so we can
## reconstruct what a player actually paid for their owned levels.
func _prestige_pre_100b_curve(upgrade_id: String) -> Array:
	return PRESTIGE_PRE_100B_OVERRIDES.get(upgrade_id, PRESTIGE_XP_COSTS_LEGACY)


## One-time migration for the 100B prestige retune. Recalculates EVERY prestige
## track against the new (much pricier) curves:
##   1. Reconstruct what the player paid for their current level under the curve
##      that was live BEFORE this retune (per-track; see _prestige_pre_100b_curve).
##   2. Re-apply that spend under the NEW curve, keeping the highest level it
##      still affords.
##   3. Refund any remaining balance to spendable XP so nothing is lost.
## The player's total XP investment is preserved — levels they can no longer
## afford are converted back into spendable XP. Runs exactly once per save.
func _migrate_prestige_100b() -> void:
	if prestige_100b_migrated:
		return
	var refund: int = 0
	for id in PRESTIGE_UPGRADE_IDS:
		var current_level: int = int(prestige_levels.get(id, 0))
		if current_level <= 0:
			continue
		var old_curve: Array = _prestige_pre_100b_curve(id)
		var new_curve: Array = _prestige_cost_curve(id)
		## What the player actually paid for their owned levels (old curve).
		var paid: int = _cumulative_prestige_cost(old_curve, current_level)
		## Highest level that same spend buys under the new (pricier) curve.
		var affordable: int = 0
		while affordable < new_curve.size() and _cumulative_prestige_cost(new_curve, affordable + 1) <= paid:
			affordable += 1
		## Never grant MORE levels than they had (a track could get cheaper for
		## some early levels; we only ever refund, never inflate).
		affordable = mini(affordable, current_level)
		prestige_levels[id] = affordable
		## Refund the leftover balance (their spend minus the re-applied cost).
		refund += paid - _cumulative_prestige_cost(new_curve, affordable)
	if refund > 0:
		xp += refund
	prestige_100b_migrated = true


## Straggler pass: recalculates the five tracks that were missing from
## PRESTIGE_UPGRADE_IDS when the initial 100B migration ran. Identical logic
## to _migrate_prestige_100b but scoped to just the missed IDs. Runs once.
const _PRESTIGE_100B_STRAGGLER_IDS: Array[String] = [
	"fruit_profit", "auto_plant", "xp_boost", "market_refresh", "mission_refresh"
]
func _migrate_prestige_100b_v2() -> void:
	if prestige_100b_v2_migrated:
		return
	var refund: int = 0
	for id in _PRESTIGE_100B_STRAGGLER_IDS:
		var current_level: int = int(prestige_levels.get(id, 0))
		if current_level <= 0:
			continue
		var old_curve: Array = _prestige_pre_100b_curve(id)
		var new_curve: Array = _prestige_cost_curve(id)
		var paid: int = _cumulative_prestige_cost(old_curve, current_level)
		var affordable: int = 0
		while affordable < new_curve.size() and _cumulative_prestige_cost(new_curve, affordable + 1) <= paid:
			affordable += 1
		affordable = mini(affordable, current_level)
		prestige_levels[id] = affordable
		refund += paid - _cumulative_prestige_cost(new_curve, affordable)
	if refund > 0:
		xp += refund
	prestige_100b_v2_migrated = true

const PRESTIGE_UPGRADE_IDS: Array[String] = [
	"crop_time", "safe_tiles", "prospector_time",
	"prospector_cost", "gem_profit", "garden_profit",
	"fruit_profit", "auto_plant", "xp_boost",
	"market_refresh", "mission_refresh",
	"mine_layers", "mine_multi_layer", "excavator_rows", "mine_auto_collect",
	"saw_capacity", "saw_speed", "saw_parallel", "hourglass",
	"foundry_capacity", "foundry_speed", "foundry_parallel", "misc_value",
	"passive_xp", "horse_training_cap", "horse_stable_size"
]

## ── New prestige paths: passive XP + horse training cap + stable size ──────

## Passive XP (Steady Learner): hybrid flat XP + tiny % of next level's XP per
## hour, by prestige level (index 0 = level 1). Granted as raw XP (not
## multiplied by Scholar), offline included.
const PASSIVE_XP_PER_HOUR: Array[int] = [
	1_000, 3_000, 10_000, 30_000, 100_000,
	300_000, 1_000_000, 2_500_000, 5_000_000, 10_000_000
]
const PASSIVE_XP_PERCENT: Array[float] = [
	0.005, 0.010, 0.015, 0.020, 0.025,
	0.030, 0.035, 0.040, 0.045, 0.050
]

## Player level stops at MAX_LEVEL; XP keeps accumulating past it (it can still
## be spent). XP_HARD_CAP keeps the XP total far below the int64 limit so it
## can never wrap negative (which previously reset players to level 1).
const MAX_LEVEL := 100
const XP_HARD_CAP: int = 1_000_000_000_000_000_000

## Max stat points ONE training session can earn, by level (base 10 at L0).
## L1 = 11 ... L10 = 50. MUST match _horse_prestige_training_bonus (migration 107).
const HORSE_TRAINING_CAP_BY_LEVEL: Array[int] = [11, 13, 16, 19, 23, 27, 32, 38, 44, 50]

## Passive XP credited after an absence of 15+ min, not yet shown to the
## player. main.gd shows it in the offline report popup, then clears it.
var offline_passive_xp: int = 0

## Unix time passive XP was last credited up to (persisted).
var passive_xp_last_ts: float = 0.0

## Flat XP/hr portion from the passive XP path (0 when not owned).
func get_passive_xp_flat_per_hour() -> int:
	var lvl := get_prestige_level("passive_xp")
	if lvl <= 0:
		return 0
	return PASSIVE_XP_PER_HOUR[clampi(lvl, 1, PASSIVE_XP_PER_HOUR.size()) - 1]


## Percent of next level's XP earned per hour (0.0 when not owned).
func get_passive_xp_percent() -> float:
	var lvl := get_prestige_level("passive_xp")
	if lvl <= 0:
		return 0.0
	return PASSIVE_XP_PERCENT[clampi(lvl, 1, PASSIVE_XP_PERCENT.size()) - 1]


## Total XP per hour from the passive XP path right now (0 when not owned).
func get_passive_xp_per_hour() -> int:
	return int(floor(_passive_xp_rate()))


## Hybrid XP/hr: flat base + small % of next level's XP (at MAX_LEVEL uses last step).
func _passive_xp_rate() -> float:
	var flat: int = get_passive_xp_flat_per_hour()
	var pct: float = get_passive_xp_percent()
	if flat <= 0 and pct <= 0.0:
		return 0.0
	var step: int = xp_for_level(mini(level, MAX_LEVEL))
	return float(flat) + float(step) * pct / 100.0

## Per-session training cap from prestige alone (10 when not owned).
func get_prestige_training_cap() -> int:
	var lvl := get_prestige_level("horse_training_cap")
	if lvl <= 0:
		return 10
	return HORSE_TRAINING_CAP_BY_LEVEL[clampi(lvl, 1, HORSE_TRAINING_CAP_BY_LEVEL.size()) - 1]

## Extra stable slots from prestige (+1 per level, +10 at L10).
func get_prestige_stable_bonus() -> int:
	return get_prestige_level("horse_stable_size")

## Credits passive XP earned since the last check (works across app restarts).
## Only whole XP is credited; the leftover fraction carries over. Call often —
## a 60s timer + load + after a prestige checkout.
func accrue_passive_xp() -> void:
	var now := TrustedClock.now()
	var rate: float = _passive_xp_rate()
	if rate <= 0.0 or passive_xp_last_ts <= 0.0 or passive_xp_last_ts > now:
		## Not owned yet / no XP (or clock went backwards): start the clock from now.
		passive_xp_last_ts = now
		return
	var seconds_per_xp: float = 3600.0 / rate
	var elapsed: float = now - passive_xp_last_ts
	## Compute in float and clamp before converting, so a huge rate or a long
	## absence can't overflow the int.
	var earned_f: float = floor(elapsed / seconds_per_xp)
	var room: int = maxi(0, XP_HARD_CAP - xp)
	var earned: int = room if earned_f >= float(room) else int(earned_f)
	if earned <= 0:
		## At the XP cap (or nothing earned yet): keep the clock moving so
		## time doesn't pile up.
		if room <= 0:
			passive_xp_last_ts = now
		return
	## Away for 15+ minutes: remember the gain so main.gd can show a report.
	if elapsed >= 900.0:
		offline_passive_xp += earned
	passive_xp_last_ts += earned * seconds_per_xp
	var old_level := level
	xp += earned
	lifetime_xp = mini(lifetime_xp + earned, XP_HARD_CAP)
	recalculate_level()
	_check_level_up(old_level)
	save_data()
	emit_signal("data_changed")

## Pushes the horse prestige levels to the server (training cap + stable size
## are enforced server-side). Safe to call often; no-op when offline.
func sync_horse_prestige(refresh_stable: bool = true) -> void:
	if get_node_or_null("/root/MarketplaceAccount") == null \
			or not MarketplaceAccount.has_account() \
			or get_node_or_null("/root/SupabaseClient") == null \
			or not SupabaseClient.is_configured():
		return
	var body := {
		"p_device_hash":    MarketplaceAccount._device_hash(),
		"p_training_level": get_prestige_level("horse_training_cap"),
		"p_stable_level":   get_prestige_level("horse_stable_size"),
	}
	## Horseshoe bonus levels (count-based) also raise the training cap of the
	## shoe's stat (migration 111) — they work like the Master Trainer prestige.
	if get_node_or_null("/root/HorseRacing") != null:
		body["p_copper_level"] = HorseRacing.horseshoe_level("copper")
		body["p_iron_level"]   = HorseRacing.horseshoe_level("iron")
	await SupabaseClient.request_json("POST", "/rest/v1/rpc/set_horse_prestige", body)
	## Refresh the stable so the new capacity shows immediately.
	if refresh_stable and get_node_or_null("/root/HorseRacing") != null \
			and HorseRacing.has_method("refresh"):
		HorseRacing.refresh()

## Returns the XP cost to reach the next level for a given upgrade.
## Returns -1 if already at max level (10).
func get_prestige_upgrade_cost(upgrade_id: String) -> int:
	var current: int = prestige_levels.get(upgrade_id, 0)
	if current >= 10:
		return -1
	return int(_prestige_cost_curve(upgrade_id)[current])

## Returns the current level (0-10) for a prestige upgrade.
func get_prestige_level(upgrade_id: String) -> int:
	return prestige_levels.get(upgrade_id, 0)

## ── Prestige Multipliers (read these wherever the effect applies) ─

## Crop harvest time multiplier (1.0 = normal, 0.5 = 50% faster at max)
func get_crop_time_multiplier() -> float:
	return 1.0 - get_prestige_level("crop_time") * 0.05

## Safe pre-revealed tiles for expeditions (0 at base)
func get_safe_expedition_tiles() -> int:
	return get_prestige_level("safe_tiles")

## Prospector interval multiplier (1.0 = normal, 0.5 = 50% faster at max)
func get_prospector_time_multiplier() -> float:
	return 1.0 - get_prestige_level("prospector_time") * 0.05

## Prospector price multiplier (1.0 = normal, 0.5 = 50% cheaper at max)
func get_prospector_cost_multiplier() -> float:
	return 1.0 - get_prestige_level("prospector_cost") * 0.05

## Shared sell-price prestige ramp (percent bonus added to sale value).
## Index 0 = level 1 ... index 9 = level 10. Ramps from +25% up to +1000%.
## Used by every "increase sell price" prestige (gems, garden, fruit) so they
## all scale identically.
const SELL_PRICE_PRESTIGE_BONUS_PCT: Array[int] = [25, 75, 150, 250, 375, 525, 700, 850, 950, 1000]

## Returns the sell-price multiplier for a given prestige upgrade id.
## 1.0 at level 0, then 1.0 + (bonus%/100) from the shared ramp above.
func _sell_price_multiplier(upgrade_id: String) -> float:
	var lvl := get_prestige_level(upgrade_id)
	if lvl <= 0:
		return 1.0
	lvl = clampi(lvl, 1, SELL_PRICE_PRESTIGE_BONUS_PCT.size())
	return 1.0 + float(SELL_PRICE_PRESTIGE_BONUS_PCT[lvl - 1]) / 100.0

## Gem sell value multiplier (+25% at L1 up to +1000% at L10).
func get_gem_profit_multiplier() -> float:
	return _sell_price_multiplier("gem_profit")

## Garden harvest reward multiplier (+25% at L1 up to +1000% at L10).
func get_garden_profit_multiplier() -> float:
	return _sell_price_multiplier("garden_profit")

## Orchard fruit sell value multiplier (+25% at L1 up to +1000% at L10).
func get_fruit_profit_multiplier() -> float:
	return _sell_price_multiplier("fruit_profit")

## Misc resource (wood, sticks, and future misc items) sell value multiplier
## (+25% at L1 up to +1000% at L10). Ores/bars use get_gem_profit_multiplier.
func get_misc_profit_multiplier() -> float:
	return _sell_price_multiplier("misc_value")

## Number of rows the Auto-Plant button fills at once (0 = feature locked)
func get_auto_plant_rows() -> int:
	return get_prestige_level("auto_plant")

## The player's chosen number of garden rows to auto-plant (0 = all unlocked).
## Picked in the garden's Auto-Plant "Rows:" dropdown; saved.
var garden_auto_plant_rows: int = 0
## Same for the orchard and the guild garden (each remembered separately).
var orchard_auto_plant_rows: int = 0
var guild_garden_auto_plant_rows: int = 0

## Clamps a saved rows pick to 1..unlocked; 0 or above-unlocked means all.
func resolve_auto_plant_rows(pick: int) -> int:
	var max_rows: int = get_auto_plant_rows()
	if pick <= 0 or pick > max_rows:
		return max_rows
	return pick

## XP gain multiplier from Scholar prestige (+25% at L1 up to +1000% at L10).
func get_xp_multiplier() -> float:
	## Scholar prestige × equipped violet_stone "xp_gain" jewelry (multiplicative).
	var mult := _sell_price_multiplier("xp_boost")
	if get_node_or_null("/root/JewelryBonus") != null:
		mult *= JewelryBonus.xp_multiplier()
	return mult

## Doubles each level with ±15% random variation (seeded by level so it's consistent per player).
## ── Level and XP Calculation ──────────────────────────────────

## Returns the XP required to level up from a specific level to the next.
func xp_for_level(lvl: int) -> int:
	var base_needed: int = XP_BASE * int(pow(2, mini(lvl - 1, 30))) ## Capped power to prevent int overflow
	var variation_seed: int = (lvl * 7919) % 100
	var variation: float = 0.85 + (variation_seed / 100.0) * 0.30
	return int(base_needed * variation)


## Returns total cumulative XP required from level 1 to reach level `lvl`.
func cumulative_xp_for_level(lvl: int) -> int:
	var total: int = 0
	for l in range(1, lvl):
		total += xp_for_level(l)
	return total


## Returns the total cumulative XP required to reach the next level from current level.
func xp_for_next_level() -> int:
	return cumulative_xp_for_level(level + 1)


## Returns the XP progress within the current level (delta from current level start).
func get_current_level_progress_xp() -> int:
	return maxi(0, xp - cumulative_xp_for_level(level))


## Returns the total unspent XP (which is xp).
func get_total_xp() -> int:
	return xp


## Recalculates player level based on current cumulative xp value.
## Resets level to 1 and levels up step-by-step.
## Triggered after prestige spending and upon game load.
## Does NOT modify lifetime_xp.
func recalculate_level() -> void:
	if xp > XP_HARD_CAP:
		xp = XP_HARD_CAP
	level = 1
	## Walk up one level at a time, adding each level's cost (O(n), stops at
	## MAX_LEVEL — XP beyond that is kept but doesn't raise the level).
	var needed_for_next: int = 0
	while level < MAX_LEVEL:
		needed_for_next += xp_for_level(level)
		if xp >= needed_for_next:
			level += 1
		else:
			break
	## Track the all-time peak so the home screen can show "current/peak".
	peak_level = mini(peak_level, MAX_LEVEL)
	if level > peak_level:
		peak_level = level


## Removes `amount` XP (current and lifetime, floored at 0) and resets the peak
## level to the recalculated level. Used by the SlothXpRollback fix code.
func _rollback_xp(amount: int) -> void:
	xp = maxi(0, xp - amount)
	lifetime_xp = maxi(0, lifetime_xp - amount)
	offline_passive_xp = 0
	recalculate_level()
	peak_level = level
	save_data()
	data_changed.emit()


func recalculate_after_spend() -> void:
	recalculate_level()
	save_data()
	data_changed.emit()


## Attempts to buy a permanent boost using available XP. Returns true if successful.
func buy_permanent_boost(cost: int) -> bool:
	if xp < cost:
		return false
	xp = maxi(0, xp - cost)
	recalculate_level()
	save_data()
	data_changed.emit()
	return true

func _ready() -> void:
	load_data()
	## Collect offline prospector gems and store result for popup
	offline_prospector_haul = collect_prospector_gems()

	## Passive XP prestige: credit offline time now, then every minute.
	accrue_passive_xp()
	var passive_xp_timer := Timer.new()
	passive_xp_timer.wait_time = 60.0
	passive_xp_timer.autostart = true
	passive_xp_timer.timeout.connect(accrue_passive_xp)
	add_child(passive_xp_timer)

	## Ensure shop pools are generated immediately if empty (new player or first launch)
	_check_shop_pool_refresh()
	_check_tool_shop_refresh()

	## Periodic autosave
	var timer := Timer.new()
	timer.wait_time = AUTOSAVE_INTERVAL
	timer.autostart = true
	timer.timeout.connect(save_data)
	add_child(timer)

	## Periodic shop pool refresh check (every 60 seconds)
	var shop_timer := Timer.new()
	shop_timer.wait_time = 60.0
	shop_timer.autostart = true
	shop_timer.timeout.connect(_check_shop_pool_refresh)
	add_child(shop_timer)

	var tool_timer := Timer.new()
	tool_timer.wait_time = 60.0
	tool_timer.autostart = true
	tool_timer.timeout.connect(_check_tool_shop_refresh)
	add_child(tool_timer)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_data()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		save_data()

## ── Persistence ────────────────────────────────────────────────

func save_data() -> void:
	var config := ConfigFile.new()
	config.set_value("player", "name", player_name)
	config.set_value("player", "level", level)
	config.set_value("player", "peak_level", peak_level)
	config.set_value("player", "coins", coins)
	config.set_value("player", "xp", xp)
	config.set_value("player", "lifetime_xp", lifetime_xp)
	config.set_value("player", "storage_upgrades", storage_upgrades)
	config.set_value("player", "has_set_name", has_set_name)
	config.set_value("player", "market_suggested_pricing_seen", market_suggested_pricing_seen)
	config.set_value("player", "guild_reward_xp_watermark", guild_reward_xp_watermark)
	config.set_value("prestige", "levels", prestige_levels)
	config.set_value("prestige", "passive_xp_last_ts", passive_xp_last_ts)
	config.set_value("prestige", "garden_auto_plant_rows", garden_auto_plant_rows)
	config.set_value("prestige", "orchard_auto_plant_rows", orchard_auto_plant_rows)
	config.set_value("prestige", "guild_garden_auto_plant_rows", guild_garden_auto_plant_rows)
	config.set_value("prestige", "reprice_migrated", prestige_reprice_migrated)
	config.set_value("prestige", "reprice_100b_migrated", prestige_100b_migrated)
	config.set_value("prestige", "reprice_100b_v2_migrated", prestige_100b_v2_migrated)
	config.set_value("player", "name_changes", name_changes)

	## Serialize inventory (tiles only — gemstones stored separately).
	## Direction is intentionally NOT saved: it only matters while a tile is in
	## the player's hand during a battle and resets to the piece's default
	## afterwards. Storing compact counts per type keeps the save small.
	var inv_counts: Dictionary = {}
	for item in inventory:
		if item.has("type"):
			var t := int(item["type"])
			inv_counts[t] = int(inv_counts.get(t, 0)) + 1
	config.set_value("player", "inventory_counts", inv_counts)

	## Serialize shop pool
	var pool_data: Dictionary = {}
	for key in shop_pool:
		pool_data[int(key)] = shop_pool[key]
	config.set_value("shop", "pool", pool_data)
	config.set_value("shop", "timestamp", shop_pool_timestamp)

	## Save daily bonus
	config.set_value("daily", "streak", daily_streak)
	config.set_value("daily", "last_claim", daily_last_claim)

	## Save notification settings
	config.set_value("notifications", "daily_bonus", notify_daily_bonus)
	config.set_value("notifications", "garden", notify_garden)
	config.set_value("notifications", "orchard", notify_orchard)
	config.set_value("notifications", "workshop", notify_workshop)
	config.set_value("notifications", "foundry", notify_foundry)
	config.set_value("notifications", "missions", notify_missions)
	config.set_value("notifications", "saw_threshold", notify_saw_threshold)
	config.set_value("notifications", "foundry_threshold", notify_foundry_threshold)
	config.set_value("notifications", "garden_threshold", notify_garden_threshold)
	config.set_value("notifications", "orchard_threshold", notify_orchard_threshold)
	config.set_value("notifications", "motd_last_shown_day", motd_last_shown_day)

	## Save marketplace daily refresh counter
	config.set_value("market", "refreshes_used", market_refreshes_used)
	config.set_value("market", "refresh_day", market_refresh_day)

	## Save mission board daily reroll counter
	config.set_value("missions", "refreshes_used", mission_refreshes_used)
	config.set_value("missions", "refresh_day", mission_refresh_day)

	## Save tools
	var tools_data: Dictionary = {}
	for key in tools:
		tools_data[int(key)] = tools[key]
	config.set_value("tools", "inventory", tools_data)
	var tool_pool_data: Dictionary = {}
	for key in tool_shop_pool:
		tool_pool_data[int(key)] = tool_shop_pool[key]
	config.set_value("tools", "shop_pool", tool_pool_data)
	config.set_value("tools", "shop_timestamp", tool_shop_timestamp)

	## Save tutorial state
	config.set_value("tutorial", "completed", tutorial_completed)
	config.set_value("tutorial", "step_index", tutorial_step_index)
	config.set_value("tutorial", "home_dismissed", tutorial_home_dismissed)

	## Save items
	config.set_value("items", "diamond_ring_count", diamond_ring_count)
	config.set_value("items", "jewelry", jewelry)
	config.set_value("items", "recipes", recipes)
	config.set_value("items", "active_boosts", active_boosts)
	config.set_value("items", "wonderstone_count", wonderstone_count)
	config.set_value("items", "wonder_vessels", wonder_vessels)
	config.set_value("items", "equipped_ring", equipped_ring)
	config.set_value("items", "equipped_necklace", equipped_necklace)
	config.set_value("items", "equipped_misc", equipped_misc)
	config.set_value("items", "money_gun_owned", money_gun_owned)
	config.set_value("items", "money_gun_level", money_gun_level)
	config.set_value("items", "fruits", fruits)
	config.set_value("items", "crops", crops)
	config.set_value("items", "present_variant", present_variant)
	config.set_value("ui", "market_prefs", market_prefs)

	## Save gemstones (compact: gem_type -> count)
	config.set_value("gemstones", "counts", gemstones)
	## Save polished gems (Workshop saw output)
	config.set_value("gemstones", "polished", polished_gems)

	## Save redeemed cheat codes
	config.set_value("cheats", "redeemed_codes", redeemed_codes)
	config.set_value("cheats", "cash_stash_lifetime_granted", cash_stash_lifetime_granted)

	## Save guild membership (cached; server is authoritative)
	config.set_value("guild", "id", guild_id)
	config.set_value("guild", "role", guild_role)

	## Save prospectors
	config.set_value("prospectors", "owned", prospectors)
	config.set_value("prospectors", "last_tick", prospector_last_tick)

	_atomic_save(config, SAVE_PATH)


## Writes `config` to `path` crash-safely: save to a temp file first, and only
## if that succeeds atomically rename it over the real save (keeping the prior
## save as a .bak). A crash mid-write can then never truncate the live save —
## it leaves either the old file or the fully-written new one intact.
func _atomic_save(config: ConfigFile, path: String) -> void:
	var tmp_path := path + ".tmp"
	var err := config.save(tmp_path)
	if err != OK:
		## Temp write failed — do NOT touch the live save. Surface it, keep the
		## existing (good) file.
		push_error("PlayerData: temp save failed (err %d); keeping previous save." % err)
		return
	var dir := DirAccess.open("user://")
	if dir == null:
		push_error("PlayerData: cannot open user:// to finalize save.")
		return
	## Keep a backup of the last good save before replacing it.
	if dir.file_exists(path):
		dir.remove(path + ".bak")  ## ignore result; may not exist
		dir.copy(path, path + ".bak")
	## Swap temp over the real path. Some platforms reject rename onto an
	## existing file, so remove the destination first. If anything here fails,
	## the .bak we just wrote is a full, valid save the player can recover from.
	dir.remove(path)
	var rerr := dir.rename(tmp_path, path)
	if rerr != OK:
		push_error("PlayerData: atomic rename failed (err %d); backup retained at %s.bak" % [rerr, path])

func load_data() -> void:
	corruption_detected = false
	var config := ConfigFile.new()
	var err := config.load(SAVE_PATH)
	if err != OK:
		if not FileAccess.file_exists(SAVE_PATH):
			## First time — file doesn't exist yet, give starting inventory
			_give_starting_inventory()
			save_data()
			return
		## File exists but is corrupted/unreadable (Req 7.5)
		_handle_corrupted_save()
		return

	## File loaded structurally — now validate semantics
	var loaded_coins: int = config.get_value("player", "coins", DEFAULT_COINS)
	var loaded_level: int = config.get_value("player", "level", DEFAULT_LEVEL)
	var loaded_xp: int = config.get_value("player", "xp", 0)
	var loaded_lifetime_xp: int = config.get_value("player", "lifetime_xp", loaded_xp)
	var loaded_storage: int = config.get_value("player", "storage_upgrades", 0)
	## New compact format: { type_int: count }. Legacy format was an Array of
	## { "type": int, "direction": int } dicts — still read for migration.
	var loaded_inv_counts = config.get_value("player", "inventory_counts", null)
	var loaded_inv = config.get_value("player", "inventory", [])

	## Semantic validation — detect nonsensical values
	if not _validate_loaded_data(loaded_coins, loaded_level, loaded_xp, loaded_storage, loaded_inv, loaded_inv_counts):
		_handle_corrupted_save()
		return

	## Good load — clear the one-shot backup-restore guard so a future genuine
	## corruption (much later) can still attempt recovery from backup.
	_attempted_backup_restore = false

	## Data is valid — apply it
	player_name = config.get_value("player", "name", DEFAULT_NAME)
	level       = loaded_level
	coins       = loaded_coins
	xp          = loaded_xp
	lifetime_xp = loaded_lifetime_xp
	## Guard: xp and lifetime_xp should never be negative
	if xp < 0:
		push_warning("PlayerData: xp was %d (negative). Resetting to 0." % xp)
		xp = 0
	if lifetime_xp < 0:
		push_warning("PlayerData: lifetime_xp was %d (negative). Resetting to 0." % lifetime_xp)
		lifetime_xp = 0

	## Load the all-time peak level. Older saves without this key fall back to
	## the saved level so the high-water mark is at least the current level.
	peak_level = maxi(int(config.get_value("player", "peak_level", loaded_level)), loaded_level)

	## Recalculate level upon load based on current xp value (also bumps peak).
	recalculate_level()
	storage_upgrades = loaded_storage
	has_set_name = config.get_value("player", "has_set_name", false)
	market_suggested_pricing_seen = bool(config.get_value("player", "market_suggested_pricing_seen", false))
	guild_reward_xp_watermark = float(config.get_value("player", "guild_reward_xp_watermark", 0.0))
	name_changes = config.get_value("player", "name_changes", 0)
	## Load prestige levels
	var loaded_prestige = config.get_value("prestige", "levels", {})
	if loaded_prestige is Dictionary:
		prestige_levels = loaded_prestige
	passive_xp_last_ts = float(config.get_value("prestige", "passive_xp_last_ts", 0.0))
	garden_auto_plant_rows = int(config.get_value("prestige", "garden_auto_plant_rows", 0))
	orchard_auto_plant_rows = int(config.get_value("prestige", "orchard_auto_plant_rows", 0))
	guild_garden_auto_plant_rows = int(config.get_value("prestige", "guild_garden_auto_plant_rows", 0))

	## One-time repricing migration: reconcile levels bought at old prices with
	## the retuned (pricier) curves, refunding any excess to spendable xp.
	## The actual save is deferred to the end of load_data() (below) so we don't
	## persist a half-loaded state (inventory/gems aren't reconstructed yet).
	var _did_reprice_migration := false
	prestige_reprice_migrated = bool(config.get_value("prestige", "reprice_migrated", false))
	if not prestige_reprice_migrated:
		_migrate_prestige_repricing()
		## xp may have grown from the refund — re-derive the player's level.
		recalculate_level()
		_did_reprice_migration = true

	## 100B prestige retune: recalculate every track against the new curves,
	## refunding any spend that no longer buys the same levels. Runs after the
	## older reprice migration so override tracks are already at their pre-100B
	## prices when we reconstruct spend. Runs exactly once per save.
	prestige_100b_migrated = bool(config.get_value("prestige", "reprice_100b_migrated", false))
	if not prestige_100b_migrated:
		_migrate_prestige_100b()
		## xp may have grown from refunds — re-derive the player's level.
		recalculate_level()
		_did_reprice_migration = true

	## Straggler pass: five tracks were missing from the initial 100B migration
	## (Orchard Baron, Green Thumb, Scholar, Merchant's Ledger, Quartermaster).
	## This pass catches them on existing saves. Runs exactly once per save.
	prestige_100b_v2_migrated = bool(config.get_value("prestige", "reprice_100b_v2_migrated", false))
	if not prestige_100b_v2_migrated:
		_migrate_prestige_100b_v2()
		recalculate_level()
		_did_reprice_migration = true

	inventory.clear()
	if loaded_inv_counts is Dictionary:
		## New compact format — reconstruct tiles from per-type counts.
		## Direction is restored to each piece's default (see _default_direction_for).
		for type_key in loaded_inv_counts:
			var t := int(type_key)
			var count := int(loaded_inv_counts[type_key])
			var dir := _default_direction_for(t)
			for i in range(count):
				inventory.append({"type": t, "direction": dir})
	else:
		## Legacy format — Array of { "type", "direction" } dicts.
		## Also handles migrating legacy gemstone entries that used to live here.
		for item in loaded_inv:
			if item is Dictionary:
				var item_type = item.get("type", null)
				if item_type is String and item_type == "gemstone" and item.has("gem_type") and item.has("value"):
					# Legacy gemstone in inventory — migrate to gemstones dictionary
					var gt: String = str(item["gem_type"])
					gemstones[gt] = gemstones.get(gt, 0) + 1
				elif item.has("type") and item.has("direction"):
					# Pho tile item — drop the saved direction, use the default
					inventory.append({"type": int(item["type"]), "direction": _default_direction_for(int(item["type"]))})

	## Load shop pool
	var pool_data = config.get_value("shop", "pool", {})
	shop_pool.clear()
	for key in pool_data:
		shop_pool[int(key)] = int(pool_data[key])
	shop_pool_timestamp = config.get_value("shop", "timestamp", 0.0)

	## Check if pool needs refresh (3hrs elapsed)
	_check_shop_pool_refresh()

	## Load daily bonus
	daily_streak = config.get_value("daily", "streak", 0)
	daily_last_claim = config.get_value("daily", "last_claim", 0.0)

	## Load notification settings (default on)
	notify_daily_bonus = bool(config.get_value("notifications", "daily_bonus", true))
	notify_garden = bool(config.get_value("notifications", "garden", true))
	notify_orchard = bool(config.get_value("notifications", "orchard", true))
	notify_workshop = bool(config.get_value("notifications", "workshop", true))
	notify_foundry = bool(config.get_value("notifications", "foundry", true))
	notify_missions = bool(config.get_value("notifications", "missions", true))
	notify_saw_threshold = int(config.get_value("notifications", "saw_threshold", 10))
	notify_foundry_threshold = int(config.get_value("notifications", "foundry_threshold", 10))
	notify_garden_threshold = int(config.get_value("notifications", "garden_threshold", 1))
	notify_orchard_threshold = int(config.get_value("notifications", "orchard_threshold", 10))
	motd_last_shown_day = int(config.get_value("notifications", "motd_last_shown_day", -1))

	## Load marketplace daily refresh counter (resets if the day has changed)
	market_refreshes_used = int(config.get_value("market", "refreshes_used", 0))
	market_refresh_day = int(config.get_value("market", "refresh_day", -1))
	_roll_over_market_refresh_day()

	## Load mission board daily reroll counter (resets if the day has changed)
	mission_refreshes_used = int(config.get_value("missions", "refreshes_used", 0))
	mission_refresh_day = int(config.get_value("missions", "refresh_day", -1))
	_roll_over_mission_refresh_day()

	## Load tools
	var tools_data = config.get_value("tools", "inventory", {})
	tools.clear()
	if tools_data is Dictionary:
		for key in tools_data:
			tools[int(key)] = int(tools_data[key])
	var tool_pool_data = config.get_value("tools", "shop_pool", {})
	tool_shop_pool.clear()
	if tool_pool_data is Dictionary:
		for key in tool_pool_data:
			tool_shop_pool[int(key)] = int(tool_pool_data[key])
	tool_shop_timestamp = config.get_value("tools", "shop_timestamp", 0.0)
	_check_tool_shop_refresh()

	## Load tutorial state
	tutorial_completed = config.get_value("tutorial", "completed", false)
	tutorial_step_index = config.get_value("tutorial", "step_index", -1)
	tutorial_home_dismissed = config.get_value("tutorial", "home_dismissed", false)
	# Clamp tutorial_step_index: -1 is valid (not started), 0+ is in progress.
	# Any other negative value is corrupted — reset to 0. Clamp large values to
	# the sequence size via TutorialSystem at runtime; here just bound to 100.
	if tutorial_step_index < -1:
		push_warning("PlayerData: tutorial_step_index was %d (corrupted). Resetting to 0." % tutorial_step_index)
		tutorial_step_index = 0
	elif tutorial_step_index > 100:
		push_warning("PlayerData: tutorial_step_index was %d (out of range). Clamping to 0." % tutorial_step_index)
		tutorial_step_index = 0

	## Load items
	var loaded_ring_count = config.get_value("items", "diamond_ring_count", 0)
	if loaded_ring_count is int and loaded_ring_count >= 0:
		diamond_ring_count = loaded_ring_count
	else:
		if loaded_ring_count is int and loaded_ring_count < 0:
			push_warning("PlayerData: diamond_ring_count was %d (negative). Resetting to 0." % loaded_ring_count)
		else:
			push_warning("PlayerData: diamond_ring_count was invalid (non-integer). Resetting to 0.")
		diamond_ring_count = 0

	## Guild-produced jewelry inventory (id -> count). Sanitized to int>=0.
	jewelry.clear()
	var loaded_jewelry = config.get_value("items", "jewelry", {})
	if loaded_jewelry is Dictionary:
		for key in loaded_jewelry:
			var cnt = loaded_jewelry[key]
			if (cnt is int or cnt is float) and int(cnt) > 0:
				jewelry[str(key)] = int(cnt)

	## Food recipe inventory (id -> count). Sanitized to int>=0.
	recipes.clear()
	var loaded_recipes = config.get_value("items", "recipes", {})
	if loaded_recipes is Dictionary:
		for key in loaded_recipes:
			var rcnt = loaded_recipes[key]
			if (rcnt is int or rcnt is float) and int(rcnt) > 0:
				recipes[str(key)] = int(rcnt)

	## Active recipe boosts (effect -> {value, expires_at | remaining}).
	active_boosts.clear()
	var loaded_boosts = config.get_value("items", "active_boosts", {})
	if loaded_boosts is Dictionary:
		for key in loaded_boosts:
			if loaded_boosts[key] is Dictionary:
				active_boosts[str(key)] = (loaded_boosts[key] as Dictionary).duplicate()
	_prune_expired_boosts()

	## WonderStone count + WonderVessel inventory (tier -> count).
	var ws = config.get_value("items", "wonderstone_count", 0)
	wonderstone_count = int(ws) if (ws is int or ws is float) and int(ws) > 0 else 0
	wonder_vessels.clear()
	var loaded_vessels = config.get_value("items", "wonder_vessels", {})
	if loaded_vessels is Dictionary:
		for key in loaded_vessels:
			var vc = loaded_vessels[key]
			if (vc is int or vc is float) and int(vc) > 0:
				wonder_vessels[int(key)] = int(vc)

	## Equipped jewelry slots. Only accept ids that are valid jewelry AND fit the
	## slot (defensive against hand-edited/old saves).
	equipped_ring = _load_equip_slot(config, "equipped_ring", "ring")
	equipped_necklace = _load_equip_slot(config, "equipped_necklace", "necklace")
	equipped_misc = _load_equip_slot(config, "equipped_misc", "")

	## Money Gun (local cache of server-authoritative state).
	money_gun_owned = bool(config.get_value("items", "money_gun_owned", false))
	money_gun_level = clampi(int(config.get_value("items", "money_gun_level", 0)), 0, 10)

	## Load crops (harvested garden output — held items sold at the Marketplace)
	var loaded_crops = config.get_value("items", "crops", {})
	crops.clear()
	if loaded_crops is Dictionary:
		for key in loaded_crops:
			var cc = loaded_crops[key]
			if (cc is int or cc is float) and int(cc) > 0:
				crops[str(key)] = int(cc)

	## Load fruits
	var loaded_fruits = config.get_value("items", "fruits", {})
	fruits.clear()
	if loaded_fruits is Dictionary:
		for key in loaded_fruits:
			var fc = loaded_fruits[key]
			if (fc is int or fc is float) and int(fc) > 0:
				fruits[str(key)] = int(fc)

	## Load the save's assigned present variant (-1 = not yet assigned).
	present_variant = int(config.get_value("items", "present_variant", -1))
	if present_variant < -1 or present_variant >= PRESENT_COUNT:
		present_variant = -1

	## Load persisted marketplace UI preferences (qty/sort per tab).
	market_prefs = {}
	var loaded_prefs = config.get_value("ui", "market_prefs", {})
	if loaded_prefs is Dictionary:
		for k in loaded_prefs:
			if loaded_prefs[k] is int or loaded_prefs[k] is float:
				market_prefs[str(k)] = int(loaded_prefs[k])

	## Load gemstones (new compact format). Legacy gems were already migrated above during inventory load.
	var loaded_gems = config.get_value("gemstones", "counts", {})
	if loaded_gems is Dictionary:
		for key in loaded_gems:
			var count = loaded_gems[key]
			if count is int and count > 0:
				gemstones[str(key)] = gemstones.get(str(key), 0) + int(count)
			elif count is float and int(count) > 0:
				gemstones[str(key)] = gemstones.get(str(key), 0) + int(count)

	## Load polished gems
	polished_gems.clear()
	var loaded_polished = config.get_value("gemstones", "polished", {})
	if loaded_polished is Dictionary:
		for key in loaded_polished:
			var pc = loaded_polished[key]
			if (pc is int or pc is float) and int(pc) > 0:
				polished_gems[str(key)] = int(pc)

	## Load redeemed cheat codes
	var loaded_codes = config.get_value("cheats", "redeemed_codes", [])
	if loaded_codes is Array:
		redeemed_codes.clear()
		for code in loaded_codes:
			if code is String:
				redeemed_codes.append(code)
	else:
		redeemed_codes.clear()
	cash_stash_lifetime_granted = int(config.get_value("cheats", "cash_stash_lifetime_granted", 0))

	## Load prospectors
	var loaded_prospectors = config.get_value("prospectors", "owned", {})
	prospectors.clear()
	if loaded_prospectors is Dictionary:
		for key in loaded_prospectors:
			if loaded_prospectors[key] is int or loaded_prospectors[key] is float:
				prospectors[str(key)] = int(loaded_prospectors[key])
	prospector_last_tick = config.get_value("prospectors", "last_tick", 0.0)

	## Load guild membership
	guild_id   = str(config.get_value("guild", "id",   ""))
	guild_role = str(config.get_value("guild", "role", ""))

	if inventory.is_empty():
		_give_starting_inventory()
		save_data()
	elif _did_reprice_migration:
		## Persist the one-time repricing migration now that the full save state
		## is loaded, so it's recorded and never runs again for this save.
		save_data()


## Validates loaded data for semantic corruption.
## Returns true if data is valid, false if corrupted.
func _validate_loaded_data(p_coins: int, p_level: int, p_xp: int, p_storage: int, p_inventory, p_inventory_counts = null) -> bool:
	## Coins must be non-negative
	if p_coins < 0:
		return false

	## Level must be >= 1
	if p_level < 1:
		return false

	## XP negative is recoverable — do not treat as corruption (will be clamped to 1 on load)

	## Storage upgrades must be within valid range
	if p_storage < 0 or p_storage > MAX_STORAGE_UPGRADES:
		return false

	var max_type: int = Piece.Type.values().size() - 1

	## New compact format takes precedence when present: { type_int: count }.
	if p_inventory_counts != null:
		if not p_inventory_counts is Dictionary:
			return false
		for type_key in p_inventory_counts:
			var t := int(type_key)
			if t < 0 or t > max_type:
				return false
			if int(p_inventory_counts[type_key]) < 0:
				return false
		return true

	## Legacy format — inventory must be an array of item dicts.
	if not p_inventory is Array:
		return false

	## Validate each inventory item has valid structure
	for item in p_inventory:
		if not item is Dictionary:
			return false
		var item_type = item.get("type", null)
		if item_type is String and item_type == "gemstone":
			# Legacy gemstone item — will be migrated, just needs gem_type
			if not item.has("gem_type"):
				return false
		else:
			# Pho tile item — needs type (int) and direction
			if not item.has("type") or not item.has("direction"):
				return false
			var piece_type: int = int(item["type"])
			if piece_type < 0 or piece_type > max_type:
				return false

	return true


## Attempts to recover from the last good backup (path + ".bak") written by the
## atomic save. Promotes the backup to the primary save and reloads. Returns
## true if recovery succeeded. Guarded so a bad backup can't loop forever.
func _try_restore_from_backup() -> bool:
	if _attempted_backup_restore:
		return false
	_attempted_backup_restore = true

	var bak_path := SAVE_PATH + ".bak"
	if not FileAccess.file_exists(bak_path):
		return false

	## Only trust the backup if it loads AND passes the same semantic checks.
	var probe := ConfigFile.new()
	if probe.load(bak_path) != OK:
		return false
	var b_coins: int = probe.get_value("player", "coins", DEFAULT_COINS)
	var b_level: int = probe.get_value("player", "level", DEFAULT_LEVEL)
	var b_xp: int = probe.get_value("player", "xp", 0)
	var b_storage: int = probe.get_value("player", "storage_upgrades", 0)
	var b_inv_counts = probe.get_value("player", "inventory_counts", null)
	var b_inv = probe.get_value("player", "inventory", [])
	if not _validate_loaded_data(b_coins, b_level, b_xp, b_storage, b_inv, b_inv_counts):
		return false

	## Promote the backup to the primary save, then reload from it.
	var dir := DirAccess.open("user://")
	if dir == null:
		return false
	dir.remove(SAVE_PATH)  ## ignore result
	if dir.copy(bak_path, SAVE_PATH) != OK:
		return false
	push_warning("PlayerData: primary save was bad; recovered from backup.")
	load_data()
	return true


## Handles corrupted save data: resets to defaults and signals corruption. (Req 7.5)
func _handle_corrupted_save() -> void:
	## Before wiping to defaults, try to recover from the last good backup that
	## the atomic save keeps. This is what saves a player from a truncated /
	## corrupt primary save (e.g. app killed mid-write).
	if _try_restore_from_backup():
		return

	corruption_detected = true
	## Reset all values to defaults
	player_name = DEFAULT_NAME
	level = DEFAULT_LEVEL
	peak_level = DEFAULT_LEVEL
	coins = DEFAULT_COINS
	xp = 0
	storage_upgrades = 0
	inventory.clear()
	gemstones.clear()
	polished_gems.clear()
	shop_pool.clear()
	shop_pool_timestamp = 0.0
	daily_streak = 0
	daily_last_claim = 0.0
	market_refreshes_used = 0
	market_refresh_day = -1
	mission_refreshes_used = 0
	mission_refresh_day = -1
	tools.clear()
	tool_shop_pool.clear()
	tool_shop_timestamp = 0.0
	diamond_ring_count = 0
	jewelry.clear()
	equipped_ring = ""
	equipped_necklace = ""
	equipped_misc = ""
	money_gun_owned = false
	money_gun_level = 0
	fruits.clear()
	crops.clear()
	## Give fresh starting inventory
	_give_starting_inventory()
	save_data()
	## Notify listeners (UI can display a message to the player)
	save_corrupted.emit()

func _give_starting_inventory() -> void:
	## Start with a basic set of pawns and soldiers
	for i in range(10):
		inventory.append({"type": int(Piece.Type.PAWN), "direction": int(PieceDefinition.Direction.NONE)})
	for i in range(5):
		inventory.append({"type": int(Piece.Type.SOLDIER), "direction": int(PieceDefinition.Direction.NORTH)})
	for i in range(2):
		inventory.append({"type": int(Piece.Type.MAGE), "direction": int(PieceDefinition.Direction.NORTH)})
	inventory.append({"type": int(Piece.Type.WATCHTOWER), "direction": int(PieceDefinition.Direction.NONE)})
	inventory.append({"type": int(Piece.Type.CLERGY), "direction": int(PieceDefinition.Direction.NONE)})
	## Generate initial shop pool
	_generate_shop_pool()


## ── Shop Pool ──────────────────────────────────────────────────


## Checks if the shop pool needs to be refreshed (3hrs elapsed or empty).
## Accumulates multiple restocks if offline for longer than one interval.
func _check_shop_pool_refresh() -> void:
	var now := TrustedClock.now()
	if shop_pool.is_empty():
		_generate_shop_pool()
		save_data()
		emit_signal("data_changed")
		return
	var elapsed := now - shop_pool_timestamp
	if elapsed < SHOP_REFRESH_INTERVAL:
		return
	var cycles := int(elapsed / SHOP_REFRESH_INTERVAL)
	for i in range(cycles):
		_generate_shop_pool()
	## Advance timestamp by exact cycles consumed (not current time) to preserve remainder
	shop_pool_timestamp += cycles * SHOP_REFRESH_INTERVAL
	save_data()
	emit_signal("data_changed")


## Generates a new random shop pool of 50-75 pieces based on rarity weights.
## Adds to existing stock (capped at 1000 per piece type).
func _generate_shop_pool() -> void:
	if shop_pool_timestamp <= 0.0:
		shop_pool_timestamp = TrustedClock.now()

	## Calculate total weight
	var total_weight: int = 0
	for w in SHOP_WEIGHTS.values():
		total_weight += w

	## Determine pool size (random between min and max), scaled up by Carl's
	## Construction shop (Business District) which increases restock stock.
	var pool_size: int = randi_range(SHOP_POOL_MIN, SHOP_POOL_MAX)
	if get_node_or_null("/root/BusinessDistrict") != null:
		pool_size = int(pool_size * BusinessDistrict.market_stock_multiplier())

	## Roll each slot using weighted random
	for i in range(pool_size):
		var roll: int = randi() % total_weight
		var cumulative: int = 0
		for piece_type in SHOP_WEIGHTS:
			cumulative += SHOP_WEIGHTS[piece_type]
			if roll < cumulative:
				shop_pool[piece_type] = mini(shop_pool.get(piece_type, 0) + 1, 1000)
				break


## Returns the number of a piece type available in the current shop pool.
func get_shop_stock(piece_type: Piece.Type) -> int:
	return shop_pool.get(piece_type, 0)


## Decrements shop stock after a purchase. Returns false if out of stock.
func consume_shop_stock(piece_type: Piece.Type, qty: int) -> bool:
	var available: int = shop_pool.get(piece_type, 0)
	if available < qty:
		return false
	shop_pool[piece_type] = available - qty
	return true


## Returns seconds remaining until shop pool refreshes.
func get_shop_refresh_remaining() -> float:
	var now := TrustedClock.now()
	var elapsed := now - shop_pool_timestamp
	return maxf(0.0, SHOP_REFRESH_INTERVAL - elapsed)


## ── Tool Shop ──────────────────────────────────────────────────

func get_tool_count(tool_id: int) -> int:
	return tools.get(tool_id, 0)

func add_tool(tool_id: int, qty: int = 1) -> void:
	var def: Dictionary = TOOL_DEFS[tool_id]
	var uses: int = int(def.get("uses_per_purchase", 1)) * qty
	tools[tool_id] = tools.get(tool_id, 0) + uses
	save_data()
	emit_signal("data_changed")

func consume_tool(tool_id: int) -> bool:
	if tools.get(tool_id, 0) <= 0:
		return false
	tools[tool_id] -= 1
	save_data()
	emit_signal("data_changed")
	return true

func _check_tool_shop_refresh() -> void:
	var now := TrustedClock.now()
	if tool_shop_pool.is_empty():
		_generate_tool_shop_pool()
		save_data()
		emit_signal("data_changed")
		return
	var elapsed := now - tool_shop_timestamp
	if elapsed < TOOL_SHOP_REFRESH_INTERVAL:
		return
	var cycles := int(elapsed / TOOL_SHOP_REFRESH_INTERVAL)
	for i in range(cycles):
		_generate_tool_shop_pool()
	tool_shop_timestamp += cycles * TOOL_SHOP_REFRESH_INTERVAL
	save_data()
	emit_signal("data_changed")

func _generate_tool_shop_pool() -> void:
	if tool_shop_timestamp <= 0.0:
		tool_shop_timestamp = TrustedClock.now()

	## Guarantee stock for tools with restock_min/restock_max (additive, capped at 1000)
	for def in TOOL_DEFS:
		if def.has("restock_min") and def.has("restock_max"):
			var tid: int = int(def["id"])
			var add_qty: int = randi_range(int(def["restock_min"]), int(def["restock_max"]))
			tool_shop_pool[tid] = mini(tool_shop_pool.get(tid, 0) + add_qty, 1000)

	## Fill remaining pool randomly using weights
	var total_weight: int = 0
	for def in TOOL_DEFS:
		total_weight += int(def["weight"])

	var pool_size: int = randi_range(TOOL_SHOP_POOL_MIN, TOOL_SHOP_POOL_MAX)
	for i in range(pool_size):
		var roll := randi() % total_weight
		var cumulative := 0
		for def in TOOL_DEFS:
			cumulative += int(def["weight"])
			if roll < cumulative:
				var tid: int = int(def["id"])
				tool_shop_pool[tid] = mini(tool_shop_pool.get(tid, 0) + 1, 1000)
				break

func get_tool_shop_stock(tool_id: int) -> int:
	return tool_shop_pool.get(tool_id, 0)

func consume_tool_shop_stock(tool_id: int, qty: int) -> bool:
	var available: int = tool_shop_pool.get(tool_id, 0)
	if available < qty:
		return false
	tool_shop_pool[tool_id] = available - qty
	return true

func get_tool_shop_refresh_remaining() -> float:
	var now := TrustedClock.now()
	return maxf(0.0, TOOL_SHOP_REFRESH_INTERVAL - (now - tool_shop_timestamp))


## ── Daily Bonus ────────────────────────────────────────────────

## Returns true if the player can claim today's daily bonus.
func can_claim_daily() -> bool:
	if daily_last_claim == 0.0:
		return true  ## Never claimed
	var now := TrustedClock.now()
	var hours_since_claim := (now - daily_last_claim) / 3600.0
	return hours_since_claim >= DAILY_RESET_HOURS


## Returns the reward amount for the current streak day (next claim).
## Reward the player will get for their NEXT claim (see _daily_reward_for_day
## for the exponential curve + week bonus).
func get_daily_bonus_amount() -> int:
	return _daily_reward_for_day(daily_streak + 1)


## Reward for a given streak day. EXPONENTIAL main reward that grows from the
## day-1 base (100,000) at DAILY_GROWTH_RATE per day, hard-capped at
## DAILY_BONUS_MAX (1B) which it reaches on day 365; plus a flat week bonus
## (DAILY_BONUS_WEEK_BONUS) for each completed 7-day period, added on top of the
## capped main reward.
##   Day 1  = 100,000 (+0 week)        Day 7  ≈ 117k   + 100,000 week
##   Day 14 ≈ 139k    + 200,000 week   Day 365 = 1,000,000,000 + week bonus
func _daily_reward_for_day(day: int) -> int:
	if day < 1:
		day = 1
	## Main reward: base * rate^(day-1), clamped to the 1B cap (day >= 365).
	var main := DAILY_BONUS_BASE * pow(DAILY_GROWTH_RATE, day - 1)
	var reward := int(round(min(main, float(DAILY_BONUS_MAX))))
	## Equipped black_pearl "daily_bonus" jewelry scales the MAIN reward only
	## (the flat week bonus stays a stable floor). Null-safe.
	if get_node_or_null("/root/JewelryBonus") != null:
		reward = int(round(reward * JewelryBonus.daily_bonus_multiplier()))
	## Extra flat bonus for each completed 7-day period of the streak.
	reward += DAILY_BONUS_WEEK_BONUS * int(day / 7)
	return reward


## Claims the daily bonus. Returns the coins awarded, or 0 if not available.
func claim_daily_bonus() -> int:
	if not can_claim_daily():
		return 0

	var now := TrustedClock.now()

	## Check if streak should reset (missed more than DAILY_GRACE_HOURS)
	if daily_last_claim > 0.0:
		var hours_since_claim := (now - daily_last_claim) / 3600.0
		if hours_since_claim >= DAILY_GRACE_HOURS:
			daily_streak = 0  ## Streak broken — reset

	daily_streak += 1
	daily_last_claim = now

	var reward := _daily_reward_for_day(daily_streak)

	coins += reward
	save_data()
	emit_signal("data_changed")
	return reward


## ── Notification Settings ──────────────────────────────────────

## Sets a notification category toggle and persists it.
## category: "daily_bonus" | "garden" | "orchard" | "workshop" | "missions"
func set_notification_enabled(category: String, enabled: bool) -> void:
	match category:
		"daily_bonus": notify_daily_bonus = enabled
		"garden":      notify_garden = enabled
		"orchard":     notify_orchard = enabled
		"workshop":    notify_workshop = enabled
		"foundry":     notify_foundry = enabled
		"missions":    notify_missions = enabled
		_:             return
	save_data()


## Sets the alert threshold for a category and persists it.
## saw/foundry/orchard: item/tree count; garden: row count (0 = full garden).
func set_notification_threshold(category: String, value: int) -> void:
	match category:
		"workshop": notify_saw_threshold = value
		"foundry":  notify_foundry_threshold = value
		"garden":   notify_garden_threshold = value
		"orchard":  notify_orchard_threshold = value
		_:          return
	save_data()

## Returns the alert threshold for a category (0 if the category has none).
func get_notification_threshold(category: String) -> int:
	match category:
		"workshop": return notify_saw_threshold
		"foundry":  return notify_foundry_threshold
		"garden":   return notify_garden_threshold
		"orchard":  return notify_orchard_threshold
	return 0

## Returns whether a notification category is enabled.
func is_notification_enabled(category: String) -> bool:
	match category:
		"daily_bonus": return notify_daily_bonus
		"garden":      return notify_garden
		"orchard":     return notify_orchard
		"workshop":    return notify_workshop
		"foundry":     return notify_foundry
		"missions":    return notify_missions
	return false


## ── Marketplace Refresh Limit ──────────────────────────────────

## Integer day index (UTC-based) used to reset the daily refresh counter.
func _current_day_index() -> int:
	return int(TrustedClock.now() / 86400.0)

## Resets the daily refresh counter when the calendar day changes.
func _roll_over_market_refresh_day() -> void:
	var today := _current_day_index()
	if market_refresh_day != today:
		market_refresh_day = today
		market_refreshes_used = 0

## Total prestige bonus refreshes granted at the player's current level.
func get_market_refresh_prestige_bonus() -> int:
	var lvl := get_prestige_level("market_refresh")
	if lvl <= 0:
		return 0
	lvl = clampi(lvl, 1, MARKET_REFRESH_PRESTIGE_BONUS.size())
	return MARKET_REFRESH_PRESTIGE_BONUS[lvl - 1]

## Total refreshes allowed today (base + prestige bonus).
func get_market_refresh_limit() -> int:
	return MARKET_REFRESH_BASE + get_market_refresh_prestige_bonus()

## Refreshes remaining today.
func get_market_refreshes_remaining() -> int:
	_roll_over_market_refresh_day()
	return maxi(0, get_market_refresh_limit() - market_refreshes_used)

## True if the player can pay for another refresh today (has budget and allowance).
func can_refresh_market() -> bool:
	return coins >= MARKET_REFRESH_COST and get_market_refreshes_remaining() > 0

## Consumes one daily refresh allowance. Returns true if allowed.
## Does NOT deduct coins — the caller handles the coin cost.
func use_market_refresh() -> bool:
	_roll_over_market_refresh_day()
	if get_market_refreshes_remaining() <= 0:
		return false
	market_refreshes_used += 1
	return true


## ── Mission Board Refresh Limit ────────────────────────────────

## Resets the daily mission-reroll counter when the calendar day changes.
func _roll_over_mission_refresh_day() -> void:
	var today := _current_day_index()
	if mission_refresh_day != today:
		mission_refresh_day = today
		mission_refreshes_used = 0

## Total prestige bonus mission rerolls granted at the player's current level.
func get_mission_refresh_prestige_bonus() -> int:
	var lvl := get_prestige_level("mission_refresh")
	if lvl <= 0:
		return 0
	lvl = clampi(lvl, 1, MISSION_REFRESH_PRESTIGE_BONUS.size())
	return MISSION_REFRESH_PRESTIGE_BONUS[lvl - 1]

## Total mission rerolls allowed today (base + prestige bonus).
func get_mission_refresh_limit() -> int:
	return MISSION_REFRESH_BASE + get_mission_refresh_prestige_bonus()

## Mission rerolls remaining today.
func get_mission_refreshes_remaining() -> int:
	_roll_over_mission_refresh_day()
	return maxi(0, get_mission_refresh_limit() - mission_refreshes_used)

## True if the player can pay for another mission reroll today.
func can_refresh_mission() -> bool:
	return coins >= MISSION_REFRESH_COST and get_mission_refreshes_remaining() > 0

## Consumes one daily mission-reroll allowance. Returns true if allowed.
## Does NOT deduct coins — the caller handles the coin cost.
func use_mission_refresh() -> bool:
	_roll_over_mission_refresh_day()
	if get_mission_refreshes_remaining() <= 0:
		return false
	mission_refreshes_used += 1
	return true


## Returns the current daily streak.
func get_daily_streak() -> int:
	return daily_streak


## Returns seconds until next daily bonus is available (0 if claimable now).
func get_daily_cooldown_remaining() -> float:
	if daily_last_claim == 0.0:
		return 0.0
	var now := TrustedClock.now()
	var elapsed := now - daily_last_claim
	var remaining := (DAILY_RESET_HOURS * 3600.0) - elapsed
	return maxf(0.0, remaining)


## ── Economy ────────────────────────────────────────────────────

func get_piece_price(piece_type: Piece.Type) -> int:
	match piece_type:
		Piece.Type.PAWN:
			return 0         ## Free
		Piece.Type.SOLDIER:
			return 10
		Piece.Type.SAIL:
			return 30
		Piece.Type.WIND:
			return 40
		Piece.Type.MAGE:
			return 50
		Piece.Type.SHIELD:
			return 60
		Piece.Type.TREE:
			return 80
		Piece.Type.SLEEP:
			return 400
		Piece.Type.DRUID:
			return 120
		Piece.Type.CLERGY:
			return 150
		Piece.Type.DOME:
			return 200
		Piece.Type.BLACK_HOLE:
			return 300
		Piece.Type.WATCHTOWER:
			return 100
		Piece.Type.KING:
			return 500
		_:
			return 50

func can_afford(piece_type: Piece.Type, qty: int = 1) -> bool:
	return coins >= get_piece_price(piece_type) * qty

func purchase_tiles(piece_type: Piece.Type, qty: int) -> bool:
	## Clamp qty by remaining inventory space
	var space := MAX_INVENTORY - inventory.size()
	if space <= 0:
		return false
	qty = clampi(qty, 1, mini(MAX_PURCHASE_QTY, space))

	## Check shop stock (pawns are unlimited, others limited by pool)
	if piece_type != Piece.Type.PAWN:
		var stock := get_shop_stock(piece_type)
		if stock <= 0:
			return false
		qty = mini(qty, stock)

	var total_cost := get_piece_price(piece_type) * qty
	if coins < total_cost:
		return false
	coins -= total_cost

	## Consume from shop pool (pawns are unlimited)
	if piece_type != Piece.Type.PAWN:
		consume_shop_stock(piece_type, qty)

	var def := PieceRegistry.get_def(piece_type)
	var dir := int(PieceDefinition.Direction.NONE)
	if def:
		dir = int(def.effect_direction)

	for i in range(qty):
		inventory.append({"type": int(piece_type), "direction": dir})

	save_data()
	emit_signal("data_changed")
	return true


## Sell tiles back to the shop for half their purchase price.
## Returns true if the sale succeeded, false if player doesn't own enough.
func sell_tiles(piece_type: Piece.Type, qty: int) -> bool:
	var owned := count_in_inventory(piece_type)
	if owned <= 0:
		return false
	qty = clampi(qty, 1, owned)

	## Calculate sell price (half of buy price, rounded down)
	var sell_price := get_piece_price(piece_type) / 2
	var total_revenue := sell_price * qty

	## Remove `qty` pieces of this type in a single O(n) pass. Rebuilding a
	## filtered array is far cheaper than repeated remove_at() (each of which
	## shifts the tail), which was O(n*qty) and lagged on large sales.
	var new_inventory: Array = []
	var removed := 0
	for item in inventory:
		if removed < qty and int(item.get("type", -1)) == int(piece_type):
			removed += 1
			continue
		new_inventory.append(item)
	inventory = new_inventory

	## Return the sold tiles to the shop pool so the stock reflects what's available.
	shop_pool[int(piece_type)] = mini(shop_pool.get(int(piece_type), 0) + qty, 1000)

	coins += total_revenue
	## Selling anything grants XP = half the coin value.
	## award_xp handles save + level-up + data_changed.
	award_xp(total_revenue / 2)
	return true


## Effective tool BUY price, reduced by the Miners Source shop bonus (Business
## District). Single source so display + purchase match. Neutral when inactive.
func get_tool_buy_price(tool_id: int) -> int:
	if tool_id < 0 or tool_id >= TOOL_DEFS.size():
		return 0
	var base := int(TOOL_DEFS[tool_id].get("price", 0))
	if get_node_or_null("/root/BusinessDistrict") != null:
		base = int(base * BusinessDistrict.tool_price_multiplier(tool_id))
	return base


## Per-unit sell value for a tool: half its buy price (rounded down). Permanent
## tools (e.g. Tractor) are not sellable and return 0.
func get_tool_sell_value(tool_id: int) -> int:
	if tool_id < 0 or tool_id >= TOOL_DEFS.size():
		return 0
	var def: Dictionary = TOOL_DEFS[tool_id]
	if bool(def.get("permanent", false)):
		return 0
	return int(def.get("price", 0)) / 2


## Sells `qty` of a non-permanent tool back to the shop at half its buy price.
## Returns the number actually sold (0 if none / permanent / not owned).
func sell_tool(tool_id: int, qty: int = 1) -> int:
	if tool_id < 0 or tool_id >= TOOL_DEFS.size():
		return 0
	if bool(TOOL_DEFS[tool_id].get("permanent", false)):
		return 0  ## Permanent tools (Tractor) can't be sold.
	var owned := get_tool_count(tool_id)
	if owned <= 0 or qty <= 0:
		return 0
	qty = clampi(qty, 1, owned)
	var unit := get_tool_sell_value(tool_id)
	tools[tool_id] = owned - qty
	if tools[tool_id] <= 0:
		tools.erase(tool_id)
	## Return sold tools to the shop pool.
	tool_shop_pool[tool_id] = mini(tool_shop_pool.get(tool_id, 0) + qty, 1000)
	var total_revenue := unit * qty
	coins += total_revenue
	## Selling anything grants XP = half the coin value.
	## award_xp handles save + level-up + data_changed.
	award_xp(total_revenue / 2)
	return qty


## Per-unit sell value for a seed: half its buy price (seed_cost), rounded down.
func get_seed_sell_value(plant_type: int) -> int:
	if get_node_or_null("/root/Garden") == null:
		return 0
	var def: Dictionary = Garden.get_plant_def(plant_type)
	if def.is_empty():
		return 0
	return int(def.get("seed_cost", 0)) / 2


## Sells `qty` seeds back to the shop at half the seed's buy price. Removes the
## seeds from the Garden inventory. Returns the number actually sold.
func sell_seed(plant_type: int, qty: int = 1) -> int:
	if get_node_or_null("/root/Garden") == null:
		return 0
	var owned := Garden.get_seed_count(plant_type)
	if owned <= 0 or qty <= 0:
		return 0
	qty = clampi(qty, 1, owned)
	var unit := get_seed_sell_value(plant_type)
	## add_seeds with a negative amount removes them (it clamps + saves).
	Garden.add_seeds(plant_type, -qty)
	## Return sold seeds to the seed shop pool.
	Garden.seed_shop_pool[plant_type] = mini(Garden.seed_shop_pool.get(plant_type, 0) + qty, 1000)
	var total_revenue := unit * qty
	coins += total_revenue
	award_xp(total_revenue / 2)
	return qty


## Returns the current cost for the next storage upgrade (scales 25% per purchase).
func get_storage_upgrade_cost() -> int:
	return int(STORAGE_UPGRADE_COST * pow(1.25, storage_upgrades))


## Purchase a storage upgrade (10 extra inventory slots, scaling cost).
## Returns true if successful, false if maxed out or can't afford.
func buy_storage_upgrade() -> bool:
	if storage_upgrades >= MAX_STORAGE_UPGRADES:
		return false
	var cost := get_storage_upgrade_cost()
	if coins < cost:
		return false
	coins -= cost
	storage_upgrades += 1
	save_data()
	emit_signal("data_changed")
	return true


## Returns true if the player can purchase more storage upgrades.
func can_buy_storage() -> bool:
	return storage_upgrades < MAX_STORAGE_UPGRADES and coins >= get_storage_upgrade_cost()


## ── Name Management ────────────────────────────────────────────

## Profanity filter. MUST mirror _username_error() in migration 099.
## Long, unambiguous words are blocked ANYWHERE in a name.
const PROFANITY_ANYWHERE := [
	"fuck", "shit", "bitch", "cunt", "nigger", "nigga", "retard", "slut", "whore",
	"bastard", "twat", "wank", "bollocks", "pussy", "asshole", "dickhead",
]
## Short words that appear inside normal names ("Cassie", "Scrappy", "Dickens")
## are blocked only as a WHOLE word (split on spaces, underscores and digits).
const PROFANITY_WHOLE_WORD := ["ass", "damn", "dick", "cock", "fag", "piss", "crap"]

## One name for both the game and the online market, so one price: the old
## online-rename price. (name_changes still counts renames but no longer scales.)
const UNIFIED_NAME_CHANGE_COST := 50_000_000


## Returns the current cost for changing the name.
func get_name_change_cost() -> int:
	return UNIFIED_NAME_CHANGE_COST


## Check if a name contains profanity. Returns true if clean.
func is_name_clean(name_text: String) -> bool:
	var lower := name_text.to_lower()
	for word in PROFANITY_ANYWHERE:
		if lower.find(word) >= 0:
			return false
	## Whole-word check: break the name into letter runs.
	var regex := RegEx.new()
	regex.compile("[a-z]+")
	for m in regex.search_all(lower):
		if m.get_string() in PROFANITY_WHOLE_WORD:
			return false
	return true


## Validate a name: length, characters, and profanity check.
## Returns an error string or "" if valid.
func validate_name(name_text: String) -> String:
	var stripped := name_text.strip_edges()
	if stripped.length() < 2:
		return "Name must be at least 2 characters."
	if stripped.length() > 16:
		return "Name must be 16 characters or fewer."
	if not stripped.is_valid_identifier() and not _is_alphanumeric_with_spaces(stripped):
		return "Name can only contain letters, numbers, and spaces."
	if not is_name_clean(stripped):
		return "That name contains inappropriate language."
	return ""


## Set the player name locally (first time — free, no cost check). Does NOT
## touch the online account; use claim_initial_name() for the full flow.
func set_initial_name(name_text: String) -> String:
	var error := validate_name(name_text)
	if error != "":
		return error
	player_name = name_text.strip_edges()
	has_set_name = true
	save_data()
	emit_signal("data_changed")
	return ""


## Adopts the online account name as the in-game name (online name wins).
func adopt_online_name(online_name: String) -> void:
	var n := online_name.strip_edges()
	if n == "":
		return
	player_name = n
	has_set_name = true
	save_data()
	emit_signal("data_changed")


## First-run (or "your name was taken") flow: validates, then reserves the name
## online by registering this device's account with it. Free. Returns "" on
## success or an error message to show the player.
##   • Online + free name    → account created with that name.
##   • Device already linked → the existing online name is adopted instead.
##   • Taken / not allowed   → error returned; nothing saved.
##   • Offline               → saved locally only; MarketplaceAccount.sync_identity()
##                             registers it next time the game is online.
func claim_initial_name(name_text: String) -> String:
	var error := validate_name(name_text)
	if error != "":
		return error
	var clean := name_text.strip_edges()
	if get_node_or_null("/root/MarketplaceAccount") == null:
		return set_initial_name(clean)
	if MarketplaceAccount.has_account():
		## Already linked to an online name — keep that one.
		var rec: Dictionary = await MarketplaceAccount.reconcile()
		if rec.get("ok", false) and MarketplaceAccount.username != "":
			adopt_online_name(MarketplaceAccount.username)
			MarketplaceAccount.clear_name_change_request()
			return ""
		## Offline: keep the typed name for now; sync_identity() adopts the
		## online name the next time the game is online.
		return set_initial_name(clean)

	var res: Dictionary = await MarketplaceAccount.register_with_name(clean)
	if res.get("ok", false):
		adopt_online_name(str(res.get("username", clean)))
		MarketplaceAccount.clear_name_change_request()
		return ""
	if str(res.get("error_code", "")) == "offline":
		return set_initial_name(clean)  ## reserve online later (option b)
	return str(res.get("error", "That name isn't allowed."))


## Changes the ONE shared name (in-game + online market) for a flat cost.
## Online first: the server must accept the name (it owns uniqueness), then the
## coins are charged and the local name updated. Requires an internet
## connection so the two names can never drift apart. The FreeNameChange cheat
## (MarketplaceAccount.free_name_change) waives the cost once.
## Returns "" on success or an error message.
func change_name(name_text: String) -> String:
	var error := validate_name(name_text)
	if error != "":
		return error
	var clean := name_text.strip_edges()
	if clean == player_name:
		return "That's already your name."
	var free := get_node_or_null("/root/MarketplaceAccount") != null \
		and bool(MarketplaceAccount.free_name_change)
	var cost := 0 if free else get_name_change_cost()
	if coins < cost:
		return "Not enough coins! Need %s." % format_number(cost)
	if get_node_or_null("/root/MarketplaceAccount") == null \
			or get_node_or_null("/root/SupabaseClient") == null \
			or not SupabaseClient.is_configured():
		return "Connect to the internet to change your name."

	var res: Dictionary
	if MarketplaceAccount.has_account():
		res = await MarketplaceAccount.rename(clean)
	else:
		## No online account yet — create one with the new name.
		res = await MarketplaceAccount.register_with_name(clean)
		if not res.get("ok", false) and str(res.get("error_code", "")) == "offline":
			return "Connect to the internet to change your name."
	if not res.get("ok", false):
		return str(res.get("error", "Couldn't change your name."))

	## Server accepted — now charge and update the local copy.
	if free:
		MarketplaceAccount.free_name_change = false
	else:
		coins -= cost
	player_name = str(res.get("username", clean))
	has_set_name = true
	name_changes += 1
	MarketplaceAccount.clear_name_change_request()
	save_data()
	emit_signal("data_changed")
	return ""


func _is_alphanumeric_with_spaces(text: String) -> bool:
	for c in text:
		if not (c == " " or c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")):
			return false
	return true


## Award coins for winning a battle at a given difficulty
func award_win(enemy_count: int) -> int:
	var reward := REWARD_EASY
	match enemy_count:
		1: reward = REWARD_EASY
		3: reward = REWARD_MEDIUM
		5: reward = REWARD_HARD
		9: reward = REWARD_BRUTAL
	coins += reward
	award_xp(reward)
	return reward


## Award XP from any successful activity. Checks for level-up.
func award_xp(amount: int) -> void:
	if amount <= 0:
		return
	var boosted := int(minf(float(amount) * get_xp_multiplier(), float(XP_HARD_CAP)))
	var old_level := level
	xp = mini(xp + boosted, XP_HARD_CAP)
	lifetime_xp = mini(lifetime_xp + boosted, XP_HARD_CAP)
	recalculate_level()
	_check_level_up(old_level)
	save_data()
	emit_signal("data_changed")


## Alias for award_xp
func add_xp(amount: int) -> void:
	award_xp(amount)


## Emitted when player levels up. Includes ALL rewards if multiple levels gained at once.
signal leveled_up(new_level: int, rewards: Array)

func _check_level_up(old_level: int) -> void:
	if level > old_level:
		var total_budget: int = 0
		for l in range(old_level + 1, level + 1):
			total_budget += l * 100
		var all_rewards: Array = _generate_level_rewards_from_budget(total_budget)
		_add_reward_pieces(all_rewards)
		leveled_up.emit(level, all_rewards)

## Adds XP in bulk without running the level-up check on every single item.
func add_xp_batch(amount: int) -> void:
	if amount <= 0:
		return
	var boosted := int(minf(float(amount) * get_xp_multiplier(), float(XP_HARD_CAP)))
	xp = mini(xp + boosted, XP_HARD_CAP)
	lifetime_xp = mini(lifetime_xp + boosted, XP_HARD_CAP)


## Runs the level-up check once after a batch of XP has been awarded.
func check_level_up_batch() -> void:
	var old_level := level
	recalculate_level()
	_check_level_up(old_level)
	save_data()
	emit_signal("data_changed")
## Generates random piece rewards worth (level × 100) coins.
## Repeatedly picks a random affordable piece until budget < 10.
func _generate_level_rewards(new_level: int) -> Array:
	return _generate_level_rewards_from_budget(new_level * 100)


## ── Chest reward generation ─────────────────────────────────────
## Gem tiers used by chest generation.
## Lower: gold, blue_stone, pink_stone
## Middle: violet_stone, black_pearl, emerald
## Upper:  ruby, diamond
const _GEM_LOWER:  Array[String] = ["gold", "blue_stone", "pink_stone"]
const _GEM_MIDDLE: Array[String] = ["violet_stone", "black_pearl", "emerald"]
const _GEM_UPPER:  Array[String] = ["ruby", "diamond"]

## Picks qty random gems from a tier pool (with replacement). Equipped jewelry
## luck (ruby rarer_gems + blue_stone chest_luck, via gem+chest luck) biases the
## pick toward the rarer gem in the tier (pools are ordered common -> rare).
func _pick_gems(pool: Array[String], qty: int) -> Array:
	var out: Array = []
	## Rarity values (index+1): later in the pool = rarer = higher value.
	var values: Array = []
	var weights: Array = []
	for i in range(pool.size()):
		values.append(i + 1)
		weights.append(1)  ## equal base weight; luck tilts toward higher value
	var use_luck := get_node_or_null("/root/Luck") != null and get_node_or_null("/root/JewelryBonus") != null
	## Chest gems benefit from BOTH ruby (gem) and blue_stone (chest) luck; take
	## the stronger of the two so either necklace/ring helps chest gem rarity.
	var luck := 1
	if use_luck:
		luck = maxi(JewelryBonus.gem_roll_luck(), JewelryBonus.chest_roll_luck())
	for i in range(qty):
		var gt: String
		if use_luck:
			var idx: int = Luck.biased_pick(weights, values, luck)
			gt = pool[clampi(idx, 0, pool.size() - 1)]
		else:
			gt = pool[randi() % pool.size()]
		out.append({"gem_type": gt})
	return out

## Picks count unique (non-repeating) random seed types from the full set,
## then gives each a quantity between qty_min and qty_max.
func _pick_seeds(count: int, qty_min: int, qty_max: int) -> Array:
	var out: Array = []
	var total: int = GardenData.PLANT_DEFS.size()
	count = mini(count, total)
	var indices: Array = range(total)
	indices.shuffle()
	for i in range(count):
		out.append({"seed_type": indices[i], "quantity": randi_range(qty_min, qty_max)})
	return out

## Picks count random (possibly repeating) eligible Pho tile types.
func _pick_tiles(count: int) -> Array:
	var eligible: Array = [
		Piece.Type.SOLDIER, Piece.Type.SAIL, Piece.Type.WIND, Piece.Type.MAGE,
		Piece.Type.SHIELD, Piece.Type.TREE, Piece.Type.SLEEP, Piece.Type.DRUID,
		Piece.Type.CLERGY, Piece.Type.DOME,
	]
	var out: Array = []
	for i in range(count):
		out.append(eligible[randi() % eligible.size()])
	return out


## Main chest/level-reward generator.
## chest_level: 0-9 (chest index, display Lv.1-10). -1 = non-chest level-up reward.
## Non-chest callers (level-up rewards) use the old budget path below.
func _generate_level_rewards_from_budget(budget: int, max_pieces: int = 999, chest_level: int = -1) -> Array:
	## ── Non-chest level-up rewards: legacy budget path ───────────
	if chest_level < 0:
		return _generate_legacy_budget_rewards(budget)

	## ── Chest rewards: explicit per-level spec ───────────────────
	var rewards: Array = []

	## Determine whether prospectors are eligible for this chest.
	var prospectors_eligible := false
	if level >= 20:
		for gdef in PROSPECTOR_GEM_ORDER:
			if get_prospector_count(str(gdef["gem_type"])) > 0:
				prospectors_eligible = true
				break

	## Fixed coin reward (boosted by Bank of Pho if active).
	var base_coins: int = [
		1000, 2000, 3000, 4000, 7000, 9000, 10000, 12000, 15000, 20000
	][clampi(chest_level, 0, 9)]
	var coin_reward := base_coins
	if get_node_or_null("/root/BusinessDistrict") != null:
		coin_reward = int(coin_reward * BusinessDistrict.coin_reward_multiplier())
	rewards.append({"type": "coins", "amount": coin_reward})

	## Per-level reward table.  Each entry:
	##   tiles_min/max, seed_types, seed_qty_min/max,
	##   lower_min/max, middle_min/max, upper_min/max, prosp_min/max
	## 0 means that category is not awarded at this level.
	var spec: Array = [
		## Lv1  tiles 0-1, 2 seed types 1-2, lower 0-1
		{"t":[0,1], "st":2, "sq":[1,2],   "lo":[0,1], "mi":[0,0], "up":[0,0], "pr":[0,0]},
		## Lv2  tiles 0-1, 3 seed types 1-4, lower 0-2
		{"t":[0,1], "st":3, "sq":[1,4],   "lo":[0,2], "mi":[0,0], "up":[0,0], "pr":[0,0]},
		## Lv3  tiles 0-2, 3 seed types 2-6, lower 0-2
		{"t":[0,2], "st":3, "sq":[2,6],   "lo":[0,2], "mi":[0,0], "up":[0,0], "pr":[0,0]},
		## Lv4  tiles 0-3, 4 seed types 5-7, lower 0-2, middle 0-1
		{"t":[0,3], "st":4, "sq":[5,7],   "lo":[0,2], "mi":[0,1], "up":[0,0], "pr":[0,0]},
		## Lv5  tiles 1-4, 4 seed types 7-10, lower 1-3, middle 0-2
		{"t":[1,4], "st":4, "sq":[7,10],  "lo":[1,3], "mi":[0,2], "up":[0,0], "pr":[0,0]},
		## Lv6  tiles 2-4, 5 seed types 8-12, lower 1-3, middle 0-3
		{"t":[2,4], "st":5, "sq":[8,12],  "lo":[1,3], "mi":[0,3], "up":[0,0], "pr":[0,0]},
		## Lv7  tiles 3-5, 6 seed types 10-17, middle 1-4, upper 0-1
		{"t":[3,5], "st":6, "sq":[10,17], "lo":[0,0], "mi":[1,4], "up":[0,1], "pr":[0,0]},
		## Lv8  tiles 4-6, 7 seed types 15-22, middle 2-5, upper 1-2, prosp 0-1
		{"t":[4,6], "st":7, "sq":[15,22], "lo":[0,0], "mi":[2,5], "up":[1,2], "pr":[0,1]},
		## Lv9  tiles 5-7, 8 seed types 20-25, middle 3-6, upper 1-3, prosp 1-2
		{"t":[5,7], "st":8, "sq":[20,25], "lo":[0,0], "mi":[3,6], "up":[1,3], "pr":[1,2]},
		## Lv10 tiles 7-8, 9 seed types 25-50, lower 1-10, middle 1-5, upper 2-3, prosp 2-4
		{"t":[7,8], "st":9, "sq":[25,50], "lo":[1,10], "mi":[1,5], "up":[2,3], "pr":[2,4]},
	]
	var s: Dictionary = spec[clampi(chest_level, 0, 9)]

	## Pho tiles
	var tile_count := randi_range(int(s["t"][0]), int(s["t"][1]))
	rewards.append_array(_pick_tiles(tile_count))

	## Seeds
	rewards.append_array(_pick_seeds(int(s["st"]), int(s["sq"][0]), int(s["sq"][1])))

	## Gems
	var lo: Array = s["lo"]; var lo_n := randi_range(int(lo[0]), int(lo[1]))
	var mi: Array = s["mi"]; var mi_n := randi_range(int(mi[0]), int(mi[1]))
	var up: Array = s["up"]; var up_n := randi_range(int(up[0]), int(up[1]))
	if lo_n > 0: rewards.append_array(_pick_gems(_GEM_LOWER,  lo_n))
	if mi_n > 0: rewards.append_array(_pick_gems(_GEM_MIDDLE, mi_n))
	if up_n > 0: rewards.append_array(_pick_gems(_GEM_UPPER,  up_n))

	## Prospectors (only if unlocked at level 20+ and owned)
	var pr: Array = s["pr"]; var pr_n := randi_range(int(pr[0]), int(pr[1]))
	if pr_n > 0 and prospectors_eligible:
		var pt: String = str(PROSPECTOR_GEM_ORDER[randi() % PROSPECTOR_GEM_ORDER.size()]["gem_type"])
		rewards.append({"type": "prospector", "gem_type": pt, "quantity": pr_n})

	## WonderStone: the top (Lv.10, index 9) chest has a 50% chance to include
	## 1–20 WonderStones.
	if chest_level == 9 and randf() < 0.5:
		rewards.append({"type": "material", "item_id": "wonderstone", "quantity": randi_range(1, 20)})

	return _apply_chest_multiplier(rewards)


## Chest reward multiplier: (level + peak_level) / 2, never below 1.
func get_chest_reward_multiplier() -> float:
	return maxf(1.0, (float(level) + float(maxi(peak_level, level))) / 2.0)


## Rounds a scaled amount; the fractional part is resolved randomly so small
## quantities still average out to the exact multiplier.
func _scale_amount(amount: int, mult: float) -> int:
	var scaled: float = float(amount) * mult
	var whole: int = int(floor(scaled))
	if randf() < scaled - float(whole):
		whole += 1
	return whole


## Scales every chest reward by get_chest_reward_multiplier().
## Coins/seeds/prospectors/WonderStones have their amounts scaled; tiles and
## gems (one entry per item) are repeated.
func _apply_chest_multiplier(rewards: Array) -> Array:
	var mult: float = get_chest_reward_multiplier()
	if mult <= 1.0:
		return rewards
	var out: Array = []
	for r in rewards:
		if r is Dictionary and str(r.get("type", "")) == "coins":
			r["amount"] = int(round(float(r["amount"]) * mult))
			out.append(r)
		elif r is Dictionary and (r.has("seed_type") or str(r.get("type", "")) in ["prospector", "material", "resource", "sapling"]):
			r["quantity"] = _scale_amount(int(r.get("quantity", 1)), mult)
			if int(r["quantity"]) > 0:
				out.append(r)
		else:
			## Tile (enum int) or gem entry: repeat it.
			var copies: int = _scale_amount(1, mult)
			for i in copies:
				out.append(r.duplicate() if r is Dictionary else r)
	return out


## Legacy budget-based generator, used only for non-chest level-up rewards
## (chest_level < 0). Kept exactly as it was so level-up rewards are unaffected.
func _generate_legacy_budget_rewards(budget: int) -> Array:
	var rewards: Array = []
	var pieces_awarded: int = 0
	var eligible: Array = [
		Piece.Type.SOLDIER, Piece.Type.SAIL, Piece.Type.WIND, Piece.Type.MAGE,
		Piece.Type.SHIELD, Piece.Type.TREE, Piece.Type.SLEEP, Piece.Type.DRUID,
		Piece.Type.CLERGY, Piece.Type.DOME,
	]
	var gem_types: Array = ["gold", "blue_stone", "pink_stone", "violet_stone", "black_pearl", "emerald", "ruby", "diamond"]
	var gem_values: Dictionary = {
		"gold": 50, "blue_stone": 75, "pink_stone": 75, "violet_stone": 100,
		"black_pearl": 150, "emerald": 200, "ruby": 300, "diamond": 500,
	}
	var base_coins: int = budget * 10
	var bonus_pct: float = randf_range(0.30, 0.50)
	var coin_reward := maxi(10000, int(base_coins * (1.0 + bonus_pct)))
	rewards.append({"type": "coins", "amount": coin_reward})
	while budget >= 1:
		var roll := randi() % 100
		if roll < 25:
			if pieces_awarded >= 999:
				roll = 50 + (randi() % 50)
			else:
				var affordable: Array = []
				for pt in eligible:
					if get_piece_price(pt) <= budget:
						affordable.append(pt)
				if affordable.is_empty():
					break
				var chosen: Piece.Type = affordable[randi() % affordable.size()] as Piece.Type
				rewards.append(chosen)
				budget -= get_piece_price(chosen)
				pieces_awarded += 1
				continue
		if roll < 75:
			var affordable_gems: Array = []
			for gt in gem_types:
				if gem_values[gt] <= budget:
					affordable_gems.append(gt)
			if affordable_gems.is_empty():
				break
			var chosen_gem: String = affordable_gems[randi() % affordable_gems.size()]
			rewards.append({"gem_type": chosen_gem, "value": gem_values[chosen_gem]})
			budget -= gem_values[chosen_gem]
		else:
			var seed_type := randi() % GardenData.PLANT_DEFS.size()
			var seed_def: Dictionary = GardenData.PLANT_DEFS[seed_type]
			var seed_cost: int = maxi(int(seed_def["seed_cost"]), 1)
			var max_qty := mini(5, int(budget / seed_cost))
			if max_qty <= 0:
				break
			var qty := randi_range(1, max_qty)
			rewards.append({"seed_type": seed_type, "quantity": qty})
			budget -= seed_cost * qty
	return rewards


## Coin reward for a chest by its level index (0-9, displayed as Lv.1-10).
##   Lv.5-7 (index 4-6): ~100k-300k, ramping up across the tier.
##   Lv.8-10 (index 7-9): ~500k-1m, ramping up across the tier.
## Low chests (index 0-3) don't use this — they keep the budget-based reward.
func _coin_reward_for_chest_level(chest_level: int) -> int:
	match chest_level:
		4:  return randi_range(100_000, 160_000)   ## Lv.5
		5:  return randi_range(160_000, 230_000)   ## Lv.6
		6:  return randi_range(230_000, 300_000)   ## Lv.7
		7:  return randi_range(500_000, 660_000)   ## Lv.8
		8:  return randi_range(660_000, 830_000)   ## Lv.9
		_:  return randi_range(830_000, 1_000_000) ## Lv.10+


## Returns the max Pho tiles a chest of a given level (0-9) can award.
## Matches the per-level spec in _generate_level_rewards_from_budget.
static func get_chest_piece_cap(chest_level: int) -> int:
	## Max tiles per level (0-9):  1,1,2,3,4,4,5,6,7,8
	var caps: Array[int] = [1, 1, 2, 3, 4, 4, 5, 6, 7, 8]
	return caps[clampi(chest_level, 0, caps.size() - 1)]


## Adds reward pieces directly to inventory. Overflow converts to coins (sell value).
## Also handles seed rewards, gemstone rewards, and coin rewards.
func _add_reward_pieces(rewards: Array) -> void:
	var overflow_coins: int = 0
	for reward in rewards:
		if reward is Dictionary and reward.has("type") and reward["type"] == "coins":
			## Direct coin reward
			coins += int(reward["amount"])
			continue
		if reward is Dictionary and reward.has("seed_type"):
			## Seed reward — seeds are UNCAPPED, add the full amount.
			if get_node_or_null("/root/Garden") != null:
				Garden.add_seeds(int(reward["seed_type"]), int(reward["quantity"]))
			continue
		if reward is Dictionary and reward.get("type", "") == "sapling":
			## Sapling reward — saplings are UNCAPPED, add the full amount.
			if get_node_or_null("/root/Orchard") != null:
				Orchard.add_saplings(int(reward["tree_type"]), int(reward.get("quantity", 1)))
			continue
		if reward is Dictionary and reward.get("type", "") == "prospector":
			## Prospector reward (top-tier chest bonus) — granted for free.
			add_prospectors(str(reward["gem_type"]), int(reward.get("quantity", 1)))
			continue
		if reward is Dictionary and reward.get("type", "") == "material":
			## Rare material (WonderStone) reward.
			if str(reward.get("item_id", "")) == "wonderstone":
				add_wonderstone(int(reward.get("quantity", 1)), true)
			continue
		if reward is Dictionary and reward.get("type", "") == "resource":
			## Resource item reward (wood/ore/bar...).
			add_item(str(reward.get("item_id", "")), int(reward.get("quantity", 1)), true)
			continue
		if reward is Dictionary and reward.has("gem_type"):
			## Gemstone reward — route through add_gemstones so MissionBoard is notified
			add_gemstones(str(reward["gem_type"]), 1)
			continue
		## Piece reward (raw Piece.Type enum value)
		var piece_type = reward
		if inventory.size() >= MAX_INVENTORY:
			## Convert to coins at sell value (half buy price)
			overflow_coins += get_piece_price(piece_type as Piece.Type) / 2
			continue
		var def := PieceRegistry.get_def(piece_type as Piece.Type)
		var dir := int(PieceDefinition.Direction.NONE)
		if def:
			dir = int(def.effect_direction)
		inventory.append({"type": int(piece_type), "direction": dir})
	if overflow_coins > 0:
		coins += overflow_coins
	save_data()

## ── Inventory helpers ──────────────────────────────────────────

## Default facing direction for a piece type.
## Direction isn't persisted in the save (it only matters in-hand during a
## battle and resets afterwards), so on load we restore each tile to its
## piece definition's default. Matches the logic used by purchase/rewards.
func _default_direction_for(piece_type: int) -> int:
	var def := PieceRegistry.get_def(piece_type as Piece.Type)
	if def:
		return int(def.effect_direction)
	return int(PieceDefinition.Direction.NONE)

## Build Piece objects from inventory for use in battles
func get_inventory_as_pieces() -> Array[Piece]:
	var pieces: Array[Piece] = []
	for item in inventory:
		var p := Piece.create(item["type"] as Piece.Type, Piece.Owner.PLAYER)
		p.direction = item["direction"] as PieceDefinition.Direction
		pieces.append(p)
	return pieces

## Remove pieces that were placed on the board (consumed after battle)
func consume_pieces(placed_pieces: Array[Piece]) -> void:
	for piece in placed_pieces:
		## Find and remove the first matching entry from inventory
		for i in range(inventory.size()):
			if int(inventory[i]["type"]) == int(piece.type):
				inventory.remove_at(i)
				break
	save_data()
	emit_signal("data_changed")


## Consume a single tile from persistent inventory the moment it is committed
## to the board during a battle. Prefers an entry matching BOTH type and
## direction; falls back to any entry of the same type. Returns true if an
## entry was removed. Persists immediately so the tile can't survive a
## forfeit, quit, or being captured later in the match.
func consume_one_piece(piece_type: int, direction: int = -1) -> bool:
	var removed_index := -1
	## First pass: exact type + direction match.
	if direction >= 0:
		for i in range(inventory.size()):
			if int(inventory[i].get("type", -1)) == piece_type and int(inventory[i].get("direction", -1)) == direction:
				removed_index = i
				break
	## Fallback: first entry of the same type.
	if removed_index == -1:
		for i in range(inventory.size()):
			if int(inventory[i].get("type", -1)) == piece_type:
				removed_index = i
				break
	if removed_index == -1:
		return false
	inventory.remove_at(removed_index)
	save_data()
	emit_signal("data_changed")
	return true

## Count how many of a given type are in inventory
func count_in_inventory(piece_type: Piece.Type) -> int:
	var count := 0
	for item in inventory:
		if int(item["type"]) == int(piece_type):
			count += 1
	return count

func get_inventory_size() -> int:
	return inventory.size()

## Reset player data (for testing)
func reset() -> void:
	player_name = DEFAULT_NAME
	level = DEFAULT_LEVEL
	peak_level = DEFAULT_LEVEL
	coins = DEFAULT_COINS
	xp = 0
	diamond_ring_count = 0
	jewelry.clear()
	equipped_ring = ""
	equipped_necklace = ""
	equipped_misc = ""
	money_gun_owned = false
	money_gun_level = 0
	fruits.clear()
	crops.clear()
	redeemed_codes.clear()
	inventory.clear()
	gemstones.clear()
	tutorial_completed = false
	tutorial_step_index = -1
	tutorial_home_dismissed = false
	_give_starting_inventory()
	save_data()
	emit_signal("data_changed")
