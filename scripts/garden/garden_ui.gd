class_name GardenUI
extends VBoxContainer

## The garden UI shown in the Seeds marketplace tab.
## Contains: seed inventory, garden grid, expansion buttons.

const CELL_SIZE := 48
var _scythe_active: bool = false
var _tractor_active: bool = false
var _shovel_mode: bool = false
var _scythe_btn: Button = null
var _tractor_btn: Button = null
var _shovel_btn: Button = null
var _orchard_btn: Button = null
var _auto_plant_btn: Button = null
var _auto_plant_row: HBoxContainer = null
var _auto_plant_rows_dd: OptionButton = null
## True while a per-row auto-plant sweep is running (prevents re-entry).
var _is_auto_planting: bool = false
var _tool_status_label: Label = null
var _garden1_btn: Button = null
var _garden2_btn: Button = null
var _buy_garden2_btn: Button = null

signal coins_changed  ## Emitted when harvesting changes coins
const REFRESH_INTERVAL := 2.0  ## Seconds between UI refresh (for growth animation)

var _selected_seed: int = -1  ## Currently selected seed PlantType, or -1
var _auto_next_seed_cb: CheckBox = null
var _auto_next_seed_enabled: bool = false
var _scroll_container: ScrollContainer = null
var _grid_container: GridContainer = null
var _seed_bar: HBoxContainer = null
var _status_label: Label = null
var _expand_row_btn: Button = null
var _expand_col_btn: Button = null
var _refresh_timer: Timer = null
var _long_press_timer: Timer = null
var _long_press_cell: Array = [-1, -1]
var _timer_popup: PanelContainer = null
## Drives touch-drag-to-pan + clean-tap-to-act over the plot grid (mobile).
var _pan: GridPanController = null

## Tracks cells already planted during a swipe to avoid re-processing the same cell.
## (Reserved for future use — swipe-to-plant removed in favour of native scroll)

## Sprite caches: PlantType -> Texture2D (full strip)
var _plant_sheets: Dictionary = {}


func _ready() -> void:
	_load_plant_sheets()
	_build_ui()
	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = REFRESH_INTERVAL
	_refresh_timer.autostart = true
	_refresh_timer.timeout.connect(_refresh_grid_visuals)
	add_child(_refresh_timer)
	Garden.garden_updated.connect(_on_garden_data_updated)


func _on_garden_data_updated() -> void:
	_refresh_grid_visuals()
	_rebuild_seed_bar()
	_update_expand_buttons()
	_refresh_auto_plant_btn()


func _load_plant_sheets() -> void:
	for i in range(GardenData.PLANT_DEFS.size()):
		var def: Dictionary = GardenData.PLANT_DEFS[i]
		var tex: Texture2D = load(def["sprite"])
		if tex:
			_plant_sheets[i] = tex


