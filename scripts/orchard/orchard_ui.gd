class_name OrchardUI
extends VBoxContainer

## The orchard UI.
## Contains: sapling selection bar, tools (Shovel, Harvest All), orchard grid, and expansion buttons.

const CELL_SIZE := 56
const REFRESH_INTERVAL := 5.0
const LONG_PRESS_DURATION := 0.5   ## Seconds to hold before the info popup shows
const LONG_PRESS_MOVE_CANCEL := 12.0  ## Pixels of movement that cancels a long press

## Long-press tracking (for mobile: shows the same info as the desktop hover tooltip)
var _press_timer: Timer = null
var _pressing_btn: Button = null
var _press_row: int = -1
var _press_col: int = -1
var _press_start_pos: Vector2 = Vector2.ZERO
var _long_press_fired: bool = false
var _info_dialog: AcceptDialog = null

var _selected_sapling: int = -1  ## Currently selected TreeType or -1
var _shovel_mode: bool = false
var _auto_next_sapling_enabled: bool = false

var _status_label: Label = null
var _sapling_bar: HBoxContainer = null
var _auto_next_sapling_cb: CheckBox = null
var _tool_status_label: Label = null
var _auto_plant_btn: Button = null
var _auto_plant_row: HBoxContainer = null
var _auto_plant_rows_dd: OptionButton = null
var _shovel_btn: Button = null
var _harvest_all_btn: Button = null
## True while a per-row "Harvest All" sweep is running (prevents re-entry and
## the mid-sweep orchard_updated emits from fighting the incremental refresh).
var _is_harvesting: bool = false
## True while a per-row auto-plant sweep is running (same reasons as above).
var _is_auto_planting: bool = false
var _scroll_container: ScrollContainer = null
var _grid_container: GridContainer = null
var _expand_row_btn: Button = null
var _expand_col_btn: Button = null
var _refresh_timer: Timer = null
## Drives touch-drag-to-pan + clean-tap-to-act over the orchard grid (mobile).
var _pan: GridPanController = null

signal coins_changed


func _ready() -> void:
	_build_ui()
	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = REFRESH_INTERVAL
	_refresh_timer.autostart = true
	_refresh_timer.timeout.connect(_on_refresh_tick)
	add_child(_refresh_timer)

	## Long-press timer — fires the info popup if a cell is held long enough.
	_press_timer = Timer.new()
	_press_timer.one_shot = true
	_press_timer.wait_time = LONG_PRESS_DURATION
	_press_timer.timeout.connect(_on_long_press_timeout)
	add_child(_press_timer)
	
	if get_node_or_null("/root/Orchard") != null:
		Orchard.orchard_updated.connect(_rebuild_all)


