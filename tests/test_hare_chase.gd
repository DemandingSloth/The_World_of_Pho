extends SceneTree

## Headless tests for the hare chase mini game:
##   * HareChaseGeometry (cut validation + splitting)
##   * HareChaseField cut/trap/crate-entry rules (state set directly, no RNG)
##   * Garden heist bookkeeping (no disk writes)
##   * Screen registration + scene wiring
##
##   godot --headless --script tests/test_hare_chase.gd

var _frame := 0
var _run := 0
var _passed := 0
var _failed := 0

var _geo: GDScript = null
var _field_script: GDScript = null


func _process(_delta: float) -> bool:
	_frame += 1
	## Give autoloads one frame to finish _ready.
	if _frame < 2:
		return false

	print("\n========================================")
	print(" Hare Chase Tests")
	print("========================================\n")

	_geo = load("res://scripts/garden/hare_chase_geometry.gd")
	_field_script = load("res://scripts/garden/hare_chase_field.gd")
	_ok(_geo != null, "geometry script loads")
	_ok(_field_script != null, "field script loads")
	if _geo == null or _field_script == null:
		_finish()
		return true

	_test_geometry()
	_test_field()
	_test_heist_bookkeeping()
	_test_scene_wiring()

	_finish()
	return true


## ── Geometry ────────────────────────────────────────────────────

func _test_geometry() -> void:
	print("Geometry:")
	var poly: PackedVector2Array = _geo.rect_to_polygon(Rect2(0, 0, 100, 100))
	_ok(is_equal_approx(_geo.polygon_area(poly), 10000.0), "rect area is 10000")

	## Edge-to-edge horizontal cut, ends slightly off the walls (snapped).
	var res: Dictionary = _geo.try_cut(poly, Vector2(-4, 50), Vector2(104, 50), 30.0, 20.0)
	_ok(bool(res["ok"]), "edge-to-edge cut accepted (snaps to walls)")
	if bool(res["ok"]):
		var polys: Array = res["polys"]
		_ok(polys.size() == 2, "cut yields two pieces")
		_ok(is_equal_approx(_geo.polygon_area(polys[0]), 5000.0), "piece 1 is half the area")
		_ok(is_equal_approx(_geo.polygon_area(polys[1]), 5000.0), "piece 2 is half the area")

	## Diagonal cut corner-ish to corner-ish still splits into two convex pieces.
	var diag: Dictionary = _geo.try_cut(poly, Vector2(0, 20), Vector2(60, 100), 30.0, 20.0)
	_ok(bool(diag["ok"]), "diagonal cut accepted")
	if bool(diag["ok"]):
		var dp: Array = diag["polys"]
		var total: float = _geo.polygon_area(dp[0]) + _geo.polygon_area(dp[1])
		_ok(absf(total - 10000.0) < 0.5, "diagonal pieces sum to the whole area")

	## Interior stroke does not touch the boundary.
	var inner: Dictionary = _geo.try_cut(poly, Vector2(40, 40), Vector2(60, 60), 10.0, 5.0)
	_ok(not bool(inner["ok"]) and str(inner["reason"]) == "edge", "interior stroke rejected (edge)")

	## Stroke along a single wall is degenerate.
	var along: Dictionary = _geo.try_cut(poly, Vector2(10, 0), Vector2(90, 0), 10.0, 20.0)
	_ok(not bool(along["ok"]), "stroke along one wall rejected")

	## Too-short chord.
	var short: Dictionary = _geo.try_cut(poly, Vector2(0, 50), Vector2(100, 50), 30.0, 500.0)
	_ok(not bool(short["ok"]) and str(short["reason"]) == "short", "short chord rejected")

	## A second cut on an already-cut piece (cuts act as boundaries).
	if bool(res["ok"]):
		var top: PackedVector2Array = (res["polys"] as Array)[0]
		var second: Dictionary = _geo.try_cut(top, Vector2(50, 0), Vector2(50, 50), 30.0, 20.0)
		_ok(bool(second["ok"]), "cut ending on a previous cut is accepted")

	_ok(_geo.segment_hits_rect(Vector2(0, 5), Vector2(100, 5), Rect2(40, 0, 20, 10)),
		"segment through rect detected")
	_ok(not _geo.segment_hits_rect(Vector2(0, 50), Vector2(100, 50), Rect2(40, 0, 20, 10)),
		"segment missing rect not detected")
	_ok(_geo.contains(poly, Vector2(50, 50)), "contains: inside point")
	_ok(not _geo.contains(poly, Vector2(150, 50)), "contains: outside point")


## ── Field rules ─────────────────────────────────────────────────

