class_name GuildMineUI
extends VBoxContainer
## Community guild Deep Mine widget.
## Embedded inside CommunityPanel in guild_detail_screen.
## Shows the shared 10x10 dig grid (depth-tinted tiles + pending-treasure
## sprites), the player's shovel count, and the shared guild Warehouse.
##
## Usage:
##   var ui := GuildMineUI.new()
##   _community_panel.add_child(ui)
##   ui.setup(guild_id)
##   GuildMine.refresh(guild_id)

const CELL_SIZE := 40
const REFRESH_INTERVAL := 5.0   ## seconds between background polls

## ── State ────────────────────────────────────────────────────────
var _guild_id: String = ""

## Cell button lookup: Vector2i(row, col) -> Button
var _cell_buttons: Dictionary = {}

## ── Node refs ────────────────────────────────────────────────────
var _status_lbl:      Label           = null
var _shovel_lbl:      Label           = null
var _grid_container:  GridContainer   = null
var _scroll:          ScrollContainer = null
var _wh_container:    VBoxContainer   = null
var _refresh_timer:   Timer           = null
var _excavator_btn:   Button          = null

## Excavator mode: a tap clears whole rows (one server call) instead of digging
## one tile. Only offered when the player owns the (personal) Excavator.
var _excavator_mode := false
var _excavating := false

## Tile styles cached per depth (0..10). Building a new StyleBoxTexture and
## setting three overrides on all 100 tiles after every dig was a big part of
## the tap lag; now each tile just points at a shared style.
var _depth_styles: Dictionary = {}

## Last warehouse contents drawn, so the list is only rebuilt when it changes.
var _wh_signature := ""


## ── Setup ────────────────────────────────────────────────────────

func setup(guild_id: String) -> void:
	_guild_id = guild_id
	_build_ui()
	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = REFRESH_INTERVAL
	_refresh_timer.autostart = true
	_refresh_timer.timeout.connect(_on_timer_tick)
	add_child(_refresh_timer)
	if not GuildMine.mine_updated.is_connected(_on_mine_updated):
		GuildMine.mine_updated.connect(_on_mine_updated)
	if get_node_or_null("/root/PlayerData") != null \
			and not PlayerData.data_changed.is_connected(_on_player_data_changed):
		PlayerData.data_changed.connect(_on_player_data_changed)
	## Mission progress drives the "→ Mission" button — rebuild when it changes.
	if get_node_or_null("/root/GuildManager") != null \
			and not GuildManager.guild_data_changed.is_connected(_on_guild_data_changed):
		GuildManager.guild_data_changed.connect(_on_guild_data_changed)


func teardown() -> void:
	if GuildMine.mine_updated.is_connected(_on_mine_updated):
		GuildMine.mine_updated.disconnect(_on_mine_updated)
	if get_node_or_null("/root/PlayerData") != null \
			and PlayerData.data_changed.is_connected(_on_player_data_changed):
		PlayerData.data_changed.disconnect(_on_player_data_changed)
	if get_node_or_null("/root/GuildManager") != null \
			and GuildManager.guild_data_changed.is_connected(_on_guild_data_changed):
		GuildManager.guild_data_changed.disconnect(_on_guild_data_changed)
	if is_instance_valid(_refresh_timer):
		_refresh_timer.stop()
	_cell_buttons.clear()


## ── UI build ─────────────────────────────────────────────────────

