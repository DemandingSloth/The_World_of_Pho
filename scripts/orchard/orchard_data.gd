class_name OrchardData
extends Node

## Autoload: Orchard
## Manages orchard grid state, sapling inventory, tree growth, fruit harvesting, and stump decay.
## Saved to user://orchard_save.cfg

const SAVE_PATH := "user://orchard_save.cfg"

## Orchard size limits (same upgrade curve as garden)
const MIN_ROWS := 1
const MIN_COLS := 5
const MAX_ROWS := 16
const MAX_COLS := 16
const ROW_COST_BASE := 50000
const COL_COST_BASE := 35000
const EXPANSION_SCALE := 1.25

## Sapling shop pool — restocks every 3 hours like the seed shop
const SAPLING_SHOP_REFRESH_INTERVAL := 10800.0  ## 3 hours
const SAPLING_SHOP_POOL_MIN := 8
const SAPLING_SHOP_POOL_MAX := 16
var sapling_shop_pool: Dictionary = {}  ## TreeType (int) -> quantity available
var sapling_shop_timestamp: float = 0.0

## ── Tree Definitions ──────────────────────────────────────────
enum TreeType { PLUM, LEMON, APPLE, BANANA, COCONUT, WINTER_CONIFER }

const TREE_DEFS: Array[Dictionary] = [
	{
		"id": "plum",
		"name": "Plum Tree",
		"fruit_name": "Plum",
		"sapling_cost": 500_000,
		"fruit_sell_price": 500,
		"sprite_row": 0,
		"fruit_index": 0,
	},
	{
		"id": "lemon",
		"name": "Lemon Tree",
		"fruit_name": "Lemon",
		"sapling_cost": 625_000,
		"fruit_sell_price": 1000,
		"sprite_row": 1,
		"fruit_index": 1,
	},
	{
		"id": "apple",
		"name": "Apple Tree",
		"fruit_name": "Apple",
		"sapling_cost": 750_000,
		"fruit_sell_price": 1500,
		"sprite_row": 2,
		"fruit_index": 2,
	},
	{
		"id": "banana",
		"name": "Banana Tree",
		"fruit_name": "Banana",
		"sapling_cost": 875_000,
		"fruit_sell_price": 2000,
		"sprite_row": 3,
		"fruit_index": 3,
	},
	{
		"id": "coconut",
		"name": "Coconut Tree",
		"fruit_name": "Coconut",
		"sapling_cost": 1_000_000,
		"fruit_sell_price": 2500,
		"sprite_row": 4,
		"fruit_index": 4,
	},
	{
		## Seasonal: produces PRESENTS (not a normal fruit) and ONLY during the
		## real-world window Dec 15–31. Uses its own 4-frame sprite sheet
		## (winter_conifer_tree.png), not the shared orchard_trees sheet.
		"id": "christmas_conifer",
		"name": "Christmas Conifer",
		"fruit_name": "Present",
		"sapling_cost": 5_000_000,
		"fruit_sell_price": 500_000,
		"sprite_row": -1,          ## uses separate sheet (see get_tree_texture)
		"fruit_index": -1,         ## produces presents, not a fruit-sheet fruit
		"is_conifer": true,
	},
]

## The Christmas Conifer's own 4-frame sprite sheet (not orchard_trees.png).
const CONIFER_SHEET_PATH := "res://Assets/Plants/winter_conifer_tree.png"
## The 5 growth stages map onto the 4 conifer frames (stages 1 & 2 share frame 1).
const CONIFER_STAGE_FRAME: Array[int] = [0, 1, 1, 2, 3]

## Christmas Conifer producing window (real-world local date): Dec 15–31 inclusive.
const CONIFER_MONTH := 12
const CONIFER_START_DAY := 15
const CONIFER_END_DAY := 31

## True if the current real-world local date is inside the conifer window.
static func is_conifer_season() -> bool:
	var d := TrustedClock.local_datetime_dict()
	return int(d["month"]) == CONIFER_MONTH \
		and int(d["day"]) >= CONIFER_START_DAY and int(d["day"]) <= CONIFER_END_DAY

## Growth stage age thresholds (in seconds).
## Total available fruit = floor(age_in_days * stage_daily_rate) - harvested.
## Rates per stage are STAGE_DAILY_RATES = [0, 1, 3, 5, 10].
## Stage 1 (Sprout): 0 to 2 days   -> 0 fruit/day   (day 1  -> 0)
## Stage 2 (Sapling): 2 to 5 days  -> 1 fruit/day   (day 3  -> 3)
## Stage 3 (Young): 5 to 8 days    -> 3 fruit/day   (day 5  -> 15)
## Stage 4 (Mature): 8 to 16 days  -> 5 fruit/day   (day 8  -> 40)
## Stage 5 (Full): 16+ days        -> 10 fruit/day  (day 16 -> 160)
const STAGE_THRESHOLDS: Array[float] = [
	0.0,            ## Stage 1 (Sprout)
	172800.0,       ## Stage 2 (2 Days)
	432000.0,       ## Stage 3 (5 Days)
	691200.0,       ## Stage 4 (8 Days)
	1382400.0,      ## Stage 5 (16 Days)
]

