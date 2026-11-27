class_name GuildGardenUI
extends VBoxContainer
## Community guild garden widget.
## Embedded inside CommunityPanel in guild_detail_screen.
## Shows the shared grid, a seed selector from the player's own inventory,
## and the guild silo with per-crop deposit buttons.
##
## Usage:
##   var ui := GuildGardenUI.new()
##   _community_panel.add_child(ui)
##   ui.setup(guild_id, grid_cols, grid_rows)

const CELL_SIZE := 44
const REFRESH_INTERVAL := 3.0   ## seconds between growth-frame refreshes

## ── State ────────────────────────────────────────────────────────
var _guild_id: String = ""
var _grid_cols: int   = 5
var _grid_rows: int   = 5

var _selected_seed: int = -1
var _is_busy: bool = false   ## Used for silo deposit; cell planting is non-blocking

## Cell button lookup: Vector2i(row, col) -> Button
var _cell_buttons: Dictionary = {}

## ── Node refs ────────────────────────────────────────────────────
var _status_lbl:       Label           = null
var _seed_bar:         HBoxContainer   = null
var _grid_container:   GridContainer   = null
var _scroll:           ScrollContainer = null
var _silo_container:   VBoxContainer   = null
var _refresh_timer:    Timer           = null

## Autoplant + tractor (mirror of personal garden).
var _autoplant_btn:    Button          = null
var _autoplant_rows_lbl: Label         = null
var _autoplant_rows_dd:  OptionButton  = null
var _tractor_btn:      Button          = null
var _tractor_active:   bool            = false
var _is_autoplanting:  bool            = false

## Sprite & Texture caches
var _plant_sheets: Dictionary = {}
var _farmland_tex: Texture2D = null
var _style_empty: StyleBox = null
var _style_planted: StyleBox = null
var _style_harvestable: StyleBox = null

## Cached AtlasTextures: plant_type int -> Array[AtlasTexture] (4 frames)
var _plant_atlases: Dictionary = {}


## ── Setup ────────────────────────────────────────────────────────

func setup(guild_id: String, cols: int, rows: int) -> void:
	_guild_id  = guild_id
	_grid_cols = cols
	_grid_rows = rows
	_load_plant_sheets()
	_build_ui()
	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = REFRESH_INTERVAL
	_refresh_timer.autostart = true
	_refresh_timer.timeout.connect(_on_timer_tick)
	add_child(_refresh_timer)
	GuildGarden.garden_updated.connect(_on_garden_updated)
	## Missions load/refresh independently of the garden; keep the silo's
	## "→ Mission" buttons in step with them.
	GuildManager.guild_data_changed.connect(_on_guild_data_changed)


func teardown() -> void:
	if GuildGarden.garden_updated.is_connected(_on_garden_updated):
		GuildGarden.garden_updated.disconnect(_on_garden_updated)
	if GuildManager.guild_data_changed.is_connected(_on_guild_data_changed):
		GuildManager.guild_data_changed.disconnect(_on_guild_data_changed)
	if is_instance_valid(_refresh_timer):
		_refresh_timer.stop()
	_cell_buttons.clear()


## ── Asset loading & Caching ──────────────────────────────────────