func _build_ui() -> void:
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	## Title
	var title := Label.new()
	title.text = "⛏ Community Deep Mine"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	## Status label
	_status_lbl = Label.new()
	_status_lbl.add_theme_font_size_override("font_size", 10)
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.text = "Tap a tile to dig (uses a shovel). Tap a treasure to bank it."
	add_child(_status_lbl)

	## Shovel count
	_shovel_lbl = Label.new()
	_shovel_lbl.add_theme_font_size_override("font_size", 11)
	_shovel_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shovel_lbl.add_theme_color_override("font_color", Color(0.9, 0.85, 0.6))
	add_child(_shovel_lbl)

	## Excavator toggle — shown only when the player owns the Excavator.
	_excavator_btn = Button.new()
	_excavator_btn.toggle_mode = true
	_excavator_btn.add_theme_font_size_override("font_size", 11)
	_excavator_btn.custom_minimum_size = Vector2(0, 34)
	_excavator_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_excavator_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_excavator_btn.toggled.connect(func(on: bool):
		_excavator_mode = on
		_update_excavator_btn()
		_set_status("Excavator ON — tap a tile to clear its row (no shovels)." if on
			else "Tap a tile to dig (uses a shovel). Tap a treasure to bank it.", Color.WHITE))
	add_child(_excavator_btn)
	_update_excavator_btn()

	## Scrollable dig grid
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.scroll_deadzone        = 16   ## finger-scroll without firing taps
	_scroll.custom_minimum_size    = Vector2(0, mini(GuildMine.grid_rows * CELL_SIZE + 8, 340))
	_scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	add_child(_scroll)

	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(center)

	_grid_container = GridContainer.new()
	_grid_container.columns = GuildMine.grid_cols
	_grid_container.add_theme_constant_override("h_separation", 2)
	_grid_container.add_theme_constant_override("v_separation", 2)
	center.add_child(_grid_container)

	## Warehouse section
	var wh_title := Label.new()
	wh_title.text = "🏦 Guild Warehouse"
	wh_title.add_theme_font_size_override("font_size", 13)
	wh_title.add_theme_color_override("font_color", Color.WHITE)
	wh_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(wh_title)

	_wh_container = VBoxContainer.new()
	_wh_container.add_theme_constant_override("separation", 4)
	add_child(_wh_container)

	## Initial build
	_rebuild_grid()
	_refresh_warehouse_if_changed(true)
	_update_shovel_label()


## ── Shovel label ─────────────────────────────────────────────────

func _update_shovel_label() -> void:
	if not is_instance_valid(_shovel_lbl):
		return
	var shovels := PlayerData.get_tool_count(PlayerData.ToolType.SHOVEL)
	_shovel_lbl.text = "🪏 Your shovels: %d   |   Depth reach: %d / %d layers" \
		% [shovels, GuildMine.max_layers, 11]


## ── Grid ─────────────────────────────────────────────────────────

func _rebuild_grid() -> void:
	_cell_buttons.clear()
	for child in _grid_container.get_children():
		child.queue_free()
	_grid_container.columns = GuildMine.grid_cols

	for r in range(GuildMine.grid_rows):
		for c in range(GuildMine.grid_cols):
			var pos := Vector2i(r, c)
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(CELL_SIZE, CELL_SIZE)
			btn.focus_mode = Control.FOCUS_NONE
			btn.set_meta("row", r)
			btn.set_meta("col", c)
			btn.pressed.connect(_on_cell_pressed.bind(r, c))

			var sprite := TextureRect.new()
			sprite.name = "TreasureSprite"
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
	for pos in _cell_buttons:
		var btn: Button = _cell_buttons[pos]
		if btn and is_instance_valid(btn):
			_apply_cell_visual(btn, pos.x, pos.y)


func _apply_cell_visual(btn: Button, row: int, col: int) -> void:
	if btn == null or not is_instance_valid(btn):
		return

	var depth := GuildMine.get_depth(row, col)
	var pending := GuildMine.get_pending(row, col)
	var sprite := btn.get_node_or_null("TreasureSprite") as TextureRect

	## Tile background: use the solo mine's depth textures so deeper = darker.
	## depth = layers already dug; the "surface" shown is the next layer to dig.
	## Styles are cached per depth, and only re-applied when the depth changed.
	var d := clampi(depth, 0, 10)
	if int(btn.get_meta("style_depth", -1)) != d:
		var style := _style_for_depth(d)
		btn.add_theme_stylebox_override("normal", style)
		btn.add_theme_stylebox_override("hover", style)
		btn.add_theme_stylebox_override("pressed", style)
		btn.set_meta("style_depth", d)

	btn.text = ""

	## Pending treasure sprite + tooltip.
	if not pending.is_empty():
		var item_id := _item_id(pending)
		if sprite:
			sprite.texture = DeepMine.get_gem_texture(item_id)
			sprite.visible = true
		btn.tooltip_text = "%s — tap to bank it" % _item_label(pending)
	else:
		if sprite:
			sprite.visible = false
		if GuildMine.is_fully_dug(row, col):
			btn.tooltip_text = "Fully dug"
			btn.modulate = Color(0.6, 0.6, 0.6)
		else:
			btn.tooltip_text = "Dig (layer %d/%d)" % [depth + 1, GuildMine.max_layers]
			btn.modulate = Color.WHITE


