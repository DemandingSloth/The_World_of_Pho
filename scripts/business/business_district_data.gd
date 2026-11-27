extends Node

## Autoload: BusinessDistrict
##
## LOCAL-ONLY late-game feature. The player runs "shops"; depositing accepted
## items is a PERMANENT SINK that fills a shop toward level thresholds (0..15).
## Reaching levels grants cumulative gameplay bonuses. Up to 6 non-maxed shops
## are active at once; a maxed (L15) shop's bonus becomes permanent and no longer
## uses a slot. Switching a slot locks it for 72h.
##
## HARD RULE: this feature NEVER touches Supabase / the online marketplace /
## tokens. It only reads/writes the LOCAL save and applies LOCAL bonuses. Deposits
## use PlayerData's LOCAL market bridge (market_count_owned / market_remove_owned).
##
## Milestone 1 = state + catalog + level math + slots + deposits (no UI, no
## bonus wiring yet).

const SAVE_PATH := "user://business_save.cfg"

const SLOT_COUNT := 6
const MAX_LEVEL := 15
const SWITCH_COOLDOWN_SECONDS := 72.0 * 3600.0  ## 72 hours

## Deposits required to REACH each level (index 0 => level 1, ... index 14 => L15).
const THRESHOLDS: Array[int] = [
	50_000, 150_000, 300_000, 650_000, 1_400_000, 3_000_000, 6_500_000,
	14_000_000, 30_000_000, 65_000_000, 140_000_000, 300_000_000,
	550_000_000, 750_000_000, 1_000_000_000,
]

## Shop catalog. accepted_keys are canonical ItemKeyRegistry keys (deposits map
## 1:1 to the local PlayerData market bridge). `accepts_all_seeds` shops accept
## every seed:* key (resolved at runtime). `rate` meaning depends on bonus_type
## (see design.md); Milestone 2 consumes it.
const SHOPS: Array[Dictionary] = [
	{ "id": "flower",    "name": "Flower Shop",          "sprite": "res://Assets/business_district/flower_shop.png",
	  "bonus_type": "crop_sell",      "rate": 0.03, "desc": "Sunflowers sell for more.",
	  "accepted_keys": ["crop:sunflower"] },
	{ "id": "farmer",    "name": "Farmer's Stand",       "sprite": "res://Assets/business_district/farmers_stand.png",
	  "bonus_type": "crop_sell",      "rate": 0.03, "desc": "Vegetables sell for more.",
	  "accepted_keys": ["crop:beans", "crop:cucumbers", "crop:peppers", "crop:cauliflower", "crop:squash"] },
	{ "id": "smoothie",  "name": "Smoothie Shop",        "sprite": "res://Assets/business_district/smoothie_shop.png",
	  "bonus_type": "fruit_sell",     "rate": 0.03, "desc": "Fruit sells for more.",
	  "accepted_keys": ["crop:grapes", "crop:pineapple", "crop:watermelon", "fruit:plum", "fruit:apple", "fruit:banana", "fruit:coconut"] },
	{ "id": "lemonaid",  "name": "Lemonaid Stand",       "sprite": "res://Assets/business_district/lemonaid_stand.png",
	  "bonus_type": "fruit_sell",     "rate": 0.04, "desc": "Lemons sell for more.",
	  "accepted_keys": ["fruit:lemon"] },
	{ "id": "seed",      "name": "Seed Shop",            "sprite": "res://Assets/business_district/seed_shop.png",
	  "bonus_type": "harvest_yield",  "rate": 0.0,  "desc": "Plants yield extra crops per harvest.",
	  "accepted_keys": [], "accepts_all_seeds": true },
	{ "id": "miners",    "name": "Miners Source",        "sprite": "res://Assets/business_district/miners_source.png",
	  "bonus_type": "tool_price",     "rate": 0.02, "desc": "Tools cost less to buy.",
	  "accepted_keys": ["tool:shovel", "tool:scythe", "tool:magnifying_glass"] },
	{ "id": "jewelers",  "name": "Jewelers",             "sprite": "res://Assets/business_district/jewler.png",
	  "bonus_type": "saw_speed",      "rate": 0.02, "desc": "The Workshop saw cuts faster.",
	  "accepted_keys": ["polished:blue_stone", "polished:violet_stone", "polished:ruby", "polished:diamond"] },
	{ "id": "lucky",     "name": "Lucky's Lucky Loot",   "sprite": "res://Assets/business_district/luckys_lucky_loot.png",
	  "bonus_type": "luck",           "rate": 0.0,  "desc": "Raises your Luck (better random rewards).",
	  "accepted_keys": ["polished:emerald"] },
	{ "id": "blackpearl","name": "The Black Pearl",      "sprite": "res://Assets/business_district/the_black_pearl.png",
	  "bonus_type": "mine_find",      "rate": 0.03, "desc": "Find more in the Deep Mines.",
	  "accepted_keys": ["polished:black_pearl"] },
	{ "id": "valentine", "name": "The Valentine's Valor","sprite": "res://Assets/business_district/valentines_valor.png",
	  "bonus_type": "notifications",  "rate": 0.0,  "desc": "Adds uplifting notification messages.",
	  "accepted_keys": ["polished:pink_stone"] },
	{ "id": "carpenter", "name": "Carpenter's Shop",     "sprite": "res://Assets/business_district/carpenters_shop.png",
	  "bonus_type": "orchard_growth", "rate": 0.02, "desc": "Orchard trees grow faster.",
	  "accepted_keys": ["resource:wood", "resource:stick"] },
	{ "id": "carl",      "name": "Carl's Construction",  "sprite": "res://Assets/business_district/carls_construction.png",
	  "bonus_type": "market_stock",   "rate": 0.05, "desc": "Marketplace restocks more items.",
	  "accepted_keys": ["resource:iron_bar", "resource:copper_ingot"] },
	{ "id": "bank",      "name": "The Bank of Pho",      "sprite": "res://Assets/business_district/bank_of_pho.png",
	  "bonus_type": "coin_reward",    "rate": 0.04, "desc": "Coin rewards are increased.",
	  "accepted_keys": ["resource:gold_ingot"] },
]

