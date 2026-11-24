extends BaseScreen

## Workshop screen — the Saw (cut/polish gems) and the Hourglass (advance time).
## The saw sprite animates while gems are being cut. Gold is not polishable.

## Frame duration in seconds; higher = slower animation. Was 0.125s/frame (8 FPS);
## slowed by 0.25s to 0.375s/frame (~2.7 FPS).
const SAW_FRAME_TIME := 0.375
const SAW_ANIM_FPS := 1.0 / SAW_FRAME_TIME
const REFRESH_INTERVAL := 1.0  ## Update countdowns / animation each second

## Sentinel quantity meaning "add as many as possible" (clamped by owned + free
## slots inside Workshop.add_to_saw/add_to_foundry). Matches the marketplace's
## QTY_MAX so the two screens behave identically for the "Max" option.
const QTY_MAX := 1_000_000

## Quantity options shared by the saw and foundry "Add" dropdowns.
## Polishing/smelting count as crafting: 1 / 10 / 100 / 1000 / 10k / Max.
const QTY_OPTIONS: Array[int] = [1, 10, 100, 1000, 10000, QTY_MAX]

var _saw_sprite: TextureRect = null
var _saw_status: Label = null
var _collect_btn: Button = null
var _gem_rows: VBoxContainer = null
## Per-group "what's queued" list with Remove buttons (one row per stone type).
var _saw_queue_rows: VBoxContainer = null
var _saw_qty_dropdown: OptionButton = null
## Autofill selection: gem_type -> bool (checked = include in round-robin fill).
var _saw_autofill: Dictionary = {}
var _saw_autofill_btn: Button = null
## Whether the saw autofill ticker is currently running.
var _saw_autofill_active := false
## Which index in the rotation the ticker is currently on (cycles through pool).
var _saw_autofill_idx := 0
## Autofill selection for the foundry: raw_id -> bool.
var _foundry_autofill: Dictionary = {}
var _foundry_autofill_btn: Button = null
## Whether the foundry autofill ticker is currently running.
var _foundry_autofill_active := false
var _foundry_autofill_idx := 0
## True while an autofill tick is adding items. add_to_saw/add_to_foundry emit
## workshop_updated synchronously, whose handler ticks autofill again; this flag
## stops that from recursing.
var _autofill_ticking := false
## "Priority" toggles: when checked, Add inserts ahead of the waiting queue so
## the deposited items process next instead of behind everything already queued.
var _saw_priority_cb: CheckBox = null
var _foundry_priority_cb: CheckBox = null
var _hourglass_btn: Button = null
var _hourglass_label: Label = null
var _status_label: Label = null

## Foundry widgets (mirror the saw).
var _foundry_sprite: TextureRect = null
var _foundry_status: Label = null
var _foundry_collect_btn: Button = null
var _ore_rows: VBoxContainer = null
var _foundry_queue_rows: VBoxContainer = null
var _foundry_qty_dropdown: OptionButton = null

## Raw materials the foundry accepts, in display order. "gold" is a gemstone;
## the ores are resource items.
const FOUNDRY_RAWS: Array[String] = ["iron_ore", "copper_ore", "gold"]

var _anim_time: float = 0.0
var _foundry_anim_time: float = 0.0
var _refresh_timer: Timer = null


func get_screen_name() -> String:
	return "workshop"


func show_top_bar() -> bool:
	return true


func enter(_params: Dictionary = {}) -> void:
	_build_ui()
	if get_node_or_null("/root/Workshop") != null:
		Workshop.workshop_updated.connect(_on_workshop_updated)
	PlayerData.data_changed.connect(_on_data_changed)

	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = REFRESH_INTERVAL
	_refresh_timer.autostart = true
	_refresh_timer.timeout.connect(_on_tick)
	add_child(_refresh_timer)


func exit() -> void:
	_saw_autofill_active = false
	_foundry_autofill_active = false
	if get_node_or_null("/root/Workshop") != null and Workshop.workshop_updated.is_connected(_on_workshop_updated):
		Workshop.workshop_updated.disconnect(_on_workshop_updated)
	if PlayerData.data_changed.is_connected(_on_data_changed):
		PlayerData.data_changed.disconnect(_on_data_changed)
	for child in get_children():
		child.queue_free()


## ── Build UI ───────────────────────────────────────────────────

