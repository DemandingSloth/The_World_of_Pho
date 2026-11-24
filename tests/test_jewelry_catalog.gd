extends SceneTree

## Tests for the jewelry catalog (Task 9): the 8 item: entries in ITEM_DEFS, the
## generalized ItemKeyRegistry CAT_ITEM/CAT_FRUIT handling (no longer index-0
## hardcoded), and the PlayerData jewelry storage bridge.
##
##   godot --headless --script tests/test_jewelry_catalog.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0

const EXPECTED_JEWELRY := [
	"diamond_ring", "gold_ring", "blue_stone_necklace", "pink_stone_necklace",
	"violet_stone_ring", "black_pearl_necklace", "emerald_necklace", "ruby_ring",
]


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" Jewelry Catalog Tests")
	print("========================================\n")

	var pd = root.get_node_or_null("PlayerData")
	if pd == null:
		printerr("[FAIL] PlayerData autoload not found!")
		quit(1)
		return true

	_test_all_present(pd)
	_test_each_def(pd)
	_test_registry_item_keys(pd)
	_test_fruit_split_intact(pd)
	_test_storage_bridge(pd)

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


func _test_all_present(pd) -> void:
	print("All 8 jewelry ids present:")
	var ids = pd.jewelry_ids()
	_eq(ids.size(), 8, "jewelry_ids() size == 8")
	for id in EXPECTED_JEWELRY:
		_ok(ids.has(id), "jewelry_ids contains %s" % id)


func _test_each_def(pd) -> void:
	print("Each jewelry def has recipe + bonus + gem:")
	for id in EXPECTED_JEWELRY:
		var def = pd.get_jewelry_def(id)
		_ok(not def.is_empty(), "%s def found" % id)
		_ok(def.has("recipe") and def["recipe"] is Dictionary and not def["recipe"].is_empty(),
			"%s has non-empty recipe" % id)
		_ok(def.has("bonus") and str(def["bonus"]) != "", "%s has bonus" % id)
		_ok(def.has("gem") and str(def["gem"]) != "", "%s has gem type" % id)
		_ok(def.has("craft_minutes") and int(def["craft_minutes"]) > 0, "%s has craft_minutes" % id)
		_ok(int(def.get("sell_price", 0)) > 0, "%s has sell_price" % id)
	## Recipe keys must be canonical, stockpile-eligible categories.
	var reg = _reg()
	for id in EXPECTED_JEWELRY:
		var recipe = pd.get_jewelry_def(id).get("recipe", {})
		for key in recipe:
			var cat = reg.category_of(str(key))
			_ok(cat in ["gem", "polished", "resource"],
				"%s recipe key %s is a valid input category (%s)" % [id, key, cat])


## Loads the ItemKeyRegistry class at RUNTIME (avoids a --script compile-time
## static reference that can't see the PlayerData autoload global).
func _reg():
	return load("res://scripts/marketplace/item_key_registry.gd")


func _test_registry_item_keys(pd) -> void:
	print("ItemKeyRegistry treats all jewelry as valid + tradeable:")
	var reg = _reg()
	for id in EXPECTED_JEWELRY:
		var key = reg.item_key(id)
		_ok(reg.is_valid(key), "%s is_valid" % key)
		_ok(reg.is_tradeable(key), "%s is_tradeable" % key)
		_ok(reg.display_name(key) == pd.get_jewelry_def(id)["name"],
			"%s display_name matches def" % key)
	## all_keys() includes every jewelry item: key.
	var all = reg.all_keys()
	for id in EXPECTED_JEWELRY:
		_ok(all.has(reg.item_key(id)), "all_keys includes item:%s" % id)


func _test_fruit_split_intact(pd) -> void:
	print("Fruit/jewelry split still correct (no misclassification):")
	var reg = _reg()
	## Fruits remain valid under fruit: and are NOT jewelry.
	for fid in ["plum", "coconut"]:
		_ok(reg.is_valid(reg.fruit_key(fid)), "fruit:%s still valid" % fid)
		_ok(not pd.is_jewelry_id(fid), "%s not classified as jewelry" % fid)
	## A jewelry id is NOT a valid fruit key.
	_ok(not reg.is_valid("fruit:emerald_necklace"), "emerald_necklace not a valid fruit")


func _test_storage_bridge(pd) -> void:
	print("Jewelry storage bridge (add/count/remove via market_* + helpers):")
	## Use a non-diamond jewelry so we don't disturb diamond_ring_count.
	var key: String = _reg().item_key("emerald_necklace")
	var before: int = pd.market_count_owned(key)
	_ok(pd.market_add_owned(key, 3), "market_add_owned emerald_necklace x3")
	_eq(pd.market_count_owned(key), before + 3, "count == before+3")
	_eq(pd.get_jewelry_count("emerald_necklace"), before + 3, "get_jewelry_count matches")
	_ok(pd.market_remove_owned(key, 2), "market_remove_owned x2")
	_eq(pd.market_count_owned(key), before + 1, "count == before+1 after remove")
	## Clean up the test's leftover so we don't persist test state.
	pd.remove_jewelry("emerald_necklace", 1)
	_eq(pd.get_jewelry_count("emerald_necklace"), before, "restored to before")
