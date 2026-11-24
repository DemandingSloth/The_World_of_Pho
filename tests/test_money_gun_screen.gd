extends SceneTree

## Structural test for the Money Gun screen (Task 8): the scene loads, the script
## compiles, _build_ui() runs without error, both sprites resolve, and the
## navigator route "money_gun" is registered. Does not drive enter() (async +
## needs a navigator); _build_ui is called directly.
##
##   godot --headless --script tests/test_money_gun_screen.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" Money Gun Screen Structural Tests")
	print("========================================\n")

	_test_sprites_import()
	_test_navigator_route()
	_test_scene_builds()

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


func _test_sprites_import() -> void:
	print("Sprites are importable:")
	_ok(ResourceLoader.exists("res://Assets/benjamin_gun.png"), "benjamin_gun.png exists/imported")
	_ok(ResourceLoader.exists("res://Assets/Benjamins.png"), "Benjamins.png exists/imported")
	_ok(load("res://Assets/benjamin_gun.png") is Texture2D, "benjamin_gun.png loads as Texture2D")
	_ok(load("res://Assets/Benjamins.png") is Texture2D, "Benjamins.png loads as Texture2D")


func _test_navigator_route() -> void:
	print("Navigator route registered:")
	var nav_scr = load("res://scripts/screens/screen_navigator.gd")
	_ok(nav_scr != null, "screen_navigator.gd loads")
	if nav_scr != null:
		_ok(nav_scr.SCREEN_PATHS.has("money_gun"), "SCREEN_PATHS has 'money_gun'")
		_ok(str(nav_scr.SCREEN_PATHS.get("money_gun", "")) == "res://scenes/screens/money_gun_screen.tscn",
			"money_gun route points to the scene")


func _test_scene_builds() -> void:
	print("Scene instantiates + _build_ui runs:")
	var scene: PackedScene = load("res://scenes/screens/money_gun_screen.tscn")
	_ok(scene != null, "money_gun_screen.tscn loads")
	if scene == null:
		return
	var inst = scene.instantiate()
	_ok(inst != null, "scene instantiates")
	if inst == null:
		return
	root.add_child(inst)
	## _build_ui builds all nodes in code; call it directly (no navigator needed).
	inst._build_ui()
	## The internal labels/buttons should now exist.
	_ok(inst._balance_label != null, "_balance_label built")
	_ok(inst._claim_btn != null, "_claim_btn built")
	_ok(inst._buy_btn != null, "_buy_btn built")
	_ok(inst.get_screen_name() == "money_gun", "get_screen_name() == money_gun")
	inst.queue_free()
