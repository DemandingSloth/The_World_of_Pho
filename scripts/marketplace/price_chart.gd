extends Control

## Lightweight price-history chart drawn with _draw() — no plugins/deps.
##
## Feed it the `points` array returned by MarketplaceAccount.get_price_history()
## (oldest -> newest). Each point is a Dictionary with at least `avg_price`,
## `min_price`, `max_price`, `day`. Draws:
##   • a shaded min/max band
##   • an average-price line with dots
##   • y-axis labels (min & max price) and x-axis labels (first/last day)
##
## Prices are marketplace tokens. Uses PlayerData.format_number for compact
## labels (e.g. 1.2K, 3.4M).

var _points: Array = []

const MARGIN_LEFT := 56.0
const MARGIN_RIGHT := 12.0
const MARGIN_TOP := 14.0
const MARGIN_BOTTOM := 26.0

const COL_BG := Color(0.10, 0.11, 0.16, 1.0)
const COL_GRID := Color(1.0, 1.0, 1.0, 0.08)
const COL_BAND := Color(0.35, 0.65, 1.0, 0.18)
const COL_LINE := Color(0.55, 0.85, 1.0, 1.0)
const COL_DOT := Color(1.0, 0.9, 0.5, 1.0)
const COL_TEXT := Color(0.85, 0.88, 0.95, 1.0)


func set_points(points: Array) -> void:
	_points = points if points != null else []
	queue_redraw()


func _get_font() -> Font:
	## Fall back to the default theme font; good enough for tiny labels.
	return ThemeDB.fallback_font


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, COL_BG, true)

	var font := _get_font()
	var fs := 10

	if _points.size() == 0:
		var msg := "No sales yet for this item."
		var tw := font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, Vector2((size.x - tw) * 0.5, size.y * 0.5), msg,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_TEXT)
		return

	## Compute value range across min/max prices.
	var lo := INF
	var hi := -INF
	for p in _points:
		lo = minf(lo, float(p.get("min_price", p.get("avg_price", 0))))
		hi = maxf(hi, float(p.get("max_price", p.get("avg_price", 0))))
	if lo == INF:
		lo = 0.0
	if hi == -INF:
		hi = 0.0
	## Pad the range so the line isn't glued to the edges; handle flat series.
	if hi <= lo:
		hi = lo + maxf(1.0, lo * 0.1)
	var pad := (hi - lo) * 0.1
	lo = maxf(0.0, lo - pad)
	hi = hi + pad

	var plot_x := MARGIN_LEFT
	var plot_y := MARGIN_TOP
	var plot_w := maxf(1.0, size.x - MARGIN_LEFT - MARGIN_RIGHT)
	var plot_h := maxf(1.0, size.y - MARGIN_TOP - MARGIN_BOTTOM)

	## Grid + y labels (min, mid, max).
	var fracs: Array[float] = [0.0, 0.5, 1.0]
	for f in fracs:
		var y: float = plot_y + plot_h * (1.0 - f)
		draw_line(Vector2(plot_x, y), Vector2(plot_x + plot_w, y), COL_GRID, 1.0)
		var val := int(round(lo + (hi - lo) * f))
		var label := _fmt(val)
		draw_string(font, Vector2(4, y + fs * 0.4), label,
			HORIZONTAL_ALIGNMENT_LEFT, MARGIN_LEFT - 6, fs, COL_TEXT)

	var n := _points.size()

	## Min/max band (as a filled polygon: top = max line, bottom = min line).
	if n >= 2:
		var band := PackedVector2Array()
		for i in range(n):
			band.append(Vector2(_x_at(i, n, plot_x, plot_w),
				_y_at(float(_points[i].get("max_price", 0)), lo, hi, plot_y, plot_h)))
		for i in range(n - 1, -1, -1):
			band.append(Vector2(_x_at(i, n, plot_x, plot_w),
				_y_at(float(_points[i].get("min_price", 0)), lo, hi, plot_y, plot_h)))
		if band.size() >= 3:
			draw_colored_polygon(band, COL_BAND)

	## Average line + dots.
	var prev := Vector2.INF
	for i in range(n):
		var avg := float(_points[i].get("avg_price", 0))
		var pt := Vector2(_x_at(i, n, plot_x, plot_w), _y_at(avg, lo, hi, plot_y, plot_h))
		if prev != Vector2.INF:
			draw_line(prev, pt, COL_LINE, 2.0)
		prev = pt
	for i in range(n):
		var avg2 := float(_points[i].get("avg_price", 0))
		draw_circle(Vector2(_x_at(i, n, plot_x, plot_w), _y_at(avg2, lo, hi, plot_y, plot_h)),
			2.5, COL_DOT)

	## X-axis labels: first and last day (MM-DD).
	var first_day := _short_day(str(_points[0].get("day", "")))
	var last_day := _short_day(str(_points[n - 1].get("day", "")))
	draw_string(font, Vector2(plot_x, size.y - 6), first_day,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_TEXT)
	if n > 1:
		var lw := font.get_string_size(last_day, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, Vector2(plot_x + plot_w - lw, size.y - 6), last_day,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_TEXT)


## Maps a data index to an x screen coordinate.
func _x_at(i: int, n: int, plot_x: float, plot_w: float) -> float:
	if n <= 1:
		return plot_x + plot_w * 0.5
	return plot_x + plot_w * (float(i) / float(n - 1))


## Maps a price value to a y screen coordinate (inverted: higher = up).
func _y_at(v: float, lo: float, hi: float, plot_y: float, plot_h: float) -> float:
	if hi <= lo:
		return plot_y + plot_h * 0.5
	return plot_y + plot_h * (1.0 - (v - lo) / (hi - lo))


func _fmt(v: int) -> String:
	if get_node_or_null("/root/PlayerData") != null:
		return PlayerData.format_number(v)
	return str(v)


## "2026-09-04" -> "09-04". Falls back to the raw string if unexpected.
func _short_day(day: String) -> String:
	var parts := day.split("-")
	if parts.size() == 3:
		return "%s-%s" % [parts[1], parts[2]]
	return day
