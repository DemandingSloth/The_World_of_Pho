class_name DeepMineData
extends Node

## Autoload: DeepMine
## A grid-dig minigame unlocked at level 20. Clicking a tile consumes a shovel
## and digs it, with a 30% chance to drop a gem. Rarer gems appear the deeper
## (higher layer index) you dig; the bottom layer yields diamonds and has a
## 1-in-25,000 chance to drop a Diamond Ring.
##
## The dig area is a rows x cols grid (starts 1x5, upgradable to 16x16 like the
## garden). "Layers" stack that grid into depth: you start with 1 layer and gain
## +1 per level of the "mine_layers" prestige (cap 10 -> 11 total layers).
## Tapping a tile digs the topmost undug layer at that position; the multi-layer
## prestige digs several layers deep per action. The whole mine regenerates once
## every tile on every layer has been dug.
##
## Saved to user://deep_mine_save.cfg

const SAVE_PATH := "user://deep_mine_save.cfg"

## Unlock requirement.
const UNLOCK_LEVEL := 20

## Grid size limits (same curve as garden, higher base cost).
const MIN_ROWS := 1
const MIN_COLS := 5
const MAX_ROWS := 16
const MAX_COLS := 16
const ROW_COST_BASE := 500_000
const COL_COST_BASE := 500_000
const EXPANSION_SCALE := 1.25  ## Each purchase costs 25% more than the last

## Layers: 1 base + mine_layers prestige (cap 10) -> up to 11.
const BASE_LAYERS := 1
const MAX_LAYERS := 11

## Dig outcome tuning.
const GEM_DROP_CHANCE := 0.40             ## Shovel: 40% chance a dug layer yields a gem
## Excavator digs faster but is rougher: it reveals gems at a lower rate than a
## shovel (some treasures a careful dig would have found are destroyed).
const EXCAVATOR_GEM_DROP_CHANCE := 0.20   ## Excavator: 20% (rougher than the shovel's 40%)
const DIAMOND_RING_DROP_CHANCE := 25_000  ## 1 in 25,000 on the deepest layer

## Excavator: one-time purchase, digs a full row without consuming shovels.
const EXCAVATOR_COST := 5_000_000

## Gems in rarity order (common -> rare), mirroring PROSPECTOR_GEM_ORDER.
## Index 0 is the most common (shallow), last is diamond (deepest).
const GEM_ORDER: Array[String] = [
	"gold", "blue_stone", "pink_stone", "violet_stone",
	"black_pearl", "emerald", "ruby", "diamond",
]

## ── Ores ───────────────────────────────────────────────────────
## Ores drop only in the bottom 5 layers (indices MAX_LAYERS-5 .. MAX_LAYERS-1).
## When a layer rolls a treasure, there's a chance (rising with depth) it's an
## ore instead of a gem. The pricier ore (copper) favors the deepest layers.
const ORE_MIN_LAYER := MAX_LAYERS - 5     ## First (shallowest) layer ores can appear on.

## Base chance that a treasure on an ore-eligible layer is an ore rather than a
## gem, at the shallowest ore layer. Scales up toward the bottom (see _roll_ore).
const ORE_TREASURE_CHANCE_BASE := 0.35
const ORE_TREASURE_CHANCE_BOTTOM := 0.85  ## Chance on the very deepest layer.

## Cheaper -> pricier. Copper (pricier) is weighted toward deeper layers.
const ORE_ORDER: Array[String] = ["iron_ore", "copper_ore"]

signal deep_mine_updated

## ── State ──────────────────────────────────────────────────────
var mine_rows: int = MIN_ROWS
var mine_cols: int = MIN_COLS

## Whether the player owns the Excavator (one-time unlock).
var excavator_owned: bool = false

## Dig state: dug[layer] is a 2D array [row][col] of bool (true = dug).
## Layer 0 is the shallowest (top), higher indices are deeper.
var dug: Array = []

## Pending gems awaiting pickup at each position, from a shovel dig that unearthed
## them. found_gem[row][col] is a Dictionary { gem_type: count } while gems are
## unearthed-but-not-collected, or {} if nothing is pending. A second tap on the
## tile collects them (no shovel) and advances the tile. Excavator auto-collects.
var found_gem: Array = []

