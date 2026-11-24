extends BaseScreen
## Business District screen. LOCAL-ONLY feature (no online calls). Shows 6 slot
## cards driven by the BusinessDistrict autoload. Each card is one of:
##   • empty      → a shop-select dropdown (hides already-assigned shops)
##   • sprite     → the assigned shop's sprite + name + level (tap → manage)
##   • manage     → deposit control, per-item list, progress bar, change-shop
##                  (X returns to the sprite view)
##
## Everything is built in code so cards can swap views independently.

const SLOT_COUNT := 6

var _content: VBoxContainer = null
var _cards_box: VBoxContainer = null
var _status: Label = null

## Per-slot view mode: "auto" (empty/sprite by state) or "manage".
var _view_mode: Array = ["auto", "auto", "auto", "auto", "auto", "auto"]


func get_screen_name() -> String:
	return "business_district"


func show_top_bar() -> bool:
	return true


func enter(_params: Dictionary = {}) -> void:
	_build_ui()
	_rebuild_cards()


func exit() -> void:
	for child in get_children():
		child.queue_free()


## ── Scaffold ────────────────────────────────────────────────────

func _build_ui() -> void:
	var bg := PanelContainer.new()
	bg.name = "BgPanel"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0.08, 0.08, 0.12, 0.9)
	bg_style.set_corner_radius_all(6)
	bg_style.content_margin_left = 8; bg_style.content_margin_right = 8
	bg_style.content_margin_top = 6; bg_style.content_margin_bottom = 6
	bg.add_theme_stylebox_override("panel", bg_style)
	add_child(bg)

	_content = VBoxContainer.new()
	_content.set_anchors_preset(Control.PRESET_FULL_RECT)
	_content.add_theme_constant_override("separation", 8)
	bg.add_child(_content)

	## Top row: back + title.
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(120, 44)
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(_on_back_pressed)
	top.add_child(back_btn)
	var title := Label.new()
	title.text = "Business District"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	top.add_child(title)
	_content.add_child(top)

	## Active-slots summary.
	var summary := Label.new()
	summary.name = "Summary"
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	summary.add_theme_font_size_override("font_size", 11)
	summary.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	_content.add_child(summary)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", Color(0.85, 0.85, 0.8))
	_content.add_child(_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_content.add_child(scroll)
	_cards_box = VBoxContainer.new()
	_cards_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards_box.add_theme_constant_override("separation", 10)
	## PASS so touch drags on the cards reach the ScrollContainer for
	## swipe-to-scroll anywhere, not just on the scrollbar.
	_cards_box.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.add_child(_cards_box)


func _refresh_summary() -> void:
	var summary := _content.get_node_or_null("Summary") as Label
	if summary == null:
		return
	var used := BusinessDistrict.active_nonmaxed_count()
	summary.text = "Active shops: %d / %d" % [used, BusinessDistrict.SLOT_COUNT]


## ── Card rendering ──────────────────────────────────────────────

func _rebuild_cards() -> void:
	if not is_instance_valid(_cards_box):
		return
	for child in _cards_box.get_children():
		child.queue_free()
	_refresh_summary()
	for slot in range(SLOT_COUNT):
		_cards_box.add_child(_build_card(slot))


## Rebuilds a single card in place (used after per-card view changes) without
## disturbing the others. Falls back to a full rebuild if indices don't line up.
func _rebuild_card(slot: int) -> void:
	if not is_instance_valid(_cards_box) or slot < 0 or slot >= _cards_box.get_child_count():
		_rebuild_cards()
		return
	var old := _cards_box.get_child(slot)
	var fresh := _build_card(slot)
	_cards_box.add_child(fresh)
	_cards_box.move_child(fresh, slot)
	old.queue_free()
	_refresh_summary()


func _build_card(slot: int) -> Control:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS  ## let drags pass to the scroll
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.14, 0.20, 0.9)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10; style.content_margin_right = 10
	style.content_margin_top = 10; style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)

	var shop_id := str(BusinessDistrict.slots[slot])
	if shop_id == "":
		panel.add_child(_build_empty_card(slot))
	elif _view_mode[slot] == "manage":
		panel.add_child(_build_manage_view(slot, shop_id))
	else:
		panel.add_child(_build_sprite_view(slot, shop_id))
	return panel