signal business_updated

## ── State (LOCAL, saved to SAVE_PATH) ───────────────────────────
## shop_id -> total deposit count (int). Level is derived, not stored.
var deposits: Dictionary = {}
## shop_id -> { item_key -> count } for the management panel's per-item list.
var deposits_by_item: Dictionary = {}
## Which shop occupies each of the 6 slots ("" = empty).
var slots: Array = ["", "", "", "", "", ""]
## Unix time each slot was last (re)assigned (0.0 = never). Drives the 72h lock.
var slot_changed_at: Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]


func _ready() -> void:
	load_data()
	## Keep global Luck in sync with Lucky's Lucky Loot (the only luck source).
	apply_luck()
	business_updated.connect(apply_luck)


## ── Catalog helpers ─────────────────────────────────────────────

func get_shop_def(shop_id: String) -> Dictionary:
	for s in SHOPS:
		if s["id"] == shop_id:
			return s
	return {}

## Canonical keys a shop accepts. For seed shops, resolves to every seed:* key.
func accepted_keys_for(shop_id: String) -> Array:
	var def := get_shop_def(shop_id)
	if def.is_empty():
		return []
	if bool(def.get("accepts_all_seeds", false)):
		var keys: Array = []
		for k in ItemKeyRegistry.all_keys():
			if ItemKeyRegistry.category_of(k) == "seed":
				keys.append(k)
		return keys
	return (def.get("accepted_keys", []) as Array).duplicate()


## ── Level math ──────────────────────────────────────────────────

## Total deposits made into a shop.
func get_deposit_count(shop_id: String) -> int:
	return int(deposits.get(shop_id, 0))

## Current level 0..15 for a deposit count.
func level_for(count: int) -> int:
	var lvl := 0
	for t in THRESHOLDS:
		if count >= t:
			lvl += 1
		else:
			break
	return lvl