func _build_ui() -> void:
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	## Status label
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.text = "Select a seed, then click a  tile to plant."
	add_child(_status_label)

	## Garden switcher: [Garden 1] [Garden 2] — or a buy button for Garden 2.
	var switch_row := HBoxContainer.new()
	switch_row.alignment = BoxContainer.ALIGNMENT_CENTER
	switch_row.add_theme_constant_override("separation", 6)
	## (Added to the tool bar below, just left of the Orchard button.)

	_garden1_btn = Button.new()
	_garden1_btn.text = "Garden 1"
	_garden1_btn.toggle_mode = true
	_garden1_btn.add_theme_font_size_override("font_size", 11)
	_garden1_btn.custom_minimum_size = Vector2(0, 40)
	_garden1_btn.pressed.connect(_on_switch_garden.bind(0))
	switch_row.add_child(_garden1_btn)

	_garden2_btn = Button.new()
	_garden2_btn.text = "Garden 2"
	_garden2_btn.toggle_mode = true
	_garden2_btn.add_theme_font_size_override("font_size", 11)
	_garden2_btn.custom_minimum_size = Vector2(0, 40)
	_garden2_btn.pressed.connect(_on_switch_garden.bind(1))
	switch_row.add_child(_garden2_btn)

	_buy_garden2_btn = Button.new()
	_buy_garden2_btn.text = "🔒 Garden 2\n%s" % PlayerData.format_coins(GardenData.SECOND_GARDEN_COST)
	_buy_garden2_btn.add_theme_font_size_override("font_size", 10)
	_buy_garden2_btn.custom_minimum_size = Vector2(0, 40)
	_buy_garden2_btn.pressed.connect(_on_buy_garden2_pressed)
	switch_row.add_child(_buy_garden2_btn)

	## Seed inventory bar
	var seed_section := VBoxContainer.new()
	seed_section.add_theme_constant_override("separation", 2)
	seed_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var seed_title := Label.new()
	seed_title.text = "Your Seeds:"
	seed_title.add_theme_font_size_override("font_size", 11)
	seed_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	seed_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_section.add_child(seed_title)

	_seed_bar = HBoxContainer.new()
	_seed_bar.add_theme_constant_override("separation", 4)
	_seed_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	_seed_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_section.add_child(_seed_bar)

	_auto_next_seed_enabled = Garden.auto_select_next_seed
	_auto_next_seed_cb = CheckBox.new()
	_auto_next_seed_cb.name = "AutoNextSeedCheckBox"
	_auto_next_seed_cb.text = "Auto-select next seed when out"
	_auto_next_seed_cb.add_theme_font_size_override("font_size", 10)
	_auto_next_seed_cb.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_auto_next_seed_cb.button_pressed = _auto_next_seed_enabled
	_auto_next_seed_cb.toggled.connect(_on_auto_next_seed_toggled)
	seed_section.add_child(_auto_next_seed_cb)

	add_child(seed_section)

	# Tool ToolBar
	var tool_bar := HBoxContainer.new()
	tool_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	tool_bar.add_theme_constant_override("separation", 8)
	tool_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_scythe_btn = Button.new()
	_scythe_btn.custom_minimum_size = Vector2(40, 40)
	_scythe_btn.toggle_mode = true
	_scythe_btn.toggled.connect(_on_scythe_toggled)
	_scythe_btn.tooltip_text = "Scythe: harvest 3×3"
	var scythe_tex: Texture2D = load("res://Assets/Scythe.png")
	if scythe_tex:
		var scythe_icon := TextureRect.new()
		scythe_icon.texture = scythe_tex
		scythe_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		scythe_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		scythe_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		scythe_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_scythe_btn.add_child(scythe_icon)
	else:
		_scythe_btn.text = "⚔ Scythe"
	_scythe_btn.add_theme_font_size_override("font_size", 11)
	tool_bar.add_child(_scythe_btn)

	_tractor_btn = Button.new()
	_tractor_btn.custom_minimum_size = Vector2(40, 40)
	_tractor_btn.toggle_mode = true
	_tractor_btn.toggled.connect(_on_tractor_toggled)
	_tractor_btn.tooltip_text = "Tractor: harvest full row"
	var tractor_tex: Texture2D = load("res://Assets/tractor.png")
	if tractor_tex:
		var tractor_icon := TextureRect.new()
		tractor_icon.texture = tractor_tex
		tractor_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tractor_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tractor_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		tractor_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_tractor_btn.add_child(tractor_icon)
	else:
		_tractor_btn.text = "🚜 Tractor"
	_tractor_btn.add_theme_font_size_override("font_size", 11)
	tool_bar.add_child(_tractor_btn)

	_shovel_btn = Button.new()
	_shovel_btn.custom_minimum_size = Vector2(40, 40)
	_shovel_btn.toggle_mode = true
	_shovel_btn.toggled.connect(_on_shovel_toggled)
	_shovel_btn.tooltip_text = "Shovel: remove a crop"
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
	_shovel_btn.add_theme_font_size_override("font_size", 11)
	tool_bar.add_child(_shovel_btn)

	_orchard_btn = Button.new()
	_orchard_btn.custom_minimum_size = Vector2(90, 40)
	_orchard_btn.text = "🌳 Orchard"
	_orchard_btn.add_theme_font_size_override("font_size", 11)
	_orchard_btn.tooltip_text = "Visit your tree Orchard"
	_orchard_btn.pressed.connect(_on_orchard_pressed)
	tool_bar.add_child(switch_row)
	tool_bar.add_child(_orchard_btn)

	add_child(tool_bar)

	## Tool status label
	_tool_status_label = Label.new()
	_tool_status_label.add_theme_font_size_override("font_size", 10)
	_tool_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tool_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tool_status_label.modulate = Color(0.9, 0.9, 0.5)
	add_child(_tool_status_label)

	## Auto-Plant row: [rows picker] [Auto-Plant button]. Visible only when the
	## Green Thumb prestige is owned. The picker lets the player plant fewer rows
	## than they've unlocked (1..unlocked); the choice is remembered.
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
		PlayerData.garden_auto_plant_rows = _auto_plant_rows_dd.get_selected_id()
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

	## Only the plot (and expand buttons) scroll — HUD stays on the viewport
	_scroll_container = ScrollContainer.new()
	_scroll_container.name = "GardenScroll"
	_scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll_container.scroll_deadzone = 16
	add_child(_scroll_container)

	## Explicit drag-to-pan / tap-to-act controller for the plot grid. Keeps the
	## long-press info popup via the hooks below.
	_pan = GridPanController.new(_scroll_container)
	_pan.set_long_press_hooks(
		Callable(self, "_pan_long_press_began"),
		Callable(self, "_pan_long_press_moved"),
		Callable(self, "_pan_long_press_ended"))

	var garden_body := VBoxContainer.new()
	garden_body.name = "GardenBody"
	garden_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	garden_body.add_theme_constant_override("separation", 8)
	_scroll_container.add_child(garden_body)

	var grid_center := CenterContainer.new()
	grid_center.name = "GridCenter"
	grid_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	garden_body.add_child(grid_center)

	_grid_container = GridContainer.new()
	_grid_container.add_theme_constant_override("h_separation", 1)
	_grid_container.add_theme_constant_override("v_separation", 1)
	grid_center.add_child(_grid_container)

	## Expansion buttons
	var expand_row := HBoxContainer.new()
	expand_row.alignment = BoxContainer.ALIGNMENT_CENTER
	expand_row.add_theme_constant_override("separation", 10)

	_expand_row_btn = Button.new()
	_expand_row_btn.text = "+Row (150c)"
	_expand_row_btn.add_theme_font_size_override("font_size", 11)
	_expand_row_btn.pressed.connect(_on_buy_row)
	expand_row.add_child(_expand_row_btn)

	_expand_col_btn = Button.new()
	_expand_col_btn.text = "+Column (100c)"
	_expand_col_btn.add_theme_font_size_override("font_size", 11)
	_expand_col_btn.pressed.connect(_on_buy_col)
	expand_row.add_child(_expand_col_btn)

	garden_body.add_child(expand_row)

	_rebuild_all()


