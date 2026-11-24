extends BaseScreen
## Equipment screen — equip jewelry into the Ring / Necklace / Misc slots to
## activate their passive bonuses (Stage 3b). Each slot shows the equipped item
## with its live bonus level (scaled by how many you HOLD) and lets you pick a
## different owned jewelry to equip, or clear the slot.
##
## Reads/writes PlayerData equip slots; bonus math via the JewelryBonus autoload.

const SLOTS := ["ring", "necklace", "misc"]
const SLOT_LABELS := {"ring": "💍 Ring", "necklace": "📿 Necklace", "misc": "✨ Misc"}

var _content: VBoxContainer = null


func get_screen_name() -> String:
	return "equipment"


func enter(_params: Dictionary = {}) -> void:
	_build_ui()
	if not PlayerData.jewelry_equipment_changed.is_connected(_on_changed):
		PlayerData.jewelry_equipment_changed.connect(_on_changed)
	if not PlayerData.data_changed.is_connected(_on_changed):
		PlayerData.data_changed.connect(_on_changed)
	_rebuild()


func exit() -> void:
	if PlayerData.jewelry_equipment_changed.is_connected(_on_changed):
		PlayerData.jewelry_equipment_changed.disconnect(_on_changed)
	if PlayerData.data_changed.is_connected(_on_changed):
		PlayerData.data_changed.disconnect(_on_changed)
	for child in get_children():
		child.queue_free()
	_content = null


func _on_changed() -> void:
	_rebuild()


# ── UI ────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.12, 0.9)
	style.corner_radius_top_left = 6; style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6; style.corner_radius_bottom_right = 6
	style.content_margin_left = 10; style.content_margin_right = 10
	style.content_margin_top = 8; style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 10)
	scroll.add_child(_content)


func _rebuild() -> void:
	if _content == null:
		return
	for c in _content.get_children():
		c.queue_free()

	var back := Button.new()
	back.text = "< Back"
	back.custom_minimum_size = Vector2(200, 44)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.add_theme_font_size_override("font_size", 13)
	back.pressed.connect(_on_back_pressed)
	_content.add_child(back)

	var title := Label.new()
	title.text = "Jewelry Equipment"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.9, 0.8, 1.0))
	_content.add_child(title)

	var hint := Label.new()
	hint.text = "Equip jewelry to activate its bonus. Strength grows with how many of that item you hold (Lv.1 at 1, Lv.10 at 1,000,000)."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	_content.add_child(hint)

	for slot in SLOTS:
		_content.add_child(_make_slot_row(slot))

	_build_owned_section()


# ── Owned jewelry list + selling ───────────────────────────────────

## Sell-quantity sentinel for "Max" (OptionButton ids can't be negative).
## Matches the Marketplace / Inventory qty pickers.
const QTY_MAX := 1_000_000
var _sell_qty_dd: OptionButton = null


## Lists every wearable jewelry piece the player owns (Diamond Rings included)
## with its owned count, sell price, an equipped marker, and a Sell button driven
## by a shared 1 / 5 / 10 / 25 / Max quantity picker.
func _build_owned_section() -> void:
	var header := Label.new()
	header.text = "💎 Your Jewelry"
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_content.add_child(header)

	var owned: Array = []
	for jid in PlayerData.jewelry_ids():
		if PlayerData.is_horseshoe_id(jid):
			continue  ## horseshoes equip to horses, not here
		if PlayerData.get_jewelry_count(jid) > 0:
			owned.append(jid)

	if owned.is_empty():
		var none := Label.new()
		none.text = "You don't own any jewelry yet. Craft it in a guild facility or buy it from a Guild Front."
		none.add_theme_font_size_override("font_size", 11)
		none.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_content.add_child(none)
		return

	## Shared quantity picker (remembered across rebuilds and sessions).
	var qty_row := HBoxContainer.new()
	qty_row.add_theme_constant_override("separation", 8)
	qty_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var qty_lbl := Label.new()
	qty_lbl.text = "Sell qty:"
	qty_lbl.add_theme_font_size_override("font_size", 12)
	qty_row.add_child(qty_lbl)
	_sell_qty_dd = OptionButton.new()
	_sell_qty_dd.add_theme_font_size_override("font_size", 12)
	for q in [1, 100, 1000, 10000]:
		_sell_qty_dd.add_item("10k" if q == 10000 else str(q), q)
	_sell_qty_dd.add_item("Max", QTY_MAX)
	var prev := PlayerData.get_market_pref("qty_jewelry", 1)
	for i in range(_sell_qty_dd.item_count):
		if _sell_qty_dd.get_item_id(i) == prev:
			_sell_qty_dd.selected = i
			break
	_sell_qty_dd.item_selected.connect(func(_i):
		PlayerData.set_market_pref("qty_jewelry", _sell_qty_dd.get_selected_id())
		_rebuild())  ## refresh each Sell button's payout
	qty_row.add_child(_sell_qty_dd)
	_content.add_child(qty_row)

	for jid in owned:
		_content.add_child(_make_owned_row(jid))