func _build_ui() -> void:
	## Light text on a dark workshop backdrop.
	var dark := Color(0.94, 0.92, 0.85)  ## "dark" name kept; now the light text color

	## Semi-transparent dark panel over the game background (matches Marketplace).
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.08, 0.08, 0.12, 0.88)
	panel_style.corner_radius_top_left = 6
	panel_style.corner_radius_top_right = 6
	panel_style.corner_radius_bottom_left = 6
	panel_style.corner_radius_bottom_right = 6
	panel.add_theme_stylebox_override("panel", panel_style)
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 10)
	scroll.add_child(root)

	## Back button
	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(200, 44)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(_on_back_pressed)
	root.add_child(back_btn)

	var title := Label.new()
	title.text = "🛠 Workshop"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", dark)
	root.add_child(title)

	## Shared status/feedback line.
	_status_label = Label.new()
	_status_label.custom_minimum_size = Vector2(0, 20)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", dark)
	root.add_child(_status_label)

	_build_saw_section(root, dark)
	root.add_child(HSeparator.new())
	_build_foundry_section(root, dark)
	root.add_child(HSeparator.new())
	_build_hourglass_section(root, dark)

	_refresh_all()


func _build_saw_section(root: VBoxContainer, dark: Color) -> void:
	var header := Label.new()
	header.text = "🪚 Gem Saw — cut & polish gems"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", dark)
	root.add_child(header)

	## Animated saw sprite on the left, the live queue list on the right.
	var saw_row := HBoxContainer.new()
	saw_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	saw_row.add_theme_constant_override("separation", 10)
	root.add_child(saw_row)

	var saw_center := CenterContainer.new()
	saw_center.custom_minimum_size = Vector2(96, 96)
	saw_row.add_child(saw_center)
	_saw_sprite = TextureRect.new()
	_saw_sprite.custom_minimum_size = Vector2(96, 96)
	_saw_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_saw_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_saw_sprite.texture = Workshop.get_saw_frame(0)  ## initial frame
	saw_center.add_child(_saw_sprite)

	## Queue list: one row per stone type currently in the saw, with Remove.
	_saw_queue_rows = VBoxContainer.new()
	_saw_queue_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_saw_queue_rows.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_saw_queue_rows.add_theme_constant_override("separation", 3)
	saw_row.add_child(_saw_queue_rows)

	_saw_status = Label.new()
	_saw_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_saw_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_saw_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_saw_status.add_theme_font_size_override("font_size", 11)
	_saw_status.add_theme_color_override("font_color", dark)
	root.add_child(_saw_status)

	## Collect button (only enabled when something's ready).
	_collect_btn = Button.new()
	_collect_btn.text = "Collect Polished Gems"
	_collect_btn.add_theme_font_size_override("font_size", 12)
	_collect_btn.custom_minimum_size = Vector2(0, 40)
	_collect_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_collect_btn.pressed.connect(_on_collect_pressed)
	root.add_child(_collect_btn)

	## Per-gem "add to saw" rows.
	var add_label := Label.new()
	add_label.text = "Add uncut gems to the saw:"
	add_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_label.add_theme_font_size_override("font_size", 11)
	add_label.add_theme_color_override("font_color", dark)
	root.add_child(add_label)

	## Shared quantity selector for the saw "Add" buttons (1 / 10 / 25 / Max).
	## Restores the player's last choice and persists changes.
	_saw_qty_dropdown = _make_qty_dropdown(Workshop.last_saw_qty)
	_saw_qty_dropdown.item_selected.connect(func(_i):
		Workshop.last_saw_qty = _selected_qty(_saw_qty_dropdown)
		Workshop.save_data())
	_saw_priority_cb = CheckBox.new()
	var saw_qty_row := _make_qty_row("Add qty:", _saw_qty_dropdown, dark, _saw_priority_cb)
	root.add_child(saw_qty_row)

	_gem_rows = VBoxContainer.new()
	_gem_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gem_rows.add_theme_constant_override("separation", 4)
	root.add_child(_gem_rows)
	_build_gem_rows(dark)

	## Autofill button: toggles the continuous round-robin ticker on/off.
	_saw_autofill_btn = Button.new()
	_saw_autofill_btn.text = "✦ Fill Even"
	_saw_autofill_btn.tooltip_text = "Tick gems above, then tap to split the saw's free slots evenly between them."
	_saw_autofill_btn.add_theme_font_size_override("font_size", 12)
	_saw_autofill_btn.custom_minimum_size = Vector2(0, 40)
	_saw_autofill_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_saw_autofill_btn.pressed.connect(_on_saw_autofill_pressed)
	root.add_child(_saw_autofill_btn)