## Texture cache
var _tile_textures: Array = []      ## depth index -> Texture2D
var _excavator_texture: Texture2D = null
var _gem_textures: Dictionary = {}  ## gem_type -> Texture2D


## ── Lifecycle ──────────────────────────────────────────────────

func _ready() -> void:
	load_data()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		save_data()


## ── Unlock ─────────────────────────────────────────────────────

func is_unlocked() -> bool:
	return PlayerData.level >= UNLOCK_LEVEL


## ── Layers ─────────────────────────────────────────────────────

## Total active layers = base + mine_layers prestige level, capped.
func get_layer_count() -> int:
	return clampi(BASE_LAYERS + PlayerData.get_prestige_level("mine_layers"), BASE_LAYERS, MAX_LAYERS)

## How many treasures a single dig will find (drilling past empty layers) before
## it stops. Level 0 -> stops at the first treasure; +1 per mine_multi_layer level.
func get_dig_depth_per_action() -> int:
	return 1 + PlayerData.get_prestige_level("mine_multi_layer")

## Rows the excavator clears per use = 1 + excavator_rows prestige level.
func get_excavator_rows() -> int:
	return 1 + PlayerData.get_prestige_level("excavator_rows")


## ── Textures ───────────────────────────────────────────────────

func _load_textures() -> void:
	if not _tile_textures.is_empty():
		return
	## deep_mine_1.png (shallowest) .. deep_mine_11.png (deepest).
	for i in range(MAX_LAYERS):
		var tex: Texture2D = load("res://Assets/Deep_mine/deep_mine_%d.png" % (i + 1))
		_tile_textures.append(tex)
	_excavator_texture = load("res://Assets/Deep_mine/excavator.png")

## Texture for a given depth (layer index), clamped to the available range.
func get_tile_texture(depth: int) -> Texture2D:
	_load_textures()
	var idx := clampi(depth, 0, _tile_textures.size() - 1)
	return _tile_textures[idx] if idx < _tile_textures.size() else null

func get_excavator_texture() -> Texture2D:
	_load_textures()
	return _excavator_texture

## Sprite for a pending treasure. Ores use the ores sheet (OreSprites); gems use
## the Gold Panning gemstone assets. Cached.
func get_gem_texture(gem_type: String) -> Texture2D:
	if _gem_textures.has(gem_type):
		return _gem_textures[gem_type]
	var tex: Texture2D
	if ORE_ORDER.has(gem_type):
		tex = OreSprites.get_item_texture(gem_type)
	else:
		tex = load("res://Assets/GoldPanning/Gemstones/%s.png" % gem_type)
	_gem_textures[gem_type] = tex
	return tex

## The pending gems dict at a position (awaiting pickup), or {} if none.
func get_pending_gems(row: int, col: int) -> Dictionary:
	if row < 0 or row >= found_gem.size():
		return {}
	if col < 0 or col >= found_gem[row].size():
		return {}
	var v = found_gem[row][col]
	return v if v is Dictionary else {}

## True if a gem is unearthed at (row, col) and awaiting a pickup tap.
func has_pending_gem(row: int, col: int) -> bool:
	return not get_pending_gems(row, col).is_empty()

## The single gem type to display on a tile with pending gems (the rarest found),
## or "" if none. Used for the tile sprite.
func get_display_gem(row: int, col: int) -> String:
	var gems := get_pending_gems(row, col)
	if gems.is_empty():
		return ""
	## Prefer the rarest gem (highest index in GEM_ORDER) for the sprite.
	var best := ""
	var best_rank := -999
	for gem_type in gems:
		## Ores rank above the gem scale so a lone ore still displays; among
		## gems, higher GEM_ORDER index = rarer.
		var rank := 0
		if ORE_ORDER.has(gem_type):
			rank = GEM_ORDER.size() + ORE_ORDER.find(gem_type)
		else:
			rank = GEM_ORDER.find(gem_type)
		if rank > best_rank:
			best_rank = rank
			best = gem_type
	return best

func _set_found_gem(row: int, col: int, gems: Dictionary) -> void:
	if row < 0 or row >= found_gem.size():
		return
	if col < 0 or col >= found_gem[row].size():
		return
	found_gem[row][col] = gems


## ── Depth / dig queries ────────────────────────────────────────