func _rebuild_all() -> void:
	_rebuild_seed_bar()
	var expected_children := Garden.garden_rows * Garden.garden_cols
	if _grid_container == null or _grid_container.get_child_count() != expected_children or _grid_container.columns != Garden.garden_cols:
		_rebuild_grid()
	else:
		_refresh_grid_visuals()
	_update_expand_buttons()
	_update_tool_buttons()
	_refresh_auto_plant_btn()


func _update_tool_buttons() -> void:
	var has_scythe := PlayerData.get_tool_count(PlayerData.ToolType.SCYTHE) > 0
	var has_tractor := PlayerData.get_tool_count(PlayerData.ToolType.TRACTOR) > 0
	var has_shovel := PlayerData.get_tool_count(PlayerData.ToolType.SHOVEL) > 0

	if _scythe_btn:
		_scythe_btn.disabled = not has_scythe
		if not has_scythe:
			_scythe_btn.button_pressed = false
			_scythe_active = false
	if _tractor_btn:
		_tractor_btn.disabled = not has_tractor
		if not has_tractor:
			_tractor_btn.button_pressed = false
			_tractor_active = false
	if _shovel_btn:
		_shovel_btn.disabled = not has_shovel
		if not has_shovel:
			_shovel_btn.button_pressed = false
			_shovel_mode = false

	_update_tool_status()


func _update_tool_status() -> void:
	if _tool_status_label == null:
		return
	var parts: Array = []
	if _scythe_active:
		parts.append("Scythe ON (3×3 harvest)")
	if _tractor_active and _scythe_active:
		parts.append("Tractor ON (3 rows)")
	elif _tractor_active:
		parts.append("Tractor ON (full row)")
	if _shovel_mode:
		parts.append("Shovel ON (click to remove)")
	_tool_status_label.text = "  ".join(parts)


func _on_scythe_toggled(pressed: bool) -> void:
	_scythe_active = pressed
	_update_tool_status()


func _on_tractor_toggled(pressed: bool) -> void:
	_tractor_active = pressed
	_update_tool_status()


func _on_shovel_toggled(pressed: bool) -> void:
	_shovel_mode = pressed
	if pressed:
		_selected_seed = -1  ## Deselect seed when shovel mode on
	_update_tool_status()


func _on_orchard_pressed() -> void:
	var nav = get_tree().root.get_node_or_null("Main/ScreenNavigator")
	if nav != null:
		nav.navigate_to("orchard")


