class_name MiningGame
extends VBoxContainer

## Self-contained minesweeper minigame for the mining expedition.
## Creates a GridContainer with Button cells, handles reveal/flag/flood-fill logic.

signal game_won
signal game_lost
signal magnify_mode_changed(is_active: bool)

## ── Cell states ──────────────────────────────────────────────────
enum CellState { HIDDEN, REVEALED, FLAGGED }

## ── Configuration ────────────────────────────────────────────────
var grid_width: int = 8
var grid_height: int = 8
var mine_count: int = 10
var _active: bool = false

## ── Internal data ────────────────────────────────────────────────
var _cells: Array = []        ## 2D array of dictionaries {is_mine, adjacent_count, state}
var _grid: GridContainer = null
var _slot_tex: Texture2D = null
var _cell_size: Vector2 = Vector2(32, 32)
var _flags_placed: int = 0
var _cells_revealed: int = 0
## Number of tiles the PLAYER actively dug (tapped a hidden tile to dig). This
## excludes prestige pre-revealed "safe" tiles and magnify blasts, so a
## first-click loss is detected even when the safe-tiles prestige is active.
var _player_digs: int = 0

## ── Touch input cooldown (mobile) ────────────────────────────────
## Tracks last tap time per cell (keyed by "row,col") to enforce 200ms cooldown
## between taps on the same mining tile, preventing accidental double-taps.
const MINING_TAP_COOLDOWN_MS := 200
var _last_tap_times: Dictionary = {}  ## { "r,c": int (msec timestamp) }

## ── Number colors (1-8) ─────────────────────────────────────────
const NUMBER_COLORS := {
	1: Color(0.2, 0.4, 1.0),    ## blue
	2: Color(0.1, 0.6, 0.1),    ## green
	3: Color(0.9, 0.2, 0.2),    ## red
	4: Color(0.5, 0.0, 0.7),    ## purple
	5: Color(0.5, 0.1, 0.1),    ## maroon
	6: Color(0.0, 0.5, 0.5),    ## teal
	7: Color(0.1, 0.1, 0.1),    ## black
	8: Color(0.5, 0.5, 0.5),    ## gray
}

## ── Public API ───────────────────────────────────────────────────

var _magnify_mode: bool = false:  ## When true, next click reveals 3×3 instead of digging
	set(value):
		if _magnify_mode != value:
			_magnify_mode = value
			magnify_mode_changed.emit(value)
var touch_flag_mode: bool = false  ## When true, taps toggle flags instead of digging (mobile)

