extends SceneTree

## Unit tests for FormatUtils (scripts/utils/format_utils.gd).
##
##   godot --headless --script tests/test_format_utils.gd

var _done := false
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" FormatUtils Unit Tests")
	print("========================================\n")

	## format_duration
	_eq(FormatUtils.format_duration(0.0), "00:00", "duration 0s")
	_eq(FormatUtils.format_duration(-5.0), "00:00", "duration negative")
	_eq(FormatUtils.format_duration(42.0), "00:42", "duration 42s")
	_eq(FormatUtils.format_duration(135.0), "02:15", "duration 135s")
	_eq(FormatUtils.format_duration(134.2), "02:15", "duration ceils fractional")
	_eq(FormatUtils.format_duration(5040.0), "1h 24m", "duration 1h 24m")

	## format_countdown
	_eq(FormatUtils.format_countdown(0.0), "any moment", "countdown 0s")
	_eq(FormatUtils.format_countdown(-3.0), "any moment", "countdown negative")
	_eq(FormatUtils.format_countdown(42.0), "42s", "countdown 42s")
	_eq(FormatUtils.format_countdown(135.0), "2m 15s", "countdown 2m 15s")
	_eq(FormatUtils.format_countdown(5040.0), "1h 24m", "countdown 1h 24m")

	## format_number
	_eq(FormatUtils.format_number(0), "0", "number 0")
	_eq(FormatUtils.format_number(1500), "1,500", "number 1,500")
	_eq(FormatUtils.format_number(-1500), "-1,500", "number negative")
	_eq(FormatUtils.format_number(250000), "250K", "number 250K")
	_eq(FormatUtils.format_number(1500000), "1.5M", "number 1.5M")
	_eq(FormatUtils.format_number(2500000000), "2.5B", "number 2.5B")
	_eq(FormatUtils.format_number(1200000000000), "1.2T", "number 1.2T")

	## format_coins
	_eq(FormatUtils.format_coins(1500), "1,500c", "coins 1,500c")
	_eq(FormatUtils.format_coins(250000), "250K", "coins 250K")
	_eq(FormatUtils.format_coins(1500000), "1.5M", "coins 1.5M")

	_finish()
	return true


func _eq(actual: String, expected: String, label: String) -> void:
	if actual == expected:
		_passed += 1
		print("  ✓ %s (%s)" % [label, actual])
	else:
		_failed += 1
		print("  ✗ %s: expected '%s', got '%s'" % [label, expected, actual])


func _finish() -> void:
	print("\n----------------------------------------")
	print(" Results: %d passed, %d failed, %d total" % [_passed, _failed, _passed + _failed])
	print("----------------------------------------\n")
	quit(0 if _failed == 0 else 1)
