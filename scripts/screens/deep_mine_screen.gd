extends BaseScreen

## Deep Mine screen — a grid-dig minigame (unlocked at level 20).
## Tap a tile to dig it (consumes a shovel, 30% gem chance). Rarer gems appear
## deeper; the deepest layer yields diamonds and can drop a Diamond Ring.
## Owning the Excavator lets you clear whole rows without shovels.

const CELL_SIZE := 48

var _status_label: Label = null
var _info_label: Label = null
var _grid_container: GridContainer = null
var _scroll_container: ScrollContainer = null
var _expand_row_btn: Button = null
var _expand_col_btn: Button = null
var _excavator_btn: Button = null
var _collect_all_btn: Button = null
var _shovel_label: Label = null

var _excavator_mode: bool = false
## Drives touch-drag-to-pan + clean-tap-to-act over the mine grid (mobile).
var _pan: GridPanController = null


func get_screen_name() -> String:
	return "deep_mine"


func show_top_bar() -> bool:
	return true


func enter(_params: Dictionary = {}) -> void:
	## Safety net: recover a mine that got left fully dug out (all-black grid)
	## without regenerating. Do this before connecting the signal / building the
	## grid so the fresh state is what gets rendered.
	if get_node_or_null("/root/DeepMine") != null:
		DeepMine.regenerate_if_exhausted()
	_build_ui()
	if get_node_or_null("/root/DeepMine") != null:
		DeepMine.deep_mine_updated.connect(_on_mine_updated)
	PlayerData.data_changed.connect(_on_data_changed)


func exit() -> void:
	if get_node_or_null("/root/DeepMine") != null and DeepMine.deep_mine_updated.is_connected(_on_mine_updated):
		DeepMine.deep_mine_updated.disconnect(_on_mine_updated)
	if PlayerData.data_changed.is_connected(_on_data_changed):
		PlayerData.data_changed.disconnect(_on_data_changed)
	for child in get_children():
		child.queue_free()


## ── Build UI ───────────────────────────────────────────────────

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	## Back button
	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(200, 44)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(_on_back_pressed)
	root.add_child(back_btn)

	## Dark text colors for legibility against the light mountain background.
	var dark := Color(0.12, 0.10, 0.08)
	var dark_soft := Color(0.20, 0.17, 0.12)

	## Title
	var title := Label.new()
	title.text = "⛏ Deep Mine"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", dark)
	root.add_child(title)

	## Depth / layer info
	_info_label = Label.new()
	_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.add_theme_font_size_override("font_size", 10)
	_info_label.add_theme_color_override("font_color", dark_soft)
	root.add_child(_info_label)

	## Shovel count
	_shovel_label = Label.new()
	_shovel_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shovel_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shovel_label.add_theme_font_size_override("font_size", 11)
	_shovel_label.add_theme_color_override("font_color", dark)
	root.add_child(_shovel_label)

	## Status / feedback line. Wraps so a long "found ..." list can't stretch the
	## layout wider than the screen (which broke scrolling and shifted the grid).
	_status_label = Label.new()
	_status_label.custom_minimum_size = Vector2(0, 22)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", dark)
	root.add_child(_status_label)

	## Excavator toggle (only shown when owned). Fills width and wraps its label.
	_excavator_btn = Button.new()
	_excavator_btn.add_theme_font_size_override("font_size", 12)
	_excavator_btn.custom_minimum_size = Vector2(0, 40)
	_excavator_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_excavator_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_excavator_btn.toggle_mode = true
	_excavator_btn.toggled.connect(_on_excavator_toggled)
	root.add_child(_excavator_btn)

	## Collect All button (only shown once the auto-collect prestige is unlocked).
	_collect_all_btn = Button.new()
	_collect_all_btn.text = "🧲 Collect All Treasures"
	_collect_all_btn.add_theme_font_size_override("font_size", 12)
	_collect_all_btn.custom_minimum_size = Vector2(0, 40)
	_collect_all_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_collect_all_btn.pressed.connect(_on_collect_all_pressed)
	root.add_child(_collect_all_btn)

	## Scrollable grid body
	_scroll_container = ScrollContainer.new()
	_scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	## Matches the garden: a drag deadzone lets swipes over the tile buttons
	## scroll the grid, while clean taps still dig. Without it (deadzone 0) the
	## buttons eat every drag and you can only scroll in the gaps between tiles.
	_scroll_container.scroll_deadzone = 16
	root.add_child(_scroll_container)

	## Explicit drag-to-pan / tap-to-act controller for the mine grid. No
	## long-press popup here, so no hooks are registered.
	_pan = GridPanController.new(_scroll_container)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	_scroll_container.add_child(body)

	var grid_center := CenterContainer.new()
	grid_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(grid_center)

	_grid_container = GridContainer.new()
	_grid_container.add_theme_constant_override("h_separation", 2)
	_grid_container.add_theme_constant_override("v_separation", 2)
	grid_center.add_child(_grid_container)

	## Expansion buttons
	var expand_row := HBoxContainer.new()
	expand_row.alignment = BoxContainer.ALIGNMENT_CENTER
	expand_row.add_theme_constant_override("separation", 10)

	_expand_row_btn = Button.new()
	_expand_row_btn.add_theme_font_size_override("font_size", 11)
	_expand_row_btn.pressed.connect(_on_buy_row)
	expand_row.add_child(_expand_row_btn)

	_expand_col_btn = Button.new()
	_expand_col_btn.add_theme_font_size_override("font_size", 11)
	_expand_col_btn.pressed.connect(_on_buy_col)
	expand_row.add_child(_expand_col_btn)

	body.add_child(expand_row)

	_rebuild_all()


