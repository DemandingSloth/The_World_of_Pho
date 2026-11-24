extends BaseScreen
## Inventory screen — displays owned Pho tiles and seeds in a tabbed layout.
## Reads data from PlayerData (tile inventory) and Garden (seed inventory).
##
## Requirements: 1.2, 1.3, 1.5, 1.6, 9.1, 9.3


@onready var vbox: VBoxContainer = $VBox
@onready var top_row: HBoxContainer = $VBox/TopRow
@onready var title_label: Label = $VBox/TopRow/TitleLabel
@onready var back_btn: Button = $VBox/TopRow/BackBtn
@onready var summary_label: Label = $VBox/SummaryLabel
@onready var tab_bar: HBoxContainer = $VBox/TabBar
@onready var tab_tiles_btn: Button = $VBox/TabBar/TabTilesBtn
@onready var tab_seeds_btn: Button = $VBox/TabBar/TabSeedsBtn
@onready var tab_tools_btn: Button = $VBox/TabBar/TabToolsBtn
@onready var tab_items_btn: Button = $VBox/TabBar/TabItemsBtn
@onready var tiles_scroll: ScrollContainer = $VBox/TilesScroll
@onready var inv_grid: GridContainer = $VBox/TilesScroll/InvGrid
@onready var seeds_scroll: ScrollContainer = $VBox/SeedsScroll
@onready var seeds_grid: VBoxContainer = $VBox/SeedsScroll/SeedsGrid
@onready var tools_scroll: ScrollContainer = $VBox/ToolsScroll
@onready var tools_grid: VBoxContainer = $VBox/ToolsScroll/ToolsGrid
@onready var items_scroll: ScrollContainer = $VBox/ItemsScroll
@onready var items_grid: VBoxContainer = $VBox/ItemsScroll/ItemsGrid
@onready var tab_gems_btn: Button = $VBox/TabBar/TabGemsBtn
@onready var gems_scroll: ScrollContainer = $VBox/GemsScroll
@onready var gems_grid: VBoxContainer = $VBox/GemsScroll/GemsGrid

## ── Sorting ─────────────────────────────────────────────────────
## Mirrors the marketplace's sort options. Inventory is view-only, so there's no
## Stock axis; each list tab offers Name / Value / Owned. Selection per tab is
## remembered across rebuilds.
enum SortMode { NAME = 0, VALUE = 1, OWNED = 2 }

var _sort_mode_seeds: int = SortMode.NAME
var _sort_mode_tools: int = SortMode.NAME
var _sort_mode_items: int = SortMode.VALUE
var _sort_mode_gems: int = SortMode.VALUE

var _seeds_sort_dropdown: OptionButton = null
var _tools_sort_dropdown: OptionButton = null
var _items_sort_dropdown: OptionButton = null
var _gems_sort_dropdown: OptionButton = null

## Quantity sentinel + options for the Items-tab Craft action (matches the
## Marketplace: 1 / 5 / 10 / 25 / Max). "Max" crafts as many as materials allow.
const QTY_MAX := 1_000_000
var _items_qty_dropdown: OptionButton = null


## Builds a "Sort:" row with a Name / <value_label> / Owned OptionButton,
## restoring `prev_id` and connecting `on_changed`. Returns [row, dropdown].
func _make_sort_row(value_label: String, prev_id: int, on_changed: Callable) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var lbl := Label.new()
	lbl.text = "Sort:"
	lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(lbl)
	var dd := OptionButton.new()
	dd.add_item("Name", SortMode.NAME)
	dd.add_item(value_label, SortMode.VALUE)
	dd.add_item("Owned", SortMode.OWNED)
	dd.add_theme_font_size_override("font_size", 12)
	for opt_idx in range(dd.item_count):
		if dd.get_item_id(opt_idx) == prev_id:
			dd.selected = opt_idx
			break
	dd.item_selected.connect(on_changed)
	row.add_child(dd)
	return [row, dd]


## Adds a centered category header label (e.g. "── Crops ──") to a grid.
func _add_category_header(grid: Control, text: String) -> void:
	var header := Label.new()
	header.text = "── %s ──" % text
	header.add_theme_font_size_override("font_size", 13)
	header.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	grid.add_child(header)


## Builds a "Qty:" row with a 1 / 5 / 10 / 25 / Max OptionButton, restoring the
## previous selection by id. Returns [row, dropdown].
func _make_qty_row(prev_id: int) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var lbl := Label.new()
	lbl.text = "Qty:"
	lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(lbl)
	var dd := OptionButton.new()
	_fill_qty_options(dd, USE_QTY_OPTIONS)
	dd.add_theme_font_size_override("font_size", 12)
	for opt_idx in range(dd.item_count):
		if dd.get_item_id(opt_idx) == prev_id:
			dd.selected = opt_idx
			break
	## Remember the choice across visits (presents "Use" reads it).
	dd.item_selected.connect(func(_i):
		PlayerData.set_market_pref("qty_inventory", dd.get_selected_id()))
	row.add_child(dd)
	return [row, dd]


## Quantity steps. Use/sell: 1 / 100 / 1000 / 10k / Max. Craft: 1 / 10 / 100 /
## 1000 / 10k / Max. Max = QTY_MAX sentinel.
const USE_QTY_OPTIONS: Array[int] = [1, 100, 1000, 10000]
const CRAFT_QTY_OPTIONS: Array[int] = [1, 10, 100, 1000, 10000]


func _fill_qty_options(dd: OptionButton, steps: Array[int]) -> void:
	for q in steps:
		dd.add_item("10k" if q == 10000 else str(q), q)
	dd.add_item("Max", QTY_MAX)


## Wood -> sticks craft row with its OWN craft quantity picker (1 wood = 2
## sticks). Shares the remembered choice with the Marketplace craft row.
func _make_stick_craft_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = "🪵 → Sticks (1 wood = 2):"
	lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(lbl)
	var dd := OptionButton.new()
	dd.add_theme_font_size_override("font_size", 11)
	_fill_qty_options(dd, CRAFT_QTY_OPTIONS)
	var prev := PlayerData.get_market_pref("qty_craft_sticks", 1)
	for i in range(dd.item_count):
		if dd.get_item_id(i) == prev:
			dd.selected = i
			break
	row.add_child(dd)
	var btn := Button.new()
	btn.add_theme_font_size_override("font_size", 11)
	btn.custom_minimum_size = Vector2(0, 40)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(btn)
	var resolve := func() -> int:
		var wood := PlayerData.get_item_count("wood")
		var sel := dd.get_selected_id()
		return wood if sel == QTY_MAX else mini(sel, wood)
	var update := func():
		var n: int = resolve.call()
		btn.text = "Craft %s → %s sticks" % [
			PlayerData.format_number(n), PlayerData.format_number(n * 2)]
		btn.disabled = n <= 0
	update.call()
	dd.item_selected.connect(func(_i):
		PlayerData.set_market_pref("qty_craft_sticks", dd.get_selected_id())
		update.call())
	btn.pressed.connect(func():
		var n: int = resolve.call()
		if n > 0 and PlayerData.craft_sticks(n) > 0:
			_refresh_display())
	return row


## Resolves the Items-tab quantity selection against `available`: "Max"/QTY_MAX
## and any value above available return all; otherwise the picked amount.
func _items_qty(available: int) -> int:
	var sel := 1
	if _items_qty_dropdown != null and is_instance_valid(_items_qty_dropdown):
		sel = _items_qty_dropdown.get_selected_id()
	if sel == QTY_MAX:
		return available
	return mini(sel, available)


## Sorts `list` in place by SortMode using the given extractors.
## Name A→Z, Value/Owned high→low.
func _apply_sort(list: Array, mode: int, name_fn: Callable, value_fn: Callable, owned_fn: Callable) -> void:
	match mode:
		SortMode.NAME:
			list.sort_custom(func(a, b): return str(name_fn.call(a)) < str(name_fn.call(b)))
		SortMode.VALUE:
			list.sort_custom(func(a, b): return int(value_fn.call(a)) > int(value_fn.call(b)))
		SortMode.OWNED:
			list.sort_custom(func(a, b): return int(owned_fn.call(a)) > int(owned_fn.call(b)))


