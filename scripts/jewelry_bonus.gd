extends Node
## Autoload: JewelryBonus
## Resolves the passive bonuses granted by EQUIPPED jewelry (Stage 3b).
##
## Model (per user design):
##   • Three equip slots live on PlayerData (ring / necklace / misc). Only
##     equipped jewelry grants a bonus; bonuses from all filled slots STACK.
##   • Each equipped item's bonus LEVEL (1..10) is driven by how many of that
##     item the player currently HOLDS, via COUNT_THRESHOLDS (logarithmic).
##   • Bonus magnitude scales linearly with level: level 1 = BONUS_MIN_PCT,
##     level 10 = BONUS_MAX_PCT (percent). Expressed as a fraction via
##     bonus_fraction() (e.g. 0.25 at level 10).
##   • Bonus id -> gem-typed effect:
##       all_sell_value  (gold)        +% to ALL sell value
##       coin_gain       (emerald)     +% coins from sales
##       xp_gain         (violet_stone)+% XP
##       daily_bonus     (black_pearl) +% daily bonus
##       growth_speed    (diamond)     faster crop growth (reduces grow time)
##       chest_luck      (blue_stone)  biases chest/loot luck
##       rarer_gems      (ruby)        biases gem rarity rolls (feeds Luck)
##       loving_messages (pink_stone)  periodic affirmation notifications
##
##   NOTE: all_sell_value and coin_gain both affect sale coins; sale paths apply
##   the COMBINED fraction (all_sell_value + coin_gain) so equipping both gold +
##   emerald stacks, as intended.

## ── Signals ─────────────────────────────────────────────────────
signal bonuses_changed()

## ── Tuning ───────────────────────────────────────────────────────
## Held-count thresholds for levels 1..10 (index 0 = level 1). Level = highest i
## whose threshold <= held count; 0 if below the first threshold.
const COUNT_THRESHOLDS: Array[int] = [1, 10, 100, 1000, 5000, 20000, 75000, 200000, 500000, 1000000]

## Percent at level 1 and level 10 (linear between). Level 1 ≈ 1%, level 10 = 25%.
const BONUS_MIN_PCT := 1.0
const BONUS_MAX_PCT := 25.0

const MAX_LEVEL := 10

## Pink-stone "loving_messages": interval between affirmation notifications while
## a pink_stone necklace is equipped. Higher level = slightly more frequent.
const LOVING_MESSAGE_BASE_INTERVAL := 900.0   ## 15 min at level 1
const LOVING_MESSAGE_MIN_INTERVAL := 300.0    ## floor at 5 min (level 10)

var _loving_timer: Timer = null


func _ready() -> void:
	## Recompute-notify whenever equipment changes.
	if get_node_or_null("/root/PlayerData") != null:
		if not PlayerData.jewelry_equipment_changed.is_connected(_on_equipment_changed):
			PlayerData.jewelry_equipment_changed.connect(_on_equipment_changed)

	## Loving-messages scheduler (pink_stone). Runs continuously; each tick only
	## fires a message if a pink_stone is currently equipped.
	_loving_timer = Timer.new()
	_loving_timer.one_shot = false
	_loving_timer.wait_time = LOVING_MESSAGE_BASE_INTERVAL
	_loving_timer.timeout.connect(_on_loving_tick)
	add_child(_loving_timer)
	_restart_loving_timer()


func _on_equipment_changed() -> void:
	bonuses_changed.emit()
	_restart_loving_timer()


## (Re)starts the loving-message timer at an interval scaled by the equipped
## pink_stone level; stops it entirely when no pink_stone is equipped.
func _restart_loving_timer() -> void:
	if _loving_timer == null:
		return
	var lvl := level_for_bonus("loving_messages")
	if lvl <= 0:
		_loving_timer.stop()
		return
	## Level 1 -> base interval; level 10 -> min interval (linear).
	var t := LOVING_MESSAGE_BASE_INTERVAL
	if MAX_LEVEL > 1:
		t = LOVING_MESSAGE_BASE_INTERVAL + (LOVING_MESSAGE_MIN_INTERVAL - LOVING_MESSAGE_BASE_INTERVAL) \
			* float(lvl - 1) / float(MAX_LEVEL - 1)
	_loving_timer.wait_time = maxf(t, LOVING_MESSAGE_MIN_INTERVAL)
	_loving_timer.start()


func _on_loving_tick() -> void:
	if not loving_messages_active():
		return
	if get_node_or_null("/root/GameNotification") == null:
		return
	var msg := _random_loving_message()
	if msg != "":
		GameNotification.show_message("💗 A Loving Note", msg)