func start_game(p_width: int, p_height: int, p_mine_count: int) -> void:
	grid_width = p_width
	grid_height = p_height
	mine_count = p_mine_count
	_active = true
	_flags_placed = 0
	_cells_revealed = 0
	_player_digs = 0
	_last_tap_times.clear()

	## Determine cell size to fit entire grid on screen without scrolling.
	## With canvas_items stretch mode, sizes are in design pixels (420px viewport width).
	## No dp_scale needed — Godot handles the scaling to real device pixels.
	var viewport_width: float = 400.0  ## ~420 minus some margin
	var viewport_height: float = 500.0  ## Approximate available height for the grid
	## Leave room for 1px separators between cells
	var available_w := viewport_width - float(grid_width - 1)
	var available_h := viewport_height - float(grid_height - 1)
	var tile_by_width := available_w / float(grid_width)
	var tile_by_height := available_h / float(grid_height)
	## Use the smaller dimension to ensure grid fits both ways
	var tile_px := minf(tile_by_width, tile_by_height)
	## Clamp to reasonable range: minimum 20px (readable), max 64px
	tile_px = clampf(tile_px, 20.0, 64.0)
	_cell_size = Vector2(tile_px, tile_px)

	## Load slot background texture
	_slot_tex = load("res://Assets/UI/slot_bg.png")

	## Initialize cell data
	_cells.clear()
	for r in range(grid_height):
		var row_data: Array = []
		for c in range(grid_width):
			row_data.append({
				"is_mine": false,
				"adjacent_count": 0,
				"state": CellState.HIDDEN,
			})
		_cells.append(row_data)

	## Place mines randomly
	var placed := 0
	while placed < mine_count:
		var r := randi() % grid_height
		var c := randi() % grid_width
		if not _cells[r][c]["is_mine"]:
			_cells[r][c]["is_mine"] = true
			placed += 1

	## Calculate adjacent counts
	for r in range(grid_height):
		for c in range(grid_width):
			if _cells[r][c]["is_mine"]:
				continue
			var count := 0
			for dr in range(-1, 2):
				for dc in range(-1, 2):
					if dr == 0 and dc == 0:
						continue
					var nr := r + dr
					var nc := c + dc
					if nr >= 0 and nr < grid_height and nc >= 0 and nc < grid_width:
						if _cells[nr][nc]["is_mine"]:
							count += 1
			_cells[r][c]["adjacent_count"] = count

	## Build the grid UI
	_build_grid()

	## Pre-reveal safe tiles based on prestige upgrade (safe_tiles level)
	## Each level fires one free magnifier (3×3 reveal + auto-flag mines), no tool consumed.
	var safe_count: int = PlayerData.get_safe_expedition_tiles()
	if safe_count > 0:
		## Cap based on grid size: 10 max on 8x8, 25 max on 16x16
		var max_safe: int = 10 if grid_width <= 8 else 25
		safe_count = mini(safe_count, max_safe)
		## Collect non-mine, non-edge cell centres so the 3×3 stays in bounds
		var candidate_centers: Array = []
		for r in range(1, grid_height - 1):
			for c in range(1, grid_width - 1):
				if not _cells[r][c]["is_mine"]:
					candidate_centers.append(Vector2i(r, c))
		candidate_centers.shuffle()
		## Apply one magnifier blast per prestige level, using non-overlapping centres
		var used: int = 0
		for pos in candidate_centers:
			if used >= safe_count:
				break
			var center := pos as Vector2i
			## Skip centre if the 3×3 area is already fully revealed
			var any_hidden := false
			for dr in range(-1, 2):
				for dc in range(-1, 2):
					var nr: int = center.x + dr
					var nc: int = center.y + dc
					if _cells[nr][nc]["state"] == CellState.HIDDEN:
						any_hidden = true
						break
				if any_hidden:
					break
			if not any_hidden:
				continue
			_apply_magnify_at(center.x, center.y)
			used += 1


func get_mine_count() -> int:
	return mine_count


func get_cells_revealed() -> int:
	return _cells_revealed


## Tiles the player actively dug (excludes prestige pre-reveals / magnify).
## Used for first-click-loss detection so it works even with the safe-tiles
## prestige pre-revealing tiles at the start.
func get_player_digs() -> int:
	return _player_digs


func is_game_active() -> bool:
	return _active

## ── Grid building ────────────────────────────────────────────────

func _build_grid() -> void:
	## Remove old grid if exists
	if _grid != null and is_instance_valid(_grid):
		remove_child(_grid)
		_grid.queue_free()

	_grid = GridContainer.new()
	_grid.columns = grid_width
	_grid.add_theme_constant_override("h_separation", 1)
	_grid.add_theme_constant_override("v_separation", 1)
	_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_grid.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	for r in range(grid_height):
		for c in range(grid_width):
			var btn := Button.new()
			btn.custom_minimum_size = _cell_size
			btn.focus_mode = Control.FOCUS_NONE
			btn.clip_text = true
			btn.set_meta("row", r)
			btn.set_meta("col", c)
			btn.add_to_group("mining_tiles")
			btn.pressed.connect(_on_cell_left_click.bind(r, c))
			btn.gui_input.connect(_on_cell_input.bind(r, c))
			_apply_hidden_style(btn)
			_grid.add_child(btn)

	add_child(_grid)