## Shared tile style for a depth (built once per depth, then reused).
func _style_for_depth(d: int) -> StyleBox:
	if _depth_styles.has(d):
		return _depth_styles[d]
	var style: StyleBox
	var tile_tex := DeepMine.get_tile_texture(d)
	if tile_tex:
		var st := StyleBoxTexture.new()
		st.texture = tile_tex
		style = st
	else:
		var flat := StyleBoxFlat.new()
		var shade := clampf(0.5 - d * 0.04, 0.1, 0.5)
		flat.bg_color = Color(shade, shade * 0.8, shade * 0.6)
		style = flat
	_depth_styles[d] = style
	return style


## ── Warehouse ────────────────────────────────────────────────────

## Rebuilds the warehouse list only if its contents (or capacity / mission
## needs) changed since the last draw. Pass force=true to always rebuild.
func _refresh_warehouse_if_changed(force: bool = false) -> void:
	var keys: Array = GuildMine.warehouse.keys()
	keys.sort()
	var parts: PackedStringArray = [str(GuildMine.warehouse_capacity)]
	for k in keys:
		parts.append("%s=%d/%d" % [k, GuildMine.get_warehouse_amount(k), _mission_need_for_item(k)])
	var sig := "|".join(parts)
	if not force and sig == _wh_signature:
		return
	_wh_signature = sig
	_rebuild_warehouse()


func _rebuild_warehouse() -> void:
	for child in _wh_container.get_children():
		child.queue_free()

	var cap := GuildMine.warehouse_capacity

	## Stable display order: gems (common→rare) then ores, matching the mine.
	var order: Array[String] = []
	for g in DeepMine.GEM_ORDER:
		order.append("gem:" + g)
	for o in DeepMine.ORE_ORDER:
		order.append("resource:" + o)
	## Append any keys not in the known order (future-proofing).
	for k in GuildMine.warehouse.keys():
		if not order.has(k):
			order.append(k)

	var has_stock := false
	for item_key in order:
		var amount := GuildMine.get_warehouse_amount(item_key)
		if amount <= 0:
			continue
		has_stock = true

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_wh_container.add_child(row)

		var icon_tex := DeepMine.get_gem_texture(_item_id(item_key))
		if icon_tex:
			var icon := TextureRect.new()
			icon.texture = icon_tex
			icon.custom_minimum_size = Vector2(24, 24)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			row.add_child(icon)

		var info_lbl := Label.new()
		info_lbl.text = "%s   %d / %d" % [_item_label(item_key), amount, cap]
		info_lbl.add_theme_font_size_override("font_size", 10)
		info_lbl.add_theme_color_override("font_color", Color.WHITE)
		info_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info_lbl)

		## "→ Mission (n)" button when an active mission wants this item. The
		## amount counts as the GUILD's share (split evenly in the reward).
		var need := _mission_need_for_item(item_key)
		var can_deposit := mini(amount, need)
		if can_deposit > 0:
			var dep_btn := Button.new()
			dep_btn.text = "→ Mission (%d)" % can_deposit
			dep_btn.add_theme_font_size_override("font_size", 10)
			dep_btn.custom_minimum_size = Vector2(110, 26)
			dep_btn.pressed.connect(
				_on_warehouse_deposit_pressed.bind(item_key, can_deposit, dep_btn))
			row.add_child(dep_btn)

	if not has_stock:
		var empty := Label.new()
		empty.text = "Warehouse is empty. Dig to fill it!"
		empty.add_theme_font_size_override("font_size", 10)
		empty.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_wh_container.add_child(empty)

	var footer := Label.new()
	footer.text = "Warehouse capacity: %d per item type" % cap
	footer.add_theme_font_size_override("font_size", 9)
	footer.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wh_container.add_child(footer)