func _make_owned_row(jid: String) -> Control:
	var def := PlayerData.get_jewelry_def(jid)
	var count := PlayerData.get_jewelry_count(jid)
	var unit := PlayerData.get_jewelry_sell_value(jid)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(40, 40)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var tex: Texture2D = load(str(def.get("sprite", ""))) if str(def.get("sprite", "")) != "" else null
	icon.texture = tex
	row.add_child(icon)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_lbl := Label.new()
	name_lbl.text = str(def.get("name", jid))
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_child(name_lbl)
	var detail := Label.new()
	detail.text = "Owned: %s  |  Sell: %s each" % [
		PlayerData.format_number(count), PlayerData.format_coins(unit)]
	detail.add_theme_font_size_override("font_size", 10)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_child(detail)
	if PlayerData.is_jewelry_equipped(jid):
		var eq := Label.new()
		eq.text = "✓ Equipped (selling all of it unequips it)"
		eq.add_theme_font_size_override("font_size", 10)
		eq.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
		eq.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_child(eq)
	row.add_child(info)

	var qty := _sell_qty(count)
	var sell_btn := Button.new()
	sell_btn.text = "Sell %s\n%s" % [
		PlayerData.format_number(qty), PlayerData.format_coins(qty * unit)]
	sell_btn.add_theme_font_size_override("font_size", 11)
	sell_btn.custom_minimum_size = Vector2(80, 44)
	sell_btn.disabled = qty <= 0
	sell_btn.pressed.connect(_on_sell_pressed.bind(jid))
	row.add_child(sell_btn)
	return row


## Resolves the picker against what's owned: "Max" (or more than owned) sells all.
func _sell_qty(owned: int) -> int:
	var sel := 1
	if _sell_qty_dd != null and is_instance_valid(_sell_qty_dd):
		sel = _sell_qty_dd.get_selected_id()
	if sel == QTY_MAX:
		return owned
	return mini(sel, owned)


func _on_sell_pressed(jid: String) -> void:
	var qty := _sell_qty(PlayerData.get_jewelry_count(jid))
	if qty <= 0:
		return
	var payout := qty * PlayerData.get_jewelry_sell_value(jid)
	## sell_jewelry pays coins + XP, unequips a sold-out piece, and emits
	## data_changed (which rebuilds this screen).
	if PlayerData.sell_jewelry(jid, qty):
		var item_name := str(PlayerData.get_jewelry_def(jid).get("name", jid))
		GameNotification.show_message("Sold",
			"Sold %s× %s for %s coins." % [PlayerData.format_number(qty), item_name,
				PlayerData.format_coins(payout)])