func _build_ui() -> void:
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	## Status label with stable height to prevent layout shifts
	_status_label = Label.new()
	_status_label.custom_minimum_size = Vector2(0, 24)
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.text = "Select a sapling, then tap a plot to plant."
	add_child(_status_label)

	## Sapling bar section
	var sapling_section := VBoxContainer.new()
	sapling_section.add_theme_constant_override("separation", 2)
	sapling_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var sapling_title := Label.new()
	sapling_title.text = "Your Saplings:"
	sapling_title.add_theme_font_size_override("font_size", 11)
	sapling_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sapling_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sapling_section.add_child(sapling_title)

	_sapling_bar = HBoxContainer.new()
	_sapling_bar.add_theme_constant_override("separation", 6)
	_sapling_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	_sapling_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sapling_section.add_child(_sapling_bar)

	if get_node_or_null("/root/Orchard") != null:
		_auto_next_sapling_enabled = Orchard.auto_select_next_sapling
	_auto_next_sapling_cb = CheckBox.new()
	_auto_next_sapling_cb.name = "AutoNextSaplingCheckBox"
	_auto_next_sapling_cb.text = "Auto-select next sapling when out"
	_auto_next_sapling_cb.add_theme_font_size_override("font_size", 10)
	_auto_next_sapling_cb.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_auto_next_sapling_cb.button_pressed = _auto_next_sapling_enabled
	_auto_next_sapling_cb.toggled.connect(_on_auto_next_sapling_toggled)
	sapling_section.add_child(_auto_next_sapling_cb)

	add_child(sapling_section)

	## Tool bar (Shovel, Harvest All)
	var tool_bar := HBoxContainer.new()
	tool_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	tool_bar.add_theme_constant_override("separation", 10)
	tool_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_shovel_btn = Button.new()
	_shovel_btn.custom_minimum_size = Vector2(40, 40)
	_shovel_btn.toggle_mode = true
	_shovel_btn.toggled.connect(_on_shovel_toggled)
	_shovel_btn.tooltip_text = "Shovel: remove tree (leaves a stump)"
	var shovel_tex: Texture2D = load("res://Assets/Shovel.png")
	if shovel_tex:
		var shovel_icon := TextureRect.new()
		shovel_icon.texture = shovel_tex
		shovel_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		shovel_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		shovel_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		shovel_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_shovel_btn.add_child(shovel_icon)
	else:
		_shovel_btn.text = "⛏ Shovel"
	tool_bar.add_child(_shovel_btn)

	_harvest_all_btn = Button.new()
	_harvest_all_btn.custom_minimum_size = Vector2(130, 40)
	_harvest_all_btn.text = "🧺 Harvest All"
	_harvest_all_btn.add_theme_font_size_override("font_size", 12)
	_harvest_all_btn.pressed.connect(_on_harvest_all_pressed)
	tool_bar.add_child(_harvest_all_btn)

	add_child(tool_bar)

	## Tool status label
	_tool_status_label = Label.new()
	_tool_status_label.add_theme_font_size_override("font_size", 10)
	_tool_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tool_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tool_status_label.modulate = Color(0.9, 0.9, 0.5)
	add_child(_tool_status_label)

	## Auto-Plant row: [rows picker] [Auto-Plant button] (visible only when
	## prestige level > 0). The picker lets the player plant fewer rows than
	## they've unlocked; the choice is remembered.
	_auto_plant_row = HBoxContainer.new()
	_auto_plant_row.add_theme_constant_override("separation", 6)
	_auto_plant_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_child(_auto_plant_row)

	var rows_lbl := Label.new()
	rows_lbl.text = "Rows:"
	rows_lbl.add_theme_font_size_override("font_size", 12)
	_auto_plant_row.add_child(rows_lbl)

	_auto_plant_rows_dd = OptionButton.new()
	_auto_plant_rows_dd.add_theme_font_size_override("font_size", 12)
	_auto_plant_rows_dd.custom_minimum_size = Vector2(60, 40)
	_auto_plant_rows_dd.item_selected.connect(func(_i):
		PlayerData.orchard_auto_plant_rows = _auto_plant_rows_dd.get_selected_id()
		PlayerData.save_data()
		_refresh_auto_plant_btn())
	_auto_plant_row.add_child(_auto_plant_rows_dd)

	_auto_plant_btn = Button.new()
	_auto_plant_btn.name = "AutoPlantBtn"
	_auto_plant_btn.add_theme_font_size_override("font_size", 12)
	_auto_plant_btn.custom_minimum_size = Vector2(220, 40)
	_auto_plant_btn.pressed.connect(_on_auto_plant_pressed)
	_auto_plant_row.add_child(_auto_plant_btn)
	_refresh_auto_plant_btn()

	## Scrollable orchard body
	_scroll_container = ScrollContainer.new()
	_scroll_container.name = "OrchardScroll"
	_scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll_container.scroll_deadzone = 16
	add_child(_scroll_container)

	## Explicit drag-to-pan / tap-to-act controller for the orchard grid. Keeps
	## the long-press info popup via the hooks below.
	_pan = GridPanController.new(_scroll_container)
	_pan.set_long_press_hooks(
		Callable(self, "_pan_long_press_began"),
		Callable(self, "_pan_long_press_moved"),
		Callable(self, "_pan_long_press_ended"))

	var orchard_body := VBoxContainer.new()
	orchard_body.name = "OrchardBody"
	orchard_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	orchard_body.add_theme_constant_override("separation", 8)
	_scroll_container.add_child(orchard_body)

	var grid_center := CenterContainer.new()
	grid_center.name = "GridCenter"
	grid_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	orchard_body.add_child(grid_center)

	_grid_container = GridContainer.new()
	_grid_container.add_theme_constant_override("h_separation", 2)
	_grid_container.add_theme_constant_override("v_separation", 2)
	grid_center.add_child(_grid_container)

	## Expansion buttons
	var expand_row := HBoxContainer.new()
	expand_row.alignment = BoxContainer.ALIGNMENT_CENTER
	expand_row.add_theme_constant_override("separation", 10)

	_expand_row_btn = Button.new()
	_expand_row_btn.text = "+Row"
	_expand_row_btn.add_theme_font_size_override("font_size", 11)
	_expand_row_btn.pressed.connect(_on_buy_row)
	expand_row.add_child(_expand_row_btn)

	_expand_col_btn = Button.new()
	_expand_col_btn.text = "+Column"
	_expand_col_btn.add_theme_font_size_override("font_size", 11)
	_expand_col_btn.pressed.connect(_on_buy_col)
	expand_row.add_child(_expand_col_btn)

	orchard_body.add_child(expand_row)

	_rebuild_all()


