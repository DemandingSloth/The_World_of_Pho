extends Node

## Autoload: Luck
##
## Central "luck" stat that biases RANDOM reward outcomes. Luck is a single
## integer, default 1 (neutral — anything × 1 is unchanged), clamped to
## [MIN_LUCK, MAX_LUCK]. The actual source that raises luck (an item, prestige,
## buff, etc.) is a LATER update — for now this just defines the value and the
## math so drop code can call these helpers when we wire it in.
##
## Two effects are supported:
##   1. improve_odds()      — for "1 in N" rarity rolls (e.g. diamond ring).
##                            Higher luck shrinks N proportionally, so the drop
##                            gets more likely.
##   2. biased weights      — for weighted loot tables (e.g. chest rewards).
##                            Higher luck tilts probability toward higher-VALUE
##                            entries without ever removing the low-value ones.
##
## NOTHING IS WIRED IN YET. These are pure helpers + a saved value.

const MIN_LUCK := 1
const MAX_LUCK := 20

signal luck_changed(new_luck: int)

var luck: int = MIN_LUCK

const SAVE_PATH := "user://luck_save.cfg"


func _ready() -> void:
	load_data()


## ── State ───────────────────────────────────────────────────────

## Sets luck, clamped to [MIN_LUCK, MAX_LUCK]. Emits luck_changed + saves when
## the value actually changes.
func set_luck(value: int) -> void:
	var clamped := clampi(value, MIN_LUCK, MAX_LUCK)
	if clamped != luck:
		luck = clamped
		save_data()
		luck_changed.emit(luck)


func get_luck() -> int:
	return luck


## ── Effect 1: rarity odds ("1 in N") ────────────────────────────

## Returns the luck-adjusted denominator for a "1 in base_n" drop.
## Luck divides the denominator: effective_n = round(base_n / luck), floored at
## 1 (can't be better than a guaranteed drop).
##   luck 1  -> base_n         (unchanged)
##   luck 2  -> base_n / 2      (twice as likely)
##   luck 20 -> base_n / 20     (20x as likely)
## e.g. base_n = 25000 -> 25000, 12500, ..., 1250.
func adjusted_odds(base_n: int, override_luck: int = -1) -> int:
	var l := override_luck if override_luck > 0 else luck
	l = clampi(l, MIN_LUCK, MAX_LUCK)
	if base_n <= 1:
		return 1
	return maxi(1, int(round(float(base_n) / float(l))))


## Convenience: rolls a luck-adjusted "1 in base_n" chance. Returns true on a
## hit. Equivalent to `randi() % adjusted_odds(base_n) == 0`.
func roll_odds(base_n: int, override_luck: int = -1) -> bool:
	var n := adjusted_odds(base_n, override_luck)
	if n <= 1:
		return true
	return (randi() % n) == 0


## ── Effect 2: value-biased weighted picks ───────────────────────

## Given parallel arrays of base `weights` and per-entry `values`, returns a new
## weights array biased toward higher-value entries according to luck.
##
## Bias model: each weight is multiplied by (value_ratio ^ exponent), where
##   value_ratio = value / min_value   (>= 1, so cheapest entry is the anchor)
##   exponent    = (luck - 1) * LUCK_BIAS_STRENGTH
## At luck 1 the exponent is 0, so every factor is 1 and the weights are
## unchanged (neutral). As luck rises, higher-value entries gain weight
## super-linearly while low-value entries keep a non-zero share.
##
## Returns float weights (callers can use them directly in a weighted roll; see
## weighted_pick). Arrays must be the same length; mismatches return `weights`.
const LUCK_BIAS_STRENGTH := 0.15

func biased_weights(weights: Array, values: Array, override_luck: int = -1) -> Array:
	if weights.size() != values.size() or weights.is_empty():
		return weights.duplicate()
	var l := override_luck if override_luck > 0 else luck
	l = clampi(l, MIN_LUCK, MAX_LUCK)
	var exponent := float(l - 1) * LUCK_BIAS_STRENGTH

	## Anchor to the smallest positive value so ratios are >= 1.
	var min_val := INF
	for v in values:
		var fv := float(v)
		if fv > 0.0:
			min_val = minf(min_val, fv)
	if min_val == INF or min_val <= 0.0:
		min_val = 1.0

	var out: Array = []
	for i in range(weights.size()):
		var w := float(weights[i])
		var v := maxf(float(values[i]), min_val)
		var ratio := v / min_val
		out.append(w * pow(ratio, exponent))
	return out


## Weighted random index over `weights` (ints or floats). Returns -1 if the
## weights are empty or sum to <= 0. Pure helper (no luck applied here — pass
## biased_weights() output if you want luck to matter).
func weighted_pick(weights: Array) -> int:
	var total := 0.0
	for w in weights:
		total += maxf(float(w), 0.0)
	if total <= 0.0:
		return -1
	var roll := randf() * total
	var cumulative := 0.0
	for i in range(weights.size()):
		cumulative += maxf(float(weights[i]), 0.0)
		if roll < cumulative:
			return i
	return weights.size() - 1  ## fp safety


## Convenience: applies luck bias to (weights, values) then picks an index.
func biased_pick(weights: Array, values: Array, override_luck: int = -1) -> int:
	return weighted_pick(biased_weights(weights, values, override_luck))


## ── Persistence ─────────────────────────────────────────────────

func save_data() -> void:
	var config := ConfigFile.new()
	config.set_value("luck", "value", luck)
	config.save(SAVE_PATH)


func load_data() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		luck = MIN_LUCK
		return
	luck = clampi(int(config.get_value("luck", "value", MIN_LUCK)), MIN_LUCK, MAX_LUCK)