func _make_slot_row(slot: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)

	var header := Label.new()
	header.text = str(SLOT_LABELS.get(slot, slot.capitalize()))
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	box.add_child(header)

	var equipped_id := str(PlayerData.equipped_jewelry()[slot])

	## Current bonus line.
	var status := Label.new()
	status.add_theme_font_size_override("font_size", 11)
	if equipped_id == "":
		status.text = "Empty"
		status.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	else:
		var def := PlayerData.get_jewelry_def(equipped_id)
		var held := PlayerData.get_jewelry_count(equipped_id)
		var lvl := JewelryBonus.level_for_count(held)
		var pct := int(round(JewelryBonus.pct_for_level(lvl)))
		status.text = "%s — Lv.%d (%s +%d%%)  ·  held: %s" % [
			str(def.get("name", equipped_id)), lvl,
			_bonus_label_for_item(equipped_id, str(def.get("bonus", ""))), pct,
			PlayerData.format_number(held)]
		status.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	box.add_child(status)

	## Picker row: dropdown of owned eligible jewelry + Equip + Unequip.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)

	var opt := OptionButton.new()
	opt.add_theme_font_size_override("font_size", 10)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var candidates := _candidates_for_slot(slot)
	opt.add_item("— choose —", -1)
	opt.set_item_metadata(0, "")
	var sel_idx := 0
	for i in range(candidates.size()):
		var jid: String = candidates[i]
		var cdef := PlayerData.get_jewelry_def(jid)
		opt.add_item("%s (%s)" % [str(cdef.get("name", jid)),
			PlayerData.format_number(PlayerData.get_jewelry_count(jid))], i + 1)
		opt.set_item_metadata(i + 1, jid)
		if jid == equipped_id:
			sel_idx = i + 1
	opt.selected = sel_idx
	row.add_child(opt)

	var equip_btn := Button.new()
	equip_btn.text = "Equip"
	equip_btn.add_theme_font_size_override("font_size", 10)
	equip_btn.custom_minimum_size = Vector2(60, 0)
	equip_btn.disabled = candidates.is_empty()
	equip_btn.pressed.connect(func():
		var mid: String = str(opt.get_item_metadata(opt.selected)) if opt.selected >= 0 else ""
		_on_equip_pressed(slot, mid))
	row.add_child(equip_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Unequip"
	clear_btn.add_theme_font_size_override("font_size", 10)
	clear_btn.custom_minimum_size = Vector2(70, 0)
	clear_btn.disabled = equipped_id == ""
	clear_btn.pressed.connect(func(): _on_equip_pressed(slot, ""))
	row.add_child(clear_btn)

	if candidates.is_empty() and equipped_id == "":
		var none := Label.new()
		none.text = "No %s jewelry owned — craft some in your guild's facility." % \
			("ring/necklace" if slot == "misc" else slot)
		none.add_theme_font_size_override("font_size", 10)
		none.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(none)

	var sep := HSeparator.new()
	box.add_child(sep)
	return box


## Owned jewelry ids eligible for a slot (ring slot -> rings; necklace -> necklaces;
## misc -> either), excluding items already equipped in ANOTHER slot (no dups).
func _candidates_for_slot(slot: String) -> Array:
	var out: Array = []
	var equipped := PlayerData.equipped_jewelry()
	for jid in PlayerData.jewelry_ids():
		if PlayerData.get_jewelry_count(jid) <= 0:
			continue
		## Horseshoes carry jewelry:true (for the guild produce/sell loop) but
		## equip to a HORSE, not the personal ring/necklace/misc slots — skip them.
		if PlayerData.is_horseshoe_id(jid):
			continue
		var st := PlayerData.jewelry_slot_type(jid)
		if slot == "ring" and st != "ring":
			continue
		if slot == "necklace" and st != "necklace":
			continue
		## Exclude items currently equipped in a DIFFERENT slot.
		var in_other := false
		for other in SLOTS:
			if other != slot and str(equipped[other]) == jid:
				in_other = true
		if in_other:
			continue
		out.append(jid)
	return out


func _on_equip_pressed(slot: String, item_id: String) -> void:
	if not PlayerData.equip_jewelry(slot, item_id):
		GameNotification.show_message("Can't Equip",
			"That item can't go in the %s slot (or you don't own it)." % slot)
	## equip_jewelry emits jewelry_equipment_changed -> _rebuild.


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


## Human label for a jewelry bonus id.
func _bonus_label(bonus_id: String) -> String:
	match bonus_id:
		"all_sell_value": return "All sell value"
		"coin_gain":      return "Coin gains"
		"xp_gain":        return "XP gain"
		"daily_bonus":    return "Daily bonus"
		"growth_speed":   return "Crop growth speed"
		"chest_luck":     return "Chest luck"
		"rarer_gems":     return "Rarer gem odds"
		"loving_messages":return "Loving messages"
	return bonus_id.capitalize()


## Like _bonus_label but appends extra bonuses for items that do more than one
## thing (e.g. blue_stone_necklace grants chest luck AND double crop yield).
func _bonus_label_for_item(item_id: String, bonus_id: String) -> String:
	var base := _bonus_label(bonus_id)
	match item_id:
		"blue_stone_necklace":
			return base + " + double crop chance"
	return base