func _rebuild_all() -> void:
	## During a per-row Harvest All / auto-plant sweep, each row emits
	## orchard_updated. Skip the heavy full rebuild here — the sweep refreshes
	## each row in place and does a final full pass when it finishes.
	if _is_harvesting or _is_auto_planting:
		return
	_rebuild_sapling_bar()
	var expected_children := Orchard.orchard_rows * Orchard.orchard_cols
	if _grid_container == null or _grid_container.get_child_count() != expected_children or _grid_container.columns != Orchard.orchard_cols:
		_rebuild_grid()
	else:
		_refresh_grid_visuals()
	_update_expand_buttons()
	_update_tool_status()
	_refresh_auto_plant_btn()


func _on_auto_next_sapling_toggled(toggled_on: bool) -> void:
	_auto_next_sapling_enabled = toggled_on
	if get_node_or_null("/root/Orchard") != null:
		Orchard.set_auto_select_next_sapling(toggled_on)


func _advance_to_next_sapling_if_needed() -> void:
	if _selected_sapling < 0:
		return
	if Orchard.get_sapling_count(_selected_sapling) > 0:
		return

	if _auto_next_sapling_enabled:
		var total_types: int = Orchard.TREE_DEFS.size()
		var found_next := false
		for offset in range(1, total_types):
			var next_type: int = (_selected_sapling + offset) % total_types
			if Orchard.get_sapling_count(next_type) > 0:
				_selected_sapling = next_type
				found_next = true
				var next_def := Orchard.get_tree_def(_selected_sapling)
				_status_label.text = "Planted! Out of previous saplings — switched to %s." % next_def.get("fruit_name", "")
				break
		if not found_next:
			_selected_sapling = -1
			_status_label.text = "Planted! No saplings remaining in inventory."
	else:
		_selected_sapling = -1

	_rebuild_sapling_bar()
	_refresh_auto_plant_btn()


func _rebuild_sapling_bar() -> void:
	if _sapling_bar == null:
		return

	## Only show sapling types the player actually owns (matches the garden's
	## seed bar, which skips seeds with count 0). If none are owned the bar is
	## empty.
	var owned_types: Array[int] = []
	for i in range(Orchard.TREE_DEFS.size()):
		if Orchard.get_sapling_count(i) > 0:
			owned_types.append(i)

	## Clear a selection whose sapling is no longer owned (and thus no longer
	## shown), so the player isn't left with an invisible/stale selection.
	if _selected_sapling >= 0 and Orchard.get_sapling_count(_selected_sapling) <= 0:
		_selected_sapling = -1

	## Update existing buttons in-place to avoid layout flickering/jumping, but
	## only when the exact set of owned types still matches what's displayed
	## (each item stores its tree_type in meta). If the set changed (a type ran
	## out or was restocked), fall through to a full rebuild.
	if _sapling_bar.get_child_count() == owned_types.size():
		var matches := true
		for idx in range(owned_types.size()):
			var item: VBoxContainer = _sapling_bar.get_child(idx) as VBoxContainer
			if item == null or int(item.get_meta("tree_type", -1)) != owned_types[idx]:
				matches = false
				break
		if matches:
			for idx in range(owned_types.size()):
				var tt: int = owned_types[idx]
				var count: int = Orchard.get_sapling_count(tt)
				var def: Dictionary = Orchard.TREE_DEFS[tt]
				var item: VBoxContainer = _sapling_bar.get_child(idx) as VBoxContainer
				if item != null and item.get_child_count() >= 2:
					var btn: Button = item.get_child(0) as Button
					var lbl: Label = item.get_child(1) as Label
					if btn:
						btn.modulate = Color(1.0, 0.85, 0.2) if _selected_sapling == tt else Color(1.0, 1.0, 1.0)
					if lbl:
						lbl.text = "%s:%d" % [def.get("fruit_name", "").substr(0, 4), count]
			return

	for child in _sapling_bar.get_children():
		child.queue_free()

	for i in owned_types:
		var count: int = Orchard.get_sapling_count(i)
		var def: Dictionary = Orchard.TREE_DEFS[i]
		var item := VBoxContainer.new()
		item.add_theme_constant_override("separation", 1)
		## Remember which tree type this item represents so the in-place update
		## path above can verify the displayed set still matches what's owned.
		item.set_meta("tree_type", i)

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(40, 40)
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_on_sapling_selected.bind(i))
		if _selected_sapling == i:
			btn.modulate = Color(1.0, 0.85, 0.2)

		## Fruit trees show their fruit icon; the Christmas Conifer produces
		## presents, so its sapling slot shows THIS SAVE's present sprite.
		var fruit_atlas: Texture2D = null
		if bool(Orchard.TREE_DEFS[i].get("is_conifer", false)):
			fruit_atlas = PlayerData.get_present_texture(PlayerData.ensure_present_variant())
		else:
			fruit_atlas = Orchard.get_fruit_texture(i)
		if fruit_atlas:
			var sprite := TextureRect.new()
			sprite.texture = fruit_atlas
			sprite.custom_minimum_size = Vector2(28, 28)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			btn.add_child(sprite)
		
		item.add_child(btn)

		var lbl := Label.new()
		lbl.text = "%s:%d" % [def.get("fruit_name", "").substr(0, 4), count]
		lbl.add_theme_font_size_override("font_size", 8)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		item.add_child(lbl)

		_sapling_bar.add_child(item)