const STAGE_DAILY_RATES: Array[int] = [0, 1, 3, 5, 10]

## Asset Paths
const TREES_SHEET_PATH := "res://Assets/Plants/orchard_trees.png"
const FRUIT_SHEET_PATH := "res://Assets/Plants/orchard_fruit.png"
const STUMP_PATH := "res://Assets/Plants/stump.png"

## Slicing definitions for orchard_trees.png (256x368)
## 5 tree rows (y bands) x 5 growth stages (x bands)
const TREE_ROW_BOUNDS: Array[Vector2] = [
	Vector2(0, 80),    ## Plum: y 0..80
	Vector2(80, 66),   ## Lemon: y 80..146
	Vector2(146, 66),  ## Apple: y 146..212
	Vector2(212, 78),  ## Banana: y 212..290
	Vector2(290, 78),  ## Coconut: y 290..368
]

const TREE_COL_BOUNDS: Array[Vector2] = [
	Vector2(0, 30),    ## Col 0: Sprout (width 30)
	Vector2(30, 38),   ## Col 1: Sapling (width 38)
	Vector2(68, 57),   ## Col 2: Young Tree (width 57)
	Vector2(125, 67),  ## Col 3: Mature Tree (width 67)
	Vector2(192, 64),  ## Col 4: Full Tree (width 64)
]

signal orchard_updated

## ── State ──────────────────────────────────────────────────────
var orchard_rows: int = MIN_ROWS
var orchard_cols: int = MIN_COLS

## Grid cells: 2D array [row][col] of Dictionary or null
## Planted tree cell: { "tree_type": int, "plant_time": float, "harvested_count": int }
## Stump cell: { "is_stump": true, "tree_type": int, "stump_start_time": float, "decay_end_time": float, "planted_days": float }
var grid: Array = []

## Sapling inventory: { TreeType (int) -> quantity (int) }
var saplings: Dictionary = {}

## Auto-select next sapling when current sapling runs out
var auto_select_next_sapling: bool = false

## Total lifetime trees planted (for achievement tracking)
var lifetime_trees_planted: int = 0
var lifetime_trees_planted_by_type: Dictionary = {}  ## TreeType (int) -> count (int)

## Texture cache
var _trees_sheet: Texture2D = null
var _fruit_sheet: Texture2D = null
var _stump_texture: Texture2D = null
var _tree_atlas_cache: Dictionary = {}   ## "row_col" -> AtlasTexture
var _fruit_atlas_cache: Dictionary = {}  ## index -> AtlasTexture


## ── Lifecycle ──────────────────────────────────────────────────

func _ready() -> void:
	_load_textures()
	load_data()
	## Periodic sapling shop refresh check
	var shop_timer := Timer.new()
	shop_timer.wait_time = 60.0
	shop_timer.autostart = true
	shop_timer.timeout.connect(_check_sapling_shop_refresh)
	add_child(shop_timer)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		save_data()


func _load_textures() -> void:
	_trees_sheet = load(TREES_SHEET_PATH)
	_fruit_sheet = load(FRUIT_SHEET_PATH)
	_stump_texture = load(STUMP_PATH)


## ── Public API: Textures ───────────────────────────────────────

func get_tree_texture(tree_type: int, stage: int) -> AtlasTexture:
	tree_type = clampi(tree_type, 0, TREE_DEFS.size() - 1)
	stage = clampi(stage, 0, 4)

	## Christmas Conifer uses its OWN 4-frame sheet, not orchard_trees.png.
	if bool(TREE_DEFS[tree_type].get("is_conifer", false)):
		return _get_conifer_texture(stage)

	if _trees_sheet == null:
		_load_textures()
	if _trees_sheet == null:
		return null

	var key := "%d_%d" % [tree_type, stage]
	if _tree_atlas_cache.has(key):
		return _tree_atlas_cache[key]

	var r_info: Vector2 = TREE_ROW_BOUNDS[tree_type]
	var c_info: Vector2 = TREE_COL_BOUNDS[stage]
	var atlas := AtlasTexture.new()
	atlas.atlas = _trees_sheet
	atlas.region = Rect2(c_info.x, r_info.x, c_info.y, r_info.y)
	_tree_atlas_cache[key] = atlas
	return atlas


