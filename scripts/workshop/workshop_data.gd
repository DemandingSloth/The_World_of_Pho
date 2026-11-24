class_name WorkshopData
extends Node

## Autoload: Workshop
## The Workshop houses two tools:
##
## SAW — cuts/polishes uncut gems into their polished version (worth 10x).
##   Gems queue up (FIFO) and are cut SEQUENTIALLY: the saw processes only a
##   few at once (1 base, +1 per "saw_parallel" prestige level). Each gem takes
##   SAW_CUT_TIME (reducible via the "saw_speed" prestige at 5%/level like
##   prospectors/garden). So 10 gems with no upgrades = 10 x 5min = 50 minutes.
##   Total gems that fit in the saw (waiting + cutting) is capped by capacity
##   (10 base, up to 1000 via "saw_capacity" prestige). Gold is NOT polishable
##   (it will go to the future Foundry).
##
## HOURGLASS — advances every time-based system by 1 hour per click (garden
##   growth, prospector output, gem cutting, shop restock timers), but NOT the
##   daily bonus. Limited to HOURGLASS_BASE_CLICKS/day + "hourglass" prestige.
##
## Saved to user://workshop_save.cfg

const SAVE_PATH := "user://workshop_save.cfg"

## ── Saw tuning ─────────────────────────────────────────────────
const SAW_CUT_TIME := 300.0              ## 5 minutes per batch (base)
const SAW_BASE_CAPACITY := 10            ## Gems that fit in the saw at once (base)
const SAW_MAX_CAPACITY := 10000          ## Cap via prestige

## ── Foundry tuning (mirrors the saw) ───────────────────────────
const FOUNDRY_SMELT_TIME := 300.0        ## 5 minutes per smelt (base)
const FOUNDRY_BASE_CAPACITY := 10        ## Ores that fit in the foundry at once (base)
const FOUNDRY_MAX_CAPACITY := 10000      ## Cap via prestige

## ── Hourglass tuning ───────────────────────────────────────────
const HOURGLASS_BASE_CLICKS := 3         ## Free hourglass uses per day (base)
const HOURGLASS_SECONDS_PER_CLICK := 3600.0  ## Each click = 1 hour

signal workshop_updated

## ── Saw state ──────────────────────────────────────────────────
## FIFO queue of gem_type strings still in the saw (waiting + being cut).
## Gems are processed from the front. `saw_start` is the unix time the current
## processing window began; completed count = floor(elapsed / cut_time) *
## parallelism. On collect, finished gems are removed and saw_start advances by
## the whole cut-windows consumed (remainder carries). Empty queue -> saw_start = 0.
var saw_queue: Array = []
var saw_start: float = 0.0

## ── Foundry state (mirrors the saw) ────────────────────────────
## FIFO queue of RAW material ids still in the foundry (waiting + smelting).
## Raw ids are "iron_ore", "copper_ore" (resource items) or "gold" (a gemstone).
## On collect, each finished raw is converted to its output bar/ingot.
var foundry_queue: Array = []
var foundry_start: float = 0.0

## Raw material id -> smelted output item id. Gold is a gemstone (not a resource
## item), so it's handled here explicitly alongside the ore recipes.
const FOUNDRY_OUTPUTS := {
	"iron_ore": "iron_bar",
	"copper_ore": "copper_ingot",
	"gold": "gold_ingot",
}

## ── Hourglass state (daily-limited) ────────────────────────────
## Last-selected "Add qty" option on the workshop screen (persisted so the saw
## and foundry dropdowns re-open on the player's previous choice). Stored as the
## option VALUE (1/10/25 or the QTY_MAX sentinel 1_000_000). Defaults to 1.
var last_saw_qty: int = 1
var last_foundry_qty: int = 1

var hourglass_used: int = 0              ## Clicks used in the current day
var hourglass_day: int = -1              ## Day index the counter applies to

## Texture cache
var _saw_frames: Array = []              ## 4 animation frames
var _foundry_frames: Array = []          ## 6 animation frames
var _hourglass_texture: Texture2D = null