func enter(params: Dictionary = {}) -> void:
	# Dark semi-transparent backdrop over the game background, matching the
	# Marketplace. Added behind the existing VBox so content stays readable.
	_add_background_panel()

	# Connect buttons
	back_btn.pressed.connect(_on_back_pressed)
	tab_tiles_btn.pressed.connect(_on_tab_tiles)
	tab_seeds_btn.pressed.connect(_on_tab_seeds)
	tab_tools_btn.pressed.connect(_on_tab_tools)
	tab_items_btn.pressed.connect(_on_tab_items)
	tab_gems_btn.pressed.connect(_on_tab_gems)

	# Money Gun + Jewelry (equipment) shortcuts — moved here from the Town menu.
	_build_feature_buttons()

	# Connect to PlayerData for live updates (Req 1.5)
	PlayerData.data_changed.connect(_refresh_display)
	Garden.garden_updated.connect(_refresh_display)

	# Initial display
	_refresh_display()
	_show_tab("tiles")


func exit() -> void:
	# Disconnect signals (Req 1.6)
	if PlayerData.data_changed.is_connected(_refresh_display):
		PlayerData.data_changed.disconnect(_refresh_display)
	if Garden.garden_updated.is_connected(_refresh_display):
		Garden.garden_updated.disconnect(_refresh_display)


func get_screen_name() -> String:
	return "inventory"


## Adds a dark semi-transparent panel behind the inventory content, matching the
## Marketplace's backdrop. Idempotent — reuses the panel if one already exists.
func _add_background_panel() -> void:
	if get_node_or_null("BgPanel") != null:
		return
	var panel := PanelContainer.new()
	panel.name = "BgPanel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE  ## let clicks reach the content
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.08, 0.08, 0.12, 0.88)
	panel_style.corner_radius_top_left = 6
	panel_style.corner_radius_top_right = 6
	panel_style.corner_radius_bottom_left = 6
	panel_style.corner_radius_bottom_right = 6
	panel.add_theme_stylebox_override("panel", panel_style)
	add_child(panel)
	## Render behind the existing VBox content.
	move_child(panel, 0)

	## The shared game theme uses a near-black default Label color, which is
	## unreadable on the dark backdrop. Override the VBox's theme so default
	## labels (title, summary, item names) render in light text. Labels that set
	## their own explicit color (counts, values) are unaffected.
	if vbox != null:
		var light_theme := Theme.new()
		light_theme.set_color("font_color", "Label", Color(0.9, 0.9, 0.85))
		vbox.theme = light_theme


## ── Private: Display ─────────────────────────────────────────────


func _refresh_display() -> void:
	## Tiles are capped (show "x / max"); seeds/saplings are uncapped (count only).
	var seeds_txt: String
	if Garden.has_seed_cap():
		seeds_txt = "%d / %d" % [Garden.get_total_seeds_and_saplings(), Garden.MAX_SEED_STORAGE]
	else:
		seeds_txt = str(Garden.get_total_seeds_and_saplings())
	summary_label.text = "Pho Tiles: %d / %d  |  Seeds/Saplings: %s  |  Coins: %s" % [
		PlayerData.get_inventory_size(), PlayerData.MAX_INVENTORY,
		seeds_txt, PlayerData.format_number(PlayerData.coins)]

	_rebuild_tiles_grid()
	_rebuild_seeds_list()
	_rebuild_tools_list()
	_rebuild_items_list()
	_rebuild_gems_list()


func _show_tab(tab_name: String) -> void:
	tiles_scroll.visible = (tab_name == "tiles")
	seeds_scroll.visible = (tab_name == "seeds")
	tools_scroll.visible = (tab_name == "tools")
	items_scroll.visible = (tab_name == "items")
	gems_scroll.visible = (tab_name == "gems")

	# Highlight active tab
	tab_tiles_btn.modulate = Color(1.0, 0.85, 0.2) if tab_name == "tiles" else Color.WHITE
	tab_seeds_btn.modulate = Color(1.0, 0.85, 0.2) if tab_name == "seeds" else Color.WHITE
	tab_tools_btn.modulate = Color(1.0, 0.85, 0.2) if tab_name == "tools" else Color.WHITE
	tab_items_btn.modulate = Color(1.0, 0.85, 0.2) if tab_name == "items" else Color.WHITE
	tab_gems_btn.modulate = Color(1.0, 0.85, 0.2) if tab_name == "gems" else Color.WHITE


func _rebuild_tiles_grid() -> void:
	var counts: Dictionary = {}
	var all_defs := PieceRegistry.get_all()
	for d in all_defs:
		if d != null and d.display_name != null and d.display_name != "":
			if d.piece_type == Piece.Type.CLAW or d.piece_type == Piece.Type.BITE:
				continue
			counts[d.piece_type] = PlayerData.count_in_inventory(d.piece_type)
	UiPieceGrid.build_grid(inv_grid, counts, -1, Callable(), Vector2(64, 64))


func _rebuild_seeds_list() -> void:
	for child in seeds_grid.get_children():
		child.queue_free()

	## Sort row (Name / Cost / Owned).
	var sort_parts := _make_sort_row("Cost", _sort_mode_seeds, _on_seeds_sort_changed)
	_seeds_sort_dropdown = sort_parts[1]
	seeds_grid.add_child(sort_parts[0])

	## Sorted list of seed indices per the selected mode.
	var seed_indices: Array = []
	for si in range(GardenData.PLANT_DEFS.size()):
		seed_indices.append(si)
	_apply_sort(seed_indices, _sort_mode_seeds,
		func(idx): return str(GardenData.PLANT_DEFS[idx].get("name", "")),
		func(idx): return int(GardenData.PLANT_DEFS[idx].get("seed_cost", 0)),
		func(idx): return Garden.get_seed_count(idx))

	var has_any := false
	for i in seed_indices:
		var count := Garden.get_seed_count(i)
		if count <= 0:
			continue
		has_any = true
		var def: Dictionary = GardenData.PLANT_DEFS[i]

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		# Seed sprite (first frame of the strip)
		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(48, 48)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tex: Texture2D = load(def["sprite"])
		if tex:
			var frame_w: float = tex.get_width() / 4.0
			var atlas := AtlasTexture.new()
			atlas.atlas = tex
			atlas.region = Rect2(0, 0, frame_w, tex.get_height())
			var sprite := TextureRect.new()
			sprite.texture = atlas
			sprite.custom_minimum_size = Vector2(40, 40)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_btn.add_child(sprite)
		row.add_child(icon_btn)

		# Name and count
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = def["name"]
		name_lbl.add_theme_font_size_override("font_size", 14)
		info.add_child(name_lbl)
		var count_lbl := Label.new()
		count_lbl.text = "Owned: %d" % count
		count_lbl.add_theme_font_size_override("font_size", 11)
		info.add_child(count_lbl)
		row.add_child(info)

		seeds_grid.add_child(row)

	if not has_any:
		var empty_lbl := Label.new()
		empty_lbl.text = "No seeds. Buy some at the Marketplace!"
		empty_lbl.add_theme_font_size_override("font_size", 12)
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		seeds_grid.add_child(empty_lbl)


