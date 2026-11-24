extends SceneTree

## Tests for Task 12a: equip slots (PlayerData) + the JewelryBonus resolver
## (count->level thresholds, 1%..25% curve, slot validation, no-duplicates,
## stacking across slots, prune-on-sellout).
##
##   godot --headless --script tests/test_jewelry_bonus.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" Jewelry Bonus / Equipment Tests")
	print("========================================\n")

	var pd = root.get_node_or_null("PlayerData")
	var jb = root.get_node_or_null("JewelryBonus")
	if pd == null or jb == null:
		printerr("[FAIL] PlayerData or JewelryBonus autoload not found!")
		quit(1)
		return true

	## Clean slate for the test (restore at end).
	var saved_jewelry = pd.jewelry.duplicate()
	var saved_ring = pd.equipped_ring
	var saved_neck = pd.equipped_necklace
	var saved_misc = pd.equipped_misc
	pd.jewelry.clear()
	pd.equipped_ring = ""; pd.equipped_necklace = ""; pd.equipped_misc = ""

	_test_level_curve(jb)
	_test_slot_validation(pd)
	_test_no_duplicates(pd)
	_test_stacking(pd, jb)
	_test_prune(pd)
	_test_luck_helpers(pd, jb)
	_test_gold_panning_bias()

	## Restore.
	pd.jewelry = saved_jewelry
	pd.equipped_ring = saved_ring
	pd.equipped_necklace = saved_neck
	pd.equipped_misc = saved_misc

	print("\n----------------------------------------")
	print(" Results: %d passed, %d failed, %d total" % [_passed, _failed, _run])
	print("----------------------------------------\n")
	quit(1 if _failed > 0 else 0)
	return true


func _ok(cond: bool, desc: String) -> void:
	_run += 1
	if cond:
		_passed += 1
		print("  ✓ %s" % desc)
	else:
		_failed += 1
		print("  ✗ FAIL: %s" % desc)


func _eq(actual, expected, desc: String) -> void:
	_ok(actual == expected, "%s  (got %s, expected %s)" % [desc, str(actual), str(expected)])


func _approx(a: float, b: float, desc: String) -> void:
	_ok(abs(a - b) < 0.0001, "%s  (got %.4f, expected %.4f)" % [desc, a, b])


func _test_level_curve(jb) -> void:
	print("Count -> level thresholds + pct curve:")
	_eq(jb.level_for_count(0), 0, "count 0 -> level 0")
	_eq(jb.level_for_count(1), 1, "count 1 -> level 1")
	_eq(jb.level_for_count(9), 1, "count 9 -> level 1")
	_eq(jb.level_for_count(10), 2, "count 10 -> level 2")
	_eq(jb.level_for_count(999), 3, "count 999 -> level 3")
	_eq(jb.level_for_count(1000), 4, "count 1000 -> level 4")
	_eq(jb.level_for_count(999999), 9, "count 999,999 -> level 9")
	_eq(jb.level_for_count(1000000), 10, "count 1,000,000 -> level 10")
	_eq(jb.level_for_count(50000000), 10, "huge count -> level 10 (capped)")
	## Curve: level 1 = 1%, level 10 = 25%.
	_approx(jb.pct_for_level(1), 1.0, "level 1 == 1%")
	_approx(jb.pct_for_level(10), 25.0, "level 10 == 25%")
	_approx(jb.fraction_for_level(10), 0.25, "level 10 fraction == 0.25")
	_approx(jb.fraction_for_level(0), 0.0, "level 0 fraction == 0")


func _test_slot_validation(pd) -> void:
	print("Slot validation (ring/necklace/misc):")
	pd.jewelry["emerald_necklace"] = 5
	pd.jewelry["ruby_ring"] = 5
	## emerald_necklace is a necklace: can't go in ring slot.
	_eq(pd.equip_jewelry("ring", "emerald_necklace"), false, "necklace rejected from ring slot")
	## ruby_ring is a ring: can't go in necklace slot.
	_eq(pd.equip_jewelry("necklace", "ruby_ring"), false, "ring rejected from necklace slot")
	## Correct slots work.
	_eq(pd.equip_jewelry("ring", "ruby_ring"), true, "ring into ring slot ok")
	_eq(pd.equip_jewelry("necklace", "emerald_necklace"), true, "necklace into necklace slot ok")
	## misc takes either.
	pd.jewelry["gold_ring"] = 3
	_eq(pd.equip_jewelry("misc", "gold_ring"), true, "ring into misc slot ok")
	## Can't equip something you don't own.
	_eq(pd.equip_jewelry("ring", "diamond_ring"), false, "unowned item rejected")
	## Clear a slot.
	_eq(pd.equip_jewelry("misc", ""), true, "clear misc slot ok")
	_eq(pd.equipped_misc, "", "misc slot cleared")


