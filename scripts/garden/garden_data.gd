class_name GardenData
extends Node

## Autoload: Garden
## Manages garden grid state, seed inventory, planting, and harvest timers.
## Saved to user://garden_save.cfg

const SAVE_PATH := "user://garden_save.cfg"

## Garden size limits
const MIN_ROWS := 1
const MIN_COLS := 5
const MAX_ROWS := 16
const MAX_COLS := 16
const ROW_COST_BASE := 150
const COL_COST_BASE := 100
const EXPANSION_SCALE := 1.25  ## Each purchase costs 25% more than the last

## Seed storage
const BASE_SEED_STORAGE := 50
const SEED_STORAGE_UPGRADE_SLOTS := 10
const SEED_STORAGE_UPGRADE_COST := 500
const MAX_SEED_STORAGE_UPGRADES := 100
var seed_storage_upgrades: int = 0

## Seeds and saplings are UNCAPPED — there is no storage limit on them (unlike
## Pho tiles, which remain capped by PlayerData.MAX_INVENTORY). When false,
## MAX_SEED_STORAGE returns a huge sentinel so every existing
## `total < MAX_SEED_STORAGE` / `MAX_SEED_STORAGE - total` gate across the game
## treats the pool as effectively unlimited. The seed_storage_upgrades state is
## kept (loaded/saved) but inert while uncapped. Flip to true to restore the cap.
const SEED_STORAGE_CAPPED := false
## A value large enough that no legitimate seed/sapling total can ever reach it.
const SEED_STORAGE_UNCAPPED_SENTINEL := 1_000_000_000

func has_seed_cap() -> bool:
	return SEED_STORAGE_CAPPED

var MAX_SEED_STORAGE: int:
	get:
		if not SEED_STORAGE_CAPPED:
			return SEED_STORAGE_UNCAPPED_SENTINEL
		return BASE_SEED_STORAGE + (seed_storage_upgrades * SEED_STORAGE_UPGRADE_SLOTS)

## Seed shop pool — restocks every 3 hours like the tile shop
const SEED_SHOP_REFRESH_INTERVAL := 10800.0  ## 3 hours
const SEED_SHOP_POOL_MIN := 60
const SEED_SHOP_POOL_MAX := 100
var seed_shop_pool: Dictionary = {}  ## PlantType (int) -> quantity available
var seed_shop_timestamp: float = 0.0

## Plant definitions: name, seed_cost, harvest_time_seconds, harvest_reward
## Ordered cheapest to most expensive
enum PlantType { BEANS, CUCUMBERS, PEPPERS, SQUASH, GRAPES, SUNFLOWER, CAULIFLOWER, PINEAPPLE, WATERMELON }

const PLANT_DEFS: Array[Dictionary] = [
	{ "name": "Beans", "seed_cost": 1, "harvest_time": 300, "reward": 15, "sprite": "res://Assets/Plants/beans.png" },
	{ "name": "Cucumbers", "seed_cost": 3, "harvest_time": 600, "reward": 36, "sprite": "res://Assets/Plants/cucumbers.png" },
	{ "name": "Peppers", "seed_cost": 5, "harvest_time": 1200, "reward": 60, "sprite": "res://Assets/Plants/peppers.png" },
	{ "name": "Squash", "seed_cost": 7, "harvest_time": 2400, "reward": 105, "sprite": "res://Assets/Plants/Squash.png" },
	{ "name": "Grapes", "seed_cost": 9, "harvest_time": 4800, "reward": 150, "sprite": "res://Assets/Plants/grapes.png" },
	{ "name": "Sunflower", "seed_cost": 12, "harvest_time": 7200, "reward": 195, "sprite": "res://Assets/Plants/sunflower.png" },
	{ "name": "Cauliflower", "seed_cost": 15, "harvest_time": 10800, "reward": 225, "sprite": "res://Assets/Plants/cauliflower.png" },
	{ "name": "Pineapple", "seed_cost": 18, "harvest_time": 16200, "reward": 264, "sprite": "res://Assets/Plants/pineapple.png" },
	{ "name": "Watermelon", "seed_cost": 20, "harvest_time": 21600, "reward": 300, "sprite": "res://Assets/Plants/Watermelon.png" },
]