func _rebuild_tools_list() -> void:
	for child in tools_grid.get_children():
		child.queue_free()

	## Sort row (Name / Cost / Owned).
	var sort_parts := _make_sort_row("Cost", _sort_mode_tools, _on_tools_sort_changed)
	_tools_sort_dropdown = sort_parts[1]
	tools_grid.add_child(sort_parts[0])

	var tool_defs: Array = PlayerData.TOOL_DEFS.duplicate()
	_apply_sort(tool_defs, _sort_mode_tools,
		func(d): return str(d.get("name", "")),
		func(d): return int(d.get("price", 0)),
		func(d): return PlayerData.get_tool_count(int(d.get("id", 0))))

	var has_any := false
	for def in tool_defs:
		var tid: int = int(def["id"])
		var owned: int = PlayerData.get_tool_count(tid)
		if owned <= 0:
			continue
		has_any = true

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		# Tool sprite
		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(48, 48)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tex: Texture2D = load(def.get("sprite", ""))
		if tex:
			var sprite := TextureRect.new()
			sprite.texture = tex
			sprite.custom_minimum_size = Vector2(40, 40)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_btn.add_child(sprite)
		row.add_child(icon_btn)

		# Name, description, and count
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = def["name"]
		name_lbl.add_theme_font_size_override("font_size", 14)
		info.add_child(name_lbl)
		var desc_lbl := Label.new()
		desc_lbl.text = def["description"]
		desc_lbl.add_theme_font_size_override("font_size", 11)
		desc_lbl.modulate = Color(0.8, 0.8, 0.8)
		info.add_child(desc_lbl)
		if not bool(def.get("permanent", false)):
			var count_lbl := Label.new()
			count_lbl.text = "Uses remaining: %d" % owned
			count_lbl.add_theme_font_size_override("font_size", 11)
			info.add_child(count_lbl)
		else:
			var perm_lbl := Label.new()
			perm_lbl.text = "✓ Permanent"
			perm_lbl.add_theme_font_size_override("font_size", 11)
			perm_lbl.modulate = Color(0.4, 1.0, 0.4)
			info.add_child(perm_lbl)
		row.add_child(info)

		tools_grid.add_child(row)

	## Deep Mine Excavator — a permanent tool owned via DeepMine (not the tools
	## dict), so it isn't covered by the TOOL_DEFS loop above. Show it as owned.
	if get_node_or_null("/root/DeepMine") != null and DeepMine.has_excavator():
		has_any = true
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(48, 48)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tex := DeepMine.get_excavator_texture()
		if tex:
			var sprite := TextureRect.new()
			sprite.texture = tex
			sprite.custom_minimum_size = Vector2(40, 40)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_btn.add_child(sprite)
		row.add_child(icon_btn)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = "Excavator"
		name_lbl.add_theme_font_size_override("font_size", 14)
		info.add_child(name_lbl)
		var desc_lbl := Label.new()
		desc_lbl.text = "Deep Mine: dig a full row without shovels (%d row%s per use)." % [
			DeepMine.get_excavator_rows(), "s" if DeepMine.get_excavator_rows() > 1 else ""]
		desc_lbl.add_theme_font_size_override("font_size", 11)
		desc_lbl.modulate = Color(0.8, 0.8, 0.8)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_child(desc_lbl)
		var perm_lbl := Label.new()
		perm_lbl.text = "✓ Permanent"
		perm_lbl.add_theme_font_size_override("font_size", 11)
		perm_lbl.modulate = Color(0.4, 1.0, 0.4)
		info.add_child(perm_lbl)
		row.add_child(info)

		tools_grid.add_child(row)

	if not has_any:
		var empty_lbl := Label.new()
		empty_lbl.text = "No tools. Buy some at the Marketplace!"
		empty_lbl.add_theme_font_size_override("font_size", 12)
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tools_grid.add_child(empty_lbl)


func _rebuild_items_list() -> void:
	for child in items_grid.get_children():
		child.queue_free()

	## Quantity selector (used by the Wood → Sticks Craft action). Preserve the
	## prior selection across rebuilds.
	var prev_qty_id := PlayerData.get_market_pref("qty_inventory", 1)
	var qty_parts := _make_qty_row(prev_qty_id)
	_items_qty_dropdown = qty_parts[1]
	items_grid.add_child(qty_parts[0])

	## Sort row (Name / Value / Owned), applied within each category below.
	var sort_parts := _make_sort_row("Value", _sort_mode_items, _on_items_sort_changed)
	_items_sort_dropdown = sort_parts[1]
	items_grid.add_child(sort_parts[0])

	## Render categories in a fixed order, each with a header shown only when the
	## category has owned items. Sorting applies WITHIN each category. Matches the
	## Marketplace Items tab for consistency.
	var has_any := false
	if _render_crops_section():
		has_any = true
	if _render_fruit_section():
		has_any = true
	if _render_resources_section():
		has_any = true
	if _render_presents_section():
		has_any = true
	## Jewelry (incl. Diamond Rings) now lives on the Jewelry screen (💍 button),
	## where it can be equipped and sold.
	if _render_recipes_section():
		has_any = true
	if _render_wonder_section():
		has_any = true

	if not has_any:
		var empty_lbl := Label.new()
		empty_lbl.text = "No special items owned"
		empty_lbl.add_theme_font_size_override("font_size", 12)
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		items_grid.add_child(empty_lbl)

	## Keep the tab inside the screen width (see _fit_labels_to_width).
	_fit_labels_to_width(items_grid)


## The Items tab lives in a ScrollContainer with horizontal scrolling disabled,
## so a single row wider than the viewport stretches the whole tab and it gets
## cut off on both sides. Long one-line labels (item names, "Owned | Total
## Value" lines) were the cause. Make every non-wrapping label wrap instead so
## rows shrink to the screen width.
func _fit_labels_to_width(node: Node) -> void:
	for child in node.get_children():
		## Only labels stacked in a VBox (item info columns, section headers) get
		## the column's full width to wrap into. Labels sitting directly in an
		## HBox row ("Qty:", "Sort:") are short and would collapse if wrapped.
		if child is Label and node is VBoxContainer:
			var lbl := child as Label
			if lbl.autowrap_mode == TextServer.AUTOWRAP_OFF:
				lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_fit_labels_to_width(child)


## ── Items tab: category renderers (mirror the Marketplace) ──────
## Each returns true if it rendered at least one row. Header shown only when non-empty.


## Enhancement items (currently the Diamond Ring). Returns true if any shown.
## Wearable jewelry the player owns (rings/necklaces/misc — includes the Diamond
## Ring). Excludes horseshoes (slot "horse") and food recipes. View-only here —
## sell at the Marketplace, equip from the Jewelry screen. Returns true if any.
func _render_jewelry_section() -> bool:
	var rendered := false
	for jid in PlayerData.jewelry_ids():
		var def := PlayerData.get_jewelry_def(jid)
		if str(def.get("slot", "")) == "horse":
			continue
		var count := PlayerData.get_jewelry_count(jid)
		if count <= 0:
			continue
		if not rendered:
			_add_category_header(items_grid, "Jewelry")
			rendered = true

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(48, 48)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tex: Texture2D = load(str(def.get("sprite", "")))
		if tex:
			var sprite := TextureRect.new()
			sprite.texture = tex
			sprite.custom_minimum_size = Vector2(40, 40)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_btn.add_child(sprite)
		row.add_child(icon_btn)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = str(def.get("name", jid))
		name_lbl.add_theme_font_size_override("font_size", 14)
		info.add_child(name_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = str(def.get("description", ""))
		desc_lbl.add_theme_font_size_override("font_size", 11)
		desc_lbl.modulate = Color(0.8, 0.8, 0.8)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_child(desc_lbl)

		var count_lbl := Label.new()
		count_lbl.text = "Owned: %d  |  Sell: %s each" % [
			count, PlayerData.format_coins(PlayerData.get_jewelry_sell_value(jid))]
		count_lbl.add_theme_font_size_override("font_size", 11)
		count_lbl.modulate = Color(1.0, 0.9, 0.5)
		info.add_child(count_lbl)

		## If this jewelry is currently equipped, show an indicator.
		if PlayerData.equipped_jewelry().values().has(jid):
			var eq_lbl := Label.new()
			eq_lbl.text = "✓ Equipped"
			eq_lbl.add_theme_font_size_override("font_size", 11)
			eq_lbl.modulate = Color(0.4, 1.0, 0.5)
			info.add_child(eq_lbl)

		row.add_child(info)
		items_grid.add_child(row)
	return rendered


## Orchard fruit, sorted by the selected mode. Returns true if any shown.
func _render_fruit_section() -> bool:
	var fruit_defs: Array = []
	for fi in range(1, PlayerData.ITEM_DEFS.size()):
		fruit_defs.append(PlayerData.ITEM_DEFS[fi])
	_apply_sort(fruit_defs, _sort_mode_items,
		func(d): return str(d.get("name", "")),
		func(d): return PlayerData.get_fruit_sell_value(str(d.get("id", ""))),
		func(d): return PlayerData.get_fruit_count(str(d.get("id", ""))))
	var rendered := false
	for f_def in fruit_defs:
		var f_id: String = f_def["id"]
		var count: int = PlayerData.get_fruit_count(f_id)
		if count > 0:
			if not rendered:
				_add_category_header(items_grid, "Fruit")
				rendered = true
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 10)

			var icon_btn := Button.new()
			icon_btn.custom_minimum_size = Vector2(48, 48)
			icon_btn.focus_mode = Control.FOCUS_NONE
			icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var fruit_idx: int = f_def.get("fruit_index", 0)
			if get_node_or_null("/root/Orchard") != null:
				var atlas = get_node("/root/Orchard").get_fruit_texture(fruit_idx)
				if atlas:
					var sprite := TextureRect.new()
					sprite.texture = atlas
					sprite.custom_minimum_size = Vector2(36, 36)
					sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
					sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
					sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
					sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
					icon_btn.add_child(sprite)
			row.add_child(icon_btn)

			var info := VBoxContainer.new()
			info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var name_lbl := Label.new()
			name_lbl.text = f_def["name"]
			name_lbl.add_theme_font_size_override("font_size", 14)
			info.add_child(name_lbl)

			## Per-fruit value (prestige + Business District bonus), matching Marketplace.
			var unit_value := PlayerData.get_fruit_sell_value(f_id)
			var desc_lbl := Label.new()
			desc_lbl.text = "%s  (Sell: %s each)" % [f_def["description"], PlayerData.format_coins(unit_value)]
			desc_lbl.add_theme_font_size_override("font_size", 11)
			desc_lbl.modulate = Color(0.8, 0.8, 0.8)
			info.add_child(desc_lbl)

			var count_lbl := Label.new()
			count_lbl.text = "Owned: %d  |  Total Value: %s" % [count, PlayerData.format_coins(count * unit_value)]
			count_lbl.add_theme_font_size_override("font_size", 11)
			count_lbl.modulate = Color(1.0, 0.9, 0.5)
			info.add_child(count_lbl)

			row.add_child(info)
			items_grid.add_child(row)
	return rendered