func _make_field() -> Control:
	var f: Control = _field_script.new()
	f.size = Vector2(320, 420)
	root.add_child(f)
	f.start_game()
	return f


func _test_field() -> void:
	print("Field rules:")

	## Cage contact classification.
	var f: Control = _make_field()
	f._cage_rect = Rect2(150, 200, 40, 40)
	var mid_y: float = 220.0
	_ok(f._cage_contact(Vector2(150 - 6, mid_y)) == 1, "left side touch = entry")
	_ok(f._cage_contact(Vector2(190 + 6, mid_y)) == 1, "right side touch = entry")
	_ok(f._cage_contact(Vector2(170, 200 - 6)) == 2, "top touch = blocked")
	_ok(f._cage_contact(Vector2(170, 240 + 6)) == 2, "bottom touch = blocked")
	_ok(f._cage_contact(Vector2(20, 20)) == 0, "far away = no contact")
	f.queue_free()

	## Hare on the cage side survives a cut.
	var f2: Control = _make_field()
	f2._cage_rect = Rect2(230, 200, 40, 40)
	f2._hare_pos = Vector2(260, 100)
	f2._apply_cut(Vector2(160, 0), Vector2(160, 420))
	_ok(f2.is_active(), "hare on crate side: game continues")
	var area2: float = _geo.polygon_area(f2._open_poly)
	_ok(area2 < 320.0 * 420.0 * 0.6, "open area shrank to roughly half")
	_ok(_geo.contains(f2._open_poly, f2._cage_rect.get_center()), "crate stays in open area")
	f2.queue_free()

	## Hare on the far side is trapped.
	var f3: Control = _make_field()
	f3._cage_rect = Rect2(230, 200, 40, 40)
	f3._hare_pos = Vector2(60, 100)
	f3._apply_cut(Vector2(160, 0), Vector2(160, 420))
	_ok(not f3.is_active(), "hare on far side: game no longer active")
	_ok(f3._state == f3.State.DYING, "hare enters the death state")
	f3.queue_free()

	## A cut through the crate is rejected and changes nothing.
	var f4: Control = _make_field()
	f4._cage_rect = Rect2(140, 200, 40, 40)
	f4._hare_pos = Vector2(60, 100)
	var before: float = _geo.polygon_area(f4._open_poly)
	f4._apply_cut(Vector2(160, 0), Vector2(160, 420))
	_ok(is_equal_approx(_geo.polygon_area(f4._open_poly), before), "cut through crate rejected")
	_ok(f4.is_active(), "game still active after rejected cut")
	f4.queue_free()

	## Interior stroke is rejected with a hint.
	var f5: Control = _make_field()
	var hints: Array = []
	f5.hint.connect(func(t: String): hints.append(t))
	f5._apply_cut(Vector2(100, 100), Vector2(200, 200))
	_ok(hints.size() == 1, "interior stroke emits a hint")
	f5.queue_free()


## ── Heist bookkeeping (no disk writes) ──────────────────────────

func _test_heist_bookkeeping() -> void:
	print("Heist bookkeeping:")
	var garden: Node = root.get_node_or_null("Garden")
	_ok(garden != null, "Garden autoload present")
	if garden == null:
		return

	var saved: Dictionary = garden.pending_heist.duplicate()
	garden.pending_heist.clear()
	_ok(not garden.has_pending_heist(), "no heist when empty")

	garden.pending_heist = {0: 5, 3: 2}
	_ok(garden.has_pending_heist(), "heist pending when set")
	_ok(garden.heist_total() == 7, "heist_total sums quantities")
	_ok(garden.heist_summary_text() == "5 Beans, 2 Squash", "summary text is readable")
	_ok(garden.roll_hare_heist(), "roll keeps an existing pending heist")

	## Restore whatever was there (in memory only; nothing was saved).
	garden.pending_heist = saved


## ── Scene wiring ────────────────────────────────────────────────

func _test_scene_wiring() -> void:
	print("Scene wiring:")
	_ok(ScreenNavigator.SCREEN_PATHS.has("hare_chase"), "hare_chase registered in SCREEN_PATHS")
	_ok(ScreenNavigator.SCREEN_PARENTS.get("hare_chase", "") == "garden", "hare_chase parent is garden")
	var ps: PackedScene = load("res://scenes/screens/hare_chase_screen.tscn")
	_ok(ps != null, "hare chase scene loads")
	if ps == null:
		return
	var inst: Node = ps.instantiate()
	_ok(inst != null, "hare chase scene instantiates")
	if inst != null:
		_ok(inst.get_screen_name() == "hare_chase", "screen name is hare_chase")
		inst.free()


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