func _on_sapling_selected(tree_type: int) -> void:
	if _selected_sapling == tree_type:
		_selected_sapling = -1
		_status_label.text = "Sapling deselected."
	else:
		_selected_sapling = tree_type
		_shovel_mode = false
		if _shovel_btn:
			_shovel_btn.button_pressed = false
		var def := Orchard.get_tree_def(tree_type)
		_status_label.text = "%s selected. Tap a plot to plant." % def.get("fruit_name", "")
	_rebuild_sapling_bar()
	_update_tool_status()
	_refresh_auto_plant_btn()


func _on_shovel_toggled(pressed: bool) -> void:
	_shovel_mode = pressed
	if pressed:
		_selected_sapling = -1
		_rebuild_sapling_bar()
		_status_label.text = "Shovel mode ON. Tap a tree to remove."
	else:
		_status_label.text = "Select a sapling, then tap a plot to plant."
	_update_tool_status()
	_refresh_auto_plant_btn()


func _update_tool_status() -> void:
	if _tool_status_label == null:
		return
	if _shovel_mode:
		_tool_status_label.text = "⛏ Shovel Active — Click tree to remove"
	else:
		_tool_status_label.text = ""


func _rebuild_grid() -> void:
	if _grid_container == null:
		return

	var prev_h := 0
	var prev_v := 0
	if _scroll_container != null and is_instance_valid(_scroll_container):
		prev_h = _scroll_container.scroll_horizontal
		prev_v = _scroll_container.scroll_vertical

	for child in _grid_container.get_children():
		child.queue_free()

	_grid_container.columns = Orchard.orchard_cols

	for r in range(Orchard.orchard_rows):
		for c in range(Orchard.orchard_cols):
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(CELL_SIZE, CELL_SIZE)
			btn.focus_mode = Control.FOCUS_NONE
			btn.mouse_filter = Control.MOUSE_FILTER_PASS
			## Touch-and-drag pans the grid; a clean tap runs _on_cell_pressed.
			## The controller supplies drag vs tap; long-press info popup is kept
			## through the hooks wired in _build_ui.
			btn.gui_input.connect(_pan.handle_tile_input.bind([btn, r, c], Callable(self, "_on_cell_pressed").bind(r, c)))
			_apply_cell_visual(btn, r, c)
			_grid_container.add_child(btn)

	if _scroll_container != null and is_instance_valid(_scroll_container) and (prev_h > 0 or prev_v > 0):
		_scroll_container.set_deferred("scroll_horizontal", prev_h)
		_scroll_container.set_deferred("scroll_vertical", prev_v)


