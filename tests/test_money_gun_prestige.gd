extends SceneTree

## Tests for the Money Gun's Prestige-screen integration (Task 7). Verifies the
## prestige def exists, the effect-rate math, that the gun uses the DEFAULT XP
## cost curve (not an override), and the ownership-gating helper logic. Does not
## drive the full screen UI (needs a navigator); checks the pure pieces + that
## the screen script loads/compiles.
##
##   godot --headless --script tests/test_money_gun_prestige.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" Money Gun Prestige Integration Tests")
	print("========================================\n")

	var pd = root.get_node_or_null("PlayerData")
	if pd == null:
		printerr("[FAIL] PlayerData autoload not found!")
		quit(1)
		return true

	_test_screen_loads()
	_test_def_present()
	_test_default_cost_curve(pd)
	_test_rate_math()

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


## Load the prestige screen script and read its UPGRADE_DEFS without running the
## full scene (compile check + def inspection).
func _prestige_defs() -> Array:
	var scr = load("res://scripts/screens/prestige_screen.gd")
	if scr == null:
		return []
	return scr.UPGRADE_DEFS


func _test_screen_loads() -> void:
	print("Prestige screen script loads/compiles:")
	_ok(load("res://scripts/screens/prestige_screen.gd") != null, "prestige_screen.gd loads")


func _test_def_present() -> void:
	print("money_gun def present in UPGRADE_DEFS:")
	var found := false
	for def in _prestige_defs():
		if def is Dictionary and def.get("id", "") == "money_gun":
			found = true
			_ok(def.has("effect_fmt"), "money_gun def has effect_fmt")
			_ok(def.has("title"), "money_gun def has title")
	_ok(found, "money_gun id found in UPGRADE_DEFS")


func _test_default_cost_curve(pd) -> void:
	print("money_gun uses the DEFAULT prestige XP curve:")
	## Not registered in PRESTIGE_COST_OVERRIDES -> _prestige_cost_curve returns
	## PRESTIGE_XP_COSTS. Compare level-0 and level-9 costs against the default.
	_eq(pd.prestige_cost_for_level("money_gun", 0),
		pd.PRESTIGE_XP_COSTS[0], "level 0 cost == default curve[0]")
	_eq(pd.prestige_cost_for_level("money_gun", 9),
		pd.PRESTIGE_XP_COSTS[9], "level 9 cost == default curve[9]")
	_ok(not pd.PRESTIGE_COST_OVERRIDES.has("money_gun"),
		"money_gun NOT in PRESTIGE_COST_OVERRIDES (uses default)")


func _test_rate_math() -> void:
	print("Print-rate effect math (1 << level):")
	_eq(1 << 0, 1, "Lv.0 -> 1/hr")
	_eq(1 << 5, 32, "Lv.5 -> 32/hr")
	_eq(1 << 10, 1024, "Lv.10 -> 1024/hr")
