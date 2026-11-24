extends SceneTree

## Structural test for the Stockpile tab added to guild_detail_screen.tscn/.gd.
## Instantiates the scene and asserts the new nav button + panel nodes resolve
## at the paths the script's @onready vars expect, so a typo in either the scene
## or the node paths is caught headlessly. Does NOT call enter() (that needs a
## navigator + network); this is a pure wiring/compile check.
##
##   godot --headless --script tests/test_guild_stockpile_ui.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" Guild Stockpile UI Structural Tests")
	print("========================================\n")

	var scene: PackedScene = load("res://scenes/screens/guild_detail_screen.tscn")
	if scene == null:
		printerr("[FAIL] Could not load guild_detail_screen.tscn")
		quit(1)
		return true

	var inst = scene.instantiate()
	if inst == null:
		printerr("[FAIL] Could not instantiate scene")
		quit(1)
		return true

	## Adding to the tree triggers @onready resolution.
	root.add_child(inst)

	_check_node(inst, "MarginContainer/OuterVBox/NavRow/StockpileNavBtn", "StockpileNavBtn")
	_check_node(inst, "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StockpilePanel", "StockpilePanel")
	_check_node(inst, "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StockpilePanel/StockpileStatus", "StockpileStatus")
	_check_node(inst, "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StockpilePanel/StockpileEmpty", "StockpileEmpty")
	_check_node(inst, "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StockpilePanel/StockpileList", "StockpileList")
	_check_node(inst, "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StockpilePanel/DepositArea", "DepositArea")

	## The script's @onready refs should have resolved (non-null) after add_child.
	_ok(inst._nav_stockpile != null, "@onready _nav_stockpile resolved")
	_ok(inst._stockpile_panel != null, "@onready _stockpile_panel resolved")
	_ok(inst._stockpile_status != null, "@onready _stockpile_status resolved")
	_ok(inst._stockpile_list != null, "@onready _stockpile_list resolved")
	_ok(inst._stockpile_deposit_area != null, "@onready _stockpile_deposit_area resolved")

	## The client's eligible categories must match the server's allowed set
	## (_guild_stockpile_key_ok in migration 052).
	var expected := ["resource", "gem", "polished", "crop", "fruit"]
	_eq(inst._STOCKPILE_CATEGORIES.size(), expected.size(), "eligible category count")
	var all_present := true
	for c in expected:
		if not inst._STOCKPILE_CATEGORIES.has(c):
			all_present = false
	_ok(all_present, "eligible categories match server (resource/gem/polished/crop/fruit)")

	inst.queue_free()

	print("\n----------------------------------------")
	print(" Results: %d passed, %d failed, %d total" % [_passed, _failed, _run])
	print("----------------------------------------\n")
	quit(1 if _failed > 0 else 0)
	return true


func _check_node(root_node: Node, path: String, desc: String) -> void:
	_ok(root_node.get_node_or_null(path) != null, "node exists: %s" % desc)


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