## Convenience: a shop's current level.
func get_level(shop_id: String) -> int:
	return level_for(get_deposit_count(shop_id))

## True once a shop hits the max level (bonus becomes permanent).
func is_maxed(shop_id: String) -> bool:
	return get_level(shop_id) >= MAX_LEVEL

## Progress info toward the next level:
##   { level, is_max, floor, next, into, span, frac }
## floor = threshold of current level (0 at L0), next = threshold of next level,
## into = deposits past floor, span = next-floor, frac = into/span (1.0 at max).
func progress_to_next(shop_id: String) -> Dictionary:
	var count := get_deposit_count(shop_id)
	var lvl := level_for(count)
	if lvl >= MAX_LEVEL:
		return { "level": lvl, "is_max": true, "floor": THRESHOLDS[MAX_LEVEL - 1],
			"next": THRESHOLDS[MAX_LEVEL - 1], "into": 0, "span": 0, "frac": 1.0 }
	var floor_t := 0 if lvl == 0 else THRESHOLDS[lvl - 1]
	var next_t := THRESHOLDS[lvl]
	var into := count - floor_t
	var span := next_t - floor_t
	var frac := 0.0 if span <= 0 else clampf(float(into) / float(span), 0.0, 1.0)
	return { "level": lvl, "is_max": false, "floor": floor_t, "next": next_t,
		"into": into, "span": span, "frac": frac }


## ── Active / slot logic ─────────────────────────────────────────

## A shop's bonus applies if it's assigned to a slot OR it's maxed (permanent,
## even if later unassigned).
func is_bonus_active(shop_id: String) -> bool:
	return is_maxed(shop_id) or _slot_of(shop_id) != -1

## Slot index a shop occupies, or -1.
func _slot_of(shop_id: String) -> int:
	return slots.find(shop_id)

## Number of NON-maxed shops currently occupying slots (these count against the
## 6-slot limit; maxed shops are free).
func active_nonmaxed_count() -> int:
	var n := 0
	for sid in slots:
		if sid != "" and not is_maxed(sid):
			n += 1
	return n

## Effective bonus capacity: base 6 plus one per maxed shop (maxed shops don't
## consume the base slots).
func effective_capacity() -> int:
	var maxed := 0
	for s in SHOPS:
		if is_maxed(s["id"]):
			maxed += 1
	return SLOT_COUNT + maxed

## Seconds remaining on a slot's 72h switch lock (0.0 = free to change).
func slot_cooldown_remaining(slot: int) -> float:
	if slot < 0 or slot >= SLOT_COUNT:
		return 0.0
	var last := float(slot_changed_at[slot])
	if last <= 0.0:
		return 0.0
	var elapsed := TrustedClock.now() - last
	return maxf(0.0, SWITCH_COOLDOWN_SECONDS - elapsed)

func is_slot_locked(slot: int) -> bool:
	return slot_cooldown_remaining(slot) > 0.0

## Assigns `shop_id` to `slot` (or clears it with ""). Returns { ok } or
## { ok=false, error }. Enforces: valid slot, not locked, shop not already in
## another slot, and the 6 non-maxed limit.
##   error codes: bad_slot, slot_locked, unknown_shop, already_assigned,
##                slot_limit_reached
func assign_shop(slot: int, shop_id: String) -> Dictionary:
	if slot < 0 or slot >= SLOT_COUNT:
		return { "ok": false, "error": "bad_slot" }
	if is_slot_locked(slot):
		return { "ok": false, "error": "slot_locked" }

	## Clearing a slot.
	if shop_id == "":
		if slots[slot] != "":
			slots[slot] = ""
			slot_changed_at[slot] = TrustedClock.now()
			save_data()
			business_updated.emit()
		return { "ok": true }

	if get_shop_def(shop_id).is_empty():
		return { "ok": false, "error": "unknown_shop" }
	## No duplicates across slots.
	var existing := _slot_of(shop_id)
	if existing != -1 and existing != slot:
		return { "ok": false, "error": "already_assigned" }
	if existing == slot:
		return { "ok": true }  ## no change

	## Enforce the non-maxed active limit. Assigning a non-maxed shop into a slot
	## that currently holds nothing/a maxed shop would add a non-maxed occupant.
	var current := str(slots[slot])
	var current_is_nonmaxed := current != "" and not is_maxed(current)
	var adding_nonmaxed := not is_maxed(shop_id)
	if adding_nonmaxed and not current_is_nonmaxed:
		if active_nonmaxed_count() >= SLOT_COUNT:
			return { "ok": false, "error": "slot_limit_reached" }

	slots[slot] = shop_id
	slot_changed_at[slot] = TrustedClock.now()
	save_data()
	business_updated.emit()
	return { "ok": true }