func _rebuild_seed_bar() -> void:
	for child in _seed_bar.get_children():
		_seed_bar.remove_child(child)
		child.queue_free()

	for i in range(GardenData.PLANT_DEFS.size()):
		var count := Garden.get_seed_count(i)
		if count <= 0:
			continue
		var def: Dictionary = GardenData.PLANT_DEFS[i]
		var item := VBoxContainer.new()
		item.add_theme_constant_override("separation", 1)
		## Tag the item with its plant index so the count label can be updated
		## in place (without a full seed-bar rebuild).
		item.set_meta("plant_type", i)

		var btn := Button.new()
		btn.name = "SeedBtn"
		btn.custom_minimum_size = Vector2(36, 36)
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_on_seed_selected.bind(i))
		if _selected_seed == i:
			btn.modulate = Color(1.0, 0.85, 0.2)
		## Show first frame of plant as icon
		if _plant_sheets.has(i):
			var tex: Texture2D = _plant_sheets[i]
			var frame_w: float = tex.get_width() / 4.0
			var atlas := AtlasTexture.new()
			atlas.atlas = tex
			atlas.region = Rect2(0, 0, frame_w, tex.get_height())
			var sprite := TextureRect.new()
			sprite.texture = atlas
			sprite.custom_minimum_size = Vector2(28, 28)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			btn.add_child(sprite)
		item.add_child(btn)

		var lbl := Label.new()
		lbl.name = "CountLabel"
		lbl.text = "%s:%d" % [def["name"].substr(0, 4), count]
		lbl.add_theme_font_size_override("font_size", 8)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		item.add_child(lbl)

		_seed_bar.add_child(item)


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

	_grid_container.columns = Garden.garden_cols

	for r in range(Garden.garden_rows):
		for c in range(Garden.garden_cols):
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(CELL_SIZE, CELL_SIZE)
			btn.focus_mode = Control.FOCUS_NONE
			btn.mouse_filter = Control.MOUSE_FILTER_PASS  ## Allow scroll to detect swipes through buttons
			btn.set_meta("row", r)
			btn.set_meta("col", c)
			## Touch-and-drag pans the grid; a clean tap runs _on_grid_cell_pressed.
			## (No `pressed` signal here — the controller decides tap vs drag.)
			btn.gui_input.connect(_pan.handle_tile_input.bind(Vector2i(r, c), Callable(self, "_on_grid_cell_pressed").bind(r, c)))
			_apply_cell_visual(btn, r, c)
			_grid_container.add_child(btn)

	if _scroll_container != null and is_instance_valid(_scroll_container) and (prev_h > 0 or prev_v > 0):
		_scroll_container.set_deferred("scroll_horizontal", prev_h)
		_scroll_container.set_deferred("scroll_vertical", prev_v)


func _apply_cell_visual(btn: Button, row: int, col: int) -> void:
	var cell = Garden.grid[row][col]

	## Load farmland texture for soil background
	var farmland_tex: Texture2D = load("res://Assets/Plants/farmland.png")

	if cell == null:
		## Empty soil — use farmland sprite
		if farmland_tex:
			var style := StyleBoxTexture.new()
			style.texture = farmland_tex
			btn.add_theme_stylebox_override("normal", style)
			btn.add_theme_stylebox_override("hover", style)
			btn.add_theme_stylebox_override("pressed", style)
		else:
			var style := StyleBoxFlat.new()
			style.bg_color = Color(0.4, 0.3, 0.2)
			style.border_width_left = 1; style.border_width_right = 1
			style.border_width_top = 1; style.border_width_bottom = 1
			style.border_color = Color(0.5, 0.4, 0.3)
			btn.add_theme_stylebox_override("normal", style)
			btn.add_theme_stylebox_override("hover", style)
			btn.add_theme_stylebox_override("pressed", style)
		btn.text = ""
		btn.tooltip_text = ""
		## Remove all child sprites immediately so empty plot is blank
		for child in btn.get_children():
			child.queue_free()
		return

	## Has a plant — use farmland as background with plant on top
	var plant_type: int = cell["plant_type"]
	var frame := Garden.get_growth_frame(row, col)
	var harvestable := Garden.is_harvestable(row, col)

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
	btn.text = ""

	## Find or create single TextureRect for plant sprite
	var sprite: TextureRect = null
	for child in btn.get_children():
		if child is TextureRect:
			sprite = child
			break

	if _plant_sheets.has(plant_type) and frame >= 0:
		var tex: Texture2D = _plant_sheets[plant_type]
		var frame_w: float = tex.get_width() / 4.0
		var atlas := AtlasTexture.new()
		atlas.atlas = tex
		atlas.region = Rect2(frame * frame_w, 0, frame_w, tex.get_height())

		if sprite == null:
			sprite = TextureRect.new()
			sprite.name = "PlantSprite"
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			btn.add_child(sprite)

		sprite.texture = atlas
		sprite.visible = true
	elif sprite != null:
		sprite.queue_free()

	## Tooltip showing time remaining
	var def := Garden.get_plant_def(plant_type)
	if harvestable:
		btn.tooltip_text = "%s — Ready to harvest!" % def.get("name", "")
	else:
		var progress := Garden.get_growth_progress(row, col)
		var remaining: float = Garden.get_effective_harvest_time(plant_type) * (1.0 - progress)
		btn.tooltip_text = "%s — %s left" % [def.get("name", ""), FormatUtils.format_countdown(remaining)]