func _build_gem_rows(dark: Color) -> void:
	for child in _gem_rows.get_children():
		child.queue_free()

	for gem_type in PlayerData.POLISHABLE_GEMS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		## Autofill checkbox: ticking this includes the gem in round-robin fill.
		var cb := CheckBox.new()
		cb.tooltip_text = "Include in Fill Even"
		cb.button_pressed = bool(_saw_autofill.get(gem_type, false))
		cb.toggled.connect(func(on: bool): _saw_autofill[gem_type] = on)
		row.add_child(cb)

		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(28, 28)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = load("res://Assets/GoldPanning/Gemstones/%s.png" % gem_type)
		row.add_child(icon)

		var name_lbl := Label.new()
		name_lbl.name = "Name"
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_size_override("font_size", 11)
		name_lbl.add_theme_color_override("font_color", dark)
		row.add_child(name_lbl)

		## Single Add button — uses the shared saw quantity dropdown.
		var add_btn := Button.new()
		add_btn.text = "Add"
		add_btn.add_theme_font_size_override("font_size", 11)
		add_btn.custom_minimum_size = Vector2(60, 36)
		add_btn.pressed.connect(_on_add_gem.bind(gem_type))
		row.add_child(add_btn)

		_gem_rows.add_child(row)
	_refresh_gem_rows()


func _build_foundry_section(root: VBoxContainer, dark: Color) -> void:
	var header := Label.new()
	header.text = "🏭 Foundry — smelt ores into bars"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", dark)
	root.add_child(header)

	## Animated foundry sprite (6 frames) on the left, queue list on the right.
	var foundry_row := HBoxContainer.new()
	foundry_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foundry_row.add_theme_constant_override("separation", 10)
	root.add_child(foundry_row)

	var f_center := CenterContainer.new()
	f_center.custom_minimum_size = Vector2(96, 96)
	foundry_row.add_child(f_center)
	_foundry_sprite = TextureRect.new()
	_foundry_sprite.custom_minimum_size = Vector2(96, 96)
	_foundry_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_foundry_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_foundry_sprite.texture = Workshop.get_foundry_frame(0)
	f_center.add_child(_foundry_sprite)

	_foundry_queue_rows = VBoxContainer.new()
	_foundry_queue_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_foundry_queue_rows.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_foundry_queue_rows.add_theme_constant_override("separation", 3)
	foundry_row.add_child(_foundry_queue_rows)

	_foundry_status = Label.new()
	_foundry_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_foundry_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_foundry_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_foundry_status.add_theme_font_size_override("font_size", 11)
	_foundry_status.add_theme_color_override("font_color", dark)
	root.add_child(_foundry_status)

	_foundry_collect_btn = Button.new()
	_foundry_collect_btn.text = "Collect Bars"
	_foundry_collect_btn.add_theme_font_size_override("font_size", 12)
	_foundry_collect_btn.custom_minimum_size = Vector2(0, 40)
	_foundry_collect_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_foundry_collect_btn.pressed.connect(_on_foundry_collect_pressed)
	root.add_child(_foundry_collect_btn)

	var add_label := Label.new()
	add_label.text = "Add ores to the foundry:"
	add_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_label.add_theme_font_size_override("font_size", 11)
	add_label.add_theme_color_override("font_color", dark)
	root.add_child(add_label)

	## Shared quantity selector for the foundry "Add" buttons (1 / 10 / 25 / Max).
	## Restores the player's last choice and persists changes.
	_foundry_qty_dropdown = _make_qty_dropdown(Workshop.last_foundry_qty)
	_foundry_qty_dropdown.item_selected.connect(func(_i):
		Workshop.last_foundry_qty = _selected_qty(_foundry_qty_dropdown)
		Workshop.save_data())
	_foundry_priority_cb = CheckBox.new()
	var foundry_qty_row := _make_qty_row("Add qty:", _foundry_qty_dropdown, dark, _foundry_priority_cb)
	root.add_child(foundry_qty_row)

	_ore_rows = VBoxContainer.new()
	_ore_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ore_rows.add_theme_constant_override("separation", 4)
	root.add_child(_ore_rows)
	_build_ore_rows(dark)

	## Autofill button for the foundry (toggle).
	_foundry_autofill_btn = Button.new()
	_foundry_autofill_btn.text = "✦ Fill Even"
	_foundry_autofill_btn.tooltip_text = "Tick ores above, then tap to split the foundry's free slots evenly between them."
	_foundry_autofill_btn.add_theme_font_size_override("font_size", 12)
	_foundry_autofill_btn.custom_minimum_size = Vector2(0, 40)
	_foundry_autofill_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_foundry_autofill_btn.pressed.connect(_on_foundry_autofill_pressed)
	root.add_child(_foundry_autofill_btn)