func _apply_cell_visual(btn: Button, row: int, col: int) -> void:
	var cell = Orchard.grid[row][col]
	var farmland_tex: Texture2D = load("res://Assets/Plants/farmland.png")

	btn.text = ""

	if cell == null:
		## Empty plot — use farmland sprite
		if farmland_tex:
			var style := StyleBoxTexture.new()
			style.texture = farmland_tex
			btn.add_theme_stylebox_override("normal", style)
			btn.add_theme_stylebox_override("hover", style)
			btn.add_theme_stylebox_override("pressed", style)
		else:
			var style := StyleBoxFlat.new()
			style.bg_color = Color(0.35, 0.25, 0.15)
			style.border_width_left = 1; style.border_width_right = 1
			style.border_width_top = 1; style.border_width_bottom = 1
			style.border_color = Color(0.45, 0.35, 0.2)
			btn.add_theme_stylebox_override("normal", style)
			btn.add_theme_stylebox_override("hover", style)
			btn.add_theme_stylebox_override("pressed", style)

		## Remove any child sprites
		for child in btn.get_children():
			child.queue_free()
		var empty_tip := "Empty Orchard Plot — Tap with a sapling selected to plant."
		if btn.tooltip_text != empty_tip:
			btn.tooltip_text = empty_tip
		return

	if cell is Dictionary and cell.get("is_stump", false):
		## Stump — use normal farmland background
		if farmland_tex:
			var style := StyleBoxTexture.new()
			style.texture = farmland_tex
			btn.add_theme_stylebox_override("normal", style)
			btn.add_theme_stylebox_override("hover", style)
			btn.add_theme_stylebox_override("pressed", style)
		else:
			var style := StyleBoxFlat.new()
			style.bg_color = Color(0.35, 0.25, 0.15)
			style.border_width_left = 1; style.border_width_right = 1
			style.border_width_top = 1; style.border_width_bottom = 1
			style.border_color = Color(0.45, 0.35, 0.2)
			btn.add_theme_stylebox_override("normal", style)
			btn.add_theme_stylebox_override("hover", style)
			btn.add_theme_stylebox_override("pressed", style)

		## Stump — remove tree/badge children if any
		var old_tree = btn.get_node_or_null("TreeSprite")
		if old_tree: old_tree.queue_free()
		var old_badge = btn.get_node_or_null("FruitBadge")
		if old_badge: old_badge.queue_free()

		var stump_sprite: TextureRect = btn.get_node_or_null("StumpSprite") as TextureRect
		if stump_sprite == null:
			var stump_tex := Orchard.get_stump_texture()
			if stump_tex:
				stump_sprite = TextureRect.new()
				stump_sprite.name = "StumpSprite"
				stump_sprite.texture = stump_tex
				stump_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				stump_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				stump_sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
				stump_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
				btn.add_child(stump_sprite)

		var now := TrustedClock.now()
		var remaining := maxf(0.0, float(cell.get("decay_end_time", 0.0)) - now)

		var timer_lbl: Label = btn.get_node_or_null("TimerLabel") as Label
		if timer_lbl == null:
			timer_lbl = Label.new()
			timer_lbl.name = "TimerLabel"
			timer_lbl.add_theme_font_size_override("font_size", 8)
			timer_lbl.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
			timer_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			timer_lbl.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
			btn.add_child(timer_lbl)
		var timer_text := FormatUtils.format_duration(remaining)
		if timer_lbl.text != timer_text:
			timer_lbl.text = timer_text

		var stump_tip := "Decaying Stump — %s left before soil clears" % timer_text
		if btn.tooltip_text != stump_tip:
			btn.tooltip_text = stump_tip
		return

	## Planted Tree
	var old_stump = btn.get_node_or_null("StumpSprite")
	if old_stump: old_stump.queue_free()
	var old_timer = btn.get_node_or_null("TimerLabel")
	if old_timer: old_timer.queue_free()

	var tree_type: int = cell.get("tree_type", 0)
	var stage := Orchard.get_growth_stage(row, col)
	var def := Orchard.get_tree_def(tree_type)
	var available_fruit := Orchard.get_available_fruit(row, col)
	var harvestable := available_fruit > 0
	var age_days := Orchard.get_tree_age_days(row, col)
	var rate := Orchard.get_stage_daily_rate(stage)

	if farmland_tex:
		var style := StyleBoxTexture.new()
		style.texture = farmland_tex
		if harvestable:
			style.modulate_color = Color(1.1, 1.2, 0.9)
		btn.add_theme_stylebox_override("normal", style)
		btn.add_theme_stylebox_override("hover", style)
		btn.add_theme_stylebox_override("pressed", style)
	else:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.3, 0.45, 0.2) if not harvestable else Color(0.2, 0.55, 0.15)
		style.border_width_left = 1; style.border_width_right = 1
		style.border_width_top = 1; style.border_width_bottom = 1
		style.border_color = Color(0.4, 0.55, 0.3) if not harvestable else Color(0.9, 0.8, 0.2)
		btn.add_theme_stylebox_override("normal", style)
		btn.add_theme_stylebox_override("hover", style)
		btn.add_theme_stylebox_override("pressed", style)

	var tree_tex := Orchard.get_tree_texture(tree_type, stage)
	var tree_sprite: TextureRect = btn.get_node_or_null("TreeSprite") as TextureRect
	if tree_sprite == null:
		tree_sprite = TextureRect.new()
		tree_sprite.name = "TreeSprite"
		tree_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tree_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tree_sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
		tree_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(tree_sprite)
	if tree_sprite.texture != tree_tex:
		tree_sprite.texture = tree_tex

	## Ready fruit indicator badge
	var badge: PanelContainer = btn.get_node_or_null("FruitBadge") as PanelContainer
	if available_fruit > 0:
		if badge == null:
			badge = PanelContainer.new()
			badge.name = "FruitBadge"
			badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			var badge_style := StyleBoxFlat.new()
			badge_style.bg_color = Color(0.8, 0.15, 0.15, 0.9)
			badge_style.corner_radius_top_left = 6
			badge_style.corner_radius_top_right = 6
			badge_style.corner_radius_bottom_left = 6
			badge_style.corner_radius_bottom_right = 6
			badge.add_theme_stylebox_override("panel", badge_style)

			var badge_lbl := Label.new()
			badge_lbl.name = "BadgeLabel"
			badge_lbl.add_theme_font_size_override("font_size", 9)
			badge_lbl.add_theme_color_override("font_color", Color.WHITE)
			badge.add_child(badge_lbl)
			btn.add_child(badge)

		var badge_lbl: Label = badge.get_node_or_null("BadgeLabel") as Label
		if badge_lbl and badge_lbl.text != str(available_fruit):
			badge_lbl.text = str(available_fruit)
	elif badge != null:
		badge.queue_free()

	## Build comprehensive tooltip only if changed
	var stage_names: Array[String] = [
		"Sprout (0/day)",
		"Sapling (+1/day)",
		"Young Tree (+3/day)",
		"Mature Tree (+5/day)",
		"Full Tree (+10/day)"
	]
	var stage_name: String = stage_names[stage] if stage >= 0 and stage < stage_names.size() else "Tree"
	## Fruit accumulates every day since planting: total = floor(age × rate/day).
	## e.g. an 8-day Mature tree at 5/day has produced 40 total. The per-day rate
	## alone reads misleadingly, so we surface the accumulated total too.
	var fruit_name: String = def.get("fruit_name", "fruit")
	var total_produced: int = int(age_days * rate)
	var tooltip_lines: Array = [
		"%s — %s" % [def.get("name", "Tree"), stage_name],
		"Age: %.1f days" % age_days,
		"Produces %d %s/day (accumulates)" % [rate, fruit_name],
		"Total grown: %d %s over %.1f days" % [total_produced, fruit_name, age_days],
		"Ready to harvest: %d %s" % [available_fruit, fruit_name],
	]
	var new_tooltip := "\n".join(tooltip_lines)
	if btn.tooltip_text != new_tooltip:
		btn.tooltip_text = new_tooltip