## ── Deposits (permanent sink) ───────────────────────────────────

## Deposits up to `qty` of `item_key` into `shop_id`. Clamps to what the player
## holds locally, consumes it via the LOCAL market bridge (no coins/XP/tokens),
## and adds the count to the shop's deposit total. Returns { ok, deposited } or
## { ok=false, error }.
##   error codes: unknown_shop, item_not_accepted, invalid_qty, none_on_hand
func deposit(shop_id: String, item_key: String, qty: int) -> Dictionary:
	if get_shop_def(shop_id).is_empty():
		return { "ok": false, "error": "unknown_shop" }
	if not accepted_keys_for(shop_id).has(item_key):
		return { "ok": false, "error": "item_not_accepted" }
	if qty <= 0:
		return { "ok": false, "error": "invalid_qty" }

	## Clamp to what the player actually holds (LOCAL bridge).
	var on_hand := PlayerData.market_count_owned(item_key)
	var amount := mini(qty, on_hand)
	if amount <= 0:
		return { "ok": false, "error": "none_on_hand" }

	## Consume locally (permanent sink — no currency granted).
	if not PlayerData.market_remove_owned(item_key, amount):
		return { "ok": false, "error": "none_on_hand" }

	deposits[shop_id] = get_deposit_count(shop_id) + amount
	## Track the per-item breakdown for the management panel's list.
	var by_item: Dictionary = deposits_by_item.get(shop_id, {})
	by_item[item_key] = int(by_item.get(item_key, 0)) + amount
	deposits_by_item[shop_id] = by_item
	save_data()
	business_updated.emit()
	## Mission tracking: depositing items (Business District category mission).
	if get_node_or_null("/root/MissionBoard") != null:
		MissionBoard.on_business_deposit(amount)
	## Achievements: total deposited + shops maxed.
	if get_node_or_null("/root/Achievements") != null:
		Achievements.record_business_progress()
	return { "ok": true, "deposited": amount }

## Aggregate deposit total for a shop (drives level math).
func get_deposited_total(shop_id: String) -> int:
	return get_deposit_count(shop_id)

## Per-item deposited counts for a shop's management panel:
## { item_key -> count }, only items the player has actually deposited.
func get_deposits_by_item(shop_id: String) -> Dictionary:
	return (deposits_by_item.get(shop_id, {}) as Dictionary).duplicate()


## ── Persistence (LOCAL ONLY) ────────────────────────────────────

func save_data() -> void:
	var config := ConfigFile.new()
	config.set_value("business", "deposits", deposits)
	config.set_value("business", "deposits_by_item", deposits_by_item)
	config.set_value("business", "slots", slots)
	config.set_value("business", "slot_changed_at", slot_changed_at)
	config.save(SAVE_PATH)