## Empty slot: a dropdown of assignable shops (hides shops already in a slot).
func _build_empty_card(slot: int) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_PASS

	var lbl := Label.new()
	lbl.text = "Slot %d — empty" % (slot + 1)
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.75))
	box.add_child(lbl)

	var dd := OptionButton.new()
	dd.add_theme_font_size_override("font_size", 13)
	dd.custom_minimum_size = Vector2(0, 44)
	## Long "Name — what it does" entries must not widen the screen: clip the
	## closed button's caption; the opened list shows the full text.
	dd.fit_to_longest_item = false
	dd.clip_text = true
	dd.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dd.add_item("Select a shop…", -1)
	## List shops not already assigned to another slot, each with a one-line
	## summary of its bonus and what it takes as deposits, so players can choose
	## without opening every preview.
	for s in BusinessDistrict.SHOPS:
		var sid := str(s["id"])
		if BusinessDistrict.slots.find(sid) == -1:
			dd.add_item(_shop_dropdown_label(s))
			dd.set_item_metadata(dd.item_count - 1, sid)
	dd.item_selected.connect(func(idx):
		var sid = dd.get_item_metadata(idx)
		if sid is String and sid != "":
			_show_business_preview(slot, sid, dd))
	box.add_child(dd)
	return box


## "Flower Shop — Sunflowers sell for more. (feed: Sunflower)" for the picker.
## The Valentine's Valor keeps its effect a surprise, matching its preview.
func _shop_dropdown_label(s: Dictionary) -> String:
	var sid := str(s.get("id", ""))
	var desc := "Surprise!" if sid == "valentine" else str(s.get("desc", ""))
	var feed := ""
	if bool(s.get("accepts_all_seeds", false)):
		feed = "any seeds"
	else:
		var names: PackedStringArray = []
		for key in s.get("accepted_keys", []):
			names.append(ItemKeyRegistry.display_name(str(key)))
		if names.size() > 3:
			feed = "%s +%d more" % [", ".join(names.slice(0, 2)), names.size() - 2]
		else:
			feed = ", ".join(names)
	if feed == "":
		return "%s — %s" % [str(s.get("name", sid)), desc]
	return "%s — %s (feed: %s)" % [str(s.get("name", sid)), desc, feed]


## Assigned slot, sprite view: sprite + name + level. Tap sprite → manage.
func _build_sprite_view(slot: int, shop_id: String) -> Control:
	var def := BusinessDistrict.get_shop_def(shop_id)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = Control.MOUSE_FILTER_PASS

	var sprite_btn := Button.new()
	sprite_btn.flat = true
	sprite_btn.custom_minimum_size = Vector2(0, 96)
	sprite_btn.tooltip_text = "Tap to manage %s" % str(def.get("name", "shop"))
	var tex := _safe_load(str(def.get("sprite", "")))
	if tex != null:
		var icon := TextureRect.new()
		icon.texture = tex
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(0, 96)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sprite_btn.add_child(icon)
		icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	else:
		sprite_btn.text = str(def.get("name", "Shop"))
	sprite_btn.pressed.connect(func():
		_view_mode[slot] = "manage"
		_rebuild_card(slot))
	box.add_child(sprite_btn)

	var name_lbl := Label.new()
	var lvl := BusinessDistrict.get_level(shop_id)
	var maxed := BusinessDistrict.is_maxed(shop_id)
	name_lbl.text = "%s — Lv.%d%s" % [str(def.get("name", "")), lvl, "  ⭐ MAX" if maxed else ""]
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", Color(0.7, 1.0, 0.7) if maxed else Color(1.0, 0.9, 0.5))
	box.add_child(name_lbl)

	## Short bonus description under the sprite.
	var desc_lbl := Label.new()
	desc_lbl.text = str(def.get("desc", ""))
	desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.add_theme_font_size_override("font_size", 10)
	desc_lbl.add_theme_color_override("font_color", Color(0.82, 0.85, 0.9))
	box.add_child(desc_lbl)

	## Maxed shops keep their bonus permanently even when unassigned — so moving
	## a maxed shop out of its slot frees that slot for another shop while the
	## bonus lives on. Surface that so players know how to reach 6+ bonuses.
	if maxed:
		var hint := Label.new()
		hint.text = "⭐ Maxed — its bonus is permanent. Move it out (Change Shop) to free this slot; you'll keep the bonus."
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", 9)
		hint.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
		box.add_child(hint)
	return box