func _apply_hidden_style(btn: Button) -> void:
	btn.text = ""
	var font_size := 14 if _cell_size.x >= 32 else 11
	btn.add_theme_font_size_override("font_size", font_size)

	if _slot_tex != null:
		var style := StyleBoxTexture.new()
		style.texture = _slot_tex
		btn.add_theme_stylebox_override("normal", style)
		var hover := StyleBoxTexture.new()
		hover.texture = _slot_tex
		hover.modulate_color = Color(1.2, 1.2, 1.3)
		btn.add_theme_stylebox_override("hover", hover)
		btn.add_theme_stylebox_override("pressed", style)
	else:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.3, 0.3, 0.4)
		style.border_width_left = 1; style.border_width_right = 1
		style.border_width_top = 1; style.border_width_bottom = 1
		style.border_color = Color(0.5, 0.5, 0.6)
		btn.add_theme_stylebox_override("normal", style)
		btn.add_theme_stylebox_override("hover", style)
		btn.add_theme_stylebox_override("pressed", style)


func _apply_revealed_style(btn: Button, cell_data: Dictionary) -> void:
	var font_size := 14 if _cell_size.x >= 32 else 11
	btn.add_theme_font_size_override("font_size", font_size)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.75, 0.73, 0.68)
	style.border_width_left = 1; style.border_width_right = 1
	style.border_width_top = 1; style.border_width_bottom = 1
	style.border_color = Color(0.6, 0.58, 0.54)
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("hover", style)
	btn.add_theme_stylebox_override("pressed", style)

	var count: int = cell_data["adjacent_count"]
	if count > 0:
		btn.text = str(count)
		var color: Color = NUMBER_COLORS.get(count, Color.BLACK)
		btn.add_theme_color_override("font_color", color)
		btn.add_theme_color_override("font_hover_color", color)
		btn.add_theme_color_override("font_pressed_color", color)
	else:
		btn.text = ""


func _apply_flagged_style(btn: Button) -> void:
	var font_size := 16 if _cell_size.x >= 32 else 12
	btn.add_theme_font_size_override("font_size", font_size)
	btn.text = "⚑"
	btn.add_theme_color_override("font_color", Color(0.9, 0.2, 0.1))
	btn.add_theme_color_override("font_hover_color", Color(0.9, 0.2, 0.1))
	btn.add_theme_color_override("font_pressed_color", Color(0.9, 0.2, 0.1))


func _apply_mine_style(btn: Button, exploded: bool) -> void:
	var font_size := 16 if _cell_size.x >= 32 else 12
	btn.add_theme_font_size_override("font_size", font_size)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.8, 0.2, 0.2) if exploded else Color(0.6, 0.55, 0.5)
	style.border_width_left = 1; style.border_width_right = 1
	style.border_width_top = 1; style.border_width_bottom = 1
	style.border_color = Color(0.4, 0.2, 0.2)
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("hover", style)
	btn.add_theme_stylebox_override("pressed", style)
	btn.text = "💎"

## ── Input handling ───────────────────────────────────────────────

func _on_cell_left_click(row: int, col: int) -> void:
	if not _active:
		return

	## Enforce 200ms cooldown between taps on the same tile (prevents double-taps)
	var cell_key := "%d,%d" % [row, col]
	var now_ms := Time.get_ticks_msec()
	if _last_tap_times.has(cell_key):
		var elapsed := now_ms - int(_last_tap_times[cell_key])
		if elapsed < MINING_TAP_COOLDOWN_MS:
			return
	_last_tap_times[cell_key] = now_ms

 ## Magnifying glass mode: reveal safe cells and flag mines in 3×3 area
	if _magnify_mode:
		_magnify_mode = false  ## One-use per purchase
		_apply_magnify_at(row, col)
		_check_win()
		return
		
	## Touch flag mode: tap toggles flag instead of digging (mobile)
	## Exception: tapping a revealed number should still chord (clear neighbors)
	if touch_flag_mode:
		var cell: Dictionary = _cells[row][col]
		if cell["state"] == CellState.REVEALED and cell["adjacent_count"] > 0:
			_chord_reveal(row, col)
			return
		_toggle_flag(row, col)
		return

	var cell: Dictionary = _cells[row][col]

	
	## Chording: clicking a revealed number clears neighbors if flags match
	if cell["state"] == CellState.REVEALED:
		if cell["adjacent_count"] > 0:
			_chord_reveal(row, col)
		return

	if cell["state"] == CellState.FLAGGED:
		return  ## Must unflag first (right-click)

	## Reveal the cell — this is a genuine player dig (counts toward first-click
	## detection, unlike prestige pre-reveals / magnify blasts).
	if cell["is_mine"]:
		## Stuffed Roasted Peppers recipe boost ("Miner's Stamina") prevents a
		## fail: the dug mine is auto-flagged (safe) instead of ending the run.
		if _try_prevent_mine_fail(row, col):
			_check_win()
		else:
			_trigger_loss(row, col)
	else:
		_player_digs += 1
		_reveal_cell(row, col)
		_check_win()


