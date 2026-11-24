extends SceneTree

## Smoke test: load + instantiate the four Equestrian Center scenes headlessly
## (equestrian hub, stable, pasture, racetrack), verify each has the expected
## screen name + lifecycle methods, and that the ScreenNavigator knows every
## screen path + parent mapping. These screens build their UI in code, so we
## cannot check named .tscn nodes; we verify wiring + navigator config instead.
## We do NOT call enter() (that needs network/HorseRacing autoload refresh).
##
##   godot --headless --script tests/test_equestrian_scene_load.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" Equestrian Scene Load Smoke Test")
	print("========================================\n")

	## scene path -> (expected screen name).
	var scenes := {
		"res://scenes/screens/equestrian_center_screen.tscn": "equestrian",
		"res://scenes/screens/stable_screen.tscn": "stable",
		"res://scenes/screens/pasture_screen.tscn": "pasture",
		"res://scenes/screens/racetrack_screen.tscn": "racetrack",
	}

	for path in scenes.keys():
		var screen_name: String = scenes[path]
		var ps: PackedScene = load(path)
		_ok(ps != null, "scene loaded: %s" % path)
		if ps == null:
			continue
		var inst = ps.instantiate()
		_ok(inst != null, "instantiated: %s" % screen_name)
		if inst == null:
			continue
		_ok(inst.has_method("get_screen_name"), "%s: has get_screen_name()" % screen_name)
		if inst.has_method("get_screen_name"):
			_ok(inst.get_screen_name() == screen_name,
				"%s: get_screen_name() == '%s'" % [screen_name, screen_name])
		_ok(inst.has_method("enter"), "%s: has enter()" % screen_name)
		_ok(inst.has_method("exit"), "%s: has exit()" % screen_name)
		inst.free()

	## ScreenNavigator must map every screen path + parent.
	var nav_script = load("res://scripts/screens/screen_navigator.gd")
	_ok(nav_script != null, "screen_navigator.gd loaded")
	if nav_script != null:
		var paths = nav_script.SCREEN_PATHS
		var parents = nav_script.SCREEN_PARENTS
		for screen_name in ["equestrian", "stable", "pasture", "racetrack"]:
			_ok(paths.has(screen_name), "SCREEN_PATHS has '%s'" % screen_name)
		_ok(parents.get("equestrian", "") == "town", "equestrian parent is town")
		_ok(parents.get("stable", "") == "equestrian", "stable parent is equestrian")
		_ok(parents.get("pasture", "") == "equestrian", "pasture parent is equestrian")
		_ok(parents.get("racetrack", "") == "equestrian", "racetrack parent is equestrian")

	## Town screen must have the Equestrian button + handler.
	var town_ps: PackedScene = load("res://scenes/screens/town_screen.tscn")
	_ok(town_ps != null, "town_screen.tscn loaded")
	if town_ps != null:
		var town = town_ps.instantiate()
		_ok(town != null, "town_screen instantiated")
		if town != null:
			var btn = town.get_node_or_null(
				"CenterWrapper/MarginContainer/TownVBox/EquestrianBtn")
			_ok(btn != null, "town has EquestrianBtn node")
			_ok(town.has_method("_on_equestrian_pressed"),
				"town has _on_equestrian_pressed()")
			town.free()

	## RaceReplay overlay loads + instantiates (used by the racetrack screen).
	var replay_script = load("res://scripts/horse_racing/race_replay.gd")
	_ok(replay_script != null, "race_replay.gd loaded")
	if replay_script != null:
		var rr = replay_script.new()
		_ok(rr != null, "RaceReplay instantiates")
		_ok(rr.has_signal("closed"), "RaceReplay has closed() signal")
		_ok(rr.has_method("setup"), "RaceReplay has setup()")
		rr.free()

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