## Conifer texture: its sheet has 4 equal-width frames laid out horizontally.
## The 5 growth stages map onto them via CONIFER_STAGE_FRAME (stages 1 & 2 share).
var _conifer_sheet: Texture2D = null
func _get_conifer_texture(stage: int) -> AtlasTexture:
	if _conifer_sheet == null:
		if not ResourceLoader.exists(CONIFER_SHEET_PATH):
			return null
		_conifer_sheet = load(CONIFER_SHEET_PATH)
	if _conifer_sheet == null:
		return null
	stage = clampi(stage, 0, CONIFER_STAGE_FRAME.size() - 1)
	var frame := CONIFER_STAGE_FRAME[stage]
	var key := "conifer_%d" % frame
	if _tree_atlas_cache.has(key):
		return _tree_atlas_cache[key]
	var frame_w := float(_conifer_sheet.get_width()) / 4.0
	var atlas := AtlasTexture.new()
	atlas.atlas = _conifer_sheet
	atlas.region = Rect2(frame * frame_w, 0, frame_w, _conifer_sheet.get_height())
	_tree_atlas_cache[key] = atlas
	return atlas


func get_fruit_texture(tree_type: int) -> AtlasTexture:
	if _fruit_sheet == null:
		_load_textures()
	if _fruit_sheet == null:
		return null
	
	tree_type = clampi(tree_type, 0, TREE_DEFS.size() - 1)
	if _fruit_atlas_cache.has(tree_type):
		return _fruit_atlas_cache[tree_type]
	
	var fruit_w := 14.0
	var fruit_h := 18.0
	var atlas := AtlasTexture.new()
	atlas.atlas = _fruit_sheet
	atlas.region = Rect2(tree_type * fruit_w, 0, fruit_w, fruit_h)
	_fruit_atlas_cache[tree_type] = atlas
	return atlas


func get_stump_texture() -> Texture2D:
	if _stump_texture == null:
		_stump_texture = load(STUMP_PATH)
	return _stump_texture


## ── Public API: Tree Metadata ──────────────────────────────────

func get_tree_def(tree_type: int) -> Dictionary:
	if tree_type >= 0 and tree_type < TREE_DEFS.size():
		return TREE_DEFS[tree_type]
	return {}


func get_sapling_count(tree_type: int) -> int:
	return saplings.get(tree_type, 0)


func add_saplings(tree_type: int, qty: int, emit_update: bool = true) -> void:
	saplings[tree_type] = saplings.get(tree_type, 0) + qty
	save_data()
	if emit_update:
		orchard_updated.emit()


## Removes `qty` saplings with NO coins/XP payout (used by the online market
## escrow when a listing is created). Clamps to owned, erases the entry at zero.
## Returns the number actually removed.
func remove_saplings(tree_type: int, qty: int) -> int:
	var owned := get_sapling_count(tree_type)
	if owned <= 0 or qty <= 0:
		return 0
	qty = clampi(qty, 1, owned)
	saplings[tree_type] = owned - qty
	if saplings[tree_type] <= 0:
		saplings.erase(tree_type)
	save_data()
	orchard_updated.emit()
	return qty


## Per-sapling sell value: half its buy price (sapling_cost), rounded down.
func get_sapling_sell_value(tree_type: int) -> int:
	var def := get_tree_def(tree_type)
	if def.is_empty():
		return 0
	return int(def.get("sapling_cost", 0)) / 2


## Sells `qty` saplings back to the shop at half their buy price. Removes them
## from inventory, credits coins, and awards XP. Returns the number sold.
func sell_sapling(tree_type: int, qty: int = 1) -> int:
	var owned := get_sapling_count(tree_type)
	if owned <= 0 or qty <= 0:
		return 0
	qty = clampi(qty, 1, owned)
	var unit := get_sapling_sell_value(tree_type)
	saplings[tree_type] = owned - qty
	if saplings[tree_type] <= 0:
		saplings.erase(tree_type)
	## Return sold saplings to the sapling shop pool.
	sapling_shop_pool[tree_type] = mini(sapling_shop_pool.get(tree_type, 0) + qty, 1000)
	var total_revenue := unit * qty
	PlayerData.coins += total_revenue
	## award_xp handles save + level-up + data_changed on PlayerData.
	PlayerData.award_xp(total_revenue / 2)
	save_data()
	orchard_updated.emit()
	return qty


func set_auto_select_next_sapling(enabled: bool) -> void:
	if auto_select_next_sapling != enabled:
		auto_select_next_sapling = enabled
		save_data()


func get_total_saplings() -> int:
	var total := 0
	for qty in saplings.values():
		total += qty
	return total