func load_data() -> void:
	deposits = {}
	deposits_by_item = {}
	slots = ["", "", "", "", "", ""]
	slot_changed_at = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return  ## fresh player — defaults stand

	var d = config.get_value("business", "deposits", {})
	if d is Dictionary:
		for k in d:
			deposits[str(k)] = int(d[k])

	var di = config.get_value("business", "deposits_by_item", {})
	if di is Dictionary:
		for sid in di:
			var inner = di[sid]
			if inner is Dictionary:
				var m: Dictionary = {}
				for ik in inner:
					m[str(ik)] = int(inner[ik])
				deposits_by_item[str(sid)] = m

	var s = config.get_value("business", "slots", [])
	if s is Array:
		for i in range(mini(s.size(), SLOT_COUNT)):
			slots[i] = str(s[i])

	var t = config.get_value("business", "slot_changed_at", [])
	if t is Array:
		for i in range(mini(t.size(), SLOT_COUNT)):
			slot_changed_at[i] = float(t[i])


## ════════════════════════════════════════════════════════════════
## Milestone 2 — Bonus getters
## ════════════════════════════════════════════════════════════════
## Every getter returns a NEUTRAL value (×1.0 multiplier, +0 bonus, luck 1) when
## the relevant shop is not active/maxed, so callers can wire these in safely
## before any shop is unlocked. All LOCAL — no online state touched.

## Effective bonus level for a shop: its deposit level IF its bonus is active
## (assigned to a slot) or maxed (permanent); otherwise 0 (neutral).
func _bonus_level(shop_id: String) -> int:
	if not is_bonus_active(shop_id):
		return 0
	return get_level(shop_id)

## Cumulative fractional bonus for a shop: rate × active level.
## e.g. rate 0.03 at level 5 → 0.15 (a +15% or −15% swing depending on use).
func _bonus_frac(shop_id: String) -> float:
	var def := get_shop_def(shop_id)
	if def.is_empty():
		return 0.0
	return float(def.get("rate", 0.0)) * float(_bonus_level(shop_id))


## ── Sell-price multipliers (increase) ───────────────────────────

## Multiplier for a crop's sell value. Sunflower → Flower Shop; the five
## vegetables → Farmer's Stand; grapes/pineapple/watermelon → Smoothie Shop.
## Returns 1.0 when no relevant shop is active.
func crop_sell_multiplier(crop_id: String) -> float:
	var key := "crop:" + crop_id
	var frac := 0.0
	for s in SHOPS:
		if s["bonus_type"] == "crop_sell" or s["bonus_type"] == "fruit_sell":
			if (s.get("accepted_keys", []) as Array).has(key):
				frac += _bonus_frac(s["id"])
	return 1.0 + frac

## Multiplier for a fruit's sell value (ITEM_DEFS fruit id, e.g. "plum",
## "lemon"). Smoothie Shop (plum/apple/banana/coconut) and Lemonaid (lemon).
func fruit_sell_multiplier(fruit_id: String) -> float:
	var key := "fruit:" + fruit_id
	var frac := 0.0
	for s in SHOPS:
		if s["bonus_type"] == "fruit_sell":
			if (s.get("accepted_keys", []) as Array).has(key):
				frac += _bonus_frac(s["id"])
	return 1.0 + frac


## ── Reduction multipliers (make things cheaper/faster) ──────────

## Tool shop price multiplier for a tool id (Miners Source). Reduces price by
## rate×level, floored at 0.5 (−50% max) so prices never go absurd.
func tool_price_multiplier(tool_id: int) -> float:
	var slug: String = ItemKeyRegistry.TOOL_SLUGS.get(tool_id, "")
	if slug == "":
		return 1.0
	var key := "tool:" + slug
	var frac := 0.0
	for s in SHOPS:
		if s["bonus_type"] == "tool_price" and (s.get("accepted_keys", []) as Array).has(key):
			frac += _bonus_frac(s["id"])
	return clampf(1.0 - frac, 0.5, 1.0)

## Saw cut-time multiplier (Jewelers). Reduces by rate×level, floored at 0.5.
## Multiplies with the existing saw_speed prestige multiplicatively.
func saw_speed_multiplier() -> float:
	return clampf(1.0 - _bonus_frac("jewelers"), 0.5, 1.0)

## Orchard growth-time multiplier (Carpenter's Shop). Reduces by rate×level,
## floored at 0.5.
func orchard_growth_multiplier() -> float:
	return clampf(1.0 - _bonus_frac("carpenter"), 0.5, 1.0)