## ── Lifecycle ──────────────────────────────────────────────────

func _ready() -> void:
	load_data()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		save_data()


## ── Prestige-scaled values ─────────────────────────────────────

## Total gems that can be in the saw at once (base + saw_capacity prestige).
## Capacity scales linearly from BASE (level 0) to MAX (level 10). Interpolating
## by level guarantees level 10 lands exactly on SAW_MAX_CAPACITY. Each level's
## value is rounded to the nearest even number so all displayed caps are even.
func get_saw_capacity() -> int:
	var lvl := clampi(PlayerData.get_prestige_level("saw_capacity"), 0, 10)
	var raw := SAW_BASE_CAPACITY + int(round((SAW_MAX_CAPACITY - SAW_BASE_CAPACITY) * lvl / 10.0))
	var cap := int(round(raw / 2.0)) * 2  ## snap to nearest even
	return clampi(cap, SAW_BASE_CAPACITY, SAW_MAX_CAPACITY)

## Effective cut time for one batch (−5% per saw_speed prestige level, cap −50%),
## further reduced by the Jewelers shop bonus (Business District, multiplicative).
func get_saw_cut_time() -> float:
	var mult := 1.0 - PlayerData.get_prestige_level("saw_speed") * 0.05
	if get_node_or_null("/root/BusinessDistrict") != null:
		mult *= BusinessDistrict.saw_speed_multiplier()
	## Roasted Cauliflower & Squash Soup recipe boost ("Precision Cutting"):
	## −value saw time while active (e.g. 0.25 = −25%).
	if PlayerData.boost_active("precision_cutting"):
		mult *= maxf(0.0, 1.0 - PlayerData.boost_value("precision_cutting"))
	return maxf(SAW_CUT_TIME * mult, 1.0)

## How many gems the saw cuts simultaneously. Base 1, plus a GROWING bonus per
## prestige level: level 1 adds +1, level 2 adds +2, ... (triangular), so total
## = 1 + n(n+1)/2. See _parallel_bonus.
func get_saw_parallelism() -> int:
	return 1 + _parallel_bonus(PlayerData.get_prestige_level("saw_parallel"))


## Cumulative parallelism bonus for a prestige level `n`: +1 at L1, +2 at L2,
## +3 at L3, ... = 1+2+...+n = n(n+1)/2. (0 at level 0.)
func _parallel_bonus(n: int) -> int:
	if n <= 0:
		return 0
	return n * (n + 1) / 2

## Total hourglass clicks allowed per day (base + hourglass prestige, +1/level).
func get_hourglass_limit() -> int:
	return HOURGLASS_BASE_CLICKS + PlayerData.get_prestige_level("hourglass")

## ── Foundry prestige-scaled values (mirror the saw) ────────────

## Total ores that can be in the foundry at once (base + foundry_capacity).
## Linear interpolation BASE (level 0) -> MAX (level 10), so level 10 lands
## exactly on FOUNDRY_MAX_CAPACITY. Each level snaps to the nearest even number
## so all displayed caps are even (mirrors the saw).
func get_foundry_capacity() -> int:
	var lvl := clampi(PlayerData.get_prestige_level("foundry_capacity"), 0, 10)
	var raw := FOUNDRY_BASE_CAPACITY + int(round((FOUNDRY_MAX_CAPACITY - FOUNDRY_BASE_CAPACITY) * lvl / 10.0))
	var cap := int(round(raw / 2.0)) * 2  ## snap to nearest even
	return clampi(cap, FOUNDRY_BASE_CAPACITY, FOUNDRY_MAX_CAPACITY)

## Effective smelt time for one ore (−5% per foundry_speed level, cap −50%).
func get_foundry_smelt_time() -> float:
	var mult := 1.0 - PlayerData.get_prestige_level("foundry_speed") * 0.05
	## Guild "Foundry Speed" perk (−5%/level; lower = faster).
	if get_node_or_null("/root/GuildManager") != null:
		mult *= GuildManager.foundry_time_perk_mult()
	## Smoked Apple Glaze recipe boost ("Furnace Fuel"): −value foundry time
	## while active (e.g. 0.20 = −20%).
	if PlayerData.boost_active("furnace_fuel"):
		mult *= maxf(0.0, 1.0 - PlayerData.boost_value("furnace_fuel"))
	return maxf(FOUNDRY_SMELT_TIME * mult, 1.0)