## Advances orchard time-based systems by `hours` (called by the Workshop
## hourglass). Shifts tree plant_time and stump decay timers back so growth /
## decay progress as if that much time passed, and re-bases the sapling-shop
## restock timer so the hourglass actually restocks the marketplace's sapling
## stock when the timer crosses zero.
func advance_time_hours(hours: float) -> void:
	var seconds := hours * 3600.0
	var changed := false
	for r in range(orchard_rows):
		for c in range(orchard_cols):
			var cell = grid[r][c]
			if not (cell is Dictionary):
				continue
			if cell.get("is_stump", false):
				## Stumps store absolute timestamps — shift both back so the
				## remaining decay window shrinks by the skipped time.
				if cell.has("stump_start_time"):
					cell["stump_start_time"] = float(cell["stump_start_time"]) - seconds
				if cell.has("decay_end_time"):
					cell["decay_end_time"] = float(cell["decay_end_time"]) - seconds
				changed = true
			elif cell.has("plant_time"):
				cell["plant_time"] = float(cell["plant_time"]) - seconds
				changed = true
	## Re-base the sapling-shop restock timer too.
	if sapling_shop_timestamp > 0.0:
		sapling_shop_timestamp -= seconds
	if changed:
		save_data()
		orchard_updated.emit()
	## Apply skipped time to the shop pool now (restocks + saves/emits).
	_check_sapling_shop_refresh()
	## Clear any stumps whose (shifted) decay window has now elapsed.
	clean_expired_stumps()


## ── Sapling Shop Pool ──────────────────────────────────────────

func _check_sapling_shop_refresh() -> void:
	var now := TrustedClock.now()
	if sapling_shop_pool.is_empty():
		_generate_sapling_shop_pool()
		save_data()
		orchard_updated.emit()
		return
	var elapsed := now - sapling_shop_timestamp
	if elapsed < SAPLING_SHOP_REFRESH_INTERVAL:
		return
	var cycles := int(elapsed / SAPLING_SHOP_REFRESH_INTERVAL)
	for i in range(cycles):
		_generate_sapling_shop_pool()
	sapling_shop_timestamp += cycles * SAPLING_SHOP_REFRESH_INTERVAL
	save_data()
	orchard_updated.emit()


func _generate_sapling_shop_pool() -> void:
	if sapling_shop_timestamp <= 0.0:
		sapling_shop_timestamp = TrustedClock.now()

	## Weights: cheaper saplings more common, more expensive == more rare
	## Plum (500k): 36, Lemon (625k): 26, Apple (750k): 18, Banana (875k): 13, Coconut (1000k): 7
	## One weight per TreeType index; cheaper trees more common. The Christmas
	## Conifer (last) is rare.
	var weights: Array[int] = [36, 26, 18, 13, 7, 4]
	var total_weight: int = 0
	for w in weights:
		total_weight += w

	var pool_size: int = randi_range(SAPLING_SHOP_POOL_MIN, SAPLING_SHOP_POOL_MAX)
	for i in range(pool_size):
		var roll := randi() % total_weight
		var cumulative := 0
		for tree_idx in range(weights.size()):
			cumulative += weights[tree_idx]
			if roll < cumulative:
				sapling_shop_pool[tree_idx] = mini(sapling_shop_pool.get(tree_idx, 0) + 1, 100)
				break


func get_sapling_shop_stock(tree_type: int) -> int:
	return sapling_shop_pool.get(tree_type, 0)


func consume_sapling_shop_stock(tree_type: int, qty: int = 1) -> bool:
	var available: int = sapling_shop_pool.get(tree_type, 0)
	if available < qty:
		return false
	sapling_shop_pool[tree_type] = available - qty
	return true


func get_sapling_shop_refresh_remaining() -> float:
	var now := TrustedClock.now()
	var elapsed := now - sapling_shop_timestamp
	return maxf(0.0, SAPLING_SHOP_REFRESH_INTERVAL - elapsed)


## ── Public API: Expansions ─────────────────────────────────────

func get_row_cost() -> int:
	var purchases_made := orchard_rows - MIN_ROWS
	return int(ROW_COST_BASE * pow(EXPANSION_SCALE, purchases_made))


func get_col_cost() -> int:
	var purchases_made := orchard_cols - MIN_COLS
	return int(COL_COST_BASE * pow(EXPANSION_SCALE, purchases_made))


func can_buy_row() -> bool:
	return orchard_rows < MAX_ROWS and PlayerData.coins >= get_row_cost()


func can_buy_col() -> bool:
	return orchard_cols < MAX_COLS and PlayerData.coins >= get_col_cost()


func buy_row() -> bool:
	var cost := get_row_cost()
	if orchard_rows >= MAX_ROWS or PlayerData.coins < cost:
		return false
	PlayerData.coins -= cost
	orchard_rows += 1
	_expand_grid()
	PlayerData.save_data()
	PlayerData.data_changed.emit()
	save_data()
	orchard_updated.emit()
	return true


func buy_col() -> bool:
	var cost := get_col_cost()
	if orchard_cols >= MAX_COLS or PlayerData.coins < cost:
		return false
	PlayerData.coins -= cost
	orchard_cols += 1
	_expand_grid()
	PlayerData.save_data()
	PlayerData.data_changed.emit()
	save_data()
	orchard_updated.emit()
	return true


## ── Growth & Fruit Calculations ────────────────────────────────