const PLANT_FRAMES := 4  ## Each plant sprite has 4 animation frames (horizontal strip)

## ── Growth Bonus ──────────────────────────────────────────────
const DIAMOND_RING_GROWTH_MULTIPLIER := 0.75
const DIAMOND_RING_DROP_CHANCE := 25_000  ## 1 in 25,000 per harvest

signal garden_updated

## ── State ──────────────────────────────────────────────────────
var garden_rows: int = MIN_ROWS
var garden_cols: int = MIN_COLS

## Grid cells: 2D array [row][col] of Dictionary or null
## Each planted cell: { "plant_type": int, "plant_time": float (unix timestamp) }
var grid: Array = []

## Seed inventory: { PlantType (int) -> quantity (int) }
var seeds: Dictionary = {}

var auto_select_next_seed: bool = false


## ── Lifecycle ──────────────────────────────────────────────────

func _ready() -> void:
	load_data()
	## Periodic seed shop refresh check
	var shop_timer := Timer.new()
	shop_timer.wait_time = 60.0
	shop_timer.autostart = true
	shop_timer.timeout.connect(_check_seed_shop_refresh)
	add_child(shop_timer)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_data()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		save_data()


## ── Public API ─────────────────────────────────────────────────

func get_plant_def(plant_type: int) -> Dictionary:
	if plant_type >= 0 and plant_type < PLANT_DEFS.size():
		return PLANT_DEFS[plant_type]
	return {}


## Returns the effective harvest time for a plant type, applying the Diamond Ring
## growth bonus (25% faster) if the player owns at least one Diamond Ring.
## The bonus does not stack — owning multiple rings has the same effect as one.
func get_effective_harvest_time(plant_type: int) -> float:
	var def := get_plant_def(plant_type)
	if def.is_empty():
		return 0.0
	var base_time: float = float(def["harvest_time"])
	var time_mult: float = PlayerData.get_crop_time_multiplier()
	## Guild "Crop Growth Speed" perk (−5%/level; lower = faster).
	if get_node_or_null("/root/GuildManager") != null:
		time_mult *= GuildManager.growth_time_perk_mult()
	## Equipped diamond "growth_speed" jewelry (count-scaled; replaces the old
	## flat diamond-ring flag). growth_time_multiplier() is <= 1.0 (faster).
	if get_node_or_null("/root/JewelryBonus") != null:
		time_mult *= JewelryBonus.growth_time_multiplier()
	## Sun-Dried Trail Mix recipe boost: "Fast Sprout" speeds crop growth while
	## the timed boost is active (value = fraction faster, e.g. 0.15 = −15%).
	if PlayerData.boost_active("fast_sprout"):
		time_mult *= maxf(0.0, 1.0 - PlayerData.boost_value("fast_sprout"))
	return base_time * time_mult


func set_auto_select_next_seed(enabled: bool) -> void:
	if auto_select_next_seed != enabled:
		auto_select_next_seed = enabled
		save_data()


## Crops produced by one harvest: base 1 plus the Seed Shop (Business District)
## yield bonus. Neutral (1) when the shop is inactive. LOCAL only.
## Crops produced by one harvest: base 1 plus the Seed Shop (Business District)
## yield bonus, plus a chance of a double yield from the Blue Stone Necklace
## (JewelryBonus.double_crop_chance()). LOCAL only.
func _harvest_qty(plant_type: int) -> int:
	var qty := 1
	if get_node_or_null("/root/BusinessDistrict") != null:
		qty += BusinessDistrict.harvest_yield_bonus(plant_type)
	## Double-crop chance = Blue Stone Necklace + Sparkling Grape Juice recipe
	## boost (additive chances), one extra crop on a hit.
	var dbl_chance := 0.0
	if get_node_or_null("/root/JewelryBonus") != null:
		dbl_chance += JewelryBonus.double_crop_chance()
	dbl_chance += PlayerData.boost_value("double_crop_chance")
	if dbl_chance > 0.0 and randf() < dbl_chance:
		qty += 1
	## Summer Melon Salad recipe boost: "Bountiful Yield" grants +1 guaranteed
	## crop per harvested tile while active.
	if PlayerData.boost_active("bountiful_yield"):
		qty += int(PlayerData.boost_value("bountiful_yield"))
	return maxi(qty, 1)