func _build_ore_rows(dark: Color) -> void:
	for child in _ore_rows.get_children():
		child.queue_free()

	for raw_id in FOUNDRY_RAWS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		## Autofill checkbox.
		var cb := CheckBox.new()
		cb.tooltip_text = "Include in Fill Even"
		cb.button_pressed = bool(_foundry_autofill.get(raw_id, false))
		cb.toggled.connect(func(on: bool): _foundry_autofill[raw_id] = on)
		row.add_child(cb)

		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(28, 28)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = _raw_icon(raw_id)
		row.add_child(icon)

		var name_lbl := Label.new()
		name_lbl.name = "Name"
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_size_override("font_size", 11)
		name_lbl.add_theme_color_override("font_color", dark)
		row.add_child(name_lbl)

		## Single Add button — uses the shared foundry quantity dropdown.
		var add_btn := Button.new()
		add_btn.text = "Add"
		add_btn.add_theme_font_size_override("font_size", 11)
		add_btn.custom_minimum_size = Vector2(60, 36)
		add_btn.pressed.connect(_on_add_ore.bind(raw_id))
		row.add_child(add_btn)

		_ore_rows.add_child(row)
	_refresh_ore_rows()


## Icon for a raw foundry material: gold uses its gemstone sprite, ores use the
## ores sheet via OreSprites.
func _raw_icon(raw_id: String) -> Texture2D:
	if raw_id == "gold":
		return load("res://Assets/GoldPanning/Gemstones/gold.png")
	return OreSprites.get_item_texture(raw_id)


func _raw_display_name(raw_id: String) -> String:
	return str(raw_id).replace("_", " ").capitalize()


func _build_hourglass_section(root: VBoxContainer, dark: Color) -> void:
	var header := Label.new()
	header.text = "⏳ Hourglass — skip 1 hour"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", dark)
	root.add_child(header)

	var desc := Label.new()
	desc.text = "Advances gardens, prospectors, gem cutting and shop restocks by 1 hour. Does not affect the daily bonus."
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 10)
	desc.add_theme_color_override("font_color", dark)
	root.add_child(desc)

	var hg_center := CenterContainer.new()
	hg_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(hg_center)

	_hourglass_btn = Button.new()
	_hourglass_btn.custom_minimum_size = Vector2(96, 96)
	_hourglass_btn.flat = true
	_hourglass_btn.pressed.connect(_on_hourglass_pressed)
	var hg_tex := Workshop.get_hourglass_texture()
	if hg_tex:
		var hg_sprite := TextureRect.new()
		hg_sprite.texture = hg_tex
		hg_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		hg_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hg_sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
		hg_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hourglass_btn.add_child(hg_sprite)
	else:
		_hourglass_btn.text = "⏳"
	hg_center.add_child(_hourglass_btn)

	_hourglass_label = Label.new()
	_hourglass_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hourglass_label.add_theme_font_size_override("font_size", 11)
	_hourglass_label.add_theme_color_override("font_color", dark)
	root.add_child(_hourglass_label)


## ── Refresh ────────────────────────────────────────────────────

func _refresh_all() -> void:
	_refresh_saw_status()
	_refresh_saw_queue_rows()
	_refresh_gem_rows()
	_refresh_foundry_status()
	_refresh_foundry_queue_rows()
	_refresh_ore_rows()
	_refresh_hourglass()


## Rebuilds the saw queue list: one row per stone type currently queued, showing
## its icon, "Name ×N", and a Remove button that returns ALL of that type.
func _refresh_saw_queue_rows() -> void:
	if _saw_queue_rows == null:
		return
	for child in _saw_queue_rows.get_children():
		child.queue_free()
	var groups := Workshop.saw_queue_groups()
	if groups.is_empty():
		var empty := Label.new()
		empty.text = "Saw queue empty."
		empty.add_theme_font_size_override("font_size", 10)
		empty.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		_saw_queue_rows.add_child(empty)
		return
	for g in groups:
		var gem_type: String = str(g["type"])
		var count: int = int(g["count"])
		var icon_tex: Texture2D = load("res://Assets/GoldPanning/Gemstones/%s.png" % gem_type)
		_saw_queue_rows.add_child(_make_queue_row(
			icon_tex, "%s ×%d" % [str(gem_type).replace("_", " ").capitalize(), count],
			_on_remove_saw_group.bind(gem_type)))


## Rebuilds the foundry queue list (mirror of the saw).
func _refresh_foundry_queue_rows() -> void:
	if _foundry_queue_rows == null:
		return
	for child in _foundry_queue_rows.get_children():
		child.queue_free()
	var groups := Workshop.foundry_queue_groups()
	if groups.is_empty():
		var empty := Label.new()
		empty.text = "Foundry queue empty."
		empty.add_theme_font_size_override("font_size", 10)
		empty.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		_foundry_queue_rows.add_child(empty)
		return
	for g in groups:
		var raw_id: String = str(g["type"])
		var count: int = int(g["count"])
		_foundry_queue_rows.add_child(_make_queue_row(
			_raw_icon(raw_id), "%s ×%d" % [_raw_display_name(raw_id), count],
			_on_remove_foundry_group.bind(raw_id)))