func _load_plant_sheets() -> void:
	_farmland_tex = load("res://Assets/Plants/farmland.png")
	if _farmland_tex:
		var s_empty := StyleBoxTexture.new()
		s_empty.texture = _farmland_tex
		_style_empty = s_empty

		var s_planted := StyleBoxTexture.new()
		s_planted.texture = _farmland_tex
		_style_planted = s_planted

		var s_harv := StyleBoxTexture.new()
		s_harv.texture = _farmland_tex
		s_harv.modulate_color = Color(1.1, 1.2, 0.9)
		_style_harvestable = s_harv
	else:
		var s_empty := StyleBoxFlat.new()
		s_empty.bg_color = Color(0.4, 0.3, 0.2)
		_style_empty = s_empty

		var s_planted := StyleBoxFlat.new()
		s_planted.bg_color = Color(0.3, 0.45, 0.2)
		_style_planted = s_planted

		var s_harv := StyleBoxFlat.new()
		s_harv.bg_color = Color(0.2, 0.55, 0.15)
		_style_harvestable = s_harv

	for i in range(GardenData.PLANT_DEFS.size()):
		var def: Dictionary = GardenData.PLANT_DEFS[i]
		var tex: Texture2D = load(def["sprite"])
		if tex:
			_plant_sheets[i] = tex
			var frame_w: float = tex.get_width() / 4.0
			var frames: Array[AtlasTexture] = []
			for f in range(4):
				var atlas := AtlasTexture.new()
				atlas.atlas = tex
				atlas.region = Rect2(f * frame_w, 0, frame_w, tex.get_height())
				frames.append(atlas)
			_plant_atlases[i] = frames


## ── UI build ─────────────────────────────────────────────────────

func _build_ui() -> void:
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	## Title
	var title := Label.new()
	title.text = "🌱 Community Garden"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	## Status label
	_status_lbl = Label.new()
	_status_lbl.add_theme_font_size_override("font_size", 10)
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_status_lbl.text = "Select a seed then tap a plot to plant."
	add_child(_status_lbl)

	## Seed bar section
	var seed_section := VBoxContainer.new()
	seed_section.add_theme_constant_override("separation", 3)
	var seed_title := Label.new()
	seed_title.text = "Your Seeds:"
	seed_title.add_theme_font_size_override("font_size", 11)
	seed_title.add_theme_color_override("font_color", Color.WHITE)
	seed_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	seed_section.add_child(seed_title)
	_seed_bar = HBoxContainer.new()
	_seed_bar.add_theme_constant_override("separation", 4)
	_seed_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	seed_section.add_child(_seed_bar)
	add_child(seed_section)

	## ── Autoplant + Tractor row ──────────────────────────────────────────────
	## Autoplant: plants up to get_auto_plant_rows() empty rows with the
	## selected seed (requires "auto_plant" prestige > 0). Each cell still fires
	## its own RPC (no server batch-plant API), so this is async.
	## Tractor: toggle-mode; when active, tapping a cell harvests the whole row.
	var tool_row := HBoxContainer.new()
	tool_row.add_theme_constant_override("separation", 6)
	tool_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(tool_row)

	## Rows picker: plant fewer rows than unlocked (choice remembered).
	_autoplant_rows_lbl = Label.new()
	_autoplant_rows_lbl.text = "Rows:"
	_autoplant_rows_lbl.add_theme_font_size_override("font_size", 11)
	_autoplant_rows_lbl.visible = false
	tool_row.add_child(_autoplant_rows_lbl)

	_autoplant_rows_dd = OptionButton.new()
	_autoplant_rows_dd.add_theme_font_size_override("font_size", 11)
	_autoplant_rows_dd.custom_minimum_size = Vector2(56, 34)
	_autoplant_rows_dd.visible = false
	_autoplant_rows_dd.item_selected.connect(func(_i):
		PlayerData.guild_garden_auto_plant_rows = _autoplant_rows_dd.get_selected_id()
		PlayerData.save_data()
		_refresh_tool_buttons())
	tool_row.add_child(_autoplant_rows_dd)

	_autoplant_btn = Button.new()
	_autoplant_btn.text = "🤖 Auto-Plant"
	_autoplant_btn.add_theme_font_size_override("font_size", 11)
	_autoplant_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_autoplant_btn.custom_minimum_size = Vector2(0, 34)
	_autoplant_btn.visible = false   ## shown only when prestige unlocked
	_autoplant_btn.pressed.connect(_on_autoplant_pressed)
	tool_row.add_child(_autoplant_btn)

	_tractor_btn = Button.new()
	_tractor_btn.text = "🚜 Tractor"
	_tractor_btn.toggle_mode = true
	_tractor_btn.add_theme_font_size_override("font_size", 11)
	_tractor_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tractor_btn.custom_minimum_size = Vector2(0, 34)
	_tractor_btn.visible = false   ## shown only when tractor owned
	_tractor_btn.toggled.connect(func(on: bool):
		_tractor_active = on
		_tractor_btn.modulate = Color(1.0, 0.85, 0.3) if on else Color.WHITE
		_set_status("Tractor ON — tap a row to harvest it all." if on else
			"Select a seed then tap a plot to plant.", Color.WHITE))
	tool_row.add_child(_tractor_btn)

	## Scrollable garden grid
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.custom_minimum_size    = Vector2(0, mini(_grid_rows * CELL_SIZE + 8, 320))
	_scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	add_child(_scroll)

	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(center)

	_grid_container = GridContainer.new()
	_grid_container.columns = _grid_cols
	_grid_container.add_theme_constant_override("h_separation", 2)
	_grid_container.add_theme_constant_override("v_separation", 2)
	center.add_child(_grid_container)

	## Silo section
	var silo_title := Label.new()
	silo_title.text = "🏚 Guild Silo"
	silo_title.add_theme_font_size_override("font_size", 13)
	silo_title.add_theme_color_override("font_color", Color.WHITE)
	silo_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(silo_title)

	_silo_container = VBoxContainer.new()
	_silo_container.add_theme_constant_override("separation", 4)
	add_child(_silo_container)

	## Initial build
	_rebuild_seed_bar()
	_rebuild_grid()
	_rebuild_silo()
	_refresh_tool_buttons()