## Resource items (wood, sticks, ores, bars, ingots). Returns true if any shown.
func _render_resources_section() -> bool:
	var resource_defs: Array = PlayerData.RESOURCE_DEFS.duplicate()
	_apply_sort(resource_defs, _sort_mode_items,
		func(d): return str(d.get("name", "")),
		func(d): return PlayerData.get_resource_sell_value(str(d.get("id", ""))),
		func(d): return PlayerData.get_item_count(str(d.get("id", ""))))
	var rendered := false
	for r_def in resource_defs:
		var r_id: String = r_def["id"]
		var r_count: int = PlayerData.get_item_count(r_id)
		if r_count <= 0:
			continue
		if not rendered:
			_add_category_header(items_grid, "Ores & Ingots")
			rendered = true
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(48, 48)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ore_tex := OreSprites.get_item_texture(str(r_def.get("ore_sprite", r_id)))
		if ore_tex:
			var sprite := TextureRect.new()
			sprite.texture = ore_tex
			sprite.custom_minimum_size = Vector2(40, 40)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_btn.add_child(sprite)
		row.add_child(icon_btn)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = r_def["name"]
		name_lbl.add_theme_font_size_override("font_size", 14)
		info.add_child(name_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = r_def.get("description", "")
		desc_lbl.add_theme_font_size_override("font_size", 11)
		desc_lbl.modulate = Color(0.8, 0.8, 0.8)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_child(desc_lbl)

		## Show the effective (prestige-scaled) per-unit value and total.
		var unit_value := PlayerData.get_resource_sell_value(r_id)
		var count_lbl := Label.new()
		count_lbl.text = "Owned: %d  |  Total Value: %s" % [r_count, PlayerData.format_coins(r_count * unit_value)]
		count_lbl.add_theme_font_size_override("font_size", 11)
		count_lbl.modulate = Color(1.0, 0.9, 0.5)
		info.add_child(count_lbl)

		row.add_child(info)

		items_grid.add_child(row)
		## Wood can be crafted into sticks right here, with its own qty picker.
		if r_id == "wood":
			items_grid.add_child(_make_stick_craft_row())
	return rendered


## Crafts sticks from wood based on the selected quantity (1 wood -> 2 sticks
## each; "Max" uses all wood), then refreshes the inventory display.
func _on_craft_sticks() -> void:
	var wood := PlayerData.get_item_count("wood")
	if wood <= 0:
		return
	var qty := _items_qty(wood)
	if qty > 0 and PlayerData.craft_sticks(qty) > 0:
		_refresh_display()


## Presents (Christmas Conifer output). Only owned variants are shown. Each has a
## "Use" button that opens N presents (via the Qty selector), granting a random
## item per present. Returns true if any shown.
func _render_presents_section() -> bool:
	var rendered := false
	for v in range(PlayerData.PRESENT_COUNT):
		var count: int = PlayerData.get_present_count(v)
		if count <= 0:
			continue
		if not rendered:
			_add_category_header(items_grid, "Presents")
			rendered = true
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(48, 48)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tex := PlayerData.get_present_texture(v)
		if tex:
			var sprite := TextureRect.new()
			sprite.texture = tex
			sprite.custom_minimum_size = Vector2(40, 40)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_btn.add_child(sprite)
		row.add_child(icon_btn)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = "Present"
		name_lbl.add_theme_font_size_override("font_size", 14)
		info.add_child(name_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = "Use to open for a random item, or sell for %s each." % \
			PlayerData.format_coins(PlayerData.get_present_sell_value())
		desc_lbl.add_theme_font_size_override("font_size", 11)
		desc_lbl.modulate = Color(0.8, 0.8, 0.8)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_child(desc_lbl)

		var count_lbl := Label.new()
		count_lbl.text = "Owned: %d  |  Total Value: %s" % [
			count, PlayerData.format_coins(count * PlayerData.get_present_sell_value())]
		count_lbl.add_theme_font_size_override("font_size", 11)
		count_lbl.modulate = Color(1.0, 0.9, 0.5)
		info.add_child(count_lbl)
		row.add_child(info)

		## Use button — opens N presents per the Qty selector.
		var use_btn := Button.new()
		use_btn.text = "Use"
		use_btn.add_theme_font_size_override("font_size", 11)
		use_btn.custom_minimum_size = Vector2(64, 48)
		use_btn.pressed.connect(_on_use_present.bind(v))
		row.add_child(use_btn)

		items_grid.add_child(row)
	return rendered


## Opens the selected quantity of a present variant (Qty selector; "Max" opens
## all owned), granting a random item per present, then refreshes + toasts.
func _on_use_present(variant: int) -> void:
	var owned := PlayerData.get_present_count(variant)
	if owned <= 0:
		return
	var qty := _items_qty(owned)
	if qty <= 0:
		return

	## ONE uniform drop pool: every tradeable item key PLUS one entry per horse
	## breed ("horse:<breed>"). Every entry has equal 1-in-N odds (Task 11d).
	var pool: Array = []
	for k in ItemKeyRegistry.all_keys():
		if ItemKeyRegistry.is_tradeable(k) and not PlayerData.is_present_id(ItemKeyRegistry.id_of(k)):
			pool.append(k)
	if get_node_or_null("/root/HorseRacing") != null:
		pool.append_array(HorseRacing.present_horse_pool_keys())
	if pool.is_empty():
		return

	var granted: Dictionary = {}     ## item_key -> count (items)
	var horse_lines: Array = []      ## granted-horse summary lines
	var used := 0

	for _i in range(qty):
		if PlayerData.get_present_count(variant) <= 0:
			break
		var key: String = str(pool[randi() % pool.size()])
		if key.begins_with("horse:"):
			## Horse drop (server-side, room-gated). Consume the present first so
			## the roll can't be reused; if the stable is full, re-roll an ITEM so
			## the present still pays out (never wasted).
			_consume_one_present(variant)
			used += 1
			var breed := key.substr("horse:".length())
			var hr: Dictionary = await HorseRacing.grant_horse(breed)
			if bool(hr.get("ok", false)):
				var hname := str((hr.get("horse", {}) as Dictionary).get("name", "a horse"))
				horse_lines.append("🐎 %s (%s)" % [hname, breed.capitalize()])
			else:
				## Stable full / offline — fall back to a random ITEM key.
				var item_keys := pool.filter(func(k): return not str(k).begins_with("horse:"))
				if not item_keys.is_empty():
					var ikey: String = str(item_keys[randi() % item_keys.size()])
					if PlayerData.market_add_owned(ikey, 1):
						granted[ikey] = int(granted.get(ikey, 0)) + 1
		else:
			## Normal item — consume one present + grant.
			_consume_one_present(variant)
			used += 1
			if PlayerData.market_add_owned(key, 1):
				granted[key] = int(granted.get(key, 0)) + 1

	if used <= 0:
		return

	if get_node_or_null("/root/GameNotification") != null:
		var lines: Array = []
		lines.append_array(horse_lines)
		for key in granted:
			lines.append("%d× %s" % [int(granted[key]), ItemKeyRegistry.display_name(key)])
		var body := ", ".join(lines) if not lines.is_empty() else "Some items!"
		GameNotification.show_message(
			"Opened %d present%s" % [used, "s" if used > 1 else ""], body)
	_refresh_display()


## Consumes exactly one present of a variant. Mirrors the consume step in
## PlayerData.use_present without granting an item (we grant per-pick here).
func _consume_one_present(variant: int) -> void:
	var pid := PlayerData.present_id(variant)
	var have := int(PlayerData.fruits.get(pid, 0))
	if have <= 0:
		return
	PlayerData.fruits[pid] = have - 1
	if PlayerData.fruits[pid] <= 0:
		PlayerData.fruits.erase(pid)
	PlayerData.save_data()
	PlayerData.data_changed.emit()


## Harvested crops (garden output). View-only here — sell at the Marketplace.
func _render_crops_section() -> bool:
	var crop_defs: Array = PlayerData.CROP_DEFS.duplicate()
	_apply_sort(crop_defs, _sort_mode_items,
		func(d): return str(d.get("name", "")),
		func(d): return PlayerData.get_crop_sell_value(str(d.get("id", ""))),
		func(d): return PlayerData.get_crop_count(str(d.get("id", ""))))
	var rendered := false
	for c_def in crop_defs:
		var c_id: String = c_def["id"]
		var c_count: int = PlayerData.get_crop_count(c_id)
		if c_count <= 0:
			continue
		if not rendered:
			_add_category_header(items_grid, "Crops")
			rendered = true
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(48, 48)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var crop_tex: Texture2D = load(c_def["sprite"])
		if crop_tex:
			var sprite := TextureRect.new()
			sprite.texture = crop_tex
			sprite.custom_minimum_size = Vector2(40, 40)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_btn.add_child(sprite)
		row.add_child(icon_btn)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = c_def["name"]
		name_lbl.add_theme_font_size_override("font_size", 14)
		info.add_child(name_lbl)

		## Show the effective (prestige-scaled) per-crop sell value and total.
		var unit_value := PlayerData.get_crop_sell_value(c_id)
		var count_lbl := Label.new()
		count_lbl.text = "Owned: %d  |  Total Value: %s" % [c_count, PlayerData.format_coins(c_count * unit_value)]
		count_lbl.add_theme_font_size_override("font_size", 11)
		count_lbl.modulate = Color(1.0, 0.9, 0.5)
		info.add_child(count_lbl)

		row.add_child(info)
		items_grid.add_child(row)
	return rendered


## Food recipes (gardening-guild crafted). Each owned recipe shows its boost +
## a "Use" button that activates the timed/counted boost. Returns true if any
## rendered.
func _render_recipes_section() -> bool:
	var rendered := false
	for rid in PlayerData.recipe_ids():
		var count := PlayerData.get_recipe_count(rid)
		if count <= 0:
			continue
		if not rendered:
			_add_category_header(items_grid, "Food Recipes")
			rendered = true
		var def := PlayerData.get_recipe_def(rid)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(48, 48)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tex: Texture2D = load(str(def.get("sprite", "")))
		if tex:
			var sprite := TextureRect.new()
			sprite.texture = tex
			sprite.custom_minimum_size = Vector2(40, 40)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_btn.add_child(sprite)
		row.add_child(icon_btn)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = str(def.get("name", rid))
		name_lbl.add_theme_font_size_override("font_size", 14)
		info.add_child(name_lbl)
		var desc_lbl := Label.new()
		desc_lbl.text = str(def.get("description", ""))
		desc_lbl.add_theme_font_size_override("font_size", 11)
		desc_lbl.modulate = Color(0.8, 0.8, 0.8)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_child(desc_lbl)
		var count_lbl := Label.new()
		count_lbl.text = "Owned: %d" % count
		count_lbl.add_theme_font_size_override("font_size", 11)
		count_lbl.modulate = Color(1.0, 0.9, 0.5)
		info.add_child(count_lbl)
		var effect := str((def.get("boost", {}) as Dictionary).get("effect", ""))
		if effect != "" and PlayerData.boost_active(effect):
			var active_lbl := Label.new()
			active_lbl.text = "⚡ Boost active"
			active_lbl.add_theme_font_size_override("font_size", 11)
			active_lbl.modulate = Color(0.4, 1.0, 0.5)
			info.add_child(active_lbl)
		row.add_child(info)

		var use_btn := Button.new()
		use_btn.text = "Use"
		use_btn.add_theme_font_size_override("font_size", 11)
		use_btn.custom_minimum_size = Vector2(64, 48)
		use_btn.pressed.connect(_on_use_recipe.bind(rid))
		row.add_child(use_btn)

		items_grid.add_child(row)
	return rendered


## Activates ONE recipe's boost, toasts the result, and refreshes.
func _on_use_recipe(rid: String) -> void:
	## Checked: Trader's Tongue activates on the server first (needs internet).
	var res: Dictionary = await PlayerData.use_recipe_checked(rid, 1)
	if int(res.get("used", 0)) <= 0:
		if res.has("error"):
			_toast("Recipe not used", str(res["error"]))
		return
	_toast("Boost activated", str(res.get("name", "Recipe")))
	if is_inside_tree():
		_refresh_display()


## ── Items tab: WonderStone + WonderVessels ──────────────────────
## Renders the rare-material row (WonderStone), the owned WonderVessel tiers
## (each with a "Use" button), and a craft row (tier dropdown filtered to
## affordable tiers + qty SpinBox + Craft button). Returns true if anything was
## shown (the craft row is always shown when the player owns ≥1 WonderStone).


func _render_wonder_section() -> bool:
	var ws_count := PlayerData.get_wonderstone_count()
	var owned_vessels: Array = []
	for tier in range(1, PlayerData.WONDERVESSEL_DEFS.size() + 1):
		if PlayerData.get_vessel_count(tier) > 0:
			owned_vessels.append(tier)
	## Can the player afford to craft ANY tier right now?
	var any_affordable := false
	for tier in range(1, PlayerData.WONDERVESSEL_DEFS.size() + 1):
		if PlayerData.can_craft_vessel(tier, 1):
			any_affordable = true
			break

	## Nothing to show unless the player owns a stone, owns a vessel, or can craft.
	if ws_count <= 0 and owned_vessels.is_empty() and not any_affordable:
		return false

	_add_category_header(items_grid, "WonderStones & WonderVessels")

	## WonderStone row (view-only — sold at the Marketplace).
	if ws_count > 0:
		var ws_row := HBoxContainer.new()
		ws_row.add_theme_constant_override("separation", 10)

		var ws_icon := Button.new()
		ws_icon.custom_minimum_size = Vector2(48, 48)
		ws_icon.focus_mode = Control.FOCUS_NONE
		ws_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ws_tex := ItemKeyRegistry.get_texture(ItemKeyRegistry.material_key("wonderstone"))
		if ws_tex:
			var sprite := TextureRect.new()
			sprite.texture = ws_tex
			sprite.custom_minimum_size = Vector2(40, 40)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			ws_icon.add_child(sprite)
		ws_row.add_child(ws_icon)

		var ws_info := VBoxContainer.new()
		ws_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var ws_name := Label.new()
		ws_name.text = "WonderStone"
		ws_name.add_theme_font_size_override("font_size", 14)
		ws_info.add_child(ws_name)
		var ws_desc := Label.new()
		ws_desc.text = "A rare material used to craft WonderVessels."
		ws_desc.add_theme_font_size_override("font_size", 11)
		ws_desc.modulate = Color(0.8, 0.8, 0.8)
		ws_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		ws_info.add_child(ws_desc)
		var ws_cl := Label.new()
		ws_cl.text = "Owned: %d  |  Value: %s each" % [
			ws_count, PlayerData.format_coins(PlayerData.WONDERSTONE_COIN_VALUE)]
		ws_cl.add_theme_font_size_override("font_size", 11)
		ws_cl.modulate = Color(1.0, 0.9, 0.5)
		ws_info.add_child(ws_cl)
		ws_row.add_child(ws_info)
		items_grid.add_child(ws_row)

	## Owned vessel rows, each with a "Use" button.
	for tier in owned_vessels:
		items_grid.add_child(_make_vessel_row(tier))

	## Craft row — tier dropdown (affordable only) + qty SpinBox + Craft button.
	items_grid.add_child(_make_vessel_craft_row())
	return true


## Builds one owned-WonderVessel row (icon, name/desc, owned count, Use button).
func _make_vessel_row(tier: int) -> Control:
	var def := PlayerData.get_vessel_def(tier)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var icon_btn := Button.new()
	icon_btn.custom_minimum_size = Vector2(48, 48)
	icon_btn.focus_mode = Control.FOCUS_NONE
	icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tex := ItemKeyRegistry.get_texture(ItemKeyRegistry.vessel_key(tier))
	if tex:
		var sprite := TextureRect.new()
		sprite.texture = tex
		sprite.custom_minimum_size = Vector2(40, 40)
		sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
		sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon_btn.add_child(sprite)
	row.add_child(icon_btn)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_lbl := Label.new()
	name_lbl.text = "WonderVessel (Tier %d)" % tier
	name_lbl.add_theme_font_size_override("font_size", 14)
	info.add_child(name_lbl)
	var desc_lbl := Label.new()
	desc_lbl.text = _vessel_effect_text(def)
	desc_lbl.add_theme_font_size_override("font_size", 11)
	desc_lbl.modulate = Color(0.8, 0.8, 0.8)
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_child(desc_lbl)
	var count_lbl := Label.new()
	count_lbl.text = "Owned: %d" % PlayerData.get_vessel_count(tier)
	count_lbl.add_theme_font_size_override("font_size", 11)
	count_lbl.modulate = Color(1.0, 0.9, 0.5)
	info.add_child(count_lbl)
	row.add_child(info)

	var use_btn := Button.new()
	use_btn.text = "Use"
	use_btn.add_theme_font_size_override("font_size", 11)
	use_btn.custom_minimum_size = Vector2(64, 48)
	use_btn.pressed.connect(_open_vessel_use_dialog.bind(tier))
	row.add_child(use_btn)
	return row


## Human-readable summary of a vessel tier's duplication effect.
func _vessel_effect_text(def: Dictionary) -> String:
	if def.is_empty():
		return ""
	var types := int(def["types"])
	var cap := int(def["cap"])
	var mode := str(def["mode"])
	var n := int(def["n"])
	var out_txt: String
	if mode == "mult":
		var factor := n + 1  ## output = input*n + input
		out_txt = "×%d output" % factor
	else:
		out_txt = "+%d per item" % n
	var types_txt := "%d item type%s" % [types, "s" if types > 1 else ""]
	return "Duplicate %s (up to %s each), %s. Single use." % [
		types_txt, PlayerData.format_number(cap), out_txt]


## Builds the "Craft a WonderVessel" row: a tier dropdown showing only tiers the
## player can currently afford, a qty SpinBox, and a Craft button.
func _make_vessel_craft_row() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var title := Label.new()
	title.text = "⚗️ Craft a WonderVessel"
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color(0.8, 0.95, 1.0))
	box.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var tier_dd := OptionButton.new()
	tier_dd.add_theme_font_size_override("font_size", 12)
	var affordable_count := 0
	for tier in range(1, PlayerData.WONDERVESSEL_DEFS.size() + 1):
		if PlayerData.can_craft_vessel(tier, 1):
			tier_dd.add_item("Tier %d" % tier, tier)
			affordable_count += 1
	if affordable_count == 0:
		tier_dd.add_item("— none affordable —", 0)
		tier_dd.disabled = true
	row.add_child(tier_dd)

	var qty_spin := SpinBox.new()
	qty_spin.min_value = 1
	qty_spin.max_value = 999
	qty_spin.value = 1
	qty_spin.custom_minimum_size = Vector2(72, 0)
	row.add_child(qty_spin)

	var craft_btn := Button.new()
	craft_btn.text = "Craft"
	craft_btn.add_theme_font_size_override("font_size", 12)
	craft_btn.disabled = (affordable_count == 0)
	craft_btn.pressed.connect(_on_craft_vessel.bind(tier_dd, qty_spin))
	row.add_child(craft_btn)

	box.add_child(row)

	## Cost preview for the currently selected tier.
	var cost_lbl := Label.new()
	cost_lbl.add_theme_font_size_override("font_size", 10)
	cost_lbl.modulate = Color(0.75, 0.75, 0.75)
	cost_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cost_lbl.text = _vessel_cost_text(tier_dd.get_selected_id())
	box.add_child(cost_lbl)
	tier_dd.item_selected.connect(func(_i):
		cost_lbl.text = _vessel_cost_text(tier_dd.get_selected_id()))

	## "Next tier" hint — tells the player exactly what they still need for the
	## lowest tier they can't yet afford.
	var hint_lbl := Label.new()
	hint_lbl.add_theme_font_size_override("font_size", 10)
	hint_lbl.modulate = Color(1.0, 0.8, 0.5)
	hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_lbl.text = _vessel_next_tier_hint()
	box.add_child(hint_lbl)
	return box


## Builds the "what you still need for the next tier" hint. Returns "" when the
## player can already afford every tier.
func _vessel_next_tier_hint() -> String:
	var tier := PlayerData.next_unaffordable_vessel_tier()
	if tier <= 0:
		return "✓ You have the materials for every WonderVessel tier."
	var missing: Array = PlayerData.vessel_missing_for_tier(tier)
	if missing.is_empty():
		return ""
	## Summarize the biggest/most relevant shortfalls (coins + WonderStones are
	## always most important; then show a few resource gaps).
	var parts: Array = []
	## Prioritise coins + wonderstone first if short.
	for want_key in ["coins", "wonderstone"]:
		for m in missing:
			if m["key"] == want_key:
				parts.append("%s %s more" % [
					PlayerData.format_number(int(m["short"])), str(m["label"])])
	## Then up to 4 resource shortfalls so the hint stays readable.
	var res_shown := 0
	for m in missing:
		if m["key"] == "coins" or m["key"] == "wonderstone":
			continue
		if res_shown >= 4:
			break
		parts.append("%s %s" % [PlayerData.format_number(int(m["short"])), str(m["label"])])
		res_shown += 1
	var more := missing.size() - parts.size()
	var extra := ("  (+%d more item%s)" % [more, "s" if more != 1 else ""]) if more > 0 else ""
	return "To unlock Tier %d you still need: %s%s" % [tier, ", ".join(parts), extra]


## Short cost summary for a tier's craft inputs (coins + WonderStones + "all raw
## resources"). Returns "" for the no-tier sentinel.
func _vessel_cost_text(tier: int) -> String:
	if tier <= 0:
		return ""
	var cost := PlayerData.vessel_resource_cost(tier)
	if cost.is_empty():
		return ""
	var coins := int(cost.get("coins", 0))
	var ws := int(cost.get("wonderstone", 0))
	return "Cost: %s coins + %s WonderStones + %s of every raw resource (+1 of each bar/ingot)." % [
		PlayerData.format_number(coins), PlayerData.format_number(ws),
		PlayerData.format_number(ws)]


## Crafts the selected tier × qty, toasts the result, and refreshes.
func _on_craft_vessel(tier_dd: OptionButton, qty_spin: SpinBox) -> void:
	var tier := tier_dd.get_selected_id()
	if tier <= 0:
		return
	var qty := int(qty_spin.value)
	if qty <= 0:
		return
	if not PlayerData.can_craft_vessel(tier, qty):
		_toast("Not enough materials", "You can't afford %d × Tier %d right now." % [qty, tier])
		return
	if PlayerData.craft_vessel(tier, qty):
		_toast("Crafted", "%d × WonderVessel (Tier %d)." % [qty, tier])
		_refresh_display()


## Opens a dialog to load items into a WonderVessel of `tier`. Shows up to
## `types` rows, each an item dropdown + qty SpinBox (max = min(cap, owned)),
## then calls PlayerData.use_vessel with the chosen adds.
func _open_vessel_use_dialog(tier: int) -> void:
	var def := PlayerData.get_vessel_def(tier)
	if def.is_empty() or PlayerData.get_vessel_count(tier) <= 0:
		return
	var max_types := int(def["types"])
	var cap := int(def["cap"])

	## Build the pool of owned, vessel-eligible item keys.
	var owned_keys: Array = []
	for k in ItemKeyRegistry.all_keys():
		if PlayerData.vessel_key_allowed(k) and PlayerData.market_count_owned(k) > 0:
			owned_keys.append(k)
	owned_keys.sort_custom(func(a, b):
		return ItemKeyRegistry.display_name(a) < ItemKeyRegistry.display_name(b))

	var vp := get_viewport().get_visible_rect().size
	var modal := _make_modal_overlay("Use WonderVessel (Tier %d)" % tier, mini(380, int(vp.x * 0.94)))
	var overlay: Control = modal["overlay"]
	var body: VBoxContainer = modal["body"]

	var info := Label.new()
	info.text = "Pick up to %d item type%s, up to %s each. Originals are kept." % [
		max_types, "s" if max_types > 1 else "", PlayerData.format_number(cap)]
	info.add_theme_font_size_override("font_size", 11)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(info)

	## Slot rows. `rows` entries: { key: String, btn: Button, spin: SpinBox }.
	var rows: Array = []

	if owned_keys.is_empty():
		var empty := Label.new()
		empty.text = "You own no items that can go in a WonderVessel."
		empty.add_theme_font_size_override("font_size", 12)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_child(empty)
	else:
		## Slots live in a height-capped scroll so a Tier 10 vessel's 10 slots
		## can't push the buttons below off-screen.
		var rows_scroll := ScrollContainer.new()
		rows_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		rows_scroll.scroll_deadzone = 16
		rows_scroll.custom_minimum_size = Vector2(0, mini(max_types * 46 + 4, int(vp.y * 0.45)))
		var rows_box := VBoxContainer.new()
		rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rows_box.add_theme_constant_override("separation", 4)
		rows_scroll.add_child(rows_box)
		body.add_child(rows_scroll)

		for _slot in range(max_types):
			var r := HBoxContainer.new()
			r.add_theme_constant_override("separation", 6)
			var pick_btn := Button.new()
			pick_btn.text = "Tap to choose an item…"
			pick_btn.add_theme_font_size_override("font_size", 12)
			pick_btn.custom_minimum_size = Vector2(0, 40)
			pick_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			pick_btn.clip_text = true
			pick_btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			r.add_child(pick_btn)
			var spin := SpinBox.new()
			spin.min_value = 1
			spin.max_value = cap
			spin.value = 1
			spin.custom_minimum_size = Vector2(84, 0)
			spin.editable = (cap > 1)
			r.add_child(spin)
			rows_box.add_child(r)
			var row_state := {"key": "", "btn": pick_btn, "spin": spin}
			rows.append(row_state)
			pick_btn.pressed.connect(func():
				_open_item_pick_overlay(owned_keys, func(key: String):
					row_state["key"] = key
					if key == "":
						pick_btn.text = "Tap to choose an item…"
						spin.max_value = cap
						return
					var owned := PlayerData.market_count_owned(key)
					pick_btn.text = "%s (%d)" % [ItemKeyRegistry.display_name(key), owned]
					spin.max_value = maxi(1, mini(cap, owned))
					if spin.value > spin.max_value:
						spin.value = spin.max_value))

	## Action buttons live INSIDE the panel, so they can never be pushed off-screen.
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(0, 44)
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(overlay.queue_free)
	btn_row.add_child(cancel_btn)
	var go_btn := Button.new()
	go_btn.text = "Duplicate"
	go_btn.custom_minimum_size = Vector2(0, 44)
	go_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	go_btn.disabled = owned_keys.is_empty()
	go_btn.pressed.connect(func():
		if _apply_vessel_use(tier, rows):
			overlay.queue_free())
	btn_row.add_child(go_btn)
	body.add_child(btn_row)


## Builds a dimmed full-screen overlay with a centered titled panel and returns
## { overlay: Control, body: VBoxContainer }. Added to this screen immediately.
## Replaces AcceptDialog, whose button row got pushed off-screen on phones.
func _make_modal_overlay(title_text: String, width: int) -> Dictionary:
	var overlay := Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP  ## block clicks to the screen below
	overlay.z_index = 100
	add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(width, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.13, 0.18, 0.98)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	panel.add_child(body)

	var title_lbl := Label.new()
	title_lbl.text = title_text
	title_lbl.add_theme_font_size_override("font_size", 15)
	title_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(title_lbl)
	return {"overlay": overlay, "body": body}


## Opens a scrollable list of `keys` (name + owned count). Tapping a row calls
## `on_pick(key)` and closes; "None" calls on_pick(""); Close just dismisses.
func _open_item_pick_overlay(keys: Array, on_pick: Callable) -> void:
	var vp := get_viewport().get_visible_rect().size
	var modal := _make_modal_overlay("Choose an item", mini(360, int(vp.x * 0.92)))
	var overlay: Control = modal["overlay"]
	var body: VBoxContainer = modal["body"]

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.scroll_deadzone = 16  ## drag over the buttons to scroll on touch
	scroll.custom_minimum_size = Vector2(0, int(vp.y * 0.55))
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	scroll.add_child(list)
	body.add_child(scroll)

	var none_btn := Button.new()
	none_btn.text = "— none —"
	none_btn.custom_minimum_size = Vector2(0, 40)
	none_btn.add_theme_font_size_override("font_size", 12)
	none_btn.pressed.connect(func():
		on_pick.call("")
		overlay.queue_free())
	list.add_child(none_btn)

	for key in keys:
		var b := Button.new()
		b.text = "%s (%d)" % [ItemKeyRegistry.display_name(key), PlayerData.market_count_owned(key)]
		b.custom_minimum_size = Vector2(0, 40)
		b.add_theme_font_size_override("font_size", 12)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func():
			on_pick.call(key)
			overlay.queue_free())
		list.add_child(b)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(0, 44)
	close_btn.pressed.connect(overlay.queue_free)
	body.add_child(close_btn)