## Returns the shallowest undug layer index at (row, col), or -1 if the whole
## column has been dug through all active layers.
func get_current_depth(row: int, col: int) -> int:
	if row < 0 or row >= mine_rows or col < 0 or col >= mine_cols:
		return -1
	var layers := get_layer_count()
	for layer in range(layers):
		if not _is_dug(layer, row, col):
			return layer
	return -1

## True if (row, col) still has an undiggable... i.e. has any undug layer.
func is_diggable(row: int, col: int) -> bool:
	return get_current_depth(row, col) >= 0

## True once every tile on every active layer has been dug AND no gems remain
## awaiting pickup (so the mine doesn't regenerate out from under a pending gem).
func is_fully_excavated() -> bool:
	var layers := get_layer_count()
	for layer in range(layers):
		for r in range(mine_rows):
			for c in range(mine_cols):
				if not _is_dug(layer, r, c):
					return false
	## Any tile still holding an uncollected gem blocks regeneration.
	for r in range(mine_rows):
		for c in range(mine_cols):
			if has_pending_gem(r, c):
				return false
	return true


## ── Digging ────────────────────────────────────────────────────

## Digs one tile at (row, col): consumes a shovel, drills through
## get_dig_depth_per_action() layers at that position, and rolls drops per layer.
## Returns a result dict: { "dug": int, "gems": { gem_type: count }, "ring": bool }
## or { "dug": 0, ... } if it couldn't dig (no shovel / nothing left).
## Handles a tap on a tile. Two-step flow:
##  - If a gem is unearthed and awaiting pickup here, this tap COLLECTS it
##    (awards the gem, no shovel consumed) and clears the pending state.
##  - Otherwise it DIGS: consumes a shovel, drills the multi-layer depth, and if
##    a gem is unearthed it is held as pending (shown on the tile) to be picked
##    up on the next tap — it is NOT awarded yet.
## Returns { "action": "pickup"|"dig"|"none", "dug": int, "tiles": int,
##           "gems": {gem:count}, "ring": bool }.
func dig_tile(row: int, col: int) -> Dictionary:
	var empty := {"action": "none", "dug": 0, "tiles": 0, "gems": {}, "ring": false}
	## The layer count can grow when mine_layers prestige is bought on another
	## screen, so make sure the dug/found_gem grids include every active layer
	## before we dig (otherwise deeper layers can't be marked dug).
	_ensure_dimensions()

	## Step 2: collect a previously-unearthed gem (no shovel).
	if has_pending_gem(row, col):
		var gems := get_pending_gems(row, col)
		_set_found_gem(row, col, {})
		for gem_type in gems:
			_award_treasure(gem_type, int(gems[gem_type]))
		## Regenerate if that pickup revealed the mine is fully dug out.
		if is_fully_excavated():
			_reset_dug()
		save_data()
		deep_mine_updated.emit()
		return {"action": "pickup", "dug": 0, "tiles": 0, "gems": gems, "ring": false}

	## Step 1: dig.
	if not is_diggable(row, col):
		return empty
	if PlayerData.get_tool_count(PlayerData.ToolType.SHOVEL) <= 0:
		return empty
	if not PlayerData.consume_tool(PlayerData.ToolType.SHOVEL):
		return empty

	var result := _dig_column(row, col, get_dig_depth_per_action())
	result["action"] = "dig"
	## Hold any unearthed gems as pending pickup rather than awarding them now.
	var gems: Dictionary = result.get("gems", {})
	if not gems.is_empty():
		_set_found_gem(row, col, gems.duplicate())
	## Ring (bottom layer) is awarded immediately; only gems use the pickup step.
	if bool(result.get("ring", false)):
		PlayerData.add_diamond_ring()
	## Mission progress for tiles dug.
	var tiles := int(result.get("tiles", 0))
	if tiles > 0 and get_node_or_null("/root/MissionBoard") != null:
		MissionBoard.on_deep_mine_dug(tiles)
	## Only regenerate here if nothing is pending (otherwise wait for pickup).
	if get_pending_gems(row, col).is_empty() and is_fully_excavated():
		_reset_dug()
	save_data()
	deep_mine_updated.emit()
	return result