## ── Item key helpers ─────────────────────────────────────────────

## Strips the 'gem:' / 'resource:' prefix to the bare id DeepMine textures use.
func _item_id(item_key: String) -> String:
	var idx := item_key.find(":")
	return item_key.substr(idx + 1) if idx >= 0 else item_key

## Human-readable name for a canonical item key.
func _item_label(item_key: String) -> String:
	return _item_id(item_key).replace("_", " ").capitalize()

## The mission base keys a deposit of `item_key` can satisfy (generic bucket +
## specific key). Mirrors the server's _guild_deposit_keys_for_item.
func _deposit_keys_for_item(item_key: String) -> Array:
	var idx := item_key.find(":")
	if idx < 0:
		return []
	var cat := item_key.substr(0, idx)
	var id := item_key.substr(idx + 1)
	if id.is_empty():
		return []
	match cat:
		"gem":      return ["deposit_gems",     "deposit_gem_" + id]
		"polished": return ["deposit_polished", "deposit_polished_" + id]
		"resource": return ["deposit_ores",     "deposit_ore_" + id]
		"crop":     return ["deposit_produce",  "deposit_" + id]
		"fruit":    return ["deposit_fruit",    "deposit_" + id]
	return []

## Largest remaining need across active missions compatible with this item.
## Used to size the "→ Mission (n)" button so we never over-deposit.
func _mission_need_for_item(item_key: String) -> int:
	var keys := _deposit_keys_for_item(item_key)
	if keys.is_empty():
		return 0
	var best := 0
	for m in GuildManager.guild_missions:
		if not m is Dictionary:
			continue
		if str(m.get("status", "")) != "active":
			continue
		if not keys.has(str(m.get("base_mission_key", ""))):
			continue
		var remaining := maxi(int(m.get("target", 0)) - int(m.get("progress", 0)), 0)
		best = maxi(best, remaining)
	return best


## ── Signal handlers ──────────────────────────────────────────────

func _on_mine_updated() -> void:
	_refresh_grid_visuals()
	_refresh_warehouse_if_changed()
	_update_shovel_label()
	_update_excavator_btn()


func _on_timer_tick() -> void:
	if _guild_id.is_empty():
		return
	GuildMine.refresh(_guild_id)


func _on_player_data_changed() -> void:
	_update_shovel_label()


func _on_guild_data_changed() -> void:
	## Missions may have changed — refresh the "→ Mission" deposit buttons
	## (the signature includes mission needs, so this rebuilds only if needed).
	_refresh_warehouse_if_changed()


func _on_warehouse_deposit_pressed(item_key: String, amount: int, btn: Button) -> void:
	if is_instance_valid(btn):
		btn.disabled = true
		btn.text = "Depositing…"
	var res := await GuildMine.deposit_warehouse(_guild_id, item_key, amount)
	if res.get("ok", false):
		var dep := int(res.get("deposited", amount))
		_set_status("Sent %d %s to the mission (guild share). 🤝" \
			% [dep, _item_label(item_key)], Color(0.5, 1.0, 0.6))
		_refresh_warehouse_if_changed(true)
	else:
		_set_status(str(res.get("message", "Deposit failed.")), Color(0.9, 0.4, 0.3))
		if is_instance_valid(btn):
			btn.disabled = false
			btn.text = "→ Mission (%d)" % amount


func _on_cell_pressed(row: int, col: int) -> void:
	if _excavating:
		return
	if _excavator_mode:
		_excavate_task(row)
		return
	if GuildMine.is_cell_pending(row, col):
		return

	var picking_up := GuildMine.has_pending(row, col)

	## Guard: fully dug and nothing to collect.
	if not picking_up and GuildMine.get_depth(row, col) >= GuildMine.max_layers:
		_set_status("That tile is fully dug.", Color(0.8, 0.8, 0.8))
		return
	## Guard: no shovel for a fresh dig.
	if not picking_up and PlayerData.get_tool_count(PlayerData.ToolType.SHOVEL) <= 0:
		_set_status("No shovels! Buy some at the Marketplace.", Color(0.9, 0.5, 0.3))
		return

	_dig_task(row, col)