## ── Other multipliers / bonuses ─────────────────────────────────

## Deep-mine find-rate multiplier (The Black Pearl). Increases by rate×level.
func mine_find_multiplier() -> float:
	return 1.0 + _bonus_frac("blackpearl")

## Coin-reward multiplier (The Bank of Pho). Increases by rate×level.
func coin_reward_multiplier() -> float:
	return 1.0 + _bonus_frac("bank")

## Market shop-stock multiplier (Carl's Construction). Increases pool size by
## rate×level.
func market_stock_multiplier() -> float:
	return 1.0 + _bonus_frac("carl")

## Extra harvest units per harvest (Seed Shop). "Plants produce multiple per
## harvest": grows with level as 1 + floor(level/3) extra at higher levels.
## Returns 0 when the Seed Shop isn't active. `plant_type` reserved for future
## per-plant tuning (currently uniform).
func harvest_yield_bonus(_plant_type: int = -1) -> int:
	var lvl := _bonus_level("seed")
	if lvl <= 0:
		return 0
	return 1 + int(lvl / 3)  ## L1-2 → +1, L3-5 → +2, ... L15 → +6


## ── Luck (Lucky's Lucky Loot) ───────────────────────────────────

## Level → luck value. 1 at L0, reaching 20 at L15 with +2 steps spread at
## levels 4, 8, 12 and 15 (deltas otherwise +1).
const LUCK_BY_LEVEL: Array[int] = [
	1, 2, 3, 4, 6, 7, 8, 9, 11, 12, 13, 14, 16, 17, 18, 20,
]  ## index = level 0..15

## The luck value granted by Lucky's Lucky Loot at its ACTIVE level (1 if the
## shop isn't active/maxed).
func current_luck() -> int:
	var lvl := _bonus_level("lucky")
	lvl = clampi(lvl, 0, MAX_LEVEL)
	return LUCK_BY_LEVEL[lvl]

## Pushes the current luck value into the global Luck autoload. Lucky's Lucky
## Loot is the ONLY source of luck, so this fully defines it.
func apply_luck() -> void:
	if get_node_or_null("/root/Luck") != null:
		Luck.set_luck(current_luck())


## ── Valentine's Valor (uplifting notifications) ─────────────────

## One message unlocked per active level (up to 15). Surfaced by the
## notification system (wired in Milestone 4).
const VALENTINE_MESSAGES: Array[String] = [
	"Slow and steady always wins the race, and today, you are moving at the exact right pace.",
	"Take a deep breath, hang onto your favorite branch, and let the rest of the world rush by without you.",
	"There is no rush to bloom; even the slowest creatures eventually reach the highest canopy.",
	"Give yourself permission to pause today. Rest is not falling behind, it is simply catching your breath.",
	"You do not have to move mountains today; just holding your ground is a victory.",
	"Embrace the quiet moments, because the best views in the forest are reserved for those who take their time.",
	"Slowing down doesn't mean stopping; it means you are paying attention to the beauty along the way.",
	"Let your worries hang loose below you, completely out of reach.",
	"Your gentle energy is a soothing balm to a world that is always in a hurry.",
	"There is profound strength in stillness, and you carry it effortlessly.",
	"Take things one branch at a time, trusting that you will get precisely where you need to be.",
	"Wrap yourself in a cozy blanket of patience; you are doing wonderfully just as you are.",
	"A peaceful heart is your superpower, and nobody can rush your inner calm.",
	"Rest as deeply as you need to, knowing tomorrow's trees will still be right where you left them.",
	"You are exactly where you belong, moving through life with a grace all your own.",
]

## Messages unlocked so far (empty if The Valentine's Valor isn't active). One
## message per active level, capped at the 15 available.
func active_valentine_messages() -> Array:
	var lvl := _bonus_level("valentine")
	if lvl <= 0:
		return []
	return VALENTINE_MESSAGES.slice(0, mini(lvl, VALENTINE_MESSAGES.size()))