## Safety net: if the mine is fully dug out with nothing pending, regenerate it.
## Call on screen entry so a save that got stuck fully-excavated (e.g. an old
## excavator sweep that cleared the last tiles without triggering a reset)
## recovers to a fresh mine instead of showing an all-black, unresponsive grid.
## Returns true if it regenerated.
func regenerate_if_exhausted() -> bool:
	_ensure_dimensions()
	if is_fully_excavated():
		_reset_dug()
		save_data()
		deep_mine_updated.emit()
		return true
	return false


## True if a treasure id is a mined ore (goes to the item store, not gemstones).
func _is_ore(treasure_id: String) -> bool:
	return ORE_ORDER.has(treasure_id)

## Awards a collected treasure to the correct inventory: ores -> item store,
## everything else -> gemstones. Collecting treasure also grants XP equal to the
## raw sell value of each item (unpolished gem value for gems/gold, resource
## sell value for ores), rewarding digging the mine.
func _award_treasure(treasure_id: String, count: int) -> void:
	if count <= 0:
		return
	var xp := 0
	if _is_ore(treasure_id):
		PlayerData.add_item(treasure_id, count)
		## XP = raw sell value of each ore collected.
		xp = PlayerData.get_resource_sell_value(treasure_id) * count
	else:
		PlayerData.add_gemstones(treasure_id, count)
		## XP = unpolished sell value of each gem collected (gold included — it's
		## a gemstone). Prestige/perk-scaled via get_gem_value.
		xp = PlayerData.get_gem_value(treasure_id) * count
	## award_xp handles save + level-up + data_changed.
	if xp > 0:
		PlayerData.award_xp(xp)


## Whether the auto-collect prestige is unlocked.
func has_auto_collect() -> bool:
	return PlayerData.get_prestige_level("mine_auto_collect") > 0

## True if any tile has an uncollected treasure to harvest.
func has_any_pending() -> bool:
	for r in range(mine_rows):
		for c in range(mine_cols):
			if has_pending_gem(r, c):
				return true
	return false

## Harvests every pending treasure across the whole grid at once (no shovels).
## Returns { gem_type: count } collected. Requires the auto-collect prestige.
func collect_all() -> Dictionary:
	var collected: Dictionary = {}
	_ensure_dimensions()
	for r in range(mine_rows):
		for c in range(mine_cols):
			var pending := get_pending_gems(r, c)
			if pending.is_empty():
				continue
			for gem_type in pending:
				collected[gem_type] = int(collected.get(gem_type, 0)) + int(pending[gem_type])
			_set_found_gem(r, c, {})
	if collected.is_empty():
		return collected
	for gem_type in collected:
		_award_treasure(gem_type, int(collected[gem_type]))
	if is_fully_excavated():
		_reset_dug()
	save_data()
	deep_mine_updated.emit()
	return collected


## Excavator dig: clears full rows (no shovels). Starts at the given row and
## clears get_excavator_rows() consecutive rows that still have undug tiles.
## Returns the aggregated result dict.
func excavate_row(start_row: int) -> Dictionary:
	var result := {"dug": 0, "tiles": 0, "gems": {}, "ring": false}
	if not excavator_owned:
		return result
	_ensure_dimensions()
	var rows_to_clear := get_excavator_rows()
	var depth := get_dig_depth_per_action()
	var cleared := 0
	var r := start_row
	## Only excavate tiles that have no uncollected treasure sitting on them
	## (the player must harvest before digging beneath — same rule as the shovel).
	while cleared < rows_to_clear and r < mine_rows:
		var row_had_dig := false
		for c in range(mine_cols):
			if has_pending_gem(r, c):
				continue  ## already has a treasure to harvest here
			if is_diggable(r, c):
				## Excavator reveals gems at its lower rate (rougher digging).
				## Each column digs down until it hits a treasure and stops.
				var col_result := _dig_column(r, c, depth, EXCAVATOR_GEM_DROP_CHANCE)
				## Hold any found treasure as pending (harvested later), like the shovel.
				var col_gems: Dictionary = col_result.get("gems", {})
				if not col_gems.is_empty():
					var existing := get_pending_gems(r, c)
					for gt in col_gems:
						existing[gt] = int(existing.get(gt, 0)) + int(col_gems[gt])
					_set_found_gem(r, c, existing)
				## Ring is awarded immediately (not part of the harvest step).
				if bool(col_result.get("ring", false)):
					PlayerData.add_diamond_ring()
				## Mission progress per tile actually dug.
				result["dug"] += int(col_result.get("dug", 0))
				result["tiles"] += int(col_result.get("tiles", 0))
				if col_result["dug"] > 0:
					row_had_dig = true
		if row_had_dig:
			cleared += 1
		r += 1
	## Mission progress for tiles dug this sweep.
	if result["tiles"] > 0 and get_node_or_null("/root/MissionBoard") != null:
		MissionBoard.on_deep_mine_dug(int(result["tiles"]))
	## Regenerate the whole mine if this sweep dug out the last remaining layers
	## and left nothing pending. Without this, an excavator sweep that clears the
	## final tiles (no gems found) leaves every tile black and the mine never
	## refreshes until some other action happens to trigger the check.
	if is_fully_excavated():
		_reset_dug()
	save_data()
	deep_mine_updated.emit()
	return result