## ── Rebuild / refresh ──────────────────────────────────────────

func _rebuild_all() -> void:
	_rebuild_grid()
	_update_info()
	_update_excavator_btn()
	_update_collect_all_btn()
	_update_expand_buttons()


func _update_collect_all_btn() -> void:
	if _collect_all_btn == null:
		return
	if not DeepMine.has_auto_collect():
		_collect_all_btn.visible = false
		return
	_collect_all_btn.visible = true
	_collect_all_btn.disabled = not DeepMine.has_any_pending()


func _rebuild_grid() -> void:
	if _grid_container == null:
		return
	for child in _grid_container.get_children():
		child.queue_free()

	_grid_container.columns = DeepMine.mine_cols

	for r in range(DeepMine.mine_rows):
		for c in range(DeepMine.mine_cols):
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(CELL_SIZE, CELL_SIZE)
			btn.focus_mode = Control.FOCUS_NONE
			## Let touch swipes pass through the button to the ScrollContainer so
			## the grid scrolls on Android (mirrors Garden/Orchard). Without this
			## the button's default MOUSE_FILTER_STOP eats every drag, so only a
			## PC two-finger pan (which bypasses the button) could scroll.
			btn.mouse_filter = Control.MOUSE_FILTER_PASS
			## Touch-and-drag pans the grid; a clean tap digs/collects the tile.
			## (No `pressed` signal — the controller decides tap vs drag.)
			btn.gui_input.connect(_pan.handle_tile_input.bind(Vector2i(r, c), Callable(self, "_on_tile_pressed").bind(r, c)))
			_apply_tile_visual(btn, r, c)
			_grid_container.add_child(btn)


func _refresh_grid_visuals() -> void:
	if _grid_container == null:
		return
	var idx := 0
	for r in range(DeepMine.mine_rows):
		for c in range(DeepMine.mine_cols):
			if idx < _grid_container.get_child_count():
				var btn := _grid_container.get_child(idx) as Button
				if btn:
					_apply_tile_visual(btn, r, c)
			idx += 1