func _dig_task(row: int, col: int) -> void:
	var picking_up := GuildMine.has_pending(row, col)
	if picking_up:
		_set_status("Banking…", Color(0.8, 0.8, 0.8))
	else:
		_set_status("Digging…", Color(0.8, 0.8, 0.8))

	## GuildMine.dig emits mine_updated on success, which repaints the tile and
	## the warehouse (only if it changed) — no second repaint needed here.
	var res := await GuildMine.dig(_guild_id, row, col)
	_update_shovel_label()

	if res.get("ok", false):
		var action := str(res.get("action", ""))
		var treasure := str(res.get("treasure", ""))
		if action == "pickup":
			if bool(res.get("stored", true)):
				_set_status("Banked %s into the warehouse. 🏦" % _item_label(treasure), Color(0.5, 1.0, 0.6))
			else:
				_set_status("Warehouse full — %s was lost!" % _item_label(treasure), Color(0.9, 0.7, 0.3))
		elif action == "dig":
			var layers := int(res.get("layers_dug", 1))
			var thru := " (drilled %d layers)" % layers if layers > 1 else ""
			if treasure.is_empty():
				_set_status("Dug deeper%s… nothing here. Keep going!" % thru, Color(0.8, 0.8, 0.8))
			else:
				_set_status("Unearthed %s%s! Tap it to bank it. ✨" % [_item_label(treasure), thru], Color(0.9, 0.9, 0.5))
	else:
		_set_status(str(res.get("message", "Could not dig.")), Color(0.9, 0.4, 0.3))


## ── Excavator ────────────────────────────────────────────────────

## True if the player owns the (personal) Excavator unlock.
func _has_excavator() -> bool:
	return get_node_or_null("/root/DeepMine") != null and DeepMine.has_excavator()


func _excavator_rows() -> int:
	if get_node_or_null("/root/DeepMine") != null:
		return maxi(DeepMine.get_excavator_rows(), 1)
	return 1


func _update_excavator_btn() -> void:
	if not is_instance_valid(_excavator_btn):
		return
	if not _has_excavator():
		_excavator_btn.visible = false
		_excavator_mode = false
		_excavator_btn.set_pressed_no_signal(false)
		return
	_excavator_btn.visible = true
	var rows := _excavator_rows()
	var plural := "s" if rows > 1 else ""
	if _excavator_mode:
		_excavator_btn.text = "🚜 Excavator ON — tap a row (%d row%s, free)" % [rows, plural]
		_excavator_btn.modulate = Color(1.0, 0.75, 0.3)
	else:
		_excavator_btn.text = "🚜 Excavator: dig %d row%s free" % [rows, plural]
		_excavator_btn.modulate = Color.WHITE


## Clears the tapped row (and the next rows per Heavy Machinery) in one call.
func _excavate_task(start_row: int) -> void:
	if not _has_excavator():
		return
	_excavating = true
	_set_status("🚜 Excavating…", Color(1.0, 0.85, 0.3))
	var res := await GuildMine.excavate(_guild_id, start_row, _excavator_rows())
	_excavating = false
	if not res.get("ok", false):
		_set_status(str(res.get("message", "Could not excavate.")), Color(0.9, 0.4, 0.3))
		return
	var tiles := int(res.get("tiles", 0))
	if tiles <= 0:
		_set_status("Nothing left to dig from that row down (bank any treasure first).", Color(0.8, 0.8, 0.8))
		return
	var found: Dictionary = res.get("found", {})
	if found.is_empty():
		_set_status("🚜 Dug %d tiles — no treasure this time." % tiles, Color(0.8, 0.8, 0.8))
	else:
		var parts: PackedStringArray = []
		for k in found:
			parts.append("%d %s" % [int(found[k]), _item_label(k)])
		_set_status("🚜 Dug %d tiles — unearthed %s. Tap them to bank. ✨" % [tiles, ", ".join(parts)],
			Color(0.9, 0.9, 0.5))


## ── Helpers ──────────────────────────────────────────────────────

func _set_status(text: String, color: Color = Color.WHITE) -> void:
	if is_instance_valid(_status_lbl):
		_status_lbl.text = text
		_status_lbl.add_theme_color_override("font_color", color)