## WonderStone drop from harvesting WATERMELON: 1/250 per YIELDED crop, so
## double-harvest / bountiful bonuses (which raise `yielded`) naturally increase
## the odds. plant_type 8 = watermelon (see GardenData.PlantType / CROP_DEFS).
const WATERMELON_PLANT_TYPE := 8
const WATERMELON_WONDERSTONE_CHANCE := 250  ## 1-in-N per yielded crop
func _roll_watermelon_wonderstone(plant_type: int, yielded: int) -> void:
	if plant_type != WATERMELON_PLANT_TYPE or yielded <= 0:
		return
	if get_node_or_null("/root/PlayerData") == null:
		return
	var found := 0
	for _i in range(yielded):
		if randi() % WATERMELON_WONDERSTONE_CHANCE == 0:
			found += 1
	if found > 0:
		## defer: harvest flows save immediately after; batch flushes once.
		PlayerData.add_wonderstone(found, true)


func get_seed_count(plant_type: int) -> int:
	return seeds.get(plant_type, 0)


func get_total_seeds() -> int:
	var total := 0
	for qty in seeds.values():
		total += qty
	return total


## Combined seeds + orchard saplings — both share the one storage pool
## (MAX_SEED_STORAGE). This is the value that gates buying more of either.
func get_total_seeds_and_saplings() -> int:
	var total := get_total_seeds()
	if get_node_or_null("/root/Orchard") != null and Orchard.has_method("get_total_saplings"):
		total += Orchard.get_total_saplings()
	return total


func add_seeds(plant_type: int, qty: int, emit_update: bool = true) -> void:
	seeds[plant_type] = seeds.get(plant_type, 0) + qty
	save_data()
	if emit_update:
		garden_updated.emit()


func get_seed_storage_cost() -> int:
	return int(SEED_STORAGE_UPGRADE_COST * seed_storage_upgrades)


func can_buy_seed_storage() -> bool:
	## Seeds/saplings are uncapped — the storage upgrade is retired.
	if not SEED_STORAGE_CAPPED:
		return false
	return seed_storage_upgrades < MAX_SEED_STORAGE_UPGRADES and PlayerData.coins >= get_seed_storage_cost()


func buy_seed_storage() -> bool:
	if seed_storage_upgrades >= MAX_SEED_STORAGE_UPGRADES:
		return false
	var cost := get_seed_storage_cost()
	if PlayerData.coins < cost:
		return false
	PlayerData.coins -= cost
	seed_storage_upgrades += 1
	PlayerData.save_data()
	PlayerData.data_changed.emit()
	save_data()
	garden_updated.emit()
	return true


## ── Seed Shop Pool ─────────────────────────────────────────────

func _check_seed_shop_refresh() -> void:
	var now := TrustedClock.now()
	if seed_shop_pool.is_empty():
		_generate_seed_shop_pool()
		save_data()
		garden_updated.emit()
		return
	var elapsed := now - seed_shop_timestamp
	if elapsed < SEED_SHOP_REFRESH_INTERVAL:
		return
	var cycles := int(elapsed / SEED_SHOP_REFRESH_INTERVAL)
	for i in range(cycles):
		_generate_seed_shop_pool()
	seed_shop_timestamp += cycles * SEED_SHOP_REFRESH_INTERVAL
	save_data()
	garden_updated.emit()