## How many ores the foundry smelts simultaneously. Base 1, plus the same
## growing per-level bonus as the saw (see _parallel_bonus).
func get_foundry_parallelism() -> int:
	return 1 + _parallel_bonus(PlayerData.get_prestige_level("foundry_parallel"))


## ── Textures ───────────────────────────────────────────────────

func _load_textures() -> void:
	if not _saw_frames.is_empty():
		return
	## saw.png is a 4-frame horizontal strip; slice it into AtlasTextures.
	var sheet: Texture2D = load("res://Assets/Workshop/saw.png")
	if sheet != null:
		var fw := int(sheet.get_width() / 4.0)
		var fh := sheet.get_height()
		for i in range(4):
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet
			atlas.region = Rect2(i * fw, 0, fw, fh)
			_saw_frames.append(atlas)
	## foundry.png is a 6-frame horizontal strip; slice it the same way.
	var fsheet: Texture2D = load("res://Assets/Workshop/foundry.png")
	if fsheet != null:
		var ffw := int(fsheet.get_width() / 6.0)
		var ffh := fsheet.get_height()
		for i in range(6):
			var fatlas := AtlasTexture.new()
			fatlas.atlas = fsheet
			fatlas.region = Rect2(i * ffw, 0, ffw, ffh)
			_foundry_frames.append(fatlas)
	_hourglass_texture = load("res://Assets/Workshop/hourglass.png")

func get_saw_frame(index: int) -> Texture2D:
	_load_textures()
	if _saw_frames.is_empty():
		return null
	return _saw_frames[index % _saw_frames.size()]

func get_saw_frame_count() -> int:
	_load_textures()
	return _saw_frames.size()

func get_foundry_frame(index: int) -> Texture2D:
	_load_textures()
	if _foundry_frames.is_empty():
		return null
	return _foundry_frames[index % _foundry_frames.size()]

func get_foundry_frame_count() -> int:
	_load_textures()
	return _foundry_frames.size()

func get_hourglass_texture() -> Texture2D:
	_load_textures()
	return _hourglass_texture


## ── Saw: capacity / queries ────────────────────────────────────

## Gems currently in the saw (waiting + being cut).
func get_saw_load() -> int:
	return saw_queue.size()

func get_saw_space() -> int:
	return maxi(0, get_saw_capacity() - get_saw_load())

func is_saw_empty() -> bool:
	return saw_queue.is_empty()

## How many queued gems have finished cutting given elapsed processing time.
## Sequential with parallelism P: after each full cut window (cut_time), P more
## gems complete. Capped at the queue length.
func _completed_count() -> int:
	if saw_queue.is_empty() or saw_start <= 0.0:
		return 0
	var elapsed := TrustedClock.now() - saw_start
	if elapsed <= 0.0:
		return 0
	var windows := int(elapsed / get_saw_cut_time())
	return mini(windows * get_saw_parallelism(), saw_queue.size())

## True if at least one gem has finished and is ready to collect.
func has_ready_gems() -> bool:
	return _completed_count() > 0

func get_ready_count() -> int:
	return _completed_count()

## Seconds until the next gem(s) finish. 0 if something is ready now, -1 if idle.
func next_ready_seconds() -> float:
	if saw_queue.is_empty() or saw_start <= 0.0:
		return -1.0
	if _completed_count() > 0:
		return 0.0
	var cut := get_saw_cut_time()
	var elapsed := TrustedClock.now() - saw_start
	var into_window := fmod(maxf(elapsed, 0.0), cut)
	return maxf(0.0, cut - into_window)


## ── Saw: adding & collecting ───────────────────────────────────