## Builds one compact queue row: small icon + label + a Remove (✕) button wired
## to `on_remove`. Shared by the saw and foundry queue lists.
func _make_queue_row(icon_tex: Texture2D, text: String, on_remove: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	if icon_tex:
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(22, 22)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = icon_tex
		row.add_child(icon)

	var lbl := Label.new()
	lbl.text = text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.94, 0.92, 0.85))
	row.add_child(lbl)

	var rm := Button.new()
	rm.text = "Remove"
	rm.add_theme_font_size_override("font_size", 10)
	rm.custom_minimum_size = Vector2(70, 30)
	rm.pressed.connect(on_remove)
	row.add_child(rm)
	return row


func _refresh_foundry_status() -> void:
	if _foundry_status == null:
		return
	var load_count := Workshop.get_foundry_load()
	var cap := Workshop.get_foundry_capacity()
	var per := Workshop.get_foundry_parallelism()
	var ready := Workshop.get_foundry_ready_count()
	if Workshop.is_foundry_empty():
		_foundry_status.text = "Foundry idle — %d/%d slots  (smelts %d at a time)" % [load_count, cap, per]
	elif ready >= load_count:
		_foundry_status.text = "%d bar(s) ready to collect!  (%d/%d slots)" % [ready, load_count, cap]
	else:
		var secs := Workshop.foundry_next_ready_seconds()
		var msg := "Smelting %d ore(s), %d at a time… next in %s" % [load_count - ready, per, _format_time(secs)]
		if ready > 0:
			msg += "  (%d ready)" % ready
		msg += "  (%d/%d slots)" % [load_count, cap]
		_foundry_status.text = msg
	if _foundry_collect_btn:
		_foundry_collect_btn.disabled = not Workshop.has_ready_bars()


func _refresh_ore_rows() -> void:
	if _ore_rows == null:
		return
	var space := Workshop.get_foundry_space()
	var idx := 0
	for raw_id in FOUNDRY_RAWS:
		if idx >= _ore_rows.get_child_count():
			break
		var row := _ore_rows.get_child(idx) as HBoxContainer
		idx += 1
		if row == null:
			continue
		var owned := PlayerData.get_gem_count("gold") if raw_id == "gold" else PlayerData.get_item_count(raw_id)
		var name_lbl := row.get_node_or_null("Name") as Label
		if name_lbl:
			name_lbl.text = "%s — Own: %d" % [_raw_display_name(raw_id), owned]
		for child in row.get_children():
			if child is Button:
				child.disabled = owned <= 0 or space <= 0


func _refresh_saw_status() -> void:
	if _saw_status == null:
		return
	var load_count := Workshop.get_saw_load()
	var cap := Workshop.get_saw_capacity()
	var per := Workshop.get_saw_parallelism()
	var ready := Workshop.get_ready_count()
	if Workshop.is_saw_empty():
		_saw_status.text = "Saw idle — %d/%d slots  (cuts %d at a time)" % [load_count, cap, per]
	elif ready >= load_count:
		_saw_status.text = "%d polished gem(s) ready to collect!  (%d/%d slots)" % [ready, load_count, cap]
	else:
		var secs := Workshop.next_ready_seconds()
		var msg := "Cutting %d gem(s), %d at a time… next in %s" % [load_count - ready, per, _format_time(secs)]
		if ready > 0:
			msg += "  (%d ready)" % ready
		msg += "  (%d/%d slots)" % [load_count, cap]
		_saw_status.text = msg
	if _collect_btn:
		_collect_btn.disabled = not Workshop.has_ready_gems()


func _refresh_gem_rows() -> void:
	if _gem_rows == null:
		return
	var space := Workshop.get_saw_space()
	var idx := 0
	for gem_type in PlayerData.POLISHABLE_GEMS:
		if idx >= _gem_rows.get_child_count():
			break
		var row := _gem_rows.get_child(idx) as HBoxContainer
		idx += 1
		if row == null:
			continue
		var owned := PlayerData.get_gem_count(gem_type)
		var name_lbl := row.get_node_or_null("Name") as Label
		if name_lbl:
			name_lbl.text = "%s — Own: %d" % [str(gem_type).replace("_", " ").capitalize(), owned]
		## Disable add buttons if none owned or saw full.
		for child in row.get_children():
			if child is Button:
				child.disabled = owned <= 0 or space <= 0