func _generate_seed_shop_pool() -> void:
	if seed_shop_timestamp <= 0.0:
		seed_shop_timestamp = TrustedClock.now()

	## Weights: cheaper seeds more common
	var weights: Array[int] = [25, 20, 16, 13, 10, 8, 6, 4, 3]
	var total_weight: int = 0
	for w in weights:
		total_weight += w

	var pool_size: int = randi_range(SEED_SHOP_POOL_MIN, SEED_SHOP_POOL_MAX)
	for i in range(pool_size):
		var roll := randi() % total_weight
		var cumulative := 0
		for plant_idx in range(weights.size()):
			cumulative += weights[plant_idx]
			if roll < cumulative:
				seed_shop_pool[plant_idx] = mini(seed_shop_pool.get(plant_idx, 0) + 1, 1000)
				break


func get_seed_shop_stock(plant_type: int) -> int:
	return seed_shop_pool.get(plant_type, 0)


func consume_seed_shop_stock(plant_type: int, qty: int) -> bool:
	var available: int = seed_shop_pool.get(plant_type, 0)
	if available < qty:
		return false
	seed_shop_pool[plant_type] = available - qty
	return true


func get_seed_shop_refresh_remaining() -> float:
	var now := TrustedClock.now()
	var elapsed := now - seed_shop_timestamp
	return maxf(0.0, SEED_SHOP_REFRESH_INTERVAL - elapsed)


func get_row_cost() -> int:
	var purchases_made := garden_rows - MIN_ROWS
	return int(ROW_COST_BASE * pow(EXPANSION_SCALE, purchases_made))


func get_col_cost() -> int:
	var purchases_made := garden_cols - MIN_COLS
	return int(COL_COST_BASE * pow(EXPANSION_SCALE, purchases_made))


func can_buy_row() -> bool:
	return garden_rows < MAX_ROWS and PlayerData.coins >= get_row_cost()


func can_buy_col() -> bool:
	return garden_cols < MAX_COLS and PlayerData.coins >= get_col_cost()


func buy_row() -> bool:
	var cost := get_row_cost()
	if garden_rows >= MAX_ROWS or PlayerData.coins < cost:
		return false
	PlayerData.coins -= cost
	garden_rows += 1
	_expand_grid()
	PlayerData.save_data()
	save_data()
	garden_updated.emit()
	return true


func buy_col() -> bool:
	var cost := get_col_cost()
	if garden_cols >= MAX_COLS or PlayerData.coins < cost:
		return false
	PlayerData.coins -= cost
	garden_cols += 1
	_expand_grid()
	PlayerData.save_data()
	save_data()
	garden_updated.emit()
	return true


## Plant a seed at the given cell. Returns true if successful.
func plant_seed(row: int, col: int, plant_type: int, defer: bool = false) -> bool:
	if row < 0 or row >= garden_rows or col < 0 or col >= garden_cols:
		return false
	if grid[row][col] != null:
		return false  ## Cell already occupied
	if get_seed_count(plant_type) <= 0:
		return false

	seeds[plant_type] = seeds.get(plant_type, 0) - 1
	grid[row][col] = {
		"plant_type": plant_type,
		"plant_time": TrustedClock.now(),
	}
	## defer=true (bulk auto-plant): skip the per-cell disk save, the full-grid
	## "garden full" achievement scan, and the signal. The caller batches these
	## with plant_seed_flush() once at the end to avoid a multi-second freeze.
	if defer:
		return true
	save_data()

	## Check if the full 16×16 garden is completely filled (before emit to avoid re-entrancy)
	if garden_rows >= MAX_ROWS and garden_cols >= MAX_COLS:
		var all_filled := true
		var first_type: int = -1
		var all_same_type := true
		for r in range(garden_rows):
			for c in range(garden_cols):
				if grid[r][c] == null:
					all_filled = false
					all_same_type = false
					break
				var cell_type: int = grid[r][c]["plant_type"]
				if first_type == -1:
					first_type = cell_type
				elif cell_type != first_type:
					all_same_type = false
			if not all_filled:
				break
		if all_filled:
			Achievements.record_garden_full()
			if all_same_type and first_type >= 0:
				Achievements.record_garden_full_single_crop(first_type)

	garden_updated.emit()
	return true