## Digs DOWN through undug layers at (row, col) until a treasure is found, then
## stops IMMEDIATELY at the first treasure, leaving all remaining layers beneath
## untouched (the player harvests, then digs again to go deeper). It only keeps
## digging down through layers that come up EMPTY.
## Each dug layer has `gem_chance` (30-40%) to contain one treasure.
## Does NOT consume shovels, save, or emit — callers handle persistence.
func _dig_column(row: int, col: int, _unused: int = 1, gem_chance: float = GEM_DROP_CHANCE) -> Dictionary:
	## "dug" = layers cleared, "tiles" = grid positions cleared (for missions).
	var result := {"dug": 0, "tiles": 0, "gems": {}, "ring": false}
	var layers := get_layer_count()
	for layer in range(layers):
		if _is_dug(layer, row, col):
			continue
		_set_dug(layer, row, col, true)
		result["dug"] += 1
		## Diamond ring only on the absolute deepest layer (layer 11).
		if layer == MAX_LAYERS - 1:
			if randi() % DIAMOND_RING_DROP_CHANCE == 0:
				result["ring"] = true
		## WonderStone from the two deepest layers: 1/250 on the second-deepest
		## (layer 10), 1/100 on the deepest (layer 11).
		var ws_chance := 0
		if layer == MAX_LAYERS - 1:
			ws_chance = 100
		elif layer == MAX_LAYERS - 2:
			ws_chance = 250
		if ws_chance > 0 and randi() % ws_chance == 0:
			result["materials"] = int(result.get("materials", 0)) + 1
		## Does this layer contain a treasure? If so, record it and STOP digging
		## here — the layers beneath are left untouched for a future dig.
		## The Black Pearl shop (Business District) raises the find chance.
		var find_chance := gem_chance
		if get_node_or_null("/root/BusinessDistrict") != null:
			find_chance = minf(gem_chance * BusinessDistrict.mine_find_multiplier(), 1.0)
		## Spiced Plum Jam recipe boost ("Deep Prospector"): +value rare-find
		## chance while active (e.g. 0.15 = +15% relative).
		if get_node_or_null("/root/PlayerData") != null and PlayerData.boost_active("deep_prospector"):
			find_chance = minf(find_chance * (1.0 + PlayerData.boost_value("deep_prospector")), 1.0)
		if randf() < find_chance:
			## Exactly ONE treasure per tile-layer: on the bottom 5 layers a
			## treasure may instead be an ore (pricier ores favor deeper layers).
			var treasure := ""
			if layer >= ORE_MIN_LAYER and randf() < _ore_treasure_chance(layer):
				treasure = _roll_ore(layer)
			else:
				treasure = _roll_gem_for_layer(layer)
			result["gems"][treasure] = int(result["gems"].get(treasure, 0)) + 1
			break
		## Empty layer — keep digging down within the same action.
	if result["dug"] > 0:
		result["tiles"] = 1
	return result