func _refresh_hourglass() -> void:
	if _hourglass_label == null:
		return
	var remaining := Workshop.get_hourglass_remaining()
	var limit := Workshop.get_hourglass_limit()
	_hourglass_label.text = "Uses left today: %d / %d" % [remaining, limit]
	if _hourglass_btn:
		_hourglass_btn.disabled = remaining <= 0


func _format_time(secs: float) -> String:
	if secs <= 0.0:
		return "ready"
	var s := int(ceil(secs))
	var m := s / 60
	var r := s % 60
	if m > 0:
		return "%dm %ds" % [m, r]
	return "%ds" % r


## ── Quantity dropdown helpers ──────────────────────────────────

## Builds an OptionButton populated with the shared quantity options
## (1 / 10 / 25 / Max). "Max" stores the QTY_MAX sentinel as its item id.
## `saved_value` is the option VALUE to pre-select (from WorkshopData), so the
## dropdown re-opens on the player's last choice.
func _make_qty_dropdown(saved_value: int = 1) -> OptionButton:
	var dd := OptionButton.new()
	dd.add_theme_font_size_override("font_size", 12)
	dd.custom_minimum_size = Vector2(80, 36)
	var sel_idx := 0
	for i in range(QTY_OPTIONS.size()):
		var q: int = QTY_OPTIONS[i]
		if q == QTY_MAX:
			dd.add_item("Max", q)
		else:
			dd.add_item("10k" if q == 10000 else str(q), q)
		if q == saved_value:
			sel_idx = i
	dd.selected = sel_idx  ## Restore the saved choice (defaults to 1).
	return dd


## Wraps a label + dropdown in a centered row for placement under an "Add …" header.
func _make_qty_row(label_text: String, dropdown: OptionButton, dark: Color, priority_cb: CheckBox = null) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", dark)
	row.add_child(lbl)
	row.add_child(dropdown)
	## Optional "Priority" toggle for Add presses in this section.
	if priority_cb != null:
		priority_cb.text = "Priority"
		priority_cb.tooltip_text = "Added items jump to the front of the queue (processed next)."
		priority_cb.add_theme_font_size_override("font_size", 11)
		priority_cb.add_theme_color_override("font_color", dark)
		row.add_child(priority_cb)
	return row


## Returns the quantity currently selected in a dropdown (QTY_MAX for "Max").
## Defaults to 1 if the dropdown is missing/invalid.
func _selected_qty(dropdown: OptionButton) -> int:
	if dropdown == null or not is_instance_valid(dropdown):
		return 1
	return dropdown.get_selected_id()


## ── Interaction ────────────────────────────────────────────────

func _on_add_gem(gem_type: String) -> void:
	var qty := _selected_qty(_saw_qty_dropdown)
	var priority := _saw_priority_cb != null and _saw_priority_cb.button_pressed
	var added := Workshop.add_to_saw(gem_type, qty, priority)
	if added <= 0:
		if Workshop.get_saw_space() <= 0:
			_status_label.text = "Saw is full (%d slots)." % Workshop.get_saw_capacity()
		else:
			_status_label.text = "No %s to add." % str(gem_type).replace("_", " ").capitalize()
		return
	var where := " (priority — next in line)" if priority else ""
	_status_label.text = "Added %d %s to the saw.%s" % [added, str(gem_type).replace("_", " ").capitalize(), where]
	_refresh_all()


func _on_remove_saw_group(gem_type: String) -> void:
	var removed := Workshop.remove_saw_group(gem_type)
	var name_txt := str(gem_type).replace("_", " ").capitalize()
	if removed <= 0:
		_status_label.text = "No %s in the saw." % name_txt
		return
	_status_label.text = "Removed %d %s from the saw — returned to your bag." % [removed, name_txt]
	_refresh_all()


func _on_remove_foundry_group(raw_id: String) -> void:
	var removed := Workshop.remove_foundry_group(raw_id)
	var name_txt := _raw_display_name(raw_id)
	if removed <= 0:
		_status_label.text = "No %s in the foundry." % name_txt
		return
	_status_label.text = "Removed %d %s from the foundry — returned to your bag." % [removed, name_txt]
	_refresh_all()


func _on_collect_pressed() -> void:
	var collected := Workshop.collect_ready()
	if collected.is_empty():
		_status_label.text = "Nothing ready yet."
		return
	var parts: Array = []
	for gem_type in collected:
		parts.append("%d %s" % [int(collected[gem_type]), str(gem_type).replace("_", " ").capitalize()])
	_status_label.text = "Collected polished: %s" % ", ".join(parts)
	_refresh_all()