## Gathers the slot selections into an `adds` dict and calls use_vessel. Toasts
## the granted items (or an error) and refreshes the display. Returns true when
## the vessel was used (so the caller can close the overlay).
func _apply_vessel_use(tier: int, rows: Array) -> bool:
	var adds: Dictionary = {}
	for r in rows:
		var key: String = str(r["key"])
		if key == "":
			continue
		var spin: SpinBox = r["spin"]
		var qty := int(spin.value)
		if qty <= 0:
			continue
		## If the same key is picked in two slots, keep the larger qty.
		adds[key] = maxi(int(adds.get(key, 0)), qty)
	if adds.is_empty():
		_toast("WonderVessel", "Choose at least one item first.")
		return false
	var res: Dictionary = PlayerData.use_vessel(tier, adds)
	if not bool(res.get("ok", false)):
		var err := str(res.get("error", "unknown"))
		var msg := "Couldn't use the vessel."
		match err:
			"not_enough":
				msg = "Not enough of %s." % ItemKeyRegistry.display_name(str(res.get("item_key", "")))
			"no_items":
				msg = "No valid items selected."
			"none_owned":
				msg = "You don't own that vessel."
		_toast("WonderVessel", msg)
		return false
	var granted: Dictionary = res.get("granted", {})
	var lines: Array = []
	for key in granted:
		lines.append("+%d %s" % [int(granted[key]), ItemKeyRegistry.display_name(key)])
	_toast("WonderVessel used", ", ".join(lines) if not lines.is_empty() else "Done.")
	_refresh_display()
	return true


