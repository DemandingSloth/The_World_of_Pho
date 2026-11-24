extends SceneTree

## Unit tests for the MoneyGun autoload's pure, network-free logic:
## apply_payload parsing (which also mirrors state into PlayerData) and the
## MONEY_GUN_COST constant. Server RPC paths are verified in-game / via the SQL
## tests; this covers the client-side cache + mirroring.
##
##   godot --headless --script tests/test_money_gun_data.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" MoneyGun Data Layer Unit Tests")
	print("========================================\n")

	var mg = root.get_node_or_null("MoneyGun")
	var pd = root.get_node_or_null("PlayerData")
	if mg == null or pd == null:
		printerr("[FAIL] MoneyGun or PlayerData autoload not found!")
		quit(1)
		return true

	_test_cost(mg)
	_test_apply_payload(mg, pd)
	_test_mirror_to_playerdata(mg, pd)
	_test_bad_payload(mg)

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


func _test_cost(mg) -> void:
	print("Cost constant:")
	_eq(mg.MONEY_GUN_COST, 500_000_000_000, "MONEY_GUN_COST == 500 billion")


func _test_apply_payload(mg, _pd) -> void:
	print("apply_payload parses the server view:")
	_ok(mg.apply_payload({
		"balance": 1234, "owned": true, "level": 3,
		"rate_per_hour": 8, "cap": 384, "accrued": 50,
		"last_claim_at": 1700000000.0,
	}), "apply_payload returns true")
	_eq(mg.balance, 1234, "balance")
	_eq(mg.owned, true, "owned")
	_eq(mg.level, 3, "level")
	_eq(mg.rate_per_hour, 8, "rate_per_hour")
	_eq(mg.cap, 384, "cap")
	_eq(mg.accrued, 50, "accrued")
	_eq(mg.last_claim_at, 1700000000.0, "last_claim_at")


func _test_mirror_to_playerdata(mg, pd) -> void:
	print("apply_payload mirrors ownership/level into PlayerData:")
	mg.apply_payload({"owned": true, "level": 7})
	_eq(pd.money_gun_owned, true, "PlayerData.money_gun_owned mirrored")
	_eq(pd.money_gun_level, 7, "PlayerData.money_gun_level mirrored")
	mg.apply_payload({"owned": false, "level": 0})
	_eq(pd.money_gun_owned, false, "mirror updates to false")
	_eq(pd.money_gun_level, 0, "mirror level reset")


func _test_bad_payload(mg) -> void:
	print("Bad payloads rejected:")
	_eq(mg.apply_payload("nope"), false, "string payload -> false")
	_eq(mg.apply_payload(7), false, "int payload -> false")
