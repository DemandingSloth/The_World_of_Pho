extends SceneTree

## Smoke test: load + instantiate the guild_detail_screen scene headlessly and
## verify every Store-panel node path resolves (so a typo in the .tscn node
## paths or the @onready expressions is caught without a device). We do NOT call
## enter() (that needs a live guild/network); we only check node wiring.
##
##   godot --headless --script tests/test_guild_detail_scene_load.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" Guild Detail Scene Load Smoke Test")
	print("========================================\n")

	var ps: PackedScene = load("res://scenes/screens/guild_detail_screen.tscn")
	_ok(ps != null, "scene resource loaded")
	if ps == null:
		_finish()
		return true

	var inst = ps.instantiate()
	_ok(inst != null, "scene instantiated without error")
	if inst == null:
		_finish()
		return true

	## Store nav button + panel + controls must exist at the expected paths.
	var paths := {
		"NavRow/StoreNavBtn": "MarginContainer/OuterVBox/NavRow/StoreNavBtn",
		"StorePanel": "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel",
		"StoreStatus": "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/StoreStatus",
		"DistributeBtn": "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/DistributeBtn",
		"JewelryOption": "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/ListRow/JewelryOption",
		"QtyEdit": "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/ListRow/QtyEdit",
		"PriceEdit": "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/ListRow/PriceEdit",
		"ListBtn": "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/ListRow/ListBtn",
		"StoreEmpty": "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/StoreEmpty",
		"StoreList": "MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/StoreList",
	}
	for label in paths.keys():
		var n = inst.get_node_or_null(paths[label])
		_ok(n != null, "node present: %s" % label)

	## The method hooks referenced by enter() must exist on the script.
	for m in ["_on_store_nav_pressed", "_on_store_changed", "_rebuild_store",
			  "_on_store_list_pressed", "_on_store_buy_pressed",
			  "_on_store_cancel_pressed", "_on_store_distribute_pressed"]:
		_ok(inst.has_method(m), "method present: %s" % m)

	inst.free()
	_finish()
	return true


func _ok(cond: bool, desc: String) -> void:
	_run += 1
	if cond:
		_passed += 1
		print("  ✓ %s" % desc)
	else:
		_failed += 1
		print("  ✗ FAIL: %s" % desc)


func _finish() -> void:
	print("\n----------------------------------------")
	print(" Results: %d passed, %d failed, %d total" % [_passed, _failed, _run])
	print("----------------------------------------\n")
	quit(1 if _failed > 0 else 0)