## Detects long-press on a cell (touch or mouse) to show the info popup that
## desktop users get from hovering. A normal tap/click is unaffected.
## Long-press hooks driven by GridPanController. `began` starts the hold timer
## for the info popup, `moved` (finger dragged = panning) cancels it, `ended`
## cancels on release. `cell` is the [button, row, col] context bound per tile.
func _pan_long_press_began(cell: Variant) -> void:
	if cell is Array and cell.size() == 3:
		_begin_press(cell[0] as Button, int(cell[1]), int(cell[2]), Vector2.ZERO)


func _pan_long_press_moved(_dist: float) -> void:
	_cancel_press()


func _pan_long_press_ended() -> void:
	_end_press()


func _begin_press(btn: Button, row: int, col: int, pos: Vector2) -> void:
	_pressing_btn = btn
	_press_row = row
	_press_col = col
	_press_start_pos = pos
	_long_press_fired = false
	if _press_timer:
		_press_timer.start()


func _end_press() -> void:
	if _press_timer:
		_press_timer.stop()
	_pressing_btn = null
	_press_row = -1
	_press_col = -1


func _cancel_press() -> void:
	if _press_timer:
		_press_timer.stop()
	_pressing_btn = null
	_press_row = -1
	_press_col = -1


func _on_long_press_timeout() -> void:
	if _pressing_btn == null or not is_instance_valid(_pressing_btn) or _press_row < 0 or _press_col < 0:
		return
	## Guard against the cell being cleared/rebuilt out from under the press.
	if _press_row >= Orchard.orchard_rows or _press_col >= Orchard.orchard_cols:
		return
	## Mark so the release doesn't also trigger a plant/harvest action.
	_long_press_fired = true
	_show_cell_info_popup(_pressing_btn, _press_row, _press_col)


## Shows a popup with the same info the desktop hover tooltip displays.
func _show_cell_info_popup(btn: Button, row: int, col: int) -> void:
	## Make sure the tooltip text reflects the current cell state.
	_apply_cell_visual(btn, row, col)
	var info: String = btn.tooltip_text
	if info.strip_edges().is_empty():
		return

	if _info_dialog == null:
		_info_dialog = AcceptDialog.new()
		_info_dialog.title = "Plot Info"
		_info_dialog.exclusive = false
		_info_dialog.unresizable = false
		## Cream / off-white text for the dialog body.
		var body_label := _info_dialog.get_label()
		if body_label:
			body_label.add_theme_color_override("font_color", Color(0.96, 0.93, 0.82))
		add_child(_info_dialog)

	_info_dialog.dialog_text = info
	_info_dialog.reset_size()
	_info_dialog.popup_centered()