## ── Seed bar ─────────────────────────────────────────────────────

func _rebuild_seed_bar() -> void:
	for child in _seed_bar.get_children():
		child.queue_free()

	var any := false
	for i in range(GardenData.PLANT_DEFS.size()):
		var count: int = Garden.get_seed_count(i)
		if count <= 0:
			continue
		any = true
		var def: Dictionary = GardenData.PLANT_DEFS[i]
		var item := VBoxContainer.new()
		item.add_theme_constant_override("separation", 1)
		item.set_meta("plant_type", i)

		var btn := Button.new()
		btn.name = "SeedBtn"
		btn.custom_minimum_size = Vector2(38, 38)
		btn.focus_mode = Control.FOCUS_NONE
		if _selected_seed == i:
			btn.modulate = Color(1.0, 0.85, 0.2)
		if _plant_atlases.has(i) and _plant_atlases[i].size() > 0:
			var sprite := TextureRect.new()
			sprite.texture = _plant_atlases[i][0]
			sprite.custom_minimum_size = Vector2(26, 26)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			btn.add_child(sprite)
		btn.pressed.connect(_on_seed_selected.bind(i))
		item.add_child(btn)

		var lbl := Label.new()
		lbl.name = "CountLabel"
		lbl.text = "%s:%d" % [def["name"].substr(0, 4), count]
		lbl.add_theme_font_size_override("font_size", 8)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		item.add_child(lbl)

		_seed_bar.add_child(item)

	if not any:
		var empty := Label.new()
		empty.text = "No seeds in your inventory."
		empty.add_theme_font_size_override("font_size", 10)
		empty.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_seed_bar.add_child(empty)


func _update_seed_count_label(plant_type: int) -> void:
	if _seed_bar == null:
		return
	var count: int = Garden.get_seed_count(plant_type)
	for child in _seed_bar.get_children():
		if not (child is Control) or int(child.get_meta("plant_type", -1)) != plant_type:
			continue
		var lbl := child.get_node_or_null("CountLabel") as Label
		if lbl:
			var def: Dictionary = GardenData.PLANT_DEFS[plant_type]
			lbl.text = "%s:%d" % [def["name"].substr(0, 4), count]
		break


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