## Management panel: X, deposit control, per-item list, progress, change shop.
func _build_manage_view(slot: int, shop_id: String) -> Control:
	var def := BusinessDistrict.get_shop_def(shop_id)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_PASS

	## Header row: name + X.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = str(def.get("name", "Shop"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	header.add_child(title)
	var x_btn := Button.new()
	x_btn.text = "X"
	x_btn.custom_minimum_size = Vector2(40, 40)
	x_btn.add_theme_font_size_override("font_size", 13)
	x_btn.pressed.connect(func():
		_view_mode[slot] = "auto"
		_rebuild_card(slot))
	header.add_child(x_btn)
	box.add_child(header)

	## Progress bar to next level.
	var prog := BusinessDistrict.progress_to_next(shop_id)
	var lvl := int(prog["level"])
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = float(prog["frac"])
	bar.custom_minimum_size = Vector2(0, 18)
	bar.show_percentage = false
	box.add_child(bar)
	var prog_lbl := Label.new()
	if bool(prog["is_max"]):
		prog_lbl.text = "Level 15 — MAXED (permanent bonus, no slot used)"
	else:
		prog_lbl.text = "Level %d  •  %s / %s to next" % [
			lvl,
			PlayerData.format_number(int(prog["into"])),
			PlayerData.format_number(int(prog["span"]))]
	prog_lbl.add_theme_font_size_override("font_size", 10)
	prog_lbl.add_theme_color_override("font_color", Color(0.85, 0.9, 0.85))
	box.add_child(prog_lbl)

	## Deposit row.
	box.add_child(_build_deposit_row(slot, shop_id))

	## Per-item deposited list.
	var by_item: Dictionary = BusinessDistrict.get_deposits_by_item(shop_id)
	if not by_item.is_empty():
		var dep_hdr := Label.new()
		dep_hdr.text = "Deposited:"
		dep_hdr.add_theme_font_size_override("font_size", 11)
		dep_hdr.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9))
		box.add_child(dep_hdr)
		for key in by_item:
			var row := Label.new()
			row.text = "  %s: %s" % [
				ItemKeyRegistry.display_name(key),
				PlayerData.format_number(int(by_item[key]))]
			row.add_theme_font_size_override("font_size", 10)
			row.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
			box.add_child(row)

	## Change Shop button (with 72h cooldown state).
	var change_btn := Button.new()
	change_btn.custom_minimum_size = Vector2(0, 40)
	change_btn.add_theme_font_size_override("font_size", 12)
	if BusinessDistrict.is_slot_locked(slot):
		var secs := BusinessDistrict.slot_cooldown_remaining(slot)
		change_btn.text = "Change Shop — locked (%s)" % _fmt_duration(secs)
		change_btn.disabled = true
	else:
		change_btn.text = "Change Shop"
		change_btn.pressed.connect(func(): _on_change_shop(slot))
	box.add_child(change_btn)
	return box