func _on_cell_pressed(row: int, col: int) -> void:
	## Suppress the tap action that follows a long press (which showed the popup).
	if _long_press_fired:
		_long_press_fired = false
		return

	var cell = Orchard.grid[row][col]

	## Case 1: Shovel Mode
	if _shovel_mode:
		if cell != null and not cell.get("is_stump", false):
			var def := Orchard.get_tree_def(cell.get("tree_type", 0))
			if Orchard.is_tree_time_locked(row, col):
				_status_label.text = "This tree was harvested ahead of time (device clock changed). It can't be removed until real time catches up."
			elif Orchard.remove_tree(row, col):
				_status_label.text = "Removed %s. Left a decaying stump." % def.get("name", "tree")
		elif cell != null and cell.get("is_stump", false):
			_status_label.text = "Stump is still decomposing."
		return

	## Case 2: Empty cell -> Plant selected sapling
	if cell == null:
		if _selected_sapling >= 0:
			if Orchard.get_sapling_count(_selected_sapling) > 0:
				if Orchard.plant_sapling(row, col, _selected_sapling):
					var def := Orchard.get_tree_def(_selected_sapling)
					_status_label.text = "Planted %s Sapling!" % def.get("fruit_name", "")
					if Orchard.get_sapling_count(_selected_sapling) <= 0:
						_advance_to_next_sapling_if_needed()
					else:
						_rebuild_sapling_bar()
						_refresh_auto_plant_btn()
			else:
				_status_label.text = "No saplings of that type remaining."
		else:
			_status_label.text = "Select a sapling from above to plant here."
		return

	## Case 3: Stump
	if cell.get("is_stump", false):
		_status_label.text = "This plot has a stump decaying. Please wait."
		return

	## Case 4: Planted Tree -> Harvest
	var available := Orchard.get_available_fruit(row, col)
	if available > 0:
		var res := Orchard.harvest_tree(row, col)
		if res["count"] > 0:
			_status_label.text = "Harvested %d %s!" % [res["count"], res["name"]]
			coins_changed.emit()
	else:
		var stage := Orchard.get_growth_stage(row, col)
		var def := Orchard.get_tree_def(cell.get("tree_type", 0))
		if stage <= 0:
			_status_label.text = "%s is in sprout stage (produces no fruit yet)." % def.get("name", "Tree")
		else:
			_status_label.text = "%s has no fruit ready right now. Check back tomorrow!" % def.get("name", "Tree")


## Harvests the whole orchard ONE ROW AT A TIME, refreshing that row and
## yielding a frame between rows so the grid visibly updates top-to-bottom
## instead of freezing and popping in at the end. Each row saves/emits once
## (Orchard.harvest_row), so there's no per-cell disk-write storm.
func _on_harvest_all_pressed() -> void:
	if _is_harvesting:
		return
	_is_harvesting = true
	if _harvest_all_btn != null:
		_harvest_all_btn.disabled = true

	var grand_totals: Dictionary = {}  ## fruit_id -> count
	var grand_count := 0

	for r in range(Orchard.orchard_rows):
		var res := Orchard.harvest_row(r)
		if int(res["total_count"]) > 0:
			for fid in res["totals"]:
				grand_totals[fid] = grand_totals.get(fid, 0) + int(res["totals"][fid])
			grand_count += int(res["total_count"])
			## Update just this row's cells immediately for a "working" feel,
			## then let the frame render before moving to the next row.
			_refresh_row_visuals(r)
			_status_label.text = "Harvesting… row %d/%d" % [r + 1, Orchard.orchard_rows]
			await get_tree().process_frame

	if grand_count > 0:
		var parts: Array = []
		for fid in grand_totals:
			parts.append("%d %s" % [grand_totals[fid], str(fid).capitalize()])
		_status_label.text = "Harvested: %s!" % ", ".join(parts)
		coins_changed.emit()
	else:
		_status_label.text = "No trees have ripe fruit ready to harvest right now."

	if _harvest_all_btn != null:
		_harvest_all_btn.disabled = false
	_is_harvesting = false
	## One final full refresh now that the sweep is done (cheap, once).
	_rebuild_all()


## Applies the cell visual for every button in a single row (in place, no node
## creation) — used for incremental per-row harvest feedback.
func _refresh_row_visuals(row: int) -> void:
	if _grid_container == null:
		return
	var cols := Orchard.orchard_cols
	for c in range(cols):
		var idx := row * cols + c
		if idx < _grid_container.get_child_count():
			var btn: Button = _grid_container.get_child(idx) as Button
			if btn != null:
				_apply_cell_visual(btn, row, c)


func _on_refresh_tick() -> void:
	Orchard.clean_expired_stumps()
	_refresh_grid_visuals()


func _refresh_grid_visuals() -> void:
	if _grid_container == null:
		return
	var idx := 0
	for r in range(Orchard.orchard_rows):
		for c in range(Orchard.orchard_cols):
			if idx < _grid_container.get_child_count():
				var btn: Button = _grid_container.get_child(idx) as Button
				_apply_cell_visual(btn, r, c)
			idx += 1


func _update_expand_buttons() -> void:
	if _expand_row_btn == null or _expand_col_btn == null:
		return
	_expand_row_btn.disabled = not Orchard.can_buy_row()
	_expand_col_btn.disabled = not Orchard.can_buy_col()
	if Orchard.orchard_rows >= OrchardData.MAX_ROWS:
		_expand_row_btn.text = "Rows Maxed"
	else:
		_expand_row_btn.text = "+Row (%sc)" % PlayerData.format_number(Orchard.get_row_cost())
	if Orchard.orchard_cols >= OrchardData.MAX_COLS:
		_expand_col_btn.text = "Cols Maxed"
	else:
		_expand_col_btn.text = "+Column (%sc)" % PlayerData.format_number(Orchard.get_col_cost())