## Applies a dig result to persistent state: awards gems/ring, checks for full
## excavation (regenerate), then saves and emits.
func _finish_dig(result: Dictionary) -> void:
	if int(result.get("dug", 0)) <= 0:
		return
	var gems: Dictionary = result.get("gems", {})
	for gem_type in gems:
		_award_treasure(gem_type, int(gems[gem_type]))
	if bool(result.get("ring", false)):
		PlayerData.add_diamond_ring()
	## WonderStone drops from the two deepest layers.
	var ws := int(result.get("materials", 0))
	if ws > 0:
		PlayerData.add_wonderstone(ws)
	## Mission progress: "dig X tiles" counts grid positions cleared.
	var tiles := int(result.get("tiles", 0))
	if tiles > 0 and get_node_or_null("/root/MissionBoard") != null:
		MissionBoard.on_deep_mine_dug(tiles)
	## Regenerate the whole mine once everything is dug.
	if is_fully_excavated():
		_reset_dug()
	save_data()
	deep_mine_updated.emit()


func _merge_result(into: Dictionary, other: Dictionary) -> void:
	into["dug"] = int(into.get("dug", 0)) + int(other.get("dug", 0))
	into["tiles"] = int(into.get("tiles", 0)) + int(other.get("tiles", 0))
	into["materials"] = int(into.get("materials", 0)) + int(other.get("materials", 0))
	if bool(other.get("ring", false)):
		into["ring"] = true
	var gems: Dictionary = other.get("gems", {})
	for gem_type in gems:
		into["gems"][gem_type] = int(into["gems"].get(gem_type, 0)) + int(gems[gem_type])


## Chance that a treasure on an ore-eligible layer is an ore (vs a gem). Ramps
## from ORE_TREASURE_CHANCE_BASE at the shallowest ore layer up to
## ORE_TREASURE_CHANCE_BOTTOM at the deepest layer.
func _ore_treasure_chance(layer: int) -> float:
	var deepest := MAX_LAYERS - 1
	if deepest <= ORE_MIN_LAYER:
		return ORE_TREASURE_CHANCE_BOTTOM
	var t := float(layer - ORE_MIN_LAYER) / float(deepest - ORE_MIN_LAYER)
	t = clampf(t, 0.0, 1.0)
	return ORE_TREASURE_CHANCE_BASE + (ORE_TREASURE_CHANCE_BOTTOM - ORE_TREASURE_CHANCE_BASE) * t

## Picks which ore drops on a given (bottom-5) layer. Cheaper ore (iron) favors
## the shallower ore layers; the pricier ore (copper) favors the deepest ones.
## Uses a depth-weighted pick so both can appear anywhere in the bottom 5, but
## the odds shift toward copper as you go deeper.
func _roll_ore(layer: int) -> String:
	var deepest := MAX_LAYERS - 1
	var t := 0.0
	if deepest > ORE_MIN_LAYER:
		t = clampf(float(layer - ORE_MIN_LAYER) / float(deepest - ORE_MIN_LAYER), 0.0, 1.0)
	## t=0 (shallowest ore layer) -> mostly iron; t=1 (bottom) -> mostly copper.
	var copper_chance := 0.15 + 0.70 * t
	if randf() < copper_chance:
		return "copper_ore"
	return "iron_ore"


## Picks a gem for an ABSOLUTE layer index (0 = top, MAX_LAYERS-1 = bottom).
## Gem rarity is anchored to fixed depth, NOT to how many layers are unlocked:
##   - Layer 0 (the top) yields only gold (the most common gem).
##   - Layer MAX_LAYERS-1 (layer 11, the deepest possible) yields only diamond,
##     and diamond appears on NO other layer.
##   - Layers in between map proportionally across the gem list, with a little
##     spread so adjacent rarities can appear.
func _roll_gem_for_layer(layer: int) -> String:
	var gem_count := GEM_ORDER.size()          ## 8 gems, index 0=gold .. 7=diamond
	var deepest := MAX_LAYERS - 1               ## absolute bottom = layer index 10

	## Top layer: gold only.
	if layer <= 0:
		return GEM_ORDER[0]
	## Absolute deepest layer (layer 11): diamond only.
	if layer >= deepest:
		return GEM_ORDER[gem_count - 1]

	## Map absolute depth (1..deepest-1) onto the non-diamond gems (indices 0..gem_count-2).
	## Diamond is excluded everywhere except the absolute deepest layer.
	var pickable := gem_count - 1               ## exclude diamond -> indices 0..6
	var frac := float(layer) / float(deepest)   ## 0..1 across the full 11-layer scale
	var center := clampi(int(round(frac * float(pickable - 1))), 0, pickable - 1)

	## Triangular weights peaked at `center` so nearby rarities can appear.
	var weights: Array = []
	var values: Array = []
	for i in range(pickable):
		weights.append(maxi(1, pickable - absi(i - center)))
		## Rarity proxy: deeper index = rarer = higher "value" so luck tilts here.
		values.append(i + 1)

	## Equipped ruby "rarer_gems" jewelry biases the pick toward rarer gems via
	## the Luck autoload. Null-safe: without it, falls back to the plain weights.
	var idx := -1
	if get_node_or_null("/root/Luck") != null and get_node_or_null("/root/JewelryBonus") != null:
		idx = Luck.biased_pick(weights, values, JewelryBonus.gem_roll_luck())
	else:
		idx = _plain_weighted_pick(weights)
	if idx < 0 or idx >= pickable:
		idx = center
	return GEM_ORDER[idx]