## Persists and signals once after a batch of deferred plant_seed() calls (bulk
## auto-plant), and runs the "garden full" achievement scan a single time. Cheap
## to call even if nothing was planted.
func plant_seed_flush() -> void:
	save_data()

	## Full-garden achievement check (runs once, not per planted cell).
	if garden_rows >= MAX_ROWS and garden_cols >= MAX_COLS:
		var all_filled := true
		var first_type: int = -1
		var all_same_type := true
		for r in range(garden_rows):
			for c in range(garden_cols):
				if grid[r][c] == null:
					all_filled = false
					all_same_type = false
					break
				var cell_type: int = grid[r][c]["plant_type"]
				if first_type == -1:
					first_type = cell_type
				elif cell_type != first_type:
					all_same_type = false
			if not all_filled:
				break
		if all_filled:
			Achievements.record_garden_full()
			if all_same_type and first_type >= 0:
				Achievements.record_garden_full_single_crop(first_type)

	garden_updated.emit()


## Returns the growth progress of a cell (0.0 to 1.0). Returns -1 if empty.
func get_growth_progress(row: int, col: int) -> float:
	if row < 0 or row >= garden_rows or col < 0 or col >= garden_cols:
		return -1.0
	var cell = grid[row][col]
	if cell == null:
		return -1.0
	var def := get_plant_def(cell["plant_type"])
	if def.is_empty():
		return -1.0
	var elapsed: float = TrustedClock.now() - float(cell["plant_time"])
	var effective_time := get_effective_harvest_time(cell["plant_type"])
	if effective_time <= 0.0:
		return -1.0
	return clampf(elapsed / effective_time, 0.0, 1.0)


## Returns the current animation frame index (0-3) for a cell.
func get_growth_frame(row: int, col: int) -> int:
	var progress := get_growth_progress(row, col)
	if progress < 0:
		return -1
	return mini(int(progress * PLANT_FRAMES), PLANT_FRAMES - 1)


## Returns true if a plant is ready to harvest.
func is_harvestable(row: int, col: int) -> bool:
	return get_growth_progress(row, col) >= 1.0


## Advances every planted crop's growth by the given number of hours (used by
## the Workshop hourglass). Shifts each plant_time back so it's as if that much
## time passed toward harvest readiness.
func advance_time_hours(hours: float) -> void:
	var seconds := hours * 3600.0
	var changed := false
	for r in range(garden_rows):
		for c in range(garden_cols):
			var cell = grid[r][c]
			if cell is Dictionary and cell.has("plant_time"):
				cell["plant_time"] = float(cell["plant_time"]) - seconds
				changed = true

	## Restock the seed shop for the skipped time. We compute cycles directly
	## from (current elapsed + skipped seconds) instead of shifting the
	## timestamp and re-reading the wall clock, because _check_seed_shop_refresh
	## measures elapsed against TrustedClock.now() — shifting the
	## timestamp and calling it back-to-back can lose the crossed-zero refresh
	## when the skip lands the timer near the interval boundary.
	if seed_shop_timestamp > 0.0 and not seed_shop_pool.is_empty():
		var now := TrustedClock.now()
		var total_elapsed := (now - seed_shop_timestamp) + seconds
		var cycles := int(total_elapsed / SEED_SHOP_REFRESH_INTERVAL)
		if cycles > 0:
			for i in range(cycles):
				_generate_seed_shop_pool()
			## Consume exactly the cycles used; keep the remainder so the next
			## restock lands at the right time. Rebase off `now` so the visible
			## countdown reflects the leftover after the skip.
			var remainder := total_elapsed - float(cycles) * SEED_SHOP_REFRESH_INTERVAL
			seed_shop_timestamp = now - remainder
		else:
			## No restock yet — just shift the timer forward by the skip.
			seed_shop_timestamp -= seconds
		changed = true

	if changed:
		save_data()
		garden_updated.emit()
	## Handles the empty-pool / normal-elapsed cases (no-op if we already
	## restocked above, since the remainder is below one interval).
	_check_seed_shop_refresh()