## Adds up to `qty` uncut gems of `gem_type` to the saw queue. Clamped by how
## many the player owns and the remaining saw capacity. Gold is rejected.
## Returns the number actually added.
## When `priority` is true, the added gems jump ahead of everything still
## WAITING — they're inserted right after the batch currently being cut (and any
## finished-but-uncollected gems at the front), so they process on the NEXT
## window instead of behind the rest of the queue. The in-progress batch keeps
## its elapsed progress untouched (we never move the front or saw_start), so
## this can't be used to rush a nearly-finished batch.
func add_to_saw(gem_type: String, qty: int, priority: bool = false) -> int:
	if not PlayerData.is_polishable(gem_type):
		return 0
	if qty <= 0:
		return 0
	var owned := PlayerData.get_gem_count(gem_type)
	var addable: int = mini(qty, mini(owned, get_saw_space()))
	if addable <= 0:
		return 0
	## Remove from the uncut inventory.
	PlayerData.gemstones[gem_type] = owned - addable
	if PlayerData.gemstones[gem_type] <= 0:
		PlayerData.gemstones.erase(gem_type)
	## Start the processing clock if the saw was idle.
	if saw_queue.is_empty():
		saw_start = TrustedClock.now()
	if priority:
		## Insert after the active batch (finished + currently-cutting) so the
		## new gems are next in line, ahead of the rest of the waiting queue.
		var insert_at: int = mini(_completed_count() + get_saw_parallelism(), saw_queue.size())
		for i in range(addable):
			saw_queue.insert(insert_at + i, gem_type)
	else:
		for _i in range(addable):
			saw_queue.append(gem_type)
	PlayerData.save_data()
	save_data()
	PlayerData.data_changed.emit()
	workshop_updated.emit()
	return addable

## Collects all finished gems (front of the queue) into polished inventory.
## Returns a Dictionary { gem_type: count } of what was collected.
func collect_ready() -> Dictionary:
	var collected: Dictionary = {}
	var done := _completed_count()
	if done <= 0:
		return collected
	## Pull the finished gems off the front of the queue.
	for _i in range(done):
		var gt: String = saw_queue.pop_front()
		collected[gt] = int(collected.get(gt, 0)) + 1
	## Advance the processing clock past the whole windows those gems consumed,
	## preserving the remainder so partially-cut gems keep their progress.
	var cut := get_saw_cut_time()
	var p := get_saw_parallelism()
	var windows_consumed := int(ceil(float(done) / float(p)))
	if saw_queue.is_empty():
		saw_start = 0.0
	else:
		saw_start += windows_consumed * cut
	var total := 0
	for gem_type in collected:
		PlayerData.add_polished_gems(gem_type, int(collected[gem_type]))
		total += int(collected[gem_type])
	## Mission progress: "polish N gems".
	if total > 0 and get_node_or_null("/root/MissionBoard") != null:
		MissionBoard.on_gems_polished(total)
	save_data()
	workshop_updated.emit()
	return collected


## Distinct gem types currently in the saw, in POLISHABLE_GEMS order, with their
## counts. For the queue list UI: [ { "type": gem_type, "count": n }, ... ].
func saw_queue_groups() -> Array:
	var counts: Dictionary = {}
	for gt in saw_queue:
		counts[gt] = int(counts.get(gt, 0)) + 1
	var out: Array = []
	for gem_type in PlayerData.POLISHABLE_GEMS:
		if counts.has(gem_type):
			out.append({"type": gem_type, "count": int(counts[gem_type])})
	## Any unexpected types not in POLISHABLE_GEMS (defensive) appended last.
	for gem_type in counts:
		if not PlayerData.POLISHABLE_GEMS.has(gem_type):
			out.append({"type": gem_type, "count": int(counts[gem_type])})
	return out