func _advance_to_next_seed_if_needed() -> void:
	if _selected_seed < 0:
		return
	if Garden.get_seed_count(_selected_seed) > 0:
		return

	var total_types: int = GardenData.PLANT_DEFS.size()
	var found_next := false
	if Garden.auto_select_next_seed:
		for offset in range(1, total_types):
			var next_type: int = (_selected_seed + offset) % total_types
			if Garden.get_seed_count(next_type) > 0:
				_selected_seed = next_type
				found_next = true
				var next_def: Dictionary = GardenData.PLANT_DEFS[_selected_seed]
				_set_status("Planted! Switched to %s seeds." % next_def.get("name", ""), Color(0.9, 0.9, 0.5))
				break
	if not found_next:
		_selected_seed = -1
		_set_status("Planted! Out of seeds.", Color(0.9, 0.8, 0.4))
	_rebuild_seed_bar()


## ── Grid ─────────────────────────────────────────────────────────

func _rebuild_grid() -> void:
	_cell_buttons.clear()
	for child in _grid_container.get_children():
		child.queue_free()
	_grid_container.columns = _grid_cols

	for r in range(_grid_rows):
		for c in range(_grid_cols):
			var pos := Vector2i(r, c)
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(CELL_SIZE, CELL_SIZE)
			btn.focus_mode = Control.FOCUS_NONE
			btn.set_meta("row", r)
			btn.set_meta("col", c)
			btn.pressed.connect(_on_cell_pressed.bind(r, c))

			var sprite := TextureRect.new()
			sprite.name = "PlantSprite"
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			sprite.visible = false
			btn.add_child(sprite)

			_cell_buttons[pos] = btn
			_apply_cell_visual(btn, r, c)
			_grid_container.add_child(btn)


func _refresh_grid_visuals() -> void:
	for r in range(_grid_rows):
		for c in range(_grid_cols):
			var pos := Vector2i(r, c)
			var btn: Button = _cell_buttons.get(pos)
			if btn and is_instance_valid(btn):
				_apply_cell_visual(btn, r, c)


func _apply_cell_visual(btn: Button, row: int, col: int) -> void:
	if btn == null or not is_instance_valid(btn):
		return

	var cell := GuildGarden.get_cell(row, col)
	var sprite := btn.get_node_or_null("PlantSprite") as TextureRect

	if cell.is_empty():
		## Empty plot
		btn.add_theme_stylebox_override("normal",  _style_empty)
		btn.add_theme_stylebox_override("hover",   _style_empty)
		btn.add_theme_stylebox_override("pressed", _style_empty)
		btn.text = ""
		btn.tooltip_text = ""
		if sprite:
			sprite.visible = false
		return

	## Planted cell
	var plant_type: int = int(cell["plant_type"])
	var harvestable: bool = GuildGarden.is_harvestable(row, col)
	var frame: int = GuildGarden.get_growth_frame(row, col)
	var style: StyleBox = _style_harvestable if harvestable else _style_planted

	btn.add_theme_stylebox_override("normal",  style)
	btn.add_theme_stylebox_override("hover",   style)
	btn.add_theme_stylebox_override("pressed", style)
	btn.text = ""

	## Tooltip
	var def: Dictionary = GardenData.PLANT_DEFS[plant_type]
	if harvestable:
		btn.tooltip_text = "%s — Ready! Tap to harvest." % def.get("name", "")
	else:
		var progress := GuildGarden.get_growth_progress(row, col)
		var remaining := GuildGarden.HARVEST_TIMES[plant_type] * (1.0 - progress)
		btn.tooltip_text = "%s — %s" % [def.get("name", ""), FormatUtils.format_countdown(remaining)]

	## Plant sprite
	if sprite:
		if _plant_atlases.has(plant_type) and frame >= 0 and frame < _plant_atlases[plant_type].size():
			sprite.texture = _plant_atlases[plant_type][frame]
			sprite.visible = true
		else:
			sprite.visible = false


## ── Silo ─────────────────────────────────────────────────────────