## Reveals safe cells and auto-flags mines in the 3×3 area centred on (row, col).
## Does NOT consume a tool — callers are responsible for tool management.
func _apply_magnify_at(row: int, col: int) -> void:
	for dr in range(-1, 2):
		for dc in range(-1, 2):
			var nr := row + dr
			var nc := col + dc
			if nr >= 0 and nr < grid_height and nc >= 0 and nc < grid_width:
				var neighbor: Dictionary = _cells[nr][nc]
				if neighbor["state"] == CellState.HIDDEN:
					if neighbor["is_mine"]:
						neighbor["state"] = CellState.FLAGGED
						_flags_placed += 1
						var nbtn := _get_btn(nr, nc)
						_apply_flagged_style(nbtn)
					else:
						_reveal_cell(nr, nc)


## Chord: if the number of adjacent flags equals the cell's number,
## reveal all non-flagged hidden neighbors.
func _chord_reveal(row: int, col: int) -> void:
	var cell: Dictionary = _cells[row][col]
	var adjacent_flags := 0
	for dr in range(-1, 2):
		for dc in range(-1, 2):
			if dr == 0 and dc == 0:
				continue
			var nr := row + dr
			var nc := col + dc
			if nr >= 0 and nr < grid_height and nc >= 0 and nc < grid_width:
				if _cells[nr][nc]["state"] == CellState.FLAGGED:
					adjacent_flags += 1

	if adjacent_flags != cell["adjacent_count"]:
		return  ## Not enough flags to chord

	## Reveal all hidden neighbors
	for dr in range(-1, 2):
		for dc in range(-1, 2):
			if dr == 0 and dc == 0:
				continue
			var nr := row + dr
			var nc := col + dc
			if nr >= 0 and nr < grid_height and nc >= 0 and nc < grid_width:
				var neighbor: Dictionary = _cells[nr][nc]
				if neighbor["state"] == CellState.HIDDEN:
					if neighbor["is_mine"]:
						## Miner's Stamina boost saves the chorded mine too.
						if _try_prevent_mine_fail(nr, nc):
							continue
						_trigger_loss(nr, nc)
						return
					else:
						_reveal_cell(nr, nc)
	_check_win()


func _on_cell_input(event: InputEvent, row: int, col: int) -> void:
	if not _active:
		return
	# Right-click (desktop) or long-press (mobile) toggles flag
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_toggle_flag(row, col)
	elif event is InputEventScreenTouch and event.pressed and event.double_tap:
		# Double-tap on mobile toggles flag
		_toggle_flag(row, col)


func _toggle_flag(row: int, col: int) -> void:
	var cell: Dictionary = _cells[row][col]
	if cell["state"] == CellState.REVEALED:
		return

	var btn := _get_btn(row, col)
	if cell["state"] == CellState.HIDDEN:
		cell["state"] = CellState.FLAGGED
		_flags_placed += 1
		_apply_flagged_style(btn)
	elif cell["state"] == CellState.FLAGGED:
		cell["state"] = CellState.HIDDEN
		_flags_placed -= 1
		_apply_hidden_style(btn)

	_check_win()