## Plain cumulative weighted pick (no luck) — fallback when Luck is unavailable.
func _plain_weighted_pick(weights: Array) -> int:
	var total := 0
	for w in weights:
		total += int(w)
	if total <= 0:
		return 0
	var roll := randi() % total
	var cumulative := 0
	for i in range(weights.size()):
		cumulative += int(weights[i])
		if roll < cumulative:
			return i
	return weights.size() - 1


## ── Dug-state helpers ──────────────────────────────────────────

func _is_dug(layer: int, row: int, col: int) -> bool:
	if layer < 0 or layer >= dug.size():
		return false
	if row < 0 or row >= dug[layer].size():
		return false
	if col < 0 or col >= dug[layer][row].size():
		return false
	return bool(dug[layer][row][col])

func _set_dug(layer: int, row: int, col: int, value: bool) -> void:
	if layer < 0 or layer >= dug.size():
		return
	if row < 0 or row >= dug[layer].size():
		return
	if col < 0 or col >= dug[layer][row].size():
		return
	dug[layer][row][col] = value


## Rebuilds the dug state to all-undug at the current layer/row/col dimensions,
## and clears all pending gems.
func _reset_dug() -> void:
	dug.clear()
	var layers := get_layer_count()
	for layer in range(layers):
		var layer_grid: Array = []
		for r in range(mine_rows):
			var row_data: Array = []
			for c in range(mine_cols):
				row_data.append(false)
			layer_grid.append(row_data)
		dug.append(layer_grid)
	_reset_found_gem()


## Makes sure the dug (and found_gem) grids match the current layer/row/col
## dimensions. Layer count can increase mid-session via prestige, so call this
## before digging. Preserves existing dug flags.
func _ensure_dimensions() -> void:
	var needs_resize := dug.size() != get_layer_count()
	if not needs_resize and dug.size() > 0:
		var layer0: Array = dug[0]
		if layer0.size() != mine_rows:
			needs_resize = true
		elif layer0.size() > 0 and layer0[0].size() != mine_cols:
			needs_resize = true
	if needs_resize:
		_resize_dug()


## Rebuilds found_gem as an empty {} grid at the current rows x cols.
func _reset_found_gem() -> void:
	found_gem.clear()
	for r in range(mine_rows):
		var row_data: Array = []
		for c in range(mine_cols):
			row_data.append({})
		found_gem.append(row_data)


## Ensures the dug structure matches current layers x rows x cols, preserving
## existing dug flags where they overlap (used after buying rows/cols/layers).
func _resize_dug() -> void:
	var layers := get_layer_count()
	## Grow/shrink layers.
	while dug.size() < layers:
		dug.append([])
	while dug.size() > layers:
		dug.pop_back()
	for layer in range(layers):
		var layer_grid: Array = dug[layer]
		while layer_grid.size() < mine_rows:
			layer_grid.append([])
		while layer_grid.size() > mine_rows:
			layer_grid.pop_back()
		for r in range(mine_rows):
			var row_data: Array = layer_grid[r]
			while row_data.size() < mine_cols:
				row_data.append(false)
			while row_data.size() > mine_cols:
				row_data.pop_back()
	## Keep found_gem the same rows x cols shape.
	while found_gem.size() < mine_rows:
		found_gem.append([])
	while found_gem.size() > mine_rows:
		found_gem.pop_back()
	for r in range(mine_rows):
		var fg_row: Array = found_gem[r]
		while fg_row.size() < mine_cols:
			fg_row.append({})
		while fg_row.size() > mine_cols:
			fg_row.pop_back()