func _rebuild_silo() -> void:
	for child in _silo_container.get_children():
		child.queue_free()

	var cap: int = GuildGarden.silo_capacity

	## Active mission keys — used to enable/disable deposit buttons.
	var active_mission_keys: Dictionary = {}
	for m in GuildManager.guild_missions:
		if m is Dictionary and str(m.get("status", "")) == "active":
			active_mission_keys[str(m.get("base_mission_key", ""))] = true

	var has_stock := false
	for c_def in PlayerData.CROP_DEFS:
		var crop_id: String = str(c_def["id"])
		var amount: int     = GuildGarden.get_silo_amount(crop_id)
		if amount <= 0:
			continue
		has_stock = true

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_silo_container.add_child(row)

		## Crop icon (collected sprite)
		var icon_tex: Texture2D = load(str(c_def.get("sprite", "")))
		if icon_tex:
			var icon := TextureRect.new()
			icon.texture = icon_tex
			icon.custom_minimum_size = Vector2(24, 24)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			row.add_child(icon)

		## Name + amount / capacity
		var info_lbl := Label.new()
		info_lbl.text = "%s  %d / %d" % [str(c_def["name"]), amount, cap]
		info_lbl.add_theme_font_size_override("font_size", 10)
		info_lbl.add_theme_color_override("font_color", Color.WHITE)
		info_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info_lbl)

		## Deposit-to-mission button (only if a matching mission is active).
		## A silo crop satisfies BOTH the crop-specific mission ("deposit_<crop>")
		## and the generic produce mission ("deposit_produce") — the server fans a
		## silo deposit out across every matching active mission (see
		## _guild_deposit_keys_for_item), so mirror that here. The amount offered
		## is the largest remaining need among them.
		var specific_key := "deposit_" + crop_id
		if active_mission_keys.has(specific_key) or active_mission_keys.has("deposit_produce"):
			var needed := 0
			for m in GuildManager.guild_missions:
				if not (m is Dictionary) or str(m.get("status", "")) != "active":
					continue
				var mkey := str(m.get("base_mission_key", ""))
				if mkey != specific_key and mkey != "deposit_produce":
					continue
				needed = maxi(needed, int(m.get("target", 0)) - int(m.get("progress", 0)))
			var can_deposit := mini(amount, needed)

			if can_deposit > 0:
				var dep_btn := Button.new()
				dep_btn.text = "→ Mission (%d)" % can_deposit
				dep_btn.add_theme_font_size_override("font_size", 10)
				dep_btn.custom_minimum_size = Vector2(110, 26)
				dep_btn.pressed.connect(
					_on_silo_deposit_pressed.bind(crop_id, can_deposit, dep_btn))
				row.add_child(dep_btn)

	if not has_stock:
		var empty := Label.new()
		empty.text = "Silo is empty."
		empty.add_theme_font_size_override("font_size", 10)
		empty.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_silo_container.add_child(empty)

	## Capacity footer
	var footer := Label.new()
	footer.text = "Silo capacity: %d per crop type" % cap
	footer.add_theme_font_size_override("font_size", 9)
	footer.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_silo_container.add_child(footer)


## ── Signal handlers ──────────────────────────────────────────────

func _on_guild_data_changed() -> void:
	if is_instance_valid(_silo_container):
		_rebuild_silo()


func _on_garden_updated() -> void:
	_refresh_grid_visuals()
	_rebuild_silo()
	_refresh_tool_buttons()
	_is_busy = false


func _on_timer_tick() -> void:
	_refresh_grid_visuals()


func _on_seed_selected(plant_type: int) -> void:
	if _selected_seed == plant_type:
		_selected_seed = -1
		_status_lbl.text = "Select a seed then tap a plot to plant."
		_status_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	else:
		_selected_seed = plant_type
		_status_lbl.text = "Tap an empty plot to plant %s." \
			% GardenData.PLANT_DEFS[plant_type].get("name", "")
		_status_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5))
	_update_seed_bar_highlight()
	_refresh_tool_buttons()