## Small helper to show a GameNotification toast if the autoload is present.
func _toast(title: String, body: String) -> void:
	if get_node_or_null("/root/GameNotification") != null:
		GameNotification.show_message(title, body)


## ── Private: Button handlers ─────────────────────────────────────


## Sort-change handlers read the selected SortMode id from the tab's dropdown.
func _on_seeds_sort_changed(_index: int) -> void:
	if _seeds_sort_dropdown != null and is_instance_valid(_seeds_sort_dropdown):
		_sort_mode_seeds = _seeds_sort_dropdown.get_selected_id()
	_rebuild_seeds_list()


func _on_tools_sort_changed(_index: int) -> void:
	if _tools_sort_dropdown != null and is_instance_valid(_tools_sort_dropdown):
		_sort_mode_tools = _tools_sort_dropdown.get_selected_id()
	_rebuild_tools_list()


func _on_items_sort_changed(_index: int) -> void:
	if _items_sort_dropdown != null and is_instance_valid(_items_sort_dropdown):
		_sort_mode_items = _items_sort_dropdown.get_selected_id()
	_rebuild_items_list()


func _on_gems_sort_changed(_index: int) -> void:
	if _gems_sort_dropdown != null and is_instance_valid(_gems_sort_dropdown):
		_sort_mode_gems = _gems_sort_dropdown.get_selected_id()
	_rebuild_gems_list()