func _apply_tile_visual(btn: Button, row: int, col: int) -> void:
	## Reuse a single persistent sprite per tile. Do NOT queue_free/recreate it
	## each refresh — queue_free is deferred, so recreating leaves the stale
	## sprite visible for a frame and made dug tiles keep showing their texture.
	var sprite: TextureRect = btn.get_node_or_null("TileSprite") as TextureRect
	if sprite == null:
		sprite = TextureRect.new()
		sprite.name = "TileSprite"
		sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
		sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(sprite)

	var style := StyleBoxFlat.new()
	style.set_border_width_all(1)

	## Highest priority: an unearthed gem awaiting pickup — show the gem sprite.
	var display_gem := DeepMine.get_display_gem(row, col)
	if display_gem != "":
		sprite.visible = true
		sprite.texture = DeepMine.get_gem_texture(display_gem)
		style.bg_color = Color(0.16, 0.13, 0.10)
		style.border_color = Color(0.9, 0.8, 0.3)  ## gold border to signal "collect me"
		btn.add_theme_stylebox_override("normal", style)
		btn.add_theme_stylebox_override("hover", style)
		btn.add_theme_stylebox_override("pressed", style)
		btn.tooltip_text = "Tap to collect %s" % display_gem.replace("_", " ").capitalize()
		return

	var depth := DeepMine.get_current_depth(row, col)
	if depth < 0:
		## Fully dug out here — hide the sprite, show a dark empty tile.
		sprite.visible = false
		style.bg_color = Color(0.06, 0.05, 0.04)
		style.border_color = Color(0.25, 0.20, 0.15)
		btn.tooltip_text = "Dug out"
	else:
		sprite.visible = true
		sprite.texture = DeepMine.get_tile_texture(depth)
		style.bg_color = Color(0.16, 0.13, 0.10)
		style.border_color = Color(0.35, 0.28, 0.20)
		btn.tooltip_text = "Layer %d of %d" % [depth + 1, DeepMine.get_layer_count()]

	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("hover", style)
	btn.add_theme_stylebox_override("pressed", style)


## ── Info / button state ────────────────────────────────────────

func _update_info() -> void:
	if _info_label == null:
		return
	var layers := DeepMine.get_layer_count()
	var depth_per := DeepMine.get_dig_depth_per_action()
	_info_label.text = "Grid %d×%d  |  Layers: %d  |  Dig depth: %d/tap" % [
		DeepMine.mine_rows, DeepMine.mine_cols, layers, depth_per]
	_update_shovel_label()


func _update_shovel_label() -> void:
	if _shovel_label == null:
		return
	var shovels := PlayerData.get_tool_count(PlayerData.ToolType.SHOVEL)
	_shovel_label.text = "🪏 Shovels: %d" % shovels


func _update_excavator_btn() -> void:
	if _excavator_btn == null:
		return
	if not DeepMine.has_excavator():
		_excavator_btn.visible = false
		_excavator_btn.button_pressed = false
		_excavator_mode = false
		return
	_excavator_btn.visible = true
	var rows := DeepMine.get_excavator_rows()
	if _excavator_mode:
		_excavator_btn.text = "🚜 Excavator ON — tap a row (%d row%s, free)" % [rows, "s" if rows > 1 else ""]
		_excavator_btn.modulate = Color(1.0, 0.75, 0.3)
	else:
		_excavator_btn.text = "🚜 Excavator: dig %d row%s free" % [rows, "s" if rows > 1 else ""]
		_excavator_btn.modulate = Color.WHITE


func _update_expand_buttons() -> void:
	if _expand_row_btn == null or _expand_col_btn == null:
		return
	if DeepMine.mine_rows >= DeepMineData.MAX_ROWS:
		_expand_row_btn.text = "Rows Maxed"
		_expand_row_btn.disabled = true
	else:
		_expand_row_btn.text = "+Row (%sc)" % PlayerData.format_number(DeepMine.get_row_cost())
		_expand_row_btn.disabled = not DeepMine.can_buy_row()
	if DeepMine.mine_cols >= DeepMineData.MAX_COLS:
		_expand_col_btn.text = "Cols Maxed"
		_expand_col_btn.disabled = true
	else:
		_expand_col_btn.text = "+Column (%sc)" % PlayerData.format_number(DeepMine.get_col_cost())
		_expand_col_btn.disabled = not DeepMine.can_buy_col()