## Pulls a random affirmation from the Business District's message pool (shared
## source of warm messages), with a small built-in fallback.
func _random_loving_message() -> String:
	var pool: Array = []
	if get_node_or_null("/root/BusinessDistrict") != null:
		pool = BusinessDistrict.VALENTINE_MESSAGES
	if pool.is_empty():
		pool = [
			"You're doing better than you think. Keep going.",
			"Take a breath — you've earned a little rest.",
			"Someone, somewhere, is glad you exist today.",
		]
	return str(pool[randi() % pool.size()])


## ── Level / magnitude helpers ────────────────────────────────────

## Bonus level (0..10) for a given held count. 0 means "below level 1" (no bonus).
func level_for_count(count: int) -> int:
	var lvl := 0
	for i in range(COUNT_THRESHOLDS.size()):
		if count >= COUNT_THRESHOLDS[i]:
			lvl = i + 1
		else:
			break
	return lvl


## Bonus PERCENT for a level (0 at level 0; linear BONUS_MIN_PCT..BONUS_MAX_PCT
## across levels 1..10).
func pct_for_level(level: int) -> float:
	if level <= 0:
		return 0.0
	var l := clampi(level, 1, MAX_LEVEL)
	if MAX_LEVEL <= 1:
		return BONUS_MAX_PCT
	return BONUS_MIN_PCT + (BONUS_MAX_PCT - BONUS_MIN_PCT) * float(l - 1) / float(MAX_LEVEL - 1)


## Bonus fraction (pct/100) for a level. e.g. level 10 -> 0.25.
func fraction_for_level(level: int) -> float:
	return pct_for_level(level) / 100.0


## ── Core resolution ──────────────────────────────────────────────

## For a given bonus id, returns the SUMMED fraction across all equipped slots
## whose item carries that bonus (each scaled by its own held count). 0.0 if
## none equipped grant it. PlayerData must be available.
func fraction_for_bonus(bonus_id: String) -> float:
	if get_node_or_null("/root/PlayerData") == null:
		return 0.0
	var total := 0.0
	for slot in ["ring", "necklace", "misc"]:
		var item_id := str(PlayerData.equipped_jewelry()[slot])
		if item_id == "":
			continue
		var def := PlayerData.get_jewelry_def(item_id)
		if str(def.get("bonus", "")) != bonus_id:
			continue
		var count := PlayerData.get_jewelry_count(item_id)
		if count <= 0:
			continue
		total += fraction_for_level(level_for_count(count))
	return total


## The combined LEVEL for a bonus id (max level among equipped items granting it)
## — for display. 0 if none.
func level_for_bonus(bonus_id: String) -> int:
	if get_node_or_null("/root/PlayerData") == null:
		return 0
	var best := 0
	for slot in ["ring", "necklace", "misc"]:
		var item_id := str(PlayerData.equipped_jewelry()[slot])
		if item_id == "":
			continue
		var def := PlayerData.get_jewelry_def(item_id)
		if str(def.get("bonus", "")) != bonus_id:
			continue
		best = maxi(best, level_for_count(PlayerData.get_jewelry_count(item_id)))
	return best


## ── Convenience accessors for the game systems (Task 12b) ────────

## Multiplier (>= 1.0) applied to COIN from sales: gold (all_sell_value) +
## emerald (coin_gain) stack additively.
func sell_value_multiplier() -> float:
	return 1.0 + fraction_for_bonus("all_sell_value") + fraction_for_bonus("coin_gain")


## Multiplier (>= 1.0) for XP gains (violet_stone).
func xp_multiplier() -> float:
	return 1.0 + fraction_for_bonus("xp_gain")


## Multiplier (>= 1.0) for the daily bonus (black_pearl).
func daily_bonus_multiplier() -> float:
	return 1.0 + fraction_for_bonus("daily_bonus")


## Crop-growth TIME multiplier (<= 1.0; lower = faster) for diamond growth_speed.
## A 25% bonus means 25% faster -> time * (1 - 0.25) = 0.75.
func growth_time_multiplier() -> float:
	return maxf(1.0 - fraction_for_bonus("growth_speed"), 0.05)


## Equivalent Luck LEVEL contribution from the ruby "rarer_gems" bonus, mapped
## onto the Luck autoload's 1..20 scale. Level 10 jewelry -> a strong but not max
## Luck push. Returns an ADDITIVE luck amount (0 if no ruby equipped).
func rarer_gems_luck_bonus() -> int:
	## Map the ruby bonus level (0..10) to +0..+10 luck.
	return level_for_bonus("rarer_gems")


## True if a pink_stone "loving_messages" bonus is active (any level).
func loving_messages_active() -> bool:
	return level_for_bonus("loving_messages") > 0