func _on_cell_pressed(row: int, col: int) -> void:
	var pos := Vector2i(row, col)
	if GuildGarden.is_cell_pending(row, col):
		return

	var cell := GuildGarden.get_cell(row, col)

	if cell.is_empty():
		## Plant
		if _selected_seed < 0:
			_set_status("Select a seed first.", Color(0.9, 0.5, 0.3))
			return
		if Garden.get_seed_count(_selected_seed) <= 0:
			_set_status("You have no more %s seeds." \
				% GardenData.PLANT_DEFS[_selected_seed].get("name", ""), Color(0.9, 0.4, 0.3))
			return

		var plant_type := _selected_seed
		var def: Dictionary = GardenData.PLANT_DEFS[plant_type]

		## 1. Instant optimistic update locally
		var ok := GuildGarden.plant_optimistic(row, col, plant_type)
		if not ok:
			return

		## 2. Immediate visual update
		var btn: Button = _cell_buttons.get(pos)
		_apply_cell_visual(btn, row, col)
		_update_seed_count_label(plant_type)
		_set_status("Planted %s! 🌱" % def.get("name", ""), Color(0.5, 1.0, 0.5))

		## 3. Advance to next seed if ran out
		if Garden.get_seed_count(plant_type) <= 0:
			_advance_to_next_seed_if_needed()

		## 4. Background non-blocking network commit
		_commit_plant_task(row, col, plant_type)
	else:
		## ── Tractor mode: harvest the whole row ──────────────────────────────
		if _tractor_active:
			_tractor_harvest_row(row)
			return
		## Harvest single cell
		if not GuildGarden.is_harvestable(row, col):
			var prog := GuildGarden.get_growth_progress(row, col)
			var pct  := int(prog * 100.0)
			_set_status("Still growing… %d%%" % pct, Color(0.8, 0.8, 0.8))
			return

		_commit_harvest_task(row, col)


func _commit_plant_task(row: int, col: int, plant_type: int) -> void:
	var res := await GuildGarden.commit_plant(_guild_id, row, col, plant_type)
	if not res.get("ok", false):
		## Failed: GuildGarden has rolled back the cell and refunded the seed
		var msg: String = str(res.get("message", "Could not plant."))
		_set_status("Plot (%d,%d): %s (seed refunded)" % [row + 1, col + 1, msg], Color(0.95, 0.4, 0.3))
		var pos := Vector2i(row, col)
		var btn: Button = _cell_buttons.get(pos)
		_apply_cell_visual(btn, row, col)
		_update_seed_count_label(plant_type)
		if _selected_seed == -1 and Garden.get_seed_count(plant_type) > 0:
			_rebuild_seed_bar()


func _commit_harvest_task(row: int, col: int) -> void:
	_set_status("Harvesting…", Color(0.8, 0.8, 0.8))
	var res := await GuildGarden.harvest(_guild_id, row, col)
	var pos := Vector2i(row, col)
	var btn: Button = _cell_buttons.get(pos)
	_apply_cell_visual(btn, row, col)

	if res.get("ok", false):
		var crop_id: String   = str(res.get("crop_id", ""))
		var to_mission: bool  = bool(res.get("went_to_mission", false))
		var to_silo: bool     = bool(res.get("went_to_silo", false))
		var crop_def          := PlayerData.get_crop_def(crop_id)
		var crop_name: String = str(crop_def.get("name", crop_id.capitalize())) \
			if not crop_def.is_empty() else crop_id.capitalize()
		if to_mission:
			_set_status("Harvested %s → Mission! ✅" % crop_name, Color(0.4, 1.0, 0.6))
		elif to_silo:
			_set_status("Harvested %s → Silo 🏚" % crop_name, Color(0.6, 0.9, 1.0))
		else:
			_set_status("Harvested %s (silo full)." % crop_name, Color(0.9, 0.7, 0.3))
	else:
		_set_status(str(res.get("message", "Could not harvest.")), Color(0.9, 0.4, 0.3))