## Check decay status of stumps; clears decayed stumps to empty soil.
func clean_expired_stumps() -> void:
	var now := TrustedClock.now()
	var changed := false
	for r in range(orchard_rows):
		for c in range(orchard_cols):
			var cell = grid[r][c]
			if cell is Dictionary and cell.get("is_stump", false):
				if now >= float(cell.get("decay_end_time", 0.0)):
					grid[r][c] = null
					changed = true
	if changed:
		save_data()
		orchard_updated.emit()


## Returns growth stage (0 Sprout, 1 Sapling, 2 Young, 3 Mature, 4 Full). Returns -1 if empty or stump.
func get_growth_stage(row: int, col: int) -> int:
	if row < 0 or row >= orchard_rows or col < 0 or col >= orchard_cols:
		return -1
	var cell = grid[row][col]
	if not (cell is Dictionary) or cell.get("is_stump", false):
		return -1
	
	var elapsed: float = _effective_elapsed(cell)
	var stage := 0
	for s in range(STAGE_THRESHOLDS.size() - 1, -1, -1):
		if elapsed >= STAGE_THRESHOLDS[s]:
			stage = s
			break
	return stage


## Returns tree age in days as float
func get_tree_age_days(row: int, col: int) -> float:
	if row < 0 or row >= orchard_rows or col < 0 or col >= orchard_cols:
		return 0.0
	var cell = grid[row][col]
	if not (cell is Dictionary) or cell.get("is_stump", false):
		return 0.0
	var elapsed: float = _effective_elapsed(cell)
	return maxf(0.0, elapsed / 86400.0)


## Real elapsed growth time for a planted cell, scaled by the Carpenter's Shop
## bonus (Business District) so trees grow / fruit faster. Neutral (×1) when the
## shop is inactive. LOCAL only.
func _effective_elapsed(cell) -> float:
	var elapsed: float = TrustedClock.now() - float(cell.get("plant_time", 0.0))
	if get_node_or_null("/root/BusinessDistrict") != null:
		var mult := BusinessDistrict.orchard_growth_multiplier()  ## <=1 means faster
		if mult > 0.0:
			elapsed = elapsed / mult
	return elapsed


## Returns daily fruit production rate for a given stage
func get_stage_daily_rate(stage: int) -> int:
	if stage >= 0 and stage < STAGE_DAILY_RATES.size():
		return STAGE_DAILY_RATES[stage]
	return 0


## Returns total unharvested fruit available on this tree
func get_available_fruit(row: int, col: int) -> int:
	if row < 0 or row >= orchard_rows or col < 0 or col >= orchard_cols:
		return 0
	var cell = grid[row][col]
	if not (cell is Dictionary) or cell.get("is_stump", false):
		return 0
	
	var stage := get_growth_stage(row, col)
	if stage <= 0:
		return 0  ## Stage 1 produces nothing

	var rate := get_stage_daily_rate(stage)
	var harvested: int = cell.get("harvested_count", 0)

	## Christmas Conifer: presents ONLY accrue during the Dec 15–31 window, so
	## its production is based on the number of IN-WINDOW days the tree has lived
	## through, not its total age. Outside the window nothing new accrues (but
	## already-accrued, unharvested presents remain claimable).
	var tree_type: int = int(cell.get("tree_type", 0))
	var def := get_tree_def(tree_type)
	if bool(def.get("is_conifer", false)):
		var plant_time: float = float(cell.get("plant_time", 0.0))
		var in_window_days := _conifer_window_days(plant_time, TrustedClock.now())
		var produced := int(in_window_days * rate)
		return maxi(0, produced - harvested)

	var days := get_tree_age_days(row, col)
	var total_produced := int(days * rate)
	return maxi(0, total_produced - harvested)


## Number of days between `from_unix` and `to_unix` that fall inside a Christmas
## Conifer producing window (Dec 15–31, local time), summed across any years the
## interval spans. Used so conifer presents accrue only during the window.
func _conifer_window_days(from_unix: float, to_unix: float) -> float:
	if to_unix <= from_unix:
		return 0.0
	## Iterate each year the interval touches and add the overlap with that
	## year's Dec 15 00:00 .. Jan 1 00:00 window.
	var total_seconds := 0.0
	var from_year := int(Time.get_datetime_dict_from_unix_time(int(from_unix))["year"])
	var to_year := int(Time.get_datetime_dict_from_unix_time(int(to_unix))["year"])
	for year in range(from_year, to_year + 1):
		var win_start := Time.get_unix_time_from_datetime_dict({
			"year": year, "month": CONIFER_MONTH, "day": CONIFER_START_DAY,
			"hour": 0, "minute": 0, "second": 0})
		## End is the start of Jan 1 next year (Dec 31 inclusive).
		var win_end := Time.get_unix_time_from_datetime_dict({
			"year": year + 1, "month": 1, "day": 1,
			"hour": 0, "minute": 0, "second": 0})
		var overlap_start := maxf(from_unix, float(win_start))
		var overlap_end := minf(to_unix, float(win_end))
		if overlap_end > overlap_start:
			total_seconds += (overlap_end - overlap_start)
	return total_seconds / 86400.0