## Removes EVERY queued gem of `gem_type` from the saw and refunds them (uncut)
## to the player's gemstone inventory. Returns the number removed.
## Refunds go straight to the gemstones dict (not add_gemstones) so a refund
## doesn't fire "collect gems" mission progress. Any remaining queue restarts its
## current cut window (start = now) so removing a group can't retroactively mark
## other gems finished.
func remove_saw_group(gem_type: String) -> int:
	var removed := 0
	var kept: Array = []
	for gt in saw_queue:
		if gt == gem_type:
			removed += 1
		else:
			kept.append(gt)
	if removed <= 0:
		return 0
	saw_queue = kept
	## Refund uncut gems directly (mirrors how add_to_saw consumed them).
	PlayerData.gemstones[gem_type] = PlayerData.get_gem_count(gem_type) + removed
	## Re-anchor / clear the processing clock.
	if saw_queue.is_empty():
		saw_start = 0.0
	else:
		saw_start = TrustedClock.now()
	PlayerData.save_data()
	save_data()
	PlayerData.data_changed.emit()
	workshop_updated.emit()
	return removed


## ── Foundry: capacity / queries (mirror the saw) ───────────────

## Whether a raw material id can be smelted by the foundry.
func is_smeltable(raw_id: String) -> bool:
	return FOUNDRY_OUTPUTS.has(raw_id)

## How many of `raw_id` the player currently owns (ores live in the item store,
## gold lives in the gemstone store).
func _owned_raw(raw_id: String) -> int:
	if raw_id == "gold":
		return PlayerData.get_gem_count("gold")
	return PlayerData.get_item_count(raw_id)

## Removes `qty` of a raw material from the correct inventory.
func _consume_raw(raw_id: String, qty: int) -> void:
	if raw_id == "gold":
		var owned := PlayerData.get_gem_count("gold")
		PlayerData.gemstones["gold"] = owned - qty
		if PlayerData.gemstones["gold"] <= 0:
			PlayerData.gemstones.erase("gold")
	else:
		var owned := PlayerData.get_item_count(raw_id)
		PlayerData.fruits[raw_id] = owned - qty
		if PlayerData.fruits[raw_id] <= 0:
			PlayerData.fruits.erase(raw_id)

func get_foundry_load() -> int:
	return foundry_queue.size()

func get_foundry_space() -> int:
	return maxi(0, get_foundry_capacity() - get_foundry_load())

func is_foundry_empty() -> bool:
	return foundry_queue.is_empty()

func _foundry_completed_count() -> int:
	if foundry_queue.is_empty() or foundry_start <= 0.0:
		return 0
	var elapsed := TrustedClock.now() - foundry_start
	if elapsed <= 0.0:
		return 0
	var windows := int(elapsed / get_foundry_smelt_time())
	return mini(windows * get_foundry_parallelism(), foundry_queue.size())

func has_ready_bars() -> bool:
	return _foundry_completed_count() > 0

func get_foundry_ready_count() -> int:
	return _foundry_completed_count()

## Seconds until the next bar(s) finish. 0 if ready now, -1 if idle.
func foundry_next_ready_seconds() -> float:
	if foundry_queue.is_empty() or foundry_start <= 0.0:
		return -1.0
	if _foundry_completed_count() > 0:
		return 0.0
	var smelt := get_foundry_smelt_time()
	var elapsed := TrustedClock.now() - foundry_start
	var into_window := fmod(maxf(elapsed, 0.0), smelt)
	return maxf(0.0, smelt - into_window)


## ── Foundry: adding & collecting (mirror the saw) ──────────────

## Adds up to `qty` of a raw material to the foundry queue. Clamped by how many
## the player owns and remaining foundry capacity. Returns the number added.
## `priority` behaves exactly like add_to_saw: the added ores jump ahead of the
## waiting queue (inserted after the batch currently smelting) so they smelt
## next, without disturbing the in-progress batch's timing.
func add_to_foundry(raw_id: String, qty: int, priority: bool = false) -> int:
	if not is_smeltable(raw_id):
		return 0
	if qty <= 0:
		return 0
	var owned := _owned_raw(raw_id)
	var addable: int = mini(qty, mini(owned, get_foundry_space()))
	if addable <= 0:
		return 0
	_consume_raw(raw_id, addable)
	if foundry_queue.is_empty():
		foundry_start = TrustedClock.now()
	if priority:
		var insert_at: int = mini(_foundry_completed_count() + get_foundry_parallelism(), foundry_queue.size())
		for i in range(addable):
			foundry_queue.insert(insert_at + i, raw_id)
	else:
		for _i in range(addable):
			foundry_queue.append(raw_id)
	PlayerData.save_data()
	save_data()
	PlayerData.data_changed.emit()
	workshop_updated.emit()
	return addable