func _on_silo_deposit_pressed(crop_id: String, amount: int, btn: Button) -> void:
	if _is_busy:
		return
	_is_busy = true
	if is_instance_valid(btn):
		btn.disabled = true
		btn.text = "Depositing…"
	var res := await GuildGarden.deposit_silo(_guild_id, crop_id, amount)
	_is_busy = false
	if not res.get("ok", false):
		_set_status(str(res.get("message", "Deposit failed.")), Color(0.9, 0.4, 0.3))
		if is_instance_valid(btn):
			btn.disabled = false
			btn.text = "→ Mission (%d)" % amount


## ── Helpers ──────────────────────────────────────────────────────

func _set_status(text: String, color: Color = Color.WHITE) -> void:
	if is_instance_valid(_status_lbl):
		_status_lbl.text = text
		_status_lbl.add_theme_color_override("font_color", color)


## ── Autoplant + Tractor ──────────────────────────────────────────

## Show/hide and label the autoplant + tractor buttons based on what the
## player has unlocked. Called on build, garden_updated, and seed selection.
func _refresh_tool_buttons() -> void:
	## Autoplant — requires "auto_plant" prestige > 0.
	var max_rows: int = PlayerData.get_auto_plant_rows()
	var ap_rows: int = PlayerData.resolve_auto_plant_rows(PlayerData.guild_garden_auto_plant_rows)
	if is_instance_valid(_autoplant_rows_lbl):
		_autoplant_rows_lbl.visible = max_rows > 0
	if is_instance_valid(_autoplant_rows_dd):
		_autoplant_rows_dd.visible = max_rows > 0
		if max_rows > 0:
			if _autoplant_rows_dd.item_count != max_rows:
				_autoplant_rows_dd.clear()
				for n in range(1, max_rows + 1):
					_autoplant_rows_dd.add_item(str(n), n)
			for i in range(_autoplant_rows_dd.item_count):
				if _autoplant_rows_dd.get_item_id(i) == ap_rows:
					_autoplant_rows_dd.selected = i
					break
	if is_instance_valid(_autoplant_btn):
		if max_rows <= 0:
			_autoplant_btn.visible = false
		else:
			_autoplant_btn.visible = true
			if _selected_seed < 0:
				_autoplant_btn.text = "🤖 Auto-Plant %d row(s) — pick a seed" % ap_rows
				_autoplant_btn.disabled = true
			else:
				var def: Dictionary = GardenData.PLANT_DEFS[_selected_seed]
				var seeds_left := Garden.get_seed_count(_selected_seed)
				_autoplant_btn.text = "🤖 Auto-Plant %d row(s) of %s (%d)" % [
					ap_rows, def.get("name", "?"), seeds_left]
				_autoplant_btn.disabled = seeds_left <= 0 or _is_autoplanting

	## Tractor — requires owning the (permanent) tractor tool.
	var has_tractor := PlayerData.get_tool_count(PlayerData.ToolType.TRACTOR) > 0
	if is_instance_valid(_tractor_btn):
		_tractor_btn.visible = has_tractor
		if not has_tractor:
			_tractor_active = false
			_tractor_btn.button_pressed = false