## Evaluate a 1/25,000 chance to award a Diamond Ring on harvest.
## Returns true if a ring was awarded.
func _try_diamond_ring_drop() -> bool:
	var roll := randi() % DIAMOND_RING_DROP_CHANCE
	if roll == 0:
		PlayerData.add_diamond_ring()
		return true
	return false


## Harvest a plant. Returns the coin reward, or 0 if not ready.
func harvest(row: int, col: int) -> int:
	if not is_harvestable(row, col):
		return 0
	var cell = grid[row][col]
	if cell == null:
		return 0
	var plant_type: int = cell["plant_type"]
	var def := get_plant_def(plant_type)
	## Crops are now HELD items: harvesting stores one crop instead of paying
	## coins. The garden-profit prestige is applied later, on SALE, in the
	## Marketplace (PlayerData.get_crop_sell_value). XP is still awarded here,
	## based on the crop's base reward (no prestige), so leveling is unaffected.
	var base_reward: int = def.get("reward", 0)
	grid[row][col] = null
	## Seed Shop (Business District) yields extra crops per harvest.
	var hq := _harvest_qty(plant_type)
	PlayerData.add_crop_by_plant_type(plant_type, hq)
	_roll_watermelon_wonderstone(plant_type, hq)
	save_data()

	## Evaluate Diamond Ring drop chance
	_try_diamond_ring_drop()

	## Achievement tracking (before emitting garden_updated to avoid re-entry)
	Achievements.record_garden_harvest(plant_type)
	MissionBoard.on_crop_harvested(plant_type)
	## Award XP for harvesting (based on the base reward, unscaled by prestige).
	PlayerData.award_xp(base_reward)
	garden_updated.emit()
	return base_reward

## Harvest multiple cells in one batch. Saves and signals only once at the end.
## cells is an Array of Vector2i (row, col) pairs.
## Returns a Dictionary with "reward" (total coins) and "count" (cells harvested).
func harvest_batch(cells: Array) -> Dictionary:
	## Total base reward, tracked only for the XP batch (crops are held items now;
	## coins come later on SALE in the Marketplace). "reward" in the returned
	## dict is this base-XP total, not coins earned.
	var total_base_reward := 0
	var harvested := 0
	var plant_types_harvested: Array[int] = []

	for cell_pos in cells:
		var r: int = cell_pos.x
		var c: int = cell_pos.y
		if not is_harvestable(r, c):
			continue
		var cell = grid[r][c]
		if cell == null:
			continue
		var plant_type: int = cell["plant_type"]
		var def := get_plant_def(plant_type)
		var base_reward: int = int(def.get("reward", 0))
		grid[r][c] = null
		## Store the harvested crop as a held item (prestige applies on sale).
		## The Seed Shop (Business District) adds extra crops per harvest.
		## defer=true: the batch does a single PlayerData.save_data() below, so
		## we skip the per-cell disk write that used to cause the harvest freeze.
		var hq := _harvest_qty(plant_type)
		PlayerData.add_crop_by_plant_type(plant_type, hq, true)
		_roll_watermelon_wonderstone(plant_type, hq)
		total_base_reward += base_reward
		harvested += 1
		plant_types_harvested.append(plant_type)
		_try_diamond_ring_drop()

	if harvested > 0:
		## Award XP in bulk silently (updates both active xp and lifetime_xp smoothly without lag)
		PlayerData.add_xp_batch(total_base_reward)
		PlayerData.check_level_up_batch() ## Run level check ONCE at the end of the batch
		
		PlayerData.save_data()
		PlayerData.data_changed.emit()
		save_data()
		
		## Record achievements for each harvested plant
		for pt in plant_types_harvested:
			Achievements.record_garden_harvest(pt)
			MissionBoard.on_crop_harvested(pt)
		garden_updated.emit()

	return {"reward": total_base_reward, "count": harvested}