func _test_no_duplicates(pd) -> void:
	print("No-duplicate across slots:")
	pd.equipped_ring = ""; pd.equipped_necklace = ""; pd.equipped_misc = ""
	pd.jewelry["ruby_ring"] = 5
	pd.equip_jewelry("ring", "ruby_ring")
	## Equipping the same item in misc removes it from ring.
	pd.equip_jewelry("misc", "ruby_ring")
	_eq(pd.equipped_misc, "ruby_ring", "ruby_ring now in misc")
	_eq(pd.equipped_ring, "", "ruby_ring removed from ring (no dup)")


func _test_stacking(pd, jb) -> void:
	print("Bonuses stack across slots + scale by held count:")
	pd.equipped_ring = ""; pd.equipped_necklace = ""; pd.equipped_misc = ""
	pd.jewelry.clear()
	## gold_ring (all_sell_value) at level 10 (1M) + emerald_necklace (coin_gain)
	## at level 1 (1). sell_value_multiplier = 1 + 0.25 + 0.01 = 1.26.
	pd.jewelry["gold_ring"] = 1000000
	pd.jewelry["emerald_necklace"] = 1
	pd.equip_jewelry("ring", "gold_ring")
	pd.equip_jewelry("necklace", "emerald_necklace")
	_approx(jb.fraction_for_bonus("all_sell_value"), 0.25, "gold all_sell_value @L10 = 0.25")
	_approx(jb.fraction_for_bonus("coin_gain"), 0.01, "emerald coin_gain @L1 = 0.01")
	_approx(jb.sell_value_multiplier(), 1.26, "sell multiplier stacks (1.26)")
	## XP/daily unaffected (nothing equipped grants them).
	_approx(jb.xp_multiplier(), 1.0, "xp multiplier 1.0 (none equipped)")
	## Equip ruby_ring in misc for rarer_gems luck.
	pd.jewelry["ruby_ring"] = 1000000
	pd.equip_jewelry("misc", "ruby_ring")
	_eq(jb.rarer_gems_luck_bonus(), 10, "ruby @L10 -> +10 luck")
	## growth_time_multiplier: no diamond equipped -> 1.0 (no speedup).
	_approx(jb.growth_time_multiplier(), 1.0, "growth time 1.0 (no diamond)")


func _test_prune(pd) -> void:
	print("prune_equipped_jewelry clears sold-out slots:")
	pd.equipped_ring = ""; pd.equipped_necklace = ""; pd.equipped_misc = ""
	pd.jewelry.clear()
	pd.jewelry["gold_ring"] = 2
	pd.equip_jewelry("ring", "gold_ring")
	## Simulate selling all of them.
	pd.jewelry.erase("gold_ring")
	pd.prune_equipped_jewelry()
	_eq(pd.equipped_ring, "", "sold-out gold_ring auto-unequipped")


func _test_luck_helpers(pd, jb) -> void:
	print("Luck helpers (ruby gem luck + blue_stone chest luck):")
	pd.equipped_ring = ""; pd.equipped_necklace = ""; pd.equipped_misc = ""
	pd.jewelry.clear()
	## No jewelry -> base luck (1).
	_eq(jb.gem_roll_luck(), 1, "gem_roll_luck base == 1 (no ruby)")
	_eq(jb.chest_roll_luck(), 1, "chest_roll_luck base == 1 (no blue_stone)")
	## Ruby @L10 -> gem luck 1 + 10 = 11.
	pd.jewelry["ruby_ring"] = 1000000
	pd.equip_jewelry("ring", "ruby_ring")
	_eq(jb.gem_roll_luck(), 11, "ruby @L10 -> gem_roll_luck 11")
	_eq(jb.chest_roll_luck(), 1, "chest_roll_luck still 1 (ruby doesn't help chests)")
	## Blue_stone @L10 -> chest luck 11.
	pd.jewelry["blue_stone_necklace"] = 1000000
	pd.equip_jewelry("necklace", "blue_stone_necklace")
	_eq(jb.chest_roll_luck(), 11, "blue_stone @L10 -> chest_roll_luck 11")


func _test_gold_panning_bias() -> void:
	print("HaulGenerator.pick_gem_type biases toward rarer gems with luck:")
	var hg = load("res://scripts/gold_panning/haul_generator.gd")
	## Rarity rank of a gem id (higher = rarer).
	var order := ["gold", "blue_stone", "pink_stone", "violet_stone",
		"black_pearl", "emerald", "ruby", "diamond"]
	var N := 4000
	var sum_low := 0
	var sum_high := 0
	for i in range(N):
		sum_low += order.find(hg.pick_gem_type(1))     ## no luck
		sum_high += order.find(hg.pick_gem_type(20))    ## max luck
	var avg_low := float(sum_low) / N
	var avg_high := float(sum_high) / N
	## With luck, the average rarity rank should be meaningfully higher.
	_ok(avg_high > avg_low + 0.5,
		"avg rarity rank rises with luck (low %.2f -> high %.2f)" % [avg_low, avg_high])
