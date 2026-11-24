extends SceneTree

## Unit tests for ItemKeyRegistry's pure (dependency-free) functions: key
## building, split_key parsing, and round-tripping. These don't require game
## autoloads (PlayerData/Piece/PieceRegistry), so they run headless:
##
##   godot --headless --script tests/marketplace/test_item_key_registry.gd
##
## The catalog-driven parts (is_valid / display_name / all_keys) depend on the
## PlayerData autoload and are verified in-game instead (see the debug dump in
## the marketplace, added in a later step).

var _run := 0
var _passed := 0
var _failed := 0


func _init() -> void:
	print("\n========================================")
	print(" ItemKeyRegistry Unit Tests")
	print("========================================\n")

	_test_key_builders()
	_test_split_and_parse()
	_test_round_trip()

	print("\n----------------------------------------")
	print(" Results: %d passed, %d failed, %d total" % [_passed, _failed, _run])
	print("----------------------------------------\n")
	quit(1 if _failed > 0 else 0)


func _eq(actual, expected, desc: String) -> void:
	_run += 1
	if actual == expected:
		_passed += 1
		print("  ✓ %s" % desc)
	else:
		_failed += 1
		print("  ✗ FAIL: %s  (got %s, expected %s)" % [desc, str(actual), str(expected)])


func _test_key_builders() -> void:
	print("Key builders:")
	_eq(ItemKeyRegistry.gem_key("diamond"), "gem:diamond", "gem key")
	_eq(ItemKeyRegistry.resource_key("iron_bar"), "resource:iron_bar", "resource key")
	_eq(ItemKeyRegistry.crop_key("beans"), "crop:beans", "crop key")
	_eq(ItemKeyRegistry.fruit_key("plum"), "fruit:plum", "fruit key")
	_eq(ItemKeyRegistry.tool_key(1), "tool:scythe", "tool key (scythe)")
	_eq(ItemKeyRegistry.tool_key(2), "tool:tractor", "tool key (tractor)")
	_eq(ItemKeyRegistry.item_key("diamond_ring"), "item:diamond_ring", "item key")


func _test_split_and_parse() -> void:
	print("Split / parse:")
	_eq(ItemKeyRegistry.split_key("gem:diamond"), ["gem", "diamond"], "split valid key")
	_eq(ItemKeyRegistry.category_of("resource:iron_bar"), "resource", "category_of")
	_eq(ItemKeyRegistry.id_of("resource:iron_bar"), "iron_bar", "id_of")
	_eq(ItemKeyRegistry.split_key("nocolon"), ["", ""], "malformed: no colon")
	_eq(ItemKeyRegistry.split_key(":leading"), ["", ""], "malformed: leading colon")
	_eq(ItemKeyRegistry.split_key("trailing:"), ["", ""], "malformed: trailing colon")


func _test_round_trip() -> void:
	print("Round-trip (build -> split -> rebuild):")
	var samples := {
		ItemKeyRegistry.CAT_GEM: "diamond",
		ItemKeyRegistry.CAT_RESOURCE: "copper_ingot",
		ItemKeyRegistry.CAT_CROP: "watermelon",
		ItemKeyRegistry.CAT_FRUIT: "coconut",
		ItemKeyRegistry.CAT_ITEM: "diamond_ring",
	}
	for cat in samples:
		var id: String = samples[cat]
		var key := "%s:%s" % [cat, id]
		var parts := ItemKeyRegistry.split_key(key)
		_eq(parts[0], cat, "%s round-trip category" % cat)
		_eq(parts[1], id, "%s round-trip id" % cat)