func _refresh_grid_visuals() -> void:
	if _grid_container == null:
		return
	## Update plant visuals without full rebuild
	var idx := 0
	for r in range(Garden.garden_rows):
		for c in range(Garden.garden_cols):
			if idx < _grid_container.get_child_count():
				var btn: Button = _grid_container.get_child(idx) as Button
				_apply_cell_visual(btn, r, c)
			idx += 1


func _update_expand_buttons() -> void:
	_expand_row_btn.disabled = not Garden.can_buy_row()
	_expand_col_btn.disabled = not Garden.can_buy_col()
	if Garden.garden_rows >= GardenData.MAX_ROWS:
		_expand_row_btn.text = "Rows Maxed"
	else:
		_expand_row_btn.text = "+Row (%s)" % PlayerData.format_coins(Garden.get_row_cost())
	if Garden.garden_cols >= GardenData.MAX_COLS:
		_expand_col_btn.text = "Cols Maxed"
	else:
		_expand_col_btn.text = "+Column (%s)" % PlayerData.format_coins(Garden.get_col_cost())
	_update_garden_switch()


## Shows Garden 1 / Garden 2 tabs once the second garden is owned, otherwise a
## buy button. Highlights the garden being viewed.
func _update_garden_switch() -> void:
	if _garden1_btn == null:
		return
	var owned: bool = Garden.second_garden_owned
	_garden1_btn.visible = owned
	_garden2_btn.visible = owned
	_buy_garden2_btn.visible = not owned
	_garden1_btn.set_pressed_no_signal(Garden.active_garden == 0)
	_garden2_btn.set_pressed_no_signal(Garden.active_garden == 1)
	_buy_garden2_btn.disabled = not Garden.can_buy_second_garden()


func _on_switch_garden(idx: int) -> void:
	if _is_auto_planting:
		_update_garden_switch()
		_status_label.text = "Wait for Auto-Plant to finish."
		return
	if Garden.switch_garden(idx):
		_hide_timer_popup_if_any()
		_scroll_container.scroll_vertical = 0
		_scroll_container.scroll_horizontal = 0
		_rebuild_all()
		_status_label.text = "Now viewing Garden %d." % (idx + 1)
	_update_garden_switch()


func _hide_timer_popup_if_any() -> void:
	if _timer_popup != null and is_instance_valid(_timer_popup):
		_timer_popup.visible = false