## ── Planting & Harvesting ──────────────────────────────────────

func plant_sapling(row: int, col: int, tree_type: int, defer: bool = false) -> bool:
	if row < 0 or row >= orchard_rows or col < 0 or col >= orchard_cols:
		return false
	if grid[row][col] != null:
		return false  ## Cell occupied
	if get_sapling_count(tree_type) <= 0:
		return false
	
	saplings[tree_type] = saplings.get(tree_type, 0) - 1
	grid[row][col] = {
		"tree_type": tree_type,
		"plant_time": TrustedClock.now(),
		"harvested_count": 0,
	}
	lifetime_trees_planted += 1
	lifetime_trees_planted_by_type[tree_type] = lifetime_trees_planted_by_type.get(tree_type, 0) + 1

	## Per-tree achievement counter still fires (cheap). The heavy parts (disk
	## save, full-grid "orchard full" scan, and the signal) are deferred so bulk
	## auto-plant doesn't freeze; the caller runs plant_sapling_flush() once.
	if get_node_or_null("/root/Achievements") != null:
		Achievements.record_orchard_tree_planted(tree_type)

	if defer:
		return true

	save_data()
	if get_node_or_null("/root/Achievements") != null:
		if orchard_rows >= MAX_ROWS and orchard_cols >= MAX_COLS:
			_check_full_orchard_achievements()

	orchard_updated.emit()
	return true


## Persists and signals once after a batch of deferred plant_sapling() calls
## (bulk auto-plant), running the full-orchard achievement scan a single time.
func plant_sapling_flush() -> void:
	save_data()
	if get_node_or_null("/root/Achievements") != null:
		if orchard_rows >= MAX_ROWS and orchard_cols >= MAX_COLS:
			_check_full_orchard_achievements()
	orchard_updated.emit()


func _check_full_orchard_achievements() -> void:
	var all_filled := true
	var first_type: int = -1
	var all_same_type := true
	for r in range(orchard_rows):
		for c in range(orchard_cols):
			var cell = grid[r][c]
			if cell == null or not (cell is Dictionary) or cell.get("is_stump", false):
				all_filled = false
				all_same_type = false
				break
			var cell_type: int = cell.get("tree_type", -1)
			if first_type == -1:
				first_type = cell_type
			elif cell_type != first_type:
				all_same_type = false
		if not all_filled:
			break
	if all_filled:
		Achievements.record_orchard_full()
		if all_same_type and first_type >= 0:
			Achievements.record_orchard_full_single_tree(first_type)


func is_harvestable(row: int, col: int) -> bool:
	return get_available_fruit(row, col) > 0


func has_harvestable_fruit() -> bool:
	for r in range(orchard_rows):
		for c in range(orchard_cols):
			if get_available_fruit(r, c) > 0:
				return true
	return false


## Harvests fruit from a tree cell. Adds fruit to PlayerData inventory.
## Saves + emits immediately (single-cell tap). For bulk harvests use the
## silent/row variants below, which defer the disk writes and signal.
func harvest_tree(row: int, col: int) -> Dictionary:
	var res := _harvest_tree_silent(row, col)
	if res["count"] > 0:
		PlayerData.flush_bulk_adds()
		save_data()
		orchard_updated.emit()
	return res


## Core harvest for one cell WITHOUT saving or emitting, and deferring the
## PlayerData inventory writes (caller must call PlayerData.flush_bulk_adds()).
## Lets bulk/row harvests avoid hundreds of disk writes + signal storms.
func _harvest_tree_silent(row: int, col: int) -> Dictionary:
	var available := get_available_fruit(row, col)
	if available <= 0:
		return {"fruit_type": -1, "count": 0, "name": ""}

	var cell = grid[row][col]
	var tree_type: int = cell.get("tree_type", 0)
	var def := get_tree_def(tree_type)
	var fruit_id: String = def.get("id", "plum")
	var fruit_name: String = def.get("fruit_name", "Fruit")

	cell["harvested_count"] = cell.get("harvested_count", 0) + available

	if bool(def.get("is_conifer", false)):
		## The Christmas Conifer yields PRESENTS (the save's assigned variant),
		## not a normal fruit. This is the ONLY source of presents.
		PlayerData.add_present(available, true)
	else:
		PlayerData.add_fruit(fruit_id, available, true)
		## Mission progress: "harvest N <fruit> from the Orchard".
		if get_node_or_null("/root/MissionBoard") != null:
			MissionBoard.on_fruit_harvested(fruit_id, available)

	## Harvesting also yields wood: 10 per full day the tree has been planted.
	## Granted once per harvest based on the tree's current age (not per fruit).
	var wood := int(floor(get_tree_age_days(row, col))) * 10
	if wood > 0 and PlayerData.has_method("add_item"):
		PlayerData.add_item("wood", wood, true)

	return {"fruit_type": tree_type, "count": available, "name": fruit_name, "fruit_id": fruit_id, "wood": wood}