## Collects all finished smelts (front of the queue) into the item store as
## their output bars/ingots. Returns { output_item_id: count } collected.
func collect_foundry_ready() -> Dictionary:
	var collected: Dictionary = {}
	var done := _foundry_completed_count()
	if done <= 0:
		return collected
	for _i in range(done):
		var raw: String = foundry_queue.pop_front()
		var out: String = FOUNDRY_OUTPUTS.get(raw, raw)
		collected[out] = int(collected.get(out, 0)) + 1
	var smelt := get_foundry_smelt_time()
	var p := get_foundry_parallelism()
	var windows_consumed := int(ceil(float(done) / float(p)))
	if foundry_queue.is_empty():
		foundry_start = 0.0
	else:
		foundry_start += windows_consumed * smelt
	var total := 0
	for out_id in collected:
		PlayerData.add_item(out_id, int(collected[out_id]))
		total += int(collected[out_id])
	## Mission progress: "smelt N bars".
	if total > 0 and get_node_or_null("/root/MissionBoard") != null:
		MissionBoard.on_bars_smelted(total)
	save_data()
	workshop_updated.emit()
	return collected


## Distinct raw materials currently in the foundry, in FOUNDRY_OUTPUTS key order,
## with counts. For the queue list UI: [ { "type": raw_id, "count": n }, ... ].
func foundry_queue_groups() -> Array:
	var counts: Dictionary = {}
	for raw in foundry_queue:
		counts[raw] = int(counts.get(raw, 0)) + 1
	var out: Array = []
	for raw_id in FOUNDRY_OUTPUTS.keys():
		if counts.has(raw_id):
			out.append({"type": raw_id, "count": int(counts[raw_id])})
	for raw_id in counts:
		if not FOUNDRY_OUTPUTS.has(raw_id):
			out.append({"type": raw_id, "count": int(counts[raw_id])})
	return out


## Removes EVERY queued unit of `raw_id` from the foundry and refunds them (as
## the raw material) to the correct inventory: gold -> gemstones, ores -> item
## store. Returns the number removed. Remaining queue restarts its smelt window.
func remove_foundry_group(raw_id: String) -> int:
	var removed := 0
	var kept: Array = []
	for raw in foundry_queue:
		if raw == raw_id:
			removed += 1
		else:
			kept.append(raw)
	if removed <= 0:
		return 0
	foundry_queue = kept
	## Refund the raw material to wherever it came from (mirrors _consume_raw).
	if raw_id == "gold":
		PlayerData.gemstones["gold"] = PlayerData.get_gem_count("gold") + removed
	else:
		PlayerData.add_item(raw_id, removed)
	if foundry_queue.is_empty():
		foundry_start = 0.0
	else:
		foundry_start = TrustedClock.now()
	PlayerData.save_data()
	save_data()
	PlayerData.data_changed.emit()
	workshop_updated.emit()
	return removed


## ── Hourglass ──────────────────────────────────────────────────

func _current_day_index() -> int:
	return int(TrustedClock.now() / 86400.0)

func _roll_over_hourglass_day() -> void:
	var today := _current_day_index()
	if hourglass_day != today:
		hourglass_day = today
		hourglass_used = 0

func get_hourglass_remaining() -> int:
	_roll_over_hourglass_day()
	return maxi(0, get_hourglass_limit() - hourglass_used)

func can_use_hourglass() -> bool:
	return get_hourglass_remaining() > 0

## Uses one hourglass click: advances every time-based system by 1 hour.
## Returns true if a click was available and applied.
func use_hourglass() -> bool:
	_roll_over_hourglass_day()
	if get_hourglass_remaining() <= 0:
		return false
	hourglass_used += 1
	_advance_all(1.0)
	save_data()
	workshop_updated.emit()
	return true

