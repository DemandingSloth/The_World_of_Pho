extends SceneTree

## Structural test for the Equipment screen (Task 12c): scene loads + compiles,
## route registered, _candidates_for_slot filters by slot-type and excludes
## items equipped in another slot, and _build_ui runs.
##
##   godot --headless --script tests/test_equipment_screen.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" Equipment Screen Structural Tests")
	print("========================================\n")

	var pd = root.get_node_or_null("PlayerData")
	if pd == null:
		printerr("[FAIL] PlayerData autoload not found!")
		quit(1)
		return true

	_test_route()
	_test_scene_builds()
	_test_candidates(pd)

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


func _test_route() -> void:
	print("Navigator route registered:")
	var nav = load("res://scripts/screens/screen_navigator.gd")
	_ok(nav != null, "screen_navigator loads")
	if nav != null:
		_ok(nav.SCREEN_PATHS.has("equipment"), "SCREEN_PATHS has 'equipment'")
		_eq(str(nav.SCREEN_PATHS.get("equipment", "")),
			"res://scenes/screens/equipment_screen.tscn", "equipment route path")


func _test_scene_builds() -> void:
	print("Equipment scene instantiates + _build_ui runs:")
	var scene: PackedScene = load("res://scenes/screens/equipment_screen.tscn")
	_ok(scene != null, "equipment_screen.tscn loads")
	if scene == null:
		return
	var inst = scene.instantiate()
	_ok(inst != null, "scene instantiates")
	if inst == null:
		return
	root.add_child(inst)
	inst._build_ui()
	_ok(inst._content != null, "_content built")
	_ok(inst.get_screen_name() == "equipment", "get_screen_name() == equipment")
	## SLOTS constant covers the 3 slots.
	_eq(inst.SLOTS.size(), 3, "3 equip slots")
	inst.queue_free()


func _test_candidates(pd) -> void:
	print("_candidates_for_slot filters by slot-type + no-dup:")
	## Set up a known inventory.
	var saved = pd.jewelry.duplicate()
	var sr = pd.equipped_ring; var sn = pd.equipped_necklace; var sm = pd.equipped_misc
	pd.jewelry.clear()
	pd.equipped_ring = ""; pd.equipped_necklace = ""; pd.equipped_misc = ""
	pd.jewelry["ruby_ring"] = 5           ## ring
	pd.jewelry["emerald_necklace"] = 5    ## necklace

	var scene: PackedScene = load("res://scenes/screens/equipment_screen.tscn")
	var inst = scene.instantiate()
	root.add_child(inst)

	## Ring slot -> only rings.
	var ring_cands: Array = inst._candidates_for_slot("ring")
	_ok(ring_cands.has("ruby_ring"), "ring slot includes ruby_ring")
	_ok(not ring_cands.has("emerald_necklace"), "ring slot excludes necklace")
	## Necklace slot -> only necklaces.
	var neck_cands: Array = inst._candidates_for_slot("necklace")
	_ok(neck_cands.has("emerald_necklace"), "necklace slot includes emerald_necklace")
	_ok(not neck_cands.has("ruby_ring"), "necklace slot excludes ring")
	## Misc -> both.
	var misc_cands: Array = inst._candidates_for_slot("misc")
	_ok(misc_cands.has("ruby_ring") and misc_cands.has("emerald_necklace"),
		"misc slot includes both ring + necklace")
	## No-dup: equip ruby_ring in ring; it should drop out of misc candidates.
	pd.equip_jewelry("ring", "ruby_ring")
	var misc_after: Array = inst._candidates_for_slot("misc")
	_ok(not misc_after.has("ruby_ring"), "ruby_ring excluded from misc once equipped in ring")

	inst.queue_free()
	## Restore.
	pd.jewelry = saved
	pd.equipped_ring = sr; pd.equipped_necklace = sn; pd.equipped_misc = sm
