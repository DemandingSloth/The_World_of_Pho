class_name FormatUtils
extends RefCounted
## Static formatting helpers for durations, countdowns, numbers, and coins.


## Formats a duration in seconds as "MM:SS" (e.g. "02:15") or "Xh Ym" (e.g. "1h 24m").
static func format_duration(seconds: float) -> String:
	var s := maxi(0, int(ceil(seconds)))
	var h := s / 3600
	var m := (s % 3600) / 60
	var sec := s % 60
	if h > 0:
		return "%dh %dm" % [h, m]
	return "%02d:%02d" % [m, sec]


## Formats a countdown in seconds as "Xh Ym", "Xm Ys", "Xs", or "any moment" when <= 0.
static func format_countdown(seconds: float) -> String:
	var s := int(max(0.0, seconds))
	if s <= 0:
		return "any moment"
	var h := s / 3600
	var m := (s % 3600) / 60
	var sec := s % 60
	if h > 0:
		return "%dh %dm" % [h, m]
	if m > 0:
		return "%dm %ds" % [m, sec]
	return "%ds" % sec


## Formats a number for display. Accepts both int and float.
## Examples: 1500 -> "1,500", 250000 -> "250K", 1500000 -> "1.5M".
static func format_number(val: Variant) -> String:
	var numeric_val: float = float(val)
	var negative: bool = numeric_val < 0.0
	var abs_amount: float = abs(numeric_val)
	var result: String

	if abs_amount >= 1_000_000_000_000.0:
		result = _format_abbreviated(abs_amount / 1_000_000_000_000.0, "T")
	elif abs_amount >= 1_000_000_000.0:
		result = _format_abbreviated(abs_amount / 1_000_000_000.0, "B")
	elif abs_amount >= 1_000_000.0:
		result = _format_abbreviated(abs_amount / 1_000_000.0, "M")
	elif abs_amount >= 100_000.0:
		result = _format_abbreviated(abs_amount / 1_000.0, "K")
	else:
		result = _add_commas(int(abs_amount))

	if negative:
		return "-" + result
	return result


## Formats a coin amount for display, appending "c" only when not abbreviated.
## Examples: 1500 -> "1,500c", 250000 -> "250K", 1500000 -> "1.5M".
static func format_coins(val: Variant) -> String:
	var s := format_number(val)
	var last := s.substr(s.length() - 1) if s.length() > 0 else ""
	if last in ["K", "M", "B", "T"]:
		return s
	return s + "c"


static func _format_abbreviated(val: float, suffix: String) -> String:
	if val < 100.0:
		return "%.1f%s" % [val, suffix]
	return "%d%s" % [int(val), suffix]


static func _add_commas(amount: int) -> String:
	var s: String = str(amount)
	var result: String = ""
	var count: int = 0
	for i in range(s.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			result = "," + result
		result = s[i] + result
		count += 1
	return result