func _on_add_ore(raw_id: String) -> void:
	var qty := _selected_qty(_foundry_qty_dropdown)
	var priority := _foundry_priority_cb != null and _foundry_priority_cb.button_pressed
	var added := Workshop.add_to_foundry(raw_id, qty, priority)
	if added <= 0:
		if Workshop.get_foundry_space() <= 0:
			_status_label.text = "Foundry is full (%d slots)." % Workshop.get_foundry_capacity()
		else:
			_status_label.text = "No %s to add." % _raw_display_name(raw_id)
		return
	var where := " (priority — next in line)" if priority else ""
	_status_label.text = "Added %d %s to the foundry.%s" % [added, _raw_display_name(raw_id), where]
	_refresh_all()


func _on_foundry_collect_pressed() -> void:
	var collected := Workshop.collect_foundry_ready()
	if collected.is_empty():
		_status_label.text = "Nothing smelted yet."
		return
	var parts: Array = []
	for out_id in collected:
		parts.append("%d %s" % [int(collected[out_id]), str(out_id).replace("_", " ").capitalize()])
	_status_label.text = "Collected: %s" % ", ".join(parts)
	_refresh_all()


func _on_hourglass_pressed() -> void:
	if not Workshop.use_hourglass():
		_status_label.text = "No hourglass uses left today."
		return
	_status_label.text = "⏳ Skipped 1 hour — gardens, prospectors, gem cutting and shops advanced."
	_refresh_all()


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


## ── Ticking / signals ──────────────────────────────────────────

func _on_tick() -> void:
	## Status/countdown update once per second. Animations run in _process().
	_refresh_saw_status()
	_refresh_foundry_status()


## Animate the saw sprite smoothly (per-frame) while gems are actively cutting.
func _process(delta: float) -> void:
	if _saw_sprite == null:
		return
	if get_node_or_null("/root/Workshop") == null:
		return
	var still_cutting := Workshop.get_saw_load() - Workshop.get_ready_count() > 0
	if still_cutting:
		_anim_time += delta
		var frames := Workshop.get_saw_frame_count()
		if frames > 0:
			var frame := int(_anim_time * SAW_ANIM_FPS) % frames
			_saw_sprite.texture = Workshop.get_saw_frame(frame)
	else:
		_saw_sprite.texture = Workshop.get_saw_frame(0)

	## Foundry animates the same way while ores are actively smelting.
	if _foundry_sprite != null:
		var still_smelting := Workshop.get_foundry_load() - Workshop.get_foundry_ready_count() > 0
		if still_smelting:
			_foundry_anim_time += delta
			var f_frames := Workshop.get_foundry_frame_count()
			if f_frames > 0:
				var f_frame := int(_foundry_anim_time * SAW_ANIM_FPS) % f_frames
				_foundry_sprite.texture = Workshop.get_foundry_frame(f_frame)
		else:
			_foundry_sprite.texture = Workshop.get_foundry_frame(0)


func _on_workshop_updated() -> void:
	_refresh_all()


func _on_data_changed() -> void:
	_refresh_gem_rows()
	_refresh_ore_rows()


# ── Auto-Fill Queue (ticker design) ───────────────────────────

## One-shot Fill Even for the saw: splits the free slots evenly across the
## ticked gems, one fill per tap. No ON/OFF state — it never runs on its own.
func _on_saw_autofill_pressed() -> void:
	var pool := _saw_pool()
	if pool.is_empty():
		_status_label.text = "Tick the gems you want, then tap Fill Even."
		return
	if Workshop.get_saw_space() <= 0:
		_status_label.text = "The saw is full."
		return
	var before := Workshop.get_saw_load()
	_saw_autofill_active = true
	_tick_saw_autofill()
	_saw_autofill_active = false
	var added := Workshop.get_saw_load() - before
	if added > 0:
		_status_label.text = "Added %d gem%s to the saw (%s)." % [
			added, "" if added == 1 else "s", ", ".join(pool)]
	else:
		_status_label.text = "You don't have any of the ticked gems."


## One-shot Fill Even for the foundry (mirror of the saw).
func _on_foundry_autofill_pressed() -> void:
	var pool := _foundry_pool()
	if pool.is_empty():
		_status_label.text = "Tick the ores you want, then tap Fill Even."
		return
	if Workshop.get_foundry_space() <= 0:
		_status_label.text = "The foundry is full."
		return
	var before := Workshop.get_foundry_load()
	_foundry_autofill_active = true
	_tick_foundry_autofill()
	_foundry_autofill_active = false
	var added := Workshop.get_foundry_load() - before
	if added > 0:
		_status_label.text = "Added %d to the foundry (%s)." % [added, ", ".join(pool)]
	else:
		_status_label.text = "You don't have any of the ticked ores."


