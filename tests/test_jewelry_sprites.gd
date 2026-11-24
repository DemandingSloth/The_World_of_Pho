extends SceneTree

## Smoke test: every jewelry item's sprite path exists AND loads as a texture
## via ItemKeyRegistry.get_texture("item:<id>"). Catches a sprite path that
## points at a missing/unimported file (which would render a blank icon).
##
##   godot --headless --script tests/test_jewelry_sprites.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" Jewelry Sprite Wiring Smoke Test")
	print("========================================\n")

	var reg = load("res://scripts/items/item_key_registry.gd")
	var pd = root.get_node_or_null("PlayerData")
	if reg == null or pd == null:
		printerr("[FAIL] ItemKeyRegistry or PlayerData unavailable")
		quit(1)
		return true

	for jid in pd.jewelry_ids():
		var def = pd.get_jewelry_def(jid)
		var path := str(def.get("sprite", ""))
		# Path points at a real resource?
		_ok(path != "" and ResourceLoader.exists(path),
			"%s sprite path exists: %s" % [jid, path])
		# Loads as a Texture2D through the registry?
		var tex = reg.get_texture("item:%s" % jid)
		_ok(tex != null, "%s texture loads via registry" % jid)

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