## ── Auto-Plant (Prestige) ──────────────────────────────────────

func _refresh_auto_plant_btn() -> void:
	if _auto_plant_btn == null:
		return
	var max_rows: int = PlayerData.get_auto_plant_rows()
	if max_rows <= 0:
		if _auto_plant_row != null:
			_auto_plant_row.visible = false
		_auto_plant_btn.visible = false
		return
	if _auto_plant_row != null:
		_auto_plant_row.visible = true
	_auto_plant_btn.visible = true
	_rebuild_rows_dropdown(max_rows)
	var rows: int = PlayerData.resolve_auto_plant_rows(PlayerData.orchard_auto_plant_rows)
	if _selected_sapling < 0:
		_auto_plant_btn.text = "🤖 Auto-Plant %d row(s) — select a sapling first" % rows
		_auto_plant_btn.disabled = true
	else:
		var def := Orchard.get_tree_def(_selected_sapling)
		var sapling_count := Orchard.get_sapling_count(_selected_sapling)
		_auto_plant_btn.text = "🤖 Auto-Plant %d row(s) of %s (%d saplings)" % [
			rows, def.get("fruit_name", "?"), sapling_count]
		_auto_plant_btn.disabled = sapling_count <= 0


## Fills the rows picker with 1..max_rows (only when that range changes) and
## selects the current choice.
func _rebuild_rows_dropdown(max_rows: int) -> void:
	if _auto_plant_rows_dd == null:
		return
	if _auto_plant_rows_dd.item_count != max_rows:
		_auto_plant_rows_dd.clear()
		for n in range(1, max_rows + 1):
			_auto_plant_rows_dd.add_item(str(n), n)
	var want: int = PlayerData.resolve_auto_plant_rows(PlayerData.orchard_auto_plant_rows)
	for i in range(_auto_plant_rows_dd.item_count):
		if _auto_plant_rows_dd.get_item_id(i) == want:
			_auto_plant_rows_dd.selected = i
			break


func _on_auto_plant_pressed() -> void:
	if _selected_sapling < 0:
		_status_label.text = "Select a sapling first."
		return
	var rows_to_fill: int = PlayerData.resolve_auto_plant_rows(PlayerData.orchard_auto_plant_rows)
	if rows_to_fill <= 0:
		return

	if _is_auto_planting or _is_harvesting:
		return
	_is_auto_planting = true
	if _auto_plant_btn != null:
		_auto_plant_btn.disabled = true

	var planted := 0
	var rows_done := 0

	for r in range(Orchard.orchard_rows):
		if rows_done >= rows_to_fill:
			break
		## Check if this row has any empty cells we can plant into
		var row_had_empty := false
		for c in range(Orchard.orchard_cols):
			if Orchard.grid[r][c] == null:
				row_had_empty = true
				break
		if not row_had_empty:
			continue  ## Skip full rows and rows with only trees/stumps, don't count against quota

		rows_done += 1
		var planted_this_row := false
		for c in range(Orchard.orchard_cols):
			if Orchard.get_sapling_count(_selected_sapling) <= 0:
				break
			if Orchard.grid[r][c] == null:
				## defer=true: no per-cell save/emit; flushed once at the end.
				if Orchard.plant_sapling(r, c, _selected_sapling, true):
					planted += 1
					planted_this_row = true
		## Show this row filling in immediately, then yield a frame.
		if planted_this_row:
			_refresh_row_visuals(r)
			_status_label.text = "Auto-planting… row %d" % (r + 1)
			await get_tree().process_frame

	## Persist + signal + full-orchard achievement scan once for the batch.
	Orchard.plant_sapling_flush()

	if planted > 0:
		var def := Orchard.get_tree_def(_selected_sapling)
		_status_label.text = "Auto-planted %d %s Saplings!" % [planted, def.get("fruit_name", "saplings")]
		if Orchard.get_sapling_count(_selected_sapling) <= 0:
			_advance_to_next_sapling_if_needed()
		else:
			_refresh_auto_plant_btn()
			_rebuild_sapling_bar()
	else:
		_status_label.text = "No empty spaces or saplings remaining."

	if _auto_plant_btn != null:
		_auto_plant_btn.disabled = false
	_is_auto_planting = false
	## One final full refresh now that the sweep is done (cheap, once).
	_rebuild_all()


func _on_buy_row() -> void:
	if Orchard.buy_row():
		_update_expand_buttons()
		coins_changed.emit()


func _on_buy_col() -> void:
	if Orchard.buy_col():
		_update_expand_buttons()
		coins_changed.emit()