## Called every second (and on workshop_updated). Splits the free slots across
## the checked items round-robin (one at a time per item, starting where the last
## tick left off), then adds each item's share in ONE call.
##
## Why planned, not looped: Workshop.add_to_saw emits workshop_updated
## synchronously, and that handler calls this ticker again. Adding one gem per
## call recursed once per free slot (each with a save + full UI rebuild) until
## the stack overflowed and the game crashed. The re-entrancy guard stops the
## recursion, and planning keeps it to at most one add per gem type.
func _tick_saw_autofill() -> void:
	if not _saw_autofill_active or _autofill_ticking:
		return
	var pool := _saw_pool()
	if pool.is_empty():
		## Checked items ran out — stop the ticker.
		_saw_autofill_active = false
		_saw_autofill_idx = 0
		_update_autofill_buttons()
		_status_label.text = "Saw Fill Even stopped — no checked gems available."
		return
	var owned: Dictionary = {}
	for gem_type in pool:
		owned[gem_type] = PlayerData.get_gem_count(gem_type)
	var plan := _plan_round_robin(pool, owned, Workshop.get_saw_space(), _saw_autofill_idx)
	_saw_autofill_idx = int(plan["next_idx"])
	var alloc: Dictionary = plan["alloc"]
	if alloc.is_empty():
		return
	_autofill_ticking = true
	for gem_type in alloc:
		Workshop.add_to_saw(gem_type, int(alloc[gem_type]), false)
	_autofill_ticking = false


## Foundry ticker — exact mirror of the saw ticker.
func _tick_foundry_autofill() -> void:
	if not _foundry_autofill_active or _autofill_ticking:
		return
	var pool := _foundry_pool()
	if pool.is_empty():
		_foundry_autofill_active = false
		_foundry_autofill_idx = 0
		_update_autofill_buttons()
		_status_label.text = "Foundry Fill Even stopped — no checked ores available."
		return
	var owned: Dictionary = {}
	for raw_id in pool:
		owned[raw_id] = Workshop._owned_raw(raw_id)
	var plan := _plan_round_robin(pool, owned, Workshop.get_foundry_space(), _foundry_autofill_idx)
	_foundry_autofill_idx = int(plan["next_idx"])
	var alloc: Dictionary = plan["alloc"]
	if alloc.is_empty():
		return
	_autofill_ticking = true
	for raw_id in alloc:
		Workshop.add_to_foundry(raw_id, int(alloc[raw_id]), false)
	_autofill_ticking = false


## Distributes `space` slots across `pool` one item at a time in rotation,
## starting at `start_idx`, never exceeding what's owned. Pure (no side effects).
## Returns { "alloc": {item -> qty}, "next_idx": int }.
func _plan_round_robin(pool: Array[String], owned: Dictionary, space: int, start_idx: int) -> Dictionary:
	var alloc: Dictionary = {}
	var n: int = pool.size()
	var idx: int = start_idx % n if n > 0 else 0
	if n == 0 or space <= 0:
		return {"alloc": alloc, "next_idx": idx}
	var remaining: Dictionary = owned.duplicate()
	var left: int = space
	var stall: int = 0
	while left > 0 and stall < n:
		var item: String = pool[idx]
		if int(remaining.get(item, 0)) > 0:
			alloc[item] = int(alloc.get(item, 0)) + 1
			remaining[item] = int(remaining[item]) - 1
			left -= 1
			stall = 0
		else:
			stall += 1
		idx = (idx + 1) % n
	return {"alloc": alloc, "next_idx": idx}


## The ordered list of checked saw gems (preserves POLISHABLE_GEMS order).
func _saw_pool() -> Array[String]:
	var out: Array[String] = []
	for gem_type in PlayerData.POLISHABLE_GEMS:
		if bool(_saw_autofill.get(gem_type, false)):
			out.append(gem_type)
	return out


## The ordered list of checked foundry ores (preserves FOUNDRY_RAWS order).
func _foundry_pool() -> Array[String]:
	var out: Array[String] = []
	for raw_id in FOUNDRY_RAWS:
		if bool(_foundry_autofill.get(raw_id, false)):
			out.append(raw_id)
	return out


## Updates the autofill button labels to reflect active/inactive state.
func _update_autofill_buttons() -> void:
	if is_instance_valid(_saw_autofill_btn):
		_saw_autofill_btn.text = "✦ Fill Even"
	if is_instance_valid(_foundry_autofill_btn):
		_foundry_autofill_btn.text = "✦ Fill Even"
