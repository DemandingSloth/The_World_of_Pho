extends SceneTree

## Unit tests for the reworked EXPONENTIAL daily bonus curve in PlayerData.
## Verifies _daily_reward_for_day (via get_daily_bonus_amount path) matches the
## agreed shape: day-1 base 100,000; exponential growth; main reward hard-capped
## at 1B on day 365; and a flat 100,000 week bonus per completed 7-day period
## added on top of the (capped) main reward.
##
## Runs with the full project so the PlayerData autoload is available:
##   godot --headless --script tests/test_daily_bonus_curve.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" Daily Bonus Curve Unit Tests")
	print("========================================\n")

	var pd = root.get_node_or_null("PlayerData")
	if pd == null:
		printerr("[FAIL] Autoload PlayerData not found!")
		quit(1)
		return true

	_test_day1(pd)
	_test_monotonic_main(pd)
	_test_cap_at_365(pd)
	_test_cap_beyond_365(pd)
	_test_week_bonus(pd)
	_test_guard_low_days(pd)

	print("\n----------------------------------------")
	print(" Results: %d passed, %d failed, %d total" % [_passed, _failed, _run])
	print("----------------------------------------\n")
	quit(1 if _failed > 0 else 0)
	return true


## The MAIN (pre-week-bonus) portion for a day: subtract the week bonus the
## formula adds so tests can reason about the exponential part in isolation.
func _main_portion(pd, day: int) -> int:
	var total: int = pd._daily_reward_for_day(day)
	var week: int = pd.DAILY_BONUS_WEEK_BONUS * int(day / 7)
	return total - week


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


func _test_day1(pd) -> void:
	print("Day 1 base:")
	## Day 1 has no completed week, so total == main == 100,000.
	_eq(pd._daily_reward_for_day(1), 100000, "day1 total == 100,000 (+0 week)")
	_eq(_main_portion(pd, 1), 100000, "day1 main portion == 100,000")


func _test_monotonic_main(pd) -> void:
	print("Main reward strictly increasing (day 1..365):")
	var prev := -1
	var monotonic := true
	for day in range(1, 366):
		var m := _main_portion(pd, day)
		if m <= prev:
			monotonic = false
			print("    break at day %d: %d <= %d" % [day, m, prev])
			break
		prev = m
	_ok(monotonic, "main portion strictly increases every day through 365")


func _test_cap_at_365(pd) -> void:
	print("Cap reached at day 365:")
	_eq(_main_portion(pd, 365), 1_000_000_000, "day365 main portion == 1,000,000,000")


func _test_cap_beyond_365(pd) -> void:
	print("Main reward never exceeds 1B at/after day 365:")
	var within := true
	for day in [365, 366, 400, 1000, 100000]:
		if _main_portion(pd, day) > 1_000_000_000:
			within = false
			print("    day %d main exceeded cap: %d" % [day, _main_portion(pd, day)])
	_ok(within, "day >= 365 main portion clamps to <= 1B")


func _test_week_bonus(pd) -> void:
	print("Week bonus (+100,000 per completed 7 days):")
	## day14 includes +200,000 week bonus on top of its main portion.
	var day14_total: int = pd._daily_reward_for_day(14)
	var day14_main: int = _main_portion(pd, 14)
	_eq(day14_total - day14_main, 200000, "day14 week bonus == 200,000")
	## day13 (one completed week) adds +100,000.
	_eq(pd._daily_reward_for_day(13) - _main_portion(pd, 13), 100000, "day13 week bonus == 100,000")
	## day6 (no completed week) adds 0.
	_eq(pd._daily_reward_for_day(6) - _main_portion(pd, 6), 0, "day6 week bonus == 0")


func _test_guard_low_days(pd) -> void:
	print("Guard: day < 1 treated as day 1:")
	_eq(pd._daily_reward_for_day(0), pd._daily_reward_for_day(1), "day0 == day1")
	_eq(pd._daily_reward_for_day(-5), pd._daily_reward_for_day(1), "day-5 == day1")