## Chest-luck additive amount (blue_stone), mapped like rarer_gems (0..10).
func chest_luck_bonus() -> int:
	return level_for_bonus("chest_luck")


## ── Effective Luck for roll sites (combines base Luck + jewelry) ─────────────
## The Luck autoload is clamped to [1,20]. Base luck is 1 unless something sets
## it; the ruby/blue_stone jewelry ADD to it. These return an override_luck value
## to pass into Luck.biased_weights / Luck.adjusted_odds at the roll site.

func _base_luck() -> int:
	if get_node_or_null("/root/Luck") != null:
		return Luck.get_luck()
	return 1


## Effective luck for GEM rarity rolls (base + ruby "rarer_gems" level).
func gem_roll_luck() -> int:
	return clampi(_base_luck() + rarer_gems_luck_bonus(), 1, 20)


## Effective luck for CHEST reward rolls (base + blue_stone "chest_luck" level).
func chest_roll_luck() -> int:
	return clampi(_base_luck() + chest_luck_bonus(), 1, 20)


## ── Horse effects (Task 11c) ─────────────────────────────────────
## These jewelry items do DOUBLE DUTY: they keep their economy bonus (above) AND
## grant a horse effect while equipped. The horse effect is count-scaled by the
## SAME level curve. Each is keyed by the specific jewelry ITEM ID (not the
## generic `bonus` field, which still names the economy effect).
##
##   emerald_necklace    -> across-the-board race-stat % (speed+endurance+life)
##   pink_stone_necklace -> life_cap % (effective max life, capped at 200)
##   violet_stone_ring   -> SPEED training-gain boost (post-cap)
##   blue_stone_necklace -> ENDURANCE training-gain boost (post-cap)
##   black_pearl_necklace-> GROOM training-gain boost (post-cap)
##
## The emerald/pink buffs are a PERSISTENT effective-stats layer applied to ALL
## horses in the stable while equipped (base stats in the DB are untouched); the
## training boosts multiply the session gain the server applies. All reverse the
## moment the jewelry is unequipped or the held count hits 0.

## Jewelry id -> owned-count-scaled fraction while equipped (0.0 if not equipped
## or count 0). Direct by-id lookup across the three slots.
func _horse_fraction_for_item(item_id: String) -> float:
	if get_node_or_null("/root/PlayerData") == null:
		return 0.0
	for slot in ["ring", "necklace", "misc"]:
		if str(PlayerData.equipped_jewelry()[slot]) != item_id:
			continue
		var count := PlayerData.get_jewelry_count(item_id)
		if count <= 0:
			return 0.0
		return fraction_for_level(level_for_count(count))
	return 0.0


## Across-the-board race-stat multiplier (>= 1.0) from an equipped emerald.
func horse_stat_multiplier() -> float:
	return 1.0 + _horse_fraction_for_item("emerald_necklace")


## Life-cap multiplier (>= 1.0) from an equipped pink stone.
func horse_life_cap_multiplier() -> float:
	return 1.0 + _horse_fraction_for_item("pink_stone_necklace")


## Owned-count LEVEL (0..10) of the emerald across-the-board horse buff.
func horse_stat_level() -> int:
	return level_for_count(PlayerData.get_jewelry_count("emerald_necklace")) \
		if _horse_fraction_for_item("emerald_necklace") > 0.0 else 0


## Owned-count LEVEL (0..10) of the pink life-cap buff.
func horse_life_cap_level() -> int:
	return level_for_count(PlayerData.get_jewelry_count("pink_stone_necklace")) \
		if _horse_fraction_for_item("pink_stone_necklace") > 0.0 else 0


## Training-gain multiplier (>= 1.0) for a training KIND, from the equipped
## kind-specific jewelry (violet=sprint/speed, blue=hurdle/endurance,
## black=groom). Applied AFTER the server's session cap, so it can push a single
## session's gain above the base cap (the hard stat ceiling still clamps).
func horse_training_multiplier(kind: String) -> float:
	match kind:
		"sprint": return 1.0 + _horse_fraction_for_item("violet_stone_ring")
		"hurdle": return 1.0 + _horse_fraction_for_item("blue_stone_necklace")
		"groom":  return 1.0 + _horse_fraction_for_item("black_pearl_necklace")
		_:        return 1.0


## ── Double crop yield (blue_stone_necklace) ─────────────────────
## When the Blue Stone Necklace is equipped, each crop harvest has a chance to
## yield TWO crops instead of one. Chance = the equipped necklace's bonus
## fraction (1%..25% at level 1..10, scaling with how many you hold).

## Probability (0.0..0.25) of doubling one crop harvest. 0 if not equipped.
func double_crop_chance() -> float:
	return _horse_fraction_for_item("blue_stone_necklace")