func _on_buy_garden2_pressed() -> void:
	if not Garden.can_buy_second_garden():
		_status_label.text = "You need %s to buy a second garden." % PlayerData.format_coins(GardenData.SECOND_GARDEN_COST)
		return
	var dlg := ConfirmationDialog.new()
	dlg.title = "Buy Garden 2"
	dlg.dialog_text = "Buy a second garden for %s?\nIt starts at %d×%d. Rows and columns start at %s each." % [
		PlayerData.format_coins(GardenData.SECOND_GARDEN_COST),
		GardenData.MIN_ROWS, GardenData.MIN_COLS,
		PlayerData.format_coins(GardenData.SECOND_GARDEN_EXPAND_BASE)]
	dlg.dialog_autowrap = true
	dlg.min_size = Vector2i(300, 0)
	dlg.confirmed.connect(func():
		if Garden.buy_second_garden():
			coins_changed.emit()
			_status_label.text = "Garden 2 bought! Tap 🌱 Garden 2 to plant there."
		_update_garden_switch()
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


## ── Input Handling ─────────────────────────────────────────────

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
	var rows: int = _chosen_auto_plant_rows()
	if _selected_seed < 0:
		_auto_plant_btn.text = "🤖 Auto-Plant %d row(s) — select a seed first" % rows
		_auto_plant_btn.disabled = true
	else:
		var def := Garden.get_plant_def(_selected_seed)
		var seed_count := Garden.get_seed_count(_selected_seed)
		_auto_plant_btn.text = "🤖 Auto-Plant %d row(s) of %s (%d seeds)" % [
			rows, def.get("name", "?"), seed_count]
		_auto_plant_btn.disabled = seed_count <= 0


## Rows the player chose to auto-plant: their saved pick (1..unlocked), or every
## unlocked row if they haven't picked / the pick is above what's unlocked.
func _chosen_auto_plant_rows() -> int:
	var max_rows: int = PlayerData.get_auto_plant_rows()
	var pick: int = PlayerData.garden_auto_plant_rows
	if pick <= 0 or pick > max_rows:
		return max_rows
	return pick


## Fills the rows picker with 1..max_rows (only when that range changes) and
## selects the current choice.
func _rebuild_rows_dropdown(max_rows: int) -> void:
	if _auto_plant_rows_dd == null:
		return
	if _auto_plant_rows_dd.item_count != max_rows:
		_auto_plant_rows_dd.clear()
		for n in range(1, max_rows + 1):
			_auto_plant_rows_dd.add_item(str(n), n)
	var want := _chosen_auto_plant_rows()
	for i in range(_auto_plant_rows_dd.item_count):
		if _auto_plant_rows_dd.get_item_id(i) == want:
			_auto_plant_rows_dd.selected = i
			break


func _on_auto_plant_pressed() -> void:
	if _selected_seed < 0:
		_status_label.text = "Select a seed first."
		return
	var rows_to_fill: int = _chosen_auto_plant_rows()
	if rows_to_fill <= 0:
		return

	if _is_auto_planting:
		return
	_is_auto_planting = true
	if _auto_plant_btn != null:
		_auto_plant_btn.disabled = true

	var planted := 0
	var rows_done := 0

	for r in range(Garden.garden_rows):
		if rows_done >= rows_to_fill:
			break
		## Check if this row has any empty cells we can plant into
		var row_had_empty := false
		for c in range(Garden.garden_cols):
			if Garden.grid[r][c] == null:
				row_had_empty = true
				break
		if not row_had_empty:
			continue  ## Skip full rows, don't count against quota

		rows_done += 1
		var planted_this_row := false
		for c in range(Garden.garden_cols):
			if Garden.get_seed_count(_selected_seed) <= 0:
				break
			if Garden.grid[r][c] == null:
				## defer=true: no per-cell save/emit; flushed once at the end.
				if Garden.plant_seed(r, c, _selected_seed, true):
					planted += 1
					planted_this_row = true
		## Show this row filling in immediately, then yield a frame so it paints
		## before the next row (responsive top-to-bottom fill, no freeze).
		if planted_this_row:
			_refresh_row_visuals(r)
			_status_label.text = "Auto-planting… row %d" % (r + 1)
			await get_tree().process_frame

	## Persist + signal + achievement scan once for the whole batch.
	Garden.plant_seed_flush()

	if planted > 0:
		var def := Garden.get_plant_def(_selected_seed)
		_status_label.text = "Auto-planted %d %s!" % [planted, def.get("name", "seeds")]
		if Garden.get_seed_count(_selected_seed) <= 0:
			_advance_to_next_seed_if_needed()
		else:
			_refresh_auto_plant_btn()
	else:
		_status_label.text = "No empty spaces or seeds remaining."

	if _auto_plant_btn != null:
		_auto_plant_btn.disabled = false
	_is_auto_planting = false
	_rebuild_all()


## Applies the cell visual for every button in one row in place (no node
## creation) — used for incremental per-row auto-plant feedback.
func _refresh_row_visuals(row: int) -> void:
	if _grid_container == null:
		return
	var cols := Garden.garden_cols
	for c in range(cols):
		var idx := row * cols + c
		if idx < _grid_container.get_child_count():
			var btn: Button = _grid_container.get_child(idx) as Button
			if btn != null:
				_apply_cell_visual(btn, row, c)

	
func _on_auto_next_seed_toggled(toggled_on: bool) -> void:
	_auto_next_seed_enabled = toggled_on
	Garden.set_auto_select_next_seed(toggled_on)


func _advance_to_next_seed_if_needed() -> void:
	if _selected_seed < 0:
		return
	if Garden.get_seed_count(_selected_seed) > 0:
		return

	if _auto_next_seed_enabled:
		var total_types: int = GardenData.PLANT_DEFS.size()
		var found_next := false
		for offset in range(1, total_types):
			var next_type: int = (_selected_seed + offset) % total_types
			if Garden.get_seed_count(next_type) > 0:
				_selected_seed = next_type
				found_next = true
				var next_def := Garden.get_plant_def(_selected_seed)
				_status_label.text = "Planted! Out of previous seeds — switched to %s." % next_def.get("name", "")
				break
		if not found_next:
			_selected_seed = -1
			_status_label.text = "Planted! No seeds remaining in inventory."
	else:
		_selected_seed = -1

	_rebuild_seed_bar()
	_refresh_auto_plant_btn()


func _on_seed_selected(plant_type: int) -> void:
	if _selected_seed == plant_type:
		_selected_seed = -1  ## Deselect
	else:
		_selected_seed = plant_type
	var def := Garden.get_plant_def(plant_type)
	if _selected_seed >= 0:
		_status_label.text = "%s selected. Click a tile to plant." % def.get("name", "")
	else:
		_status_label.text = "Select a seed, then click a garden tile to plant."
	## Only the highlight changed — update it in place instead of rebuilding the
	## seed bar (a rebuild reflows the layout and resets the grid's scroll).
	_update_seed_bar_highlight()
	_refresh_auto_plant_btn()


## Updates the selected-seed highlight on the seed bar without a full rebuild,
## so switching seeds doesn't reset the garden scroll position.
func _update_seed_bar_highlight() -> void:
	if _seed_bar == null:
		return
	for child in _seed_bar.get_children():
		if not (child is Control):
			continue
		var pt := int(child.get_meta("plant_type", -1))
		var btn := child.get_node_or_null("SeedBtn") as Button
		if btn:
			btn.modulate = Color(1.0, 0.85, 0.2) if pt == _selected_seed else Color.WHITE


func _on_grid_cell_pressed(row: int, col: int) -> void:
	## ── Shovel mode: remove a planted crop ──
	if _shovel_mode:
		var cell = Garden.grid[row][col]
		if cell == null:
			_status_label.text = "Nothing to remove here."
			return
		if not PlayerData.consume_tool(PlayerData.ToolType.SHOVEL):
			_status_label.text = "No shovels left!"
			_shovel_mode = false
			_shovel_btn.button_pressed = false
			return
		Garden.grid[row][col] = null
		Garden.save_data()
		Garden.garden_updated.emit()
		_status_label.text = "Crop removed."
		_update_tool_buttons()
		coins_changed.emit()
		return

	## ── Tractor mode: harvest full row(s) ──
	if _tractor_active:
		var rows_to_harvest: Array[int] = [row]
		if _scythe_active:
			## Scythe + Tractor: harvest 3 rows (row-1, row, row+1)
			if row - 1 >= 0:
				rows_to_harvest.append(row - 1)
			if row + 1 < Garden.garden_rows:
				rows_to_harvest.append(row + 1)
		var cells: Array = []
		for r in rows_to_harvest:
			for c in range(Garden.garden_cols):
				if Garden.is_harvestable(r, c):
					cells.append(Vector2i(r, c))
		var result := Garden.harvest_batch(cells)
		if result["count"] > 0:
			if _scythe_active:
				PlayerData.consume_tool(PlayerData.ToolType.SCYTHE)
				_update_tool_buttons()
			_status_label.text = "Tractor harvested %d crops! Sell them at the Marketplace." % result["count"]
			coins_changed.emit()
		else:
			_status_label.text = "No harvestable crops in that row."
		return

	## ── Scythe mode: harvest 3×3 area ──
	if _scythe_active:
		var cells: Array = []
		for dr in range(-1, 2):
			for dc in range(-1, 2):
				var nr := row + dr
				var nc := col + dc
				if nr >= 0 and nr < Garden.garden_rows and nc >= 0 and nc < Garden.garden_cols:
					if Garden.is_harvestable(nr, nc):
						cells.append(Vector2i(nr, nc))
		var result := Garden.harvest_batch(cells)
		if result["count"] > 0:
			PlayerData.consume_tool(PlayerData.ToolType.SCYTHE)
			_update_tool_buttons()
			_status_label.text = "Scythe harvested %d crops! Sell them at the Marketplace." % result["count"]
			coins_changed.emit()
		else:
			_status_label.text = "No harvestable crops in that area."
		return

	## ── Default: single cell interaction ──
	var cell = Garden.grid[row][col]
	if cell != null:
		if Garden.is_harvestable(row, col):
			Garden.harvest(row, col)
			var crop_def := Garden.get_plant_def(cell["plant_type"])
			_status_label.text = "Harvested %s! Sell it at the Marketplace." % crop_def.get("name", "crop")
			coins_changed.emit()
		else:
			
			var progress := Garden.get_growth_progress(row, col)
			var def := Garden.get_plant_def(cell["plant_type"])
			var remaining: float = Garden.get_effective_harvest_time(cell["plant_type"]) * (1.0 - progress)

			_status_label.text = "%s — %s remaining" % [def["name"], FormatUtils.format_countdown(remaining)]
	else:
		if _selected_seed < 0:
			_status_label.text = "Select a seed first."
			return
		## Preserve the scroll position across the whole plant action so planting
		## on an edge tile doesn't snap the view back to the origin.
		var prev_h := _scroll_container.scroll_horizontal if _scroll_container else 0
		var prev_v := _scroll_container.scroll_vertical if _scroll_container else 0
		var success := Garden.plant_seed(row, col, _selected_seed)
		if success:
			var def := Garden.get_plant_def(_selected_seed)
			_status_label.text = "Planted %s!" % def.get("name", "")

			if Garden.get_seed_count(_selected_seed) > 0:
				## Seeds remain — update in place (no seed-bar rebuild, which is
				## what reflows the layout and resets the grid scroll).
				_update_seed_count_label(_selected_seed)
				_refresh_auto_plant_btn()
				_refresh_grid_visuals()
			else:
				## Ran out of this seed — the bar must rebuild to drop the entry.
				_advance_to_next_seed_if_needed()
				_rebuild_seed_bar()
			## Restore scroll after any deferred layout pass settles.
			if _scroll_container != null and is_instance_valid(_scroll_container):
				_scroll_container.set_deferred("scroll_horizontal", prev_h)
				_scroll_container.set_deferred("scroll_vertical", prev_v)
		else:
			_status_label.text = "Can't plant here."
func _update_seed_count_label(plant_type: int) -> void:
	# Update grid cell visuals directly
	_refresh_grid_visuals()

	## Update the seed bar's count label in place (matched by plant_type meta).
	var count := Garden.get_seed_count(plant_type)
	var def: Dictionary = GardenData.PLANT_DEFS[plant_type]
	for child in _seed_bar.get_children():
		if not (child is Control) or int(child.get_meta("plant_type", -1)) != plant_type:
			continue
		var lbl := child.get_node_or_null("CountLabel") as Label
		if lbl:
			lbl.text = "%s:%d" % [def["name"].substr(0, 4), count]
		break
	
func _on_buy_row() -> void:
	if Garden.buy_row():
		## Rebuild so the new row appears immediately (garden_updated only
		## repaints existing cells, it doesn't add the new ones).
		_rebuild_all()
		coins_changed.emit()


func _on_buy_col() -> void:
	if Garden.buy_col():
		_rebuild_all()
		coins_changed.emit()


## ── Long-press timer popup (mobile touch equivalent of hover tooltip) ─────


## Long-press hooks driven by GridPanController. `began` starts the hold timer,
## `moved` (finger dragged = scrolling) cancels it, `ended` cancels on release.
func _pan_long_press_began(cell: Variant) -> void:
	if cell is Vector2i:
		_long_press_cell = [cell.x, cell.y]
		_start_long_press_timer()


func _pan_long_press_moved(_dist: float) -> void:
	_cancel_long_press()


func _pan_long_press_ended() -> void:
	_cancel_long_press()


func _start_long_press_timer() -> void:
	_cancel_long_press()
	_long_press_timer = Timer.new()
	_long_press_timer.wait_time = 0.4  ## 400ms hold to show timer
	_long_press_timer.one_shot = true
	_long_press_timer.timeout.connect(_on_long_press_triggered)
	add_child(_long_press_timer)
	_long_press_timer.start()


func _cancel_long_press() -> void:
	if _long_press_timer != null and is_instance_valid(_long_press_timer):
		_long_press_timer.stop()
		_long_press_timer.queue_free()
		_long_press_timer = null
	_dismiss_timer_popup()


func _on_long_press_triggered() -> void:
	if _long_press_cell[0] < 0:
		return
	var row: int = _long_press_cell[0]
	var col: int = _long_press_cell[1]
	var cell = Garden.grid[row][col]
	if cell == null:
		return

	var plant_type: int = cell["plant_type"]
	var def := Garden.get_plant_def(plant_type)
	if def.is_empty():
		return

	var text: String
	if Garden.is_harvestable(row, col):
		text = "%s\n✓ Ready to harvest!" % def["name"]
	else:
		var progress := Garden.get_growth_progress(row, col)
		var remaining: float = Garden.get_effective_harvest_time(plant_type) * (1.0 - progress)
		text = "%s\n⏱ %s left" % [def["name"], FormatUtils.format_countdown(remaining)]

	_show_timer_popup(text, row, col)


func _show_timer_popup(text: String, row: int, col: int) -> void:
	_dismiss_timer_popup()

	_timer_popup = PanelContainer.new()
	_timer_popup.name = "TimerPopup"

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.15, 0.92)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.4, 0.6, 0.4)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_right = 4
	style.corner_radius_bottom_left = 4
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	_timer_popup.add_theme_stylebox_override("panel", style)

	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(0.9, 0.95, 0.9))
	_timer_popup.add_child(label)

	# Position above the cell
	var cell_idx: int = row * Garden.garden_cols + col
	if cell_idx < _grid_container.get_child_count():
		var cell_btn: Button = _grid_container.get_child(cell_idx)
		var cell_pos := cell_btn.global_position
		_timer_popup.position = Vector2(cell_pos.x, cell_pos.y - 40)

	_timer_popup.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_tree().current_scene.add_child(_timer_popup)

	# Auto-dismiss after 3 seconds
	var dismiss_timer := Timer.new()
	dismiss_timer.wait_time = 3.0
	dismiss_timer.one_shot = true
	dismiss_timer.timeout.connect(_dismiss_timer_popup)
	_timer_popup.add_child(dismiss_timer)
	dismiss_timer.start()


func _dismiss_timer_popup() -> void:
	if _timer_popup != null and is_instance_valid(_timer_popup):
		_timer_popup.queue_free()
		_timer_popup = null