## Deposit control: accepted-item dropdown (with icon) + amount + Deposit.
func _build_deposit_row(slot: int, shop_id: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var accepted := BusinessDistrict.accepted_keys_for(shop_id)
	var dd := OptionButton.new()
	dd.add_theme_font_size_override("font_size", 12)
	dd.custom_minimum_size = Vector2(0, 40)
	for key in accepted:
		dd.add_item("%s  (have %s)" % [
			ItemKeyRegistry.display_name(key),
			PlayerData.format_number(PlayerData.market_count_owned(key))])
		dd.set_item_metadata(dd.item_count - 1, key)
		var tex := ItemKeyRegistry.get_texture(key)
		if tex != null:
			dd.set_item_icon(dd.item_count - 1, tex)
	box.add_child(dd)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var amount := SpinBox.new()
	amount.min_value = 1
	amount.max_value = 1_000_000_000
	amount.step = 1
	amount.value = 1
	amount.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	amount.custom_minimum_size = Vector2(0, 40)
	row.add_child(amount)
	var deposit_btn := Button.new()
	deposit_btn.text = "Deposit"
	deposit_btn.custom_minimum_size = Vector2(96, 40)
	deposit_btn.add_theme_font_size_override("font_size", 12)
	deposit_btn.pressed.connect(func():
		var idx := dd.get_selected()
		if idx < 0:
			_status.text = "Pick an item to deposit."
			return
		var key = dd.get_item_metadata(idx)
		if key is String:
			_on_deposit(slot, shop_id, key, int(amount.value)))
	row.add_child(deposit_btn)
	box.add_child(row)
	return box


## ── Actions ─────────────────────────────────────────────────────

## Shows a preview popup for a shop before the player commits to assigning it.
## Tapping "Select" calls _on_assign; "Cancel" resets the dropdown to no selection.
func _show_business_preview(slot: int, shop_id: String, dropdown: OptionButton) -> void:
	var def := BusinessDistrict.get_shop_def(shop_id)
	if def.is_empty():
		_on_assign(slot, shop_id)
		return

	## The Valentine's Valor keeps its effect a surprise.
	var raw_desc: String = str(def.get("desc", ""))
	var preview_desc: String = "Surprise!" if shop_id == "valentine" else raw_desc

	var dialog := ConfirmationDialog.new()
	dialog.title = str(def.get("name", shop_id))
	dialog.ok_button_text = "Select"
	dialog.get_cancel_button().text = "Cancel"
	dialog.dialog_autowrap = true
	dialog.dialog_text = preview_desc

	## Show the sprite above the text if available.
	var tex_path := str(def.get("sprite", ""))
	if tex_path != "" and ResourceLoader.exists(tex_path):
		var img_rect := TextureRect.new()
		img_rect.texture = load(tex_path)
		img_rect.custom_minimum_size = Vector2(96, 96)
		img_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		img_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		img_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dialog.add_child(img_rect)

	dialog.confirmed.connect(func():
		dialog.queue_free()
		_on_assign(slot, shop_id))
	dialog.canceled.connect(func():
		## Reset the dropdown back to the placeholder so a repeat tap works.
		if is_instance_valid(dropdown):
			dropdown.select(0)
		dialog.queue_free())
	dialog.close_requested.connect(func():
		if is_instance_valid(dropdown):
			dropdown.select(0)
		dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered(Vector2i(340, 0))


func _on_assign(slot: int, shop_id: String) -> void:
	var res: Dictionary = BusinessDistrict.assign_shop(slot, shop_id)
	if not res.get("ok", false):
		_status.text = _assign_error(str(res.get("error", "")))
		_rebuild_card(slot)  ## reset the dropdown
		return
	_status.text = ""
	_rebuild_card(slot)


func _on_deposit(slot: int, shop_id: String, item_key: String, qty: int) -> void:
	var res: Dictionary = BusinessDistrict.deposit(shop_id, item_key, qty)
	if not res.get("ok", false):
		_status.text = _deposit_error(str(res.get("error", "")))
		return
	_status.text = "Deposited %s %s." % [
		PlayerData.format_number(int(res.get("deposited", 0))),
		ItemKeyRegistry.display_name(item_key)]
	_rebuild_card(slot)  ## refresh progress + list + have-counts


func _on_change_shop(slot: int) -> void:
	## Clearing the slot returns it to the empty/dropdown state so the player can
	## pick a new shop. This starts the 72h lock (see assign_shop).
	var res: Dictionary = BusinessDistrict.assign_shop(slot, "")
	if not res.get("ok", false):
		_status.text = _assign_error(str(res.get("error", "")))
		return
	_view_mode[slot] = "auto"
	_rebuild_card(slot)


func _assign_error(code: String) -> String:
	match code:
		"slot_locked":         return "This slot is still on its 72-hour cooldown."
		"already_assigned":    return "That shop is already in another slot."
		"slot_limit_reached":  return "All active shop slots are full."
		_: return "Couldn't change this slot."


func _deposit_error(code: String) -> String:
	match code:
		"none_on_hand":     return "You don't have any of that item."
		"item_not_accepted":return "This shop doesn't accept that item."
		"invalid_qty":      return "Enter a valid amount."
		_: return "Deposit failed."


## Formats seconds as "Xd Yh" / "Xh Ym" / "Xm".
func _fmt_duration(secs: float) -> String:
	var s := int(secs)
	var days := s / 86400
	var hours := (s % 86400) / 3600
	var mins := (s % 3600) / 60
	if days > 0:
		return "%dd %dh" % [days, hours]
	if hours > 0:
		return "%dh %dm" % [hours, mins]
	return "%dm" % maxi(mins, 1)


func _safe_load(path: String) -> Texture2D:
	if path == "" or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()