## Harvests every ready tree in ONE row. Defers PlayerData writes and flushes
## them once, saves the orchard once, and emits orchard_updated once — so the UI
## can drive a responsive per-row "Harvest All" (harvest a row, refresh it,
## await a frame, repeat) without a per-cell freeze. Returns the same shape as
## harvest_all: {"totals": {fruit_id -> count}, "total_count": int}.
func harvest_row(row: int) -> Dictionary:
	var total_collected: Dictionary = {}
	var total_fruit_count := 0
	if row < 0 or row >= orchard_rows:
		return {"totals": total_collected, "total_count": 0}
	for c in range(orchard_cols):
		var res := _harvest_tree_silent(row, c)
		if res["count"] > 0:
			var fid: String = res["fruit_id"]
			total_collected[fid] = total_collected.get(fid, 0) + res["count"]
			total_fruit_count += res["count"]
	if total_fruit_count > 0:
		PlayerData.flush_bulk_adds()
		save_data()
		orchard_updated.emit()
	return {"totals": total_collected, "total_count": total_fruit_count}


## Harvests all harvest-ready trees across the whole orchard in one shot.
## Kept for callers that want a synchronous whole-orchard harvest; the UI now
## prefers driving harvest_row() per row for responsiveness. Defers PlayerData
## writes and saves/emits only once.
func harvest_all() -> Dictionary:
	var total_collected: Dictionary = {}  ## fruit_id -> count
	var total_fruit_count := 0

	for r in range(orchard_rows):
		for c in range(orchard_cols):
			var res := _harvest_tree_silent(r, c)
			if res["count"] > 0:
				var fid: String = res["fruit_id"]
				total_collected[fid] = total_collected.get(fid, 0) + res["count"]
				total_fruit_count += res["count"]

	if total_fruit_count > 0:
		PlayerData.flush_bulk_adds()
		save_data()
		orchard_updated.emit()

	return {"totals": total_collected, "total_count": total_fruit_count}


## True if a tree was planted or harvested "in the future" — i.e. its harvested
## fruit is more than it could have produced by now, or its plant time is ahead
## of the trusted clock. That only happens when the phone's clock was moved
## forward. Such a tree can't be dug up (so it can't be replanted to repeat the
## trick); it simply produces nothing until real time catches up.
func is_tree_time_locked(row: int, col: int) -> bool:
	if row < 0 or row >= orchard_rows or col < 0 or col >= orchard_cols:
		return false
	var cell = grid[row][col]
	if not (cell is Dictionary) or cell.get("is_stump", false):
		return false
	var now := TrustedClock.now()
	if float(cell.get("plant_time", 0.0)) > now + 60.0:
		return true
	var harvested: int = int(cell.get("harvested_count", 0))
	if harvested <= 0:
		return false
	var stage := get_growth_stage(row, col)
	var rate := get_stage_daily_rate(stage)
	var def := get_tree_def(int(cell.get("tree_type", 0)))
	var produced := 0
	if bool(def.get("is_conifer", false)):
		produced = int(_conifer_window_days(float(cell.get("plant_time", 0.0)), now) * rate)
	else:
		produced = int(get_tree_age_days(row, col) * rate)
	return harvested > produced


## Removes a tree with shovel, leaving a decaying stump.
## Decay duration is 24 to 72 hours depending on how long the tree was planted.
func remove_tree(row: int, col: int) -> bool:
	if row < 0 or row >= orchard_rows or col < 0 or col >= orchard_cols:
		return false
	var cell = grid[row][col]
	if cell == null:
		return false
	
	if cell.get("is_stump", false):
		return false  ## Already a stump
	if is_tree_time_locked(row, col):
		return false  ## Harvested ahead of real time — can't be dug up yet

	var now := TrustedClock.now()
	var plant_time: float = cell.get("plant_time", now)
	var tree_type: int = cell.get("tree_type", 0)
	var days_planted: float = maxf(0.0, (now - plant_time) / 86400.0)
	
	## Scale stump duration between 24 and 72 hours (scaled over 20 days max)
	var decay_hours := clampf(24.0 + (days_planted / 20.0) * 48.0, 24.0, 72.0)
	var decay_seconds := decay_hours * 3600.0
	
	grid[row][col] = {
		"is_stump": true,
		"tree_type": tree_type,
		"stump_start_time": now,
		"decay_end_time": now + decay_seconds,
		"planted_days": days_planted,
	}
	## Mission progress: "chop down N trees in the Orchard" (rare CHOP mission).
	if get_node_or_null("/root/MissionBoard") != null:
		MissionBoard.on_tree_chopped(1)
	save_data()
	orchard_updated.emit()
	return true