## Autoplant handler — plants up to get_auto_plant_rows() empty rows with the
## selected seed. Each row is batched into a single RPC (one network round-trip
## per row, not per cell). All rows are fired without awaiting so they run
## concurrently; garden_updated handles the repaint once each comes back.
func _on_autoplant_pressed() -> void:
	if _is_autoplanting or _selected_seed < 0:
		return
	var ap_rows: int = PlayerData.resolve_auto_plant_rows(PlayerData.guild_garden_auto_plant_rows)
	if ap_rows <= 0:
		return
	if Garden.get_seed_count(_selected_seed) <= 0:
		_set_status("You have no more %s seeds." % GardenData.PLANT_DEFS[_selected_seed].get("name", ""), Color(0.9, 0.4, 0.3))
		return

	_is_autoplanting = true
	_refresh_tool_buttons()

	var plant_type := _selected_seed
	var def: Dictionary = GardenData.PLANT_DEFS[plant_type]
	var rows_done := 0
	var planted_total := 0

	for r in range(_grid_rows):
		if rows_done >= ap_rows:
			break
		if Garden.get_seed_count(plant_type) <= 0:
			break

		## Collect every empty, non-pending cell in this row.
		var row_cells: Array = []
		for c in range(_grid_cols):
			if Garden.get_seed_count(plant_type) <= 0:
				break
			if GuildGarden.is_occupied(r, c) or GuildGarden.is_cell_pending(r, c):
				continue
			row_cells.append({"row": r, "col": c, "plant_type": plant_type})

		if row_cells.is_empty():
			continue
		rows_done += 1

		## Optimistic: mark all cells in the row locally at once + deduct seeds.
		var claimed := GuildGarden.batch_plant_optimistic(row_cells)
		if claimed.is_empty():
			continue
		planted_total += claimed.size()

		## Repaint the whole row immediately (instant visual feedback).
		for item in claimed:
			var pos := Vector2i(int(item.get("row", 0)), int(item.get("col", 0)))
			_apply_cell_visual(_cell_buttons.get(pos), pos.x, pos.y)
		_update_seed_count_label(plant_type)
		_set_status("Auto-planting… row %d" % (r + 1), Color(0.5, 1.0, 0.5))

		## Fire one RPC for the whole row — no await, runs concurrently.
		## garden_updated signal will repaint cells that get rolled back.
		_commit_batch_plant_task(claimed)

		## Yield a frame between rows so the UI stays responsive.
		await get_tree().process_frame

	## Advance seed bar if depleted.
	if Garden.get_seed_count(plant_type) <= 0:
		_advance_to_next_seed_if_needed()
		_rebuild_seed_bar()

	if planted_total > 0:
		_set_status("Auto-planting %d %s…" % [planted_total, def.get("name", "")], Color(0.5, 1.0, 0.5))
	else:
		_set_status("Nothing to plant — grid may be full or out of seeds.", Color(0.9, 0.5, 0.3))

	_is_autoplanting = false
	_refresh_tool_buttons()


## Fires a batch_plant RPC for a pre-optimistic-claimed list of cells,
## without blocking the caller. garden_updated handles the repaint on return.
func _commit_batch_plant_task(claimed: Array) -> void:
	var res := await GuildGarden.batch_plant(_guild_id, claimed)
	if not res.get("ok", false):
		## Cells that failed were already rolled back in batch_plant().
		## Just update the seed label and status to reflect the correction.
		_update_seed_count_label(_selected_seed if _selected_seed >= 0 else 0)
		_set_status("Some plots couldn't be planted: %s" % str(res.get("message", "Server error.")), Color(0.9, 0.5, 0.3))


## Tractor-mode row harvest: commits a harvest for every harvestable cell in the
## given row, firing RPCs concurrently (fire-and-forget, no await needed here).
func _tractor_harvest_row(row: int) -> void:
	var harvestable: Array[Vector2i] = []
	for c in range(_grid_cols):
		var pos := Vector2i(row, c)
		if GuildGarden.is_harvestable(row, c) and not GuildGarden.is_cell_pending(row, c):
			harvestable.append(pos)
	if harvestable.is_empty():
		_set_status("No harvestable crops in that row.", Color(0.8, 0.8, 0.8))
		return
	_set_status("🚜 Harvesting row %d… (%d crops)" % [row + 1, harvestable.size()], Color(1.0, 0.85, 0.3))
	for pos in harvestable:
		## Fire each harvest non-blocking (parallel RPCs) then let _on_garden_updated refresh.
		_commit_harvest_task(pos.x, pos.y)