## ── Reveal logic ─────────────────────────────────────────────────

func _reveal_cell(row: int, col: int) -> void:
	var cell: Dictionary = _cells[row][col]
	if cell["state"] != CellState.HIDDEN:
		return
	cell["state"] = CellState.REVEALED
	_cells_revealed += 1
	var btn := _get_btn(row, col)
	_apply_revealed_style(btn, cell)

	## Flood-fill for 0-adjacent cells
	if cell["adjacent_count"] == 0:
		for dr in range(-1, 2):
			for dc in range(-1, 2):
				if dr == 0 and dc == 0:
					continue
				var nr := row + dr
				var nc := col + dc
				if nr >= 0 and nr < grid_height and nc >= 0 and nc < grid_width:
					if _cells[nr][nc]["state"] == CellState.HIDDEN:
						_reveal_cell(nr, nc)

## ── Win/Lose conditions ──────────────────────────────────────────

func _check_win() -> void:
	## Win: all mines flagged correctly, no non-mine cells flagged
	if _flags_placed != mine_count:
		return
	for r in range(grid_height):
		for c in range(grid_width):
			var cell: Dictionary = _cells[r][c]
			if cell["is_mine"] and cell["state"] != CellState.FLAGGED:
				return
			if not cell["is_mine"] and cell["state"] == CellState.FLAGGED:
				return
	## All mines correctly flagged — victory!
	_active = false
	game_won.emit()


## If the "miner_stamina" recipe boost is active, a dug mine is auto-flagged
## (correct) instead of ending the run. Returns true if the fail was prevented.
func _try_prevent_mine_fail(row: int, col: int) -> bool:
	if get_node_or_null("/root/PlayerData") == null:
		return false
	if not PlayerData.boost_active("miner_stamina"):
		return false
	var cell: Dictionary = _cells[row][col]
	if cell["state"] == CellState.HIDDEN:
		cell["state"] = CellState.FLAGGED
		_flags_placed += 1
		var btn := _get_btn(row, col)
		if btn != null:
			_apply_flagged_style(btn)
	return true


func _trigger_loss(clicked_row: int, clicked_col: int) -> void:
	_active = false
	## Reveal all mines
	for r in range(grid_height):
		for c in range(grid_width):
			var cell: Dictionary = _cells[r][c]
			if cell["is_mine"]:
				var btn := _get_btn(r, c)
				var exploded := (r == clicked_row and c == clicked_col)
				_apply_mine_style(btn, exploded)
	await get_tree().create_timer(5.0).timeout
	game_lost.emit()

## ── Utility ──────────────────────────────────────────────────────

func _get_btn(row: int, col: int) -> Button:
	var idx := row * grid_width + col
	return _grid.get_child(idx) as Button


## Returns the dp scale factor from ResponsiveLayoutManager or fallback.
func _get_dp_scale() -> float:
	var rlm = Engine.get_singleton("ResponsiveLayoutManager") if Engine.has_singleton("ResponsiveLayoutManager") else null
	if rlm == null:
		rlm = get_node_or_null("/root/ResponsiveLayoutManager")
	if rlm != null and "dp_scale" in rlm:
		return rlm.dp_scale
	## Fallback: compute from screen DPI (baseline 160 DPI)
	var screen_dpi := DisplayServer.screen_get_dpi()
	if screen_dpi > 0:
		return screen_dpi / 160.0
	return 1.0


## Returns available width for the mining grid in pixels.
## Accounts for safe area and parent container constraints.
func _get_available_width() -> float:
	## Use our own size if available (already laid out in the scene tree)
	if size.x > 0:
		return size.x
	## Fallback to viewport width minus safe area insets
	var viewport_size := get_tree().root.get_visible_rect().size
	var safe_area := DisplayServer.get_display_safe_area()
	var safe_left := maxi(safe_area.position.x, 0)
	var safe_right := maxi(int(viewport_size.x) - (safe_area.position.x + safe_area.size.x), 0)
	return viewport_size.x - float(safe_left) - float(safe_right)