## Builds a row of feature-shortcut buttons (Money Gun, Jewelry) under the tab
## bar, so they're reachable regardless of the active tab. Built dynamically to
## avoid editing the inventory scene. Idempotent (guards against re-adding).
func _build_feature_buttons() -> void:
	if vbox.get_node_or_null("FeatureRow") != null:
		return
	var row := HBoxContainer.new()
	row.name = "FeatureRow"
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	var gun_btn := Button.new()
	gun_btn.name = "MoneyGunBtn"
	gun_btn.text = "💵 Money Gun"
	gun_btn.add_theme_font_size_override("font_size", 12)
	gun_btn.custom_minimum_size = Vector2(0, 36)
	gun_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gun_btn.pressed.connect(func(): _get_navigator().navigate_to("money_gun"))
	row.add_child(gun_btn)

	var jewelry_btn := Button.new()
	jewelry_btn.name = "JewelryBtn"
	jewelry_btn.text = "💍 Jewelry"
	jewelry_btn.add_theme_font_size_override("font_size", 12)
	jewelry_btn.custom_minimum_size = Vector2(0, 36)
	jewelry_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jewelry_btn.pressed.connect(func(): _get_navigator().navigate_to("equipment"))
	row.add_child(jewelry_btn)

	# Place the row directly under the tab bar.
	vbox.add_child(row)
	vbox.move_child(row, tab_bar.get_index() + 1)


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