## ── Hare heist (crop-thief mini game) ──────────────────────────
## Each time the garden screen opens, every harvest-ready cell independently
## rolls HARE_STEAL_CHANCE. A hit empties the cell and holds that cell's real
## harvest yield (Seed Shop / double-crop / recipe bonuses included) in
## `pending_heist` until the player resolves the mini game. The pending heist is
## persisted, so leaving by any route other than Abandon re-opens the mini game
## on the next garden visit.
const HARE_STEAL_CHANCE := 0.01

## Stolen crops awaiting the mini game: { plant_type (int) -> qty (int) }.
var pending_heist: Dictionary = {}

## Minimum time between hares: after a heist ends (caught, trapped or
## abandoned), no new hare can spawn for this long.
const HARE_COOLDOWN_SECS := 300.0  ## 5 minutes

## Unix time the last heist was resolved (0 = never). Saved, so the cooldown
## survives closing and reopening the app.
var last_heist_end: float = 0.0


## Seconds left before a hare can spawn again (0 when it can).
func heist_cooldown_remaining() -> float:
	if last_heist_end <= 0.0:
		return 0.0
	var left := HARE_COOLDOWN_SECS - (TrustedClock.now() - last_heist_end)
	return maxf(left, 0.0)


func has_pending_heist() -> bool:
	return not pending_heist.is_empty()


## Total number of stolen crops across all types.
func heist_total() -> int:
	var total := 0
	for pt in pending_heist:
		total += int(pending_heist[pt])
	return total


## Human-readable stolen list, e.g. "12 Beans, 3 Squash".
func heist_summary_text() -> String:
	var parts: PackedStringArray = []
	var keys: Array = pending_heist.keys()
	keys.sort()
	for pt in keys:
		var def := get_plant_def(int(pt))
		parts.append("%d %s" % [int(pending_heist[pt]), str(def.get("name", "crop"))])
	return ", ".join(parts)


## Rolls the steal chance for every ready cell. Returns true if a heist is now
## pending (either newly rolled, or one that was already waiting).
func roll_hare_heist() -> bool:
	if has_pending_heist():
		return true
	## Cooldown: no new hare within HARE_COOLDOWN_SECS of the last heist ending.
	## (Also covers the garden visit right after the mini game, so a heist is
	## never followed by a second installment.)
	if heist_cooldown_remaining() > 0.0:
		return false
	var stolen_any := false
	for r in range(garden_rows):
		for c in range(garden_cols):
			if not is_harvestable(r, c):
				continue
			if randf() >= HARE_STEAL_CHANCE:
				continue
			var cell = grid[r][c]
			if cell == null:
				continue
			var plant_type: int = int(cell["plant_type"])
			grid[r][c] = null
			var qty: int = _harvest_qty(plant_type)
			pending_heist[plant_type] = int(pending_heist.get(plant_type, 0)) + qty
			stolen_any = true
	if stolen_any:
		save_data()
	return stolen_any


## Mini game won: the stolen crops go to the player's inventory.
## Returns the returned { plant_type -> qty } for display.
func resolve_heist_win() -> Dictionary:
	var returned: Dictionary = pending_heist.duplicate()
	for pt in returned:
		PlayerData.add_crop_by_plant_type(int(pt), int(returned[pt]), true)
	pending_heist.clear()
	last_heist_end = TrustedClock.now()
	PlayerData.save_data()
	PlayerData.data_changed.emit()
	save_data()
	return returned


## Mini game lost or abandoned: the crops are gone for good.
func resolve_heist_loss() -> void:
	pending_heist.clear()
	last_heist_end = TrustedClock.now()
	save_data()


## ── Grid management ────────────────────────────────────────────

func _init_grid() -> void:
	grid.clear()
	for r in range(garden_rows):
		var row_data: Array = []
		for c in range(garden_cols):
			row_data.append(null)
		grid.append(row_data)