## Advances all time-based systems by `hours`. Each system clamps internally so
## nothing goes "negative": ready things read as ready, shop timers re-base with
## the remainder, and the daily bonus is deliberately left untouched.
func _advance_all(hours: float) -> void:
	## Garden crop growth.
	if get_node_or_null("/root/Garden") != null:
		Garden.advance_time_hours(hours)
	## Orchard fruit growth (if present) — same timestamp-shift approach.
	if get_node_or_null("/root/Orchard") != null and Orchard.has_method("advance_time_hours"):
		Orchard.advance_time_hours(hours)
	## Prospectors + shop/tool restock timers (daily bonus intentionally excluded).
	PlayerData.advance_time_hours(hours)
	## Saw: shift the processing clock back so more of the queue completes, but
	## never past what would finish the whole queue (clamp to "just done").
	if not saw_queue.is_empty() and saw_start > 0.0:
		var seconds := hours * 3600.0
		var cut := get_saw_cut_time()
		var p := get_saw_parallelism()
		var now := TrustedClock.now()
		## Time at which the entire queue would be complete.
		var windows_for_all := int(ceil(float(saw_queue.size()) / float(p)))
		var earliest := now - windows_for_all * cut
		saw_start = maxf(saw_start - seconds, earliest)
	## Foundry: same clamped shift-back as the saw.
	if not foundry_queue.is_empty() and foundry_start > 0.0:
		var f_seconds := hours * 3600.0
		var f_smelt := get_foundry_smelt_time()
		var f_p := get_foundry_parallelism()
		var f_now := TrustedClock.now()
		var f_windows_for_all := int(ceil(float(foundry_queue.size()) / float(f_p)))
		var f_earliest := f_now - f_windows_for_all * f_smelt
		foundry_start = maxf(foundry_start - f_seconds, f_earliest)


## ── Persistence ────────────────────────────────────────────────

func save_data() -> void:
	var config := ConfigFile.new()
	config.set_value("saw", "queue", saw_queue)
	config.set_value("saw", "start", saw_start)
	config.set_value("foundry", "queue", foundry_queue)
	config.set_value("foundry", "start", foundry_start)
	config.set_value("hourglass", "used", hourglass_used)
	config.set_value("hourglass", "day", hourglass_day)
	config.set_value("ui", "last_saw_qty", last_saw_qty)
	config.set_value("ui", "last_foundry_qty", last_foundry_qty)
	config.save(SAVE_PATH)


func load_data() -> void:
	saw_queue.clear()
	saw_start = 0.0
	foundry_queue.clear()
	foundry_start = 0.0
	var config := ConfigFile.new()
	var err := config.load(SAVE_PATH)
	if err != OK:
		hourglass_used = 0
		hourglass_day = -1
		return
	var loaded = config.get_value("saw", "queue", [])
	if loaded is Array:
		for gt in loaded:
			if gt is String:
				saw_queue.append(gt)
	saw_start = float(config.get_value("saw", "start", 0.0))
	## Safety: if we have a queue but no start time, begin processing now.
	if not saw_queue.is_empty() and saw_start <= 0.0:
		saw_start = TrustedClock.now()
	## Foundry (same shape as the saw).
	var loaded_foundry = config.get_value("foundry", "queue", [])
	if loaded_foundry is Array:
		for raw in loaded_foundry:
			if raw is String:
				foundry_queue.append(raw)
	foundry_start = float(config.get_value("foundry", "start", 0.0))
	if not foundry_queue.is_empty() and foundry_start <= 0.0:
		foundry_start = TrustedClock.now()
	hourglass_used = int(config.get_value("hourglass", "used", 0))
	hourglass_day = int(config.get_value("hourglass", "day", -1))
	last_saw_qty = int(config.get_value("ui", "last_saw_qty", 1))
	last_foundry_qty = int(config.get_value("ui", "last_foundry_qty", 1))
	_roll_over_hourglass_day()