## ── Expansions ─────────────────────────────────────────────────

func get_row_cost() -> int:
	return int(ROW_COST_BASE * pow(EXPANSION_SCALE, mine_rows - MIN_ROWS))

func get_col_cost() -> int:
	return int(COL_COST_BASE * pow(EXPANSION_SCALE, mine_cols - MIN_COLS))

func can_buy_row() -> bool:
	return mine_rows < MAX_ROWS and PlayerData.coins >= get_row_cost()

func can_buy_col() -> bool:
	return mine_cols < MAX_COLS and PlayerData.coins >= get_col_cost()

func buy_row() -> bool:
	var cost := get_row_cost()
	if mine_rows >= MAX_ROWS or PlayerData.coins < cost:
		return false
	PlayerData.coins -= cost
	mine_rows += 1
	_resize_dug()
	PlayerData.save_data()
	save_data()
	deep_mine_updated.emit()
	return true

func buy_col() -> bool:
	var cost := get_col_cost()
	if mine_cols >= MAX_COLS or PlayerData.coins < cost:
		return false
	PlayerData.coins -= cost
	mine_cols += 1
	_resize_dug()
	PlayerData.save_data()
	save_data()
	deep_mine_updated.emit()
	return true


## ── Excavator purchase ─────────────────────────────────────────

func has_excavator() -> bool:
	return excavator_owned

func can_buy_excavator() -> bool:
	return not excavator_owned and PlayerData.coins >= EXCAVATOR_COST

func buy_excavator() -> bool:
	if excavator_owned or PlayerData.coins < EXCAVATOR_COST:
		return false
	PlayerData.coins -= EXCAVATOR_COST
	excavator_owned = true
	PlayerData.save_data()
	save_data()
	PlayerData.data_changed.emit()
	deep_mine_updated.emit()
	return true


## ── Persistence ────────────────────────────────────────────────

func save_data() -> void:
	var config := ConfigFile.new()
	config.set_value("deep_mine", "rows", mine_rows)
	config.set_value("deep_mine", "cols", mine_cols)
	config.set_value("deep_mine", "excavator_owned", excavator_owned)
	## Serialize dug state as a flat array-of-arrays-of-arrays.
	config.set_value("deep_mine", "dug", dug)
	## Serialize pending gems (row x col of { gem_type: count } dicts).
	config.set_value("deep_mine", "found_gem", found_gem)
	config.save(SAVE_PATH)


func load_data() -> void:
	var config := ConfigFile.new()
	var err := config.load(SAVE_PATH)
	if err != OK:
		## Fresh mine.
		mine_rows = MIN_ROWS
		mine_cols = MIN_COLS
		excavator_owned = false
		_reset_dug()
		return

	mine_rows = clampi(int(config.get_value("deep_mine", "rows", MIN_ROWS)), MIN_ROWS, MAX_ROWS)
	mine_cols = clampi(int(config.get_value("deep_mine", "cols", MIN_COLS)), MIN_COLS, MAX_COLS)
	excavator_owned = bool(config.get_value("deep_mine", "excavator_owned", false))

	var loaded_dug = config.get_value("deep_mine", "dug", [])
	dug.clear()
	if loaded_dug is Array and loaded_dug.size() > 0:
		for layer_grid in loaded_dug:
			var new_layer: Array = []
			if layer_grid is Array:
				for row_data in layer_grid:
					var new_row: Array = []
					if row_data is Array:
						for cell in row_data:
							new_row.append(bool(cell))
					new_layer.append(new_row)
			dug.append(new_layer)

	## Load pending gems (row x col of { gem_type: count }).
	var loaded_fg = config.get_value("deep_mine", "found_gem", [])
	found_gem.clear()
	if loaded_fg is Array:
		for row_data in loaded_fg:
			var new_row: Array = []
			if row_data is Array:
				for cell in row_data:
					new_row.append(cell if cell is Dictionary else {})
			found_gem.append(new_row)

	## Normalize dimensions to the current layers x rows x cols.
	if dug.is_empty():
		_reset_dug()
	else:
		_resize_dug()
		## Ensure found_gem has the right shape if it was missing/short.
		if found_gem.is_empty():
			_reset_found_gem()