func _expand_grid() -> void:
	## Ensure grid has enough rows
	while grid.size() < garden_rows:
		var row_data: Array = []
		for c in range(garden_cols):
			row_data.append(null)
		grid.append(row_data)
	## Ensure each row has enough columns
	for r in range(grid.size()):
		while grid[r].size() < garden_cols:
			grid[r].append(null)


## ── Persistence ────────────────────────────────────────────────

func save_data() -> void:
	var config := ConfigFile.new()
	config.set_value("garden", "rows", garden_rows)
	config.set_value("garden", "cols", garden_cols)
	config.set_value("garden", "seed_storage_upgrades", seed_storage_upgrades)
	config.set_value("garden", "auto_select_next_seed", auto_select_next_seed)

	## Serialize grid
	var grid_data: Array = []
	for r in range(garden_rows):
		var row_data: Array = []
		for c in range(garden_cols):
			row_data.append(grid[r][c])  ## null or dict
		grid_data.append(row_data)
	config.set_value("garden", "grid", grid_data)

	## Serialize seeds
	var seed_data: Dictionary = {}
	for key in seeds:
		seed_data[int(key)] = seeds[key]
	config.set_value("garden", "seeds", seed_data)

	## Serialize seed shop pool
	var pool_data: Dictionary = {}
	for key in seed_shop_pool:
		pool_data[int(key)] = seed_shop_pool[key]
	config.set_value("seed_shop", "pool", pool_data)
	config.set_value("seed_shop", "timestamp", seed_shop_timestamp)

	## Pending hare heist (stolen crops awaiting the mini game).
	var heist_data: Dictionary = {}
	for key in pending_heist:
		heist_data[int(key)] = int(pending_heist[key])
	config.set_value("heist", "pending", heist_data)
	config.set_value("heist", "last_end", last_heist_end)

	config.save(SAVE_PATH)


func load_data() -> void:
	var config := ConfigFile.new()
	var err := config.load(SAVE_PATH)
	if err != OK:
		_init_grid()
		_generate_seed_shop_pool()
		return

	garden_rows = config.get_value("garden", "rows", MIN_ROWS)
	garden_cols = config.get_value("garden", "cols", MIN_COLS)
	seed_storage_upgrades = config.get_value("garden", "seed_storage_upgrades", 0)
	auto_select_next_seed = config.get_value("garden", "auto_select_next_seed", false)

	var grid_data = config.get_value("garden", "grid", [])
	grid.clear()
	if grid_data is Array and grid_data.size() > 0:
		for r in range(mini(grid_data.size(), garden_rows)):
			var row_data: Array = []
			if grid_data[r] is Array:
				for c in range(mini(grid_data[r].size(), garden_cols)):
					row_data.append(grid_data[r][c])
			## Pad columns if needed
			while row_data.size() < garden_cols:
				row_data.append(null)
			grid.append(row_data)
	## Pad rows if needed
	while grid.size() < garden_rows:
		var row_data: Array = []
		for c in range(garden_cols):
			row_data.append(null)
		grid.append(row_data)

	var seed_data = config.get_value("garden", "seeds", {})
	seeds.clear()
	if seed_data is Dictionary:
		for key in seed_data:
			seeds[int(key)] = int(seed_data[key])

	## Load seed shop pool
	var pool_data = config.get_value("seed_shop", "pool", {})
	seed_shop_pool.clear()
	if pool_data is Dictionary:
		for key in pool_data:
			seed_shop_pool[int(key)] = int(pool_data[key])
	seed_shop_timestamp = config.get_value("seed_shop", "timestamp", 0.0)

	## Pending hare heist.
	last_heist_end = float(config.get_value("heist", "last_end", 0.0))
	var heist_data = config.get_value("heist", "pending", {})
	pending_heist.clear()
	if heist_data is Dictionary:
		for key in heist_data:
			var q := int(heist_data[key])
			if q > 0:
				pending_heist[int(key)] = q

	## Check if seed shop needs refresh
	_check_seed_shop_refresh()