## ── Interaction ────────────────────────────────────────────────

func _on_tile_pressed(row: int, col: int) -> void:
	if _excavator_mode:
		_do_excavate(row)
		return

	## A pickup tap collects an unearthed gem and consumes no shovel — only a
	## fresh dig needs a shovel, so check shovels only when nothing is pending.
	if not DeepMine.has_pending_gem(row, col) and PlayerData.get_tool_count(PlayerData.ToolType.SHOVEL) <= 0:
		_status_label.text = "No shovels! Buy some at the Marketplace."
		return

	var result := DeepMine.dig_tile(row, col)
	var action := str(result.get("action", "none"))
	match action:
		"pickup":
			_status_label.text = "Collected %s" % _gems_text(result.get("gems", {}))
		"dig":
			if DeepMine.has_pending_gem(row, col):
				_status_label.text = "Unearthed %s — tap to collect!" % _gems_text(result.get("gems", {}))
			else:
				_status_label.text = _describe_result(result)
		_:
			_status_label.text = "Nothing to dig here."


func _do_excavate(start_row: int) -> void:
	var result := DeepMine.excavate_row(start_row)
	if int(result.get("dug", 0)) <= 0:
		_status_label.text = "That row is already dug out."
		return
	_status_label.text = "🚜 %s" % _describe_result(result)
	## excavate_row already emitted deep_mine_updated -> _on_mine_updated refreshed
	## the grid to the new state. No flash needed now that digging stops at
	## treasures (the row isn't wiped/regenerated in one action).


func _on_collect_all_pressed() -> void:
	var collected := DeepMine.collect_all()
	if collected.is_empty():
		_status_label.text = "No treasures to collect."
		return
	_status_label.text = "🧲 Collected: %s" % _gems_text(collected)
	_rebuild_all()


## Formats a gems dict as "2 Ruby, 1 Diamond" (pretty-cased names).
func _gems_text(gems: Dictionary) -> String:
	var parts: Array = []
	for gem_type in gems:
		var n := int(gems[gem_type])
		if n <= 0:
			continue
		parts.append("%d %s" % [n, str(gem_type).replace("_", " ").capitalize()])
	return ", ".join(parts) if not parts.is_empty() else "nothing"


## Builds a short feedback string from a dig result, naming the gems found.
## Used mainly by the excavator (which auto-collects across many tiles).
func _describe_result(result: Dictionary) -> String:
	var parts: Array = []
	var gems: Dictionary = result.get("gems", {})
	if not gems.is_empty():
		parts.append(_gems_text(gems))
	if bool(result.get("ring", false)):
		parts.append("💍 Diamond Ring!")
	var dug := int(result.get("dug", 0))
	if parts.is_empty():
		return "Dug %d — no gems this time." % dug
	return "Dug %d — found %s" % [dug, ", ".join(parts)]


func _on_excavator_toggled(pressed: bool) -> void:
	_excavator_mode = pressed
	_update_excavator_btn()
	if pressed:
		_status_label.text = "Excavator active — tap any tile to clear its row."
	else:
		_status_label.text = ""


func _on_buy_row() -> void:
	if DeepMine.buy_row():
		_rebuild_all()
	else:
		_status_label.text = "Can't buy row — not enough coins or maxed out."


func _on_buy_col() -> void:
	if DeepMine.buy_col():
		_rebuild_all()
	else:
		_status_label.text = "Can't buy column — not enough coins or maxed out."


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


## ── Signals ────────────────────────────────────────────────────

func _on_mine_updated() -> void:
	## Grid dimensions may have changed (row/col buy); rebuild if needed.
	var expected := DeepMine.mine_rows * DeepMine.mine_cols
	if _grid_container == null or _grid_container.get_child_count() != expected or _grid_container.columns != DeepMine.mine_cols:
		_rebuild_grid()
	else:
		_refresh_grid_visuals()
	_update_info()
	_update_excavator_btn()
	_update_collect_all_btn()
	_update_expand_buttons()


func _on_data_changed() -> void:
	_update_shovel_label()
	_update_expand_buttons()