func _on_tab_tiles() -> void:
	_show_tab("tiles")


func _on_tab_seeds() -> void:
	_show_tab("seeds")


func _on_tab_tools() -> void:
	_show_tab("tools")


func _on_tab_items() -> void:
	_show_tab("items")


func _on_tab_gems() -> void:
	_show_tab("gems")


## ── Private: Gems tab ────────────────────────────────────────────


func _rebuild_gems_list() -> void:
	for child in gems_grid.get_children():
		child.queue_free()

	## Sort row (Name / Value / Owned).
	var sort_parts := _make_sort_row("Value", _sort_mode_gems, _on_gems_sort_changed)
	_gems_sort_dropdown = sort_parts[1]
	gems_grid.add_child(sort_parts[0])

	# Count UNCUT gemstones by type from compact dictionary.
	var gem_counts: Dictionary = {}  # gem_type -> { "count": int, "value": int }
	for gem_def in PlayerData.PROSPECTOR_GEM_ORDER:
		var gt: String = gem_def["gem_type"]
		var count: int = PlayerData.get_gem_count(gt)
		if count > 0:
			## Prestige-scaled value, matching the Marketplace display.
			gem_counts[gt] = {"count": count, "value": PlayerData.get_gem_value(gt)}

	# Count POLISHED gems (Workshop saw output). These live in a SEPARATE store
	# (polished_gems) and were previously not shown here at all — mirror the
	# Marketplace, which lists them under their own "Polished Gems" heading.
	var polished_counts: Dictionary = {}  # gem_type -> count
	for gem_type in PlayerData.POLISHABLE_GEMS:
		var pc: int = PlayerData.get_polished_gem_count(gem_type)
		if pc > 0:
			polished_counts[gem_type] = pc

	if gem_counts.is_empty() and polished_counts.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No gemstones. Try gold panning!"
		empty_lbl.add_theme_font_size_override("font_size", 12)
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		gems_grid.add_child(empty_lbl)
		return

	## Display each UNCUT gem type (view only — sell at marketplace), sorted.
	var gem_types: Array = gem_counts.keys()
	_apply_sort(gem_types, _sort_mode_gems,
		func(gt): return str(gt).replace("_", " ").capitalize(),
		func(gt): return int(gem_counts[gt]["value"]),
		func(gt): return int(gem_counts[gt]["count"]))
	for gem_type in gem_types:
		var data: Dictionary = gem_counts[gem_type]
		_add_gem_row(gem_type, int(data["count"]), int(data["value"]), false)

	## Polished gems section (same row style, sorted the same way).
	if not polished_counts.is_empty():
		var sep := HSeparator.new()
		gems_grid.add_child(sep)
		var polished_header := Label.new()
		polished_header.text = "✨ Polished Gems (10× value)"
		polished_header.add_theme_font_size_override("font_size", 12)
		polished_header.add_theme_color_override("font_color", Color(0.8, 0.95, 1.0))
		polished_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		gems_grid.add_child(polished_header)

		var polished_types: Array = polished_counts.keys()
		_apply_sort(polished_types, _sort_mode_gems,
			func(gt): return str(gt).replace("_", " ").capitalize(),
			func(gt): return PlayerData.get_polished_gem_value(gt),
			func(gt): return int(polished_counts[gt]))
		for gem_type in polished_types:
			_add_gem_row(gem_type, int(polished_counts[gem_type]),
				PlayerData.get_polished_gem_value(gem_type), true)


## Builds one view-only gem row (uncut or polished) in the gems grid. `polished`
## selects the polished sprite + name prefix.
func _add_gem_row(gem_type: String, count: int, value: int, polished: bool) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	# Gem icon (polished gems use the "_polished" sprite variant).
	var icon_rect := TextureRect.new()
	var sprite_name := ("%s_polished" % gem_type) if polished else gem_type
	icon_rect.texture = load("res://Assets/GoldPanning/Gemstones/%s.png" % sprite_name)
	icon_rect.custom_minimum_size = Vector2(48, 48)
	icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(icon_rect)

	# Name and info
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_lbl := Label.new()
	var pretty := gem_type.replace("_", " ").capitalize()
	name_lbl.text = ("Polished %s" % pretty) if polished else pretty
	name_lbl.add_theme_font_size_override("font_size", 14)
	if polished:
		name_lbl.add_theme_color_override("font_color", Color(0.7, 0.95, 1.0))
	info.add_child(name_lbl)
	var detail_lbl := Label.new()
	detail_lbl.text = "Owned: %d  |  Value: %s each" % [count, PlayerData.format_number(value)]
	detail_lbl.add_theme_font_size_override("font_size", 11)
	info.add_child(detail_lbl)
	row.add_child(info)

	gems_grid.add_child(row)


func _on_sell_gem(gem_type: String, value: int) -> void:
	pass  # Selling is done at the Marketplace


func _on_sell_all_gems(gem_type: String, value: int) -> void:
	pass  # Selling is done at the Marketplace
