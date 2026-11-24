extends SceneTree

## Unit tests for GuildStockpile.apply_payload (the pure response-parsing path)
## and its convenience getters. Runs with the full project so the GuildStockpile
## autoload is available, but hits NO network — apply_payload is fed a mocked
## get_guild_stockpile payload directly.
##
##   godot --headless --script tests/test_guild_stockpile_data.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" GuildStockpile Data Layer Unit Tests")
	print("========================================\n")

	var sp = root.get_node_or_null("GuildStockpile")
	if sp == null:
		printerr("[FAIL] Autoload GuildStockpile not found!")
		quit(1)
		return true

	_test_parse_well_formed(sp)
	_test_getters(sp)
	_test_available_clamps(sp)
	_test_locked_and_capacity(sp)
	_test_bad_payload(sp)
	_test_skips_malformed_entries(sp)

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


func _sample_payload() -> Dictionary:
	return {
		"items": [
			{"item_key": "resource:iron_ore", "amount": 1500, "reserved": 500},
			{"item_key": "gem:diamond",       "amount": 3,    "reserved": 0},
		],
		"locked": true,
		"capacity": 500000,
	}


func _test_parse_well_formed(sp) -> void:
	print("apply_payload parses a well-formed response:")
	_ok(sp.apply_payload(_sample_payload()), "apply_payload returns true")
	_eq(sp.items.size(), 2, "two items cached")
	_eq(sp.item_keys().has("resource:iron_ore"), true, "iron_ore key present")
	_eq(sp.item_keys().has("gem:diamond"), true, "diamond key present")


func _test_getters(sp) -> void:
	print("Convenience getters:")
	sp.apply_payload(_sample_payload())
	_eq(sp.get_amount("resource:iron_ore"), 1500, "get_amount iron_ore")
	_eq(sp.get_reserved("resource:iron_ore"), 500, "get_reserved iron_ore")
	_eq(sp.get_amount("gem:diamond"), 3, "get_amount diamond")
	_eq(sp.get_amount("resource:unknown"), 0, "get_amount unknown -> 0")
	_eq(sp.get_reserved("resource:unknown"), 0, "get_reserved unknown -> 0")


func _test_available_clamps(sp) -> void:
	print("get_available = amount - reserved (>= 0):")
	sp.apply_payload(_sample_payload())
	_eq(sp.get_available("resource:iron_ore"), 1000, "iron_ore available 1500-500=1000")
	_eq(sp.get_available("gem:diamond"), 3, "diamond available (none reserved)")
	_eq(sp.get_available("resource:unknown"), 0, "unknown available -> 0")


func _test_locked_and_capacity(sp) -> void:
	print("Lock flag + capacity parsed:")
	sp.apply_payload(_sample_payload())
	_eq(sp.locked, true, "locked == true")
	_eq(sp.capacity, 500000, "capacity == 500000")
	## Unlocked variant.
	sp.apply_payload({"items": [], "locked": false, "capacity": 50000})
	_eq(sp.locked, false, "locked == false after re-parse")
	_eq(sp.capacity, 50000, "capacity == 50000 after re-parse")
	_eq(sp.is_empty(), true, "is_empty when no items")


func _test_bad_payload(sp) -> void:
	print("Bad payloads rejected gracefully:")
	_eq(sp.apply_payload("not a dict"), false, "string payload -> false")
	_eq(sp.apply_payload(42), false, "int payload -> false")
	## A dict missing fields still returns true (defaults applied).
	_ok(sp.apply_payload({}), "empty dict -> true (defaults)")
	_eq(sp.items.size(), 0, "empty dict clears items")


func _test_skips_malformed_entries(sp) -> void:
	print("Malformed item entries are skipped:")
	sp.apply_payload({
		"items": [
			{"item_key": "resource:wood", "amount": 10, "reserved": 0},
			{"amount": 99},                     ## no item_key -> skipped
			"garbage",                          ## not a dict -> skipped
			{"item_key": "", "amount": 5},      ## empty key -> skipped
		],
		"locked": false,
		"capacity": 50000,
	})
	_eq(sp.items.size(), 1, "only the valid entry kept")
	_eq(sp.get_amount("resource:wood"), 10, "valid entry amount correct")