## ── Grid Helpers ───────────────────────────────────────────────

func _init_grid() -> void:
	grid.clear()
	for r in range(orchard_rows):
		var row_data: Array = []
		for c in range(orchard_cols):
			row_data.append(null)
		grid.append(row_data)


func _expand_grid() -> void:
	while grid.size() < orchard_rows:
		var row_data: Array = []
		for c in range(orchard_cols):
			row_data.append(null)
		grid.append(row_data)
	for r in range(grid.size()):
		while grid[r].size() < orchard_cols:
			grid[r].append(null)


## ── Persistence ────────────────────────────────────────────────

func save_data() -> void:
	var config := ConfigFile.new()
	config.set_value("orchard", "rows", orchard_rows)
	config.set_value("orchard", "cols", orchard_cols)
	config.set_value("orchard", "lifetime_trees_planted", lifetime_trees_planted)
	
	var type_data: Dictionary = {}
	for k in lifetime_trees_planted_by_type:
		type_data[int(k)] = lifetime_trees_planted_by_type[k]
	config.set_value("orchard", "lifetime_trees_planted_by_type", type_data)
	
	## Grid
	var grid_data: Array = []
	for r in range(orchard_rows):
		var row_data: Array = []
		for c in range(orchard_cols):
			row_data.append(grid[r][c])
		grid_data.append(row_data)
	config.set_value("orchard", "grid", grid_data)
	
	## Saplings
	var sapling_data: Dictionary = {}
	for key in saplings:
		sapling_data[int(key)] = saplings[key]
	config.set_value("orchard", "saplings", sapling_data)
	
	config.set_value("orchard", "auto_select_next_sapling", auto_select_next_sapling)
	
	## Serialize sapling shop pool
	var pool_data: Dictionary = {}
	for key in sapling_shop_pool:
		pool_data[int(key)] = sapling_shop_pool[key]
	config.set_value("sapling_shop", "pool", pool_data)
	config.set_value("sapling_shop", "timestamp", sapling_shop_timestamp)

	config.save(SAVE_PATH)


func load_data() -> void:
	var config := ConfigFile.new()
	var err := config.load(SAVE_PATH)
	if err != OK:
		_init_grid()
		_generate_sapling_shop_pool()
		return
	
	orchard_rows = config.get_value("orchard", "rows", MIN_ROWS)
	orchard_cols = config.get_value("orchard", "cols", MIN_COLS)
	lifetime_trees_planted = config.get_value("orchard", "lifetime_trees_planted", 0)
	
	var type_data = config.get_value("orchard", "lifetime_trees_planted_by_type", {})
	lifetime_trees_planted_by_type.clear()
	if type_data is Dictionary:
		for k in type_data:
			lifetime_trees_planted_by_type[int(k)] = int(type_data[k])

	var grid_data = config.get_value("orchard", "grid", [])
	grid.clear()
	if grid_data is Array and grid_data.size() > 0:
		for r in range(mini(grid_data.size(), orchard_rows)):
			var row_data: Array = []
			if grid_data[r] is Array:
				for c in range(mini(grid_data[r].size(), orchard_cols)):
					row_data.append(grid_data[r][c])
			while row_data.size() < orchard_cols:
				row_data.append(null)
			grid.append(row_data)
	while grid.size() < orchard_rows:
		var row_data: Array = []
		for c in range(orchard_cols):
			row_data.append(null)
		grid.append(row_data)
	
	if lifetime_trees_planted == 0 and lifetime_trees_planted_by_type.is_empty():
		var current_trees := 0
		for r in range(orchard_rows):
			for c in range(orchard_cols):
				var cell = grid[r][c]
				if cell is Dictionary and not cell.get("is_stump", false):
					current_trees += 1
					var tt: int = cell.get("tree_type", 0)
					lifetime_trees_planted_by_type[tt] = lifetime_trees_planted_by_type.get(tt, 0) + 1
		lifetime_trees_planted = current_trees

	var sapling_data = config.get_value("orchard", "saplings", {})
	saplings.clear()
	if sapling_data is Dictionary:
		for key in sapling_data:
			saplings[int(key)] = int(sapling_data[key])
	
	auto_select_next_sapling = config.get_value("orchard", "auto_select_next_sapling", false)
	
	## Load sapling shop pool
	var pool_data = config.get_value("sapling_shop", "pool", {})
	sapling_shop_pool.clear()
	if pool_data is Dictionary:
		for key in pool_data:
			sapling_shop_pool[int(key)] = int(pool_data[key])
	sapling_shop_timestamp = config.get_value("sapling_shop", "timestamp", 0.0)

	## Check if sapling shop needs refresh
	_check_sapling_shop_refresh()

	clean_expired_stumps()
