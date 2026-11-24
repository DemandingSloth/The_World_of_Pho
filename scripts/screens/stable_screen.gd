extends BaseScreen
## Stable screen — view your active horses, buy new ones (with a name picker),
## and sell horses back to the game for coins. Horse ownership/stats are
## server-authoritative (HorseRacing autoload); coins are local.
## Built in code (no .tscn layout). Overflow-safe per the UI conventions.

## Preloaded by path so we don't depend on the global class_name cache being
## up to date (keeps headless tests + fresh checkouts from failing to parse).
const TrainingMinigameScene := preload("res://scripts/horse_racing/training_minigame.gd")
const HurdleMinigameScene := preload("res://scripts/horse_racing/hurdle_minigame.gd")
const SprintMinigameScene := preload("res://scripts/horse_racing/sprint_minigame.gd")

var _vbox: VBoxContainer = null
var _list: VBoxContainer = null
var _status: Label = null
var _coins_label: Label = null
var _feed_label: Label = null    ## owned-feed count in the feed shop row

## Buy row widgets.
var _breed_opt: OptionButton = null
var _name_edit: LineEdit = null          ## free-text name (pre-filled w/ a suggestion)
var _buy_btn: Button = null
var _price_label: Label = null


func get_screen_name() -> String:
	return "stable"


func enter(_params: Dictionary = {}) -> void:
	_build_ui()
	if not HorseRacing.horses_changed.is_connected(_on_horses_changed):
		HorseRacing.horses_changed.connect(_on_horses_changed)
	if not HorseRacing.training_changed.is_connected(_on_horses_changed):
		HorseRacing.training_changed.connect(_on_horses_changed)
	if not PlayerData.data_changed.is_connected(_refresh_coins):
		PlayerData.data_changed.connect(_refresh_coins)
	## Live-refresh the effective-stat display when jewelry equipment changes.
	if get_node_or_null("/root/JewelryBonus") != null \
			and not JewelryBonus.bonuses_changed.is_connected(_on_horses_changed):
		JewelryBonus.bonuses_changed.connect(_on_horses_changed)
	_set_status("Loading stable…")
	await HorseRacing.refresh()
	await HorseRacing.refresh_training()
	_rebuild()


func exit() -> void:
	if HorseRacing.horses_changed.is_connected(_on_horses_changed):
		HorseRacing.horses_changed.disconnect(_on_horses_changed)
	if HorseRacing.training_changed.is_connected(_on_horses_changed):
		HorseRacing.training_changed.disconnect(_on_horses_changed)
	if PlayerData.data_changed.is_connected(_refresh_coins):
		PlayerData.data_changed.disconnect(_refresh_coins)
	if get_node_or_null("/root/JewelryBonus") != null \
			and JewelryBonus.bonuses_changed.is_connected(_on_horses_changed):
		JewelryBonus.bonuses_changed.disconnect(_on_horses_changed)
	for child in get_children():
		child.queue_free()
	_vbox = null; _list = null; _status = null; _coins_label = null
	_feed_label = null
	_breed_opt = null; _name_edit = null
	_buy_btn = null; _price_label = null


func _on_horses_changed() -> void:
	_rebuild()


# ── UI build ──────────────────────────────────────────────────────

func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.clip_contents = true
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.12, 0.9)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10; style.content_margin_right = 10
	style.content_margin_top = 8; style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.scroll_deadzone = 16
	panel.add_child(scroll)

	_vbox = VBoxContainer.new()
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_theme_constant_override("separation", 8)
	_vbox.clip_contents = true
	_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.add_child(_vbox)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(120, 40)
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(func(): _get_navigator().navigate_back())
	top.add_child(back_btn)
	var title := Label.new()
	title.text = "🐎 Stable"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.9, 0.8, 0.5))
	top.add_child(title)
	_vbox.add_child(top)

	_coins_label = Label.new()
	_coins_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_coins_label.add_theme_font_size_override("font_size", 12)
	_coins_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_vbox.add_child(_coins_label)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", Color(0.85, 0.85, 0.8))
	_vbox.add_child(_status)

	_build_buy_section()

	_vbox.add_child(HSeparator.new())
	_build_feed_section()

	var sep := HSeparator.new()
	_vbox.add_child(sep)

	var hdr := Label.new()
	hdr.text = "Your Horses"
	hdr.add_theme_font_size_override("font_size", 13)
	hdr.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	_vbox.add_child(hdr)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	_list.clip_contents = true
	_vbox.add_child(_list)

	_refresh_coins()


func _build_buy_section() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var hdr := Label.new()
	hdr.text = "Buy a Horse"
	hdr.add_theme_font_size_override("font_size", 13)
	hdr.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6))
	box.add_child(hdr)

	## Breed picker.
	var breed_row := HBoxContainer.new()
	breed_row.add_theme_constant_override("separation", 6)
	var blbl := Label.new()
	blbl.text = "Breed:"
	blbl.add_theme_font_size_override("font_size", 11)
	breed_row.add_child(blbl)
	_breed_opt = OptionButton.new()
	_breed_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_breed_opt.clip_text = true
	_breed_opt.add_theme_font_size_override("font_size", 11)
	for breed in HorseRacing.purchasable_breeds():
		var d := HorseRacing.breed_def(breed)
		var idx := _breed_opt.item_count
		_breed_opt.add_item(str(d.get("name", breed)), idx)
		_breed_opt.set_item_metadata(idx, breed)
	_breed_opt.item_selected.connect(func(_i): _update_price())
	breed_row.add_child(_breed_opt)
	box.add_child(breed_row)

	## Stats + price preview.
	_price_label = Label.new()
	_price_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_price_label.add_theme_font_size_override("font_size", 10)
	_price_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.6))
	box.add_child(_price_label)

	## Name picker: a suggestion dropdown + a free-text field.
	## Name: a free-text box PRE-FILLED with a random suggestion the player can
	## keep, edit, or clear and type their own. The 🎲 button re-rolls the
	## suggestion. (The curated list is just a convenience, not a required pick.)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	var nlbl := Label.new()
	nlbl.text = "Name:"
	nlbl.add_theme_font_size_override("font_size", 11)
	name_row.add_child(nlbl)

	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.placeholder_text = "Name your horse"
	_name_edit.max_length = 24
	_name_edit.add_theme_font_size_override("font_size", 11)
	_name_edit.text = _random_suggestion()
	name_row.add_child(_name_edit)

	var shuffle_btn := Button.new()
	shuffle_btn.text = "🎲"
	shuffle_btn.tooltip_text = "Suggest a name"
	shuffle_btn.custom_minimum_size = Vector2(40, 0)
	shuffle_btn.add_theme_font_size_override("font_size", 14)
	shuffle_btn.pressed.connect(func(): _name_edit.text = _random_suggestion())
	name_row.add_child(shuffle_btn)

	box.add_child(name_row)

	_buy_btn = Button.new()
	_buy_btn.text = "Buy Horse"
	_buy_btn.custom_minimum_size = Vector2(0, 40)
	_buy_btn.add_theme_font_size_override("font_size", 13)
	_buy_btn.pressed.connect(_on_buy_pressed)
	box.add_child(_buy_btn)

	_vbox.add_child(box)
	_update_price()


## A random curated name to pre-fill / shuffle into the name box.
func _random_suggestion() -> String:
	var names := HorseRacing.name_suggestions()
	if names.is_empty():
		return ""
	return str(names[randi() % names.size()])


## Feed shop: shows owned feed + a buy button. Feed restores a horse's life
## (used from each horse row's "Feed" action). Feed is a local consumable.
func _build_feed_section() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var hdr := Label.new()
	hdr.text = "%s Horse Feed" % HorseRacing.FEED_ICON
	hdr.add_theme_font_size_override("font_size", 13)
	hdr.add_theme_color_override("font_color", Color(0.9, 0.75, 0.4))
	box.add_child(hdr)

	var desc := Label.new()
	desc.text = "Restores %d Life. Feed a horse from its row below." % HorseRacing.FEED_RESTORE
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 10)
	desc.add_theme_color_override("font_color", Color(0.8, 0.8, 0.75))
	box.add_child(desc)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	_feed_label = Label.new()
	_feed_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_feed_label.add_theme_font_size_override("font_size", 11)
	_feed_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.8))
	row.add_child(_feed_label)

	var buy_feed_btn := Button.new()
	buy_feed_btn.text = "Buy 1  (%s)" % PlayerData.format_number(HorseRacing.FEED_PRICE)
	buy_feed_btn.add_theme_font_size_override("font_size", 11)
	buy_feed_btn.custom_minimum_size = Vector2(0, 34)
	buy_feed_btn.pressed.connect(_on_buy_feed_pressed)
	row.add_child(buy_feed_btn)

	box.add_child(row)
	_vbox.add_child(box)
	_refresh_feed()


func _on_buy_feed_pressed() -> void:
	var res := HorseRacing.buy_feed(1)
	if res.get("ok", false):
		_set_status("Bought feed. You have %d." % HorseRacing.feed_count())
	else:
		_set_status(str(res.get("message", "Couldn't buy feed.")))


func _refresh_feed() -> void:
	if _feed_label != null:
		_feed_label.text = "Owned: %d" % HorseRacing.feed_count()


func _selected_breed() -> String:
	if _breed_opt == null or _breed_opt.selected < 0:
		return ""
	return str(_breed_opt.get_item_metadata(_breed_opt.selected))


func _update_price() -> void:
	if _price_label == null:
		return
	var breed := _selected_breed()
	if breed == "":
		_price_label.text = ""
		if _buy_btn != null:
			_buy_btn.disabled = true
		return
	var d := HorseRacing.breed_def(breed)
	var price := HorseRacing.buy_price(breed)
	var afford := PlayerData.coins >= price
	var room := HorseRacing.has_stable_room()
	_price_label.text = "Life %d · Speed %d · End %d  —  %s coins" % [
		int(d.get("life", 0)), int(d.get("speed", 0)), int(d.get("endurance", 0)),
		PlayerData.format_number(price)]
	## Red hint + disabled Buy when unaffordable or the stable is full.
	if not room:
		_price_label.text += "  (stable full)"
	_price_label.add_theme_color_override("font_color",
		Color(0.85, 0.85, 0.85) if (afford and room) else Color(1.0, 0.55, 0.5))
	if _buy_btn != null:
		_buy_btn.disabled = not (afford and room)


func _on_buy_pressed() -> void:
	var breed := _selected_breed()
	if breed == "":
		_set_status("Pick a breed first.")
		return
	var typed := _name_edit.text.strip_edges()
	if typed == "":
		_set_status("Give your horse a name.")
		return
	## Curated suggestions are pre-vetted; anything else goes through the full
	## name validator (profanity/char rules) via buy().
	var is_suggestion := HorseRacing.name_suggestions().has(typed)

	_buy_btn.disabled = true
	var res := await HorseRacing.buy(breed, typed, is_suggestion)
	_buy_btn.disabled = false
	if res.get("ok", false):
		_set_status("Bought %s the %s!" % [typed, HorseRacing.breed_def(breed).get("name", breed)])
		## Pre-fill a fresh suggestion for the next purchase.
		_name_edit.text = _random_suggestion()
	else:
		_set_status(str(res.get("message", "Couldn't buy that horse.")))


# ── List rendering ────────────────────────────────────────────────

func _rebuild() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		c.queue_free()
	_set_status("Stable: %d / %d" % [HorseRacing.active_count(), HorseRacing.stable_capacity])
	_refresh_coins()

	var active := HorseRacing.active_horses()
	if active.is_empty():
		var empty := Label.new()
		empty.text = "No horses yet — buy one above."
		empty.add_theme_font_size_override("font_size", 11)
		empty.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		_list.add_child(empty)
		return
	for h in active:
		_list.add_child(_make_horse_row(h))


func _make_horse_row(h: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.14, 0.13, 0.18, 0.9)
	style.set_corner_radius_all(6)
	style.content_margin_left = 8; style.content_margin_right = 8
	style.content_margin_top = 6; style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)

	## Breed sprite (sliced from the sheet; null-safe).
	var tex := HorseRacing.breed_texture(str(h.get("breed", "")))
	if tex != null:
		var frame := TextureRect.new()
		frame.texture = tex
		frame.custom_minimum_size = Vector2(56, 56)
		frame.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(frame)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = str(h.get("name", "?"))
	name_lbl.clip_text = true
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	info.add_child(name_lbl)

	var breed_lbl := Label.new()
	breed_lbl.text = str(HorseRacing.breed_def(str(h.get("breed", ""))).get("name", h.get("breed", "")))
	breed_lbl.add_theme_font_size_override("font_size", 10)
	breed_lbl.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9))
	info.add_child(breed_lbl)

	## EFFECTIVE stats (base × equipped-jewelry buffs). STACKED one per line so
	## they all fit in the narrow info column beside the action buttons (a single
	## line was getting truncated). A ✨ on the Life line marks an active buff.
	var eff := HorseRacing.effective_stats(h)
	var buffed := HorseRacing.has_jewelry_horse_buff()
	var stat_color := Color(0.7, 1.0, 0.8) if buffed else Color(0.85, 0.85, 0.85)
	var stat_lines := [
		"%s❤ %.2f / %.2f" % ["✨ " if buffed else "", float(eff.get("life", 0)), float(eff.get("life_cap", 0))],
		"⚡ %.2f   🏃 %.2f" % [float(eff.get("speed", 0)), float(eff.get("endurance", 0))],
		"🏆 %d wins" % int(h.get("wins", 0)),
	]
	for sline in stat_lines:
		var sl := Label.new()
		sl.text = str(sline)
		sl.add_theme_font_size_override("font_size", 10)
		sl.add_theme_color_override("font_color", stat_color)
		sl.clip_text = true
		sl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if buffed:
			sl.tooltip_text = "Boosted by equipped jewelry (emerald/pink). Base stats are unchanged."
		info.add_child(sl)

	## Right-side action column: Train (opens kind picker) + Sell.
	var actions := VBoxContainer.new()
	actions.add_theme_constant_override("separation", 4)
	actions.custom_minimum_size = Vector2(78, 0)
	row.add_child(actions)

	var horse_id := str(h.get("id", ""))
	var horse_name := str(h.get("name", ""))

	## Train button — enabled if ANY kind is still available today.
	var any_trainable := false
	for kind in HorseRacing.TRAINING_ORDER:
		if HorseRacing.can_train(horse_id, kind):
			any_trainable = true
			break
	var train_btn := Button.new()
	train_btn.text = "Train" if any_trainable else "Trained"
	train_btn.disabled = not any_trainable
	train_btn.add_theme_font_size_override("font_size", 10)
	train_btn.custom_minimum_size = Vector2(0, 30)
	train_btn.pressed.connect(_on_train_pressed.bind(horse_id, horse_name))
	actions.add_child(train_btn)

	## Feed button — restores Life. Disabled when full or no feed owned.
	var life := float(h.get("life", 0))
	var life_cap := float(h.get("life_cap", 0))
	var is_full := life >= life_cap
	var has_feed := HorseRacing.feed_count() > 0
	var feed_btn := Button.new()
	if is_full:
		feed_btn.text = "Full"
	elif not has_feed:
		feed_btn.text = "No Feed"
	else:
		feed_btn.text = "%s Feed" % HorseRacing.FEED_ICON
	feed_btn.disabled = is_full or not has_feed
	feed_btn.add_theme_font_size_override("font_size", 10)
	feed_btn.custom_minimum_size = Vector2(0, 30)
	feed_btn.pressed.connect(_on_feed_pressed.bind(horse_id, horse_name))
	actions.add_child(feed_btn)

	## Horseshoe button — equip copper (speed) / iron (endurance) if owned.
	var shoe := str(h.get("horseshoe", ""))
	var shoe_btn := Button.new()
	if shoe == "":
		shoe_btn.text = "👟 Shoe"
	else:
		shoe_btn.text = "%s On" % str(HorseRacing.horseshoe_def(shoe).get("icon", "👟"))
	shoe_btn.add_theme_font_size_override("font_size", 10)
	shoe_btn.custom_minimum_size = Vector2(0, 30)
	shoe_btn.pressed.connect(_on_horseshoe_pressed.bind(horse_id, horse_name))
	actions.add_child(shoe_btn)

	## List on the player horse market (tokens). Opens a price dialog.
	var mkt_btn := Button.new()
	mkt_btn.text = "🎟 List"
	mkt_btn.tooltip_text = "List this horse on the player market for tokens"
	mkt_btn.add_theme_font_size_override("font_size", 10)
	mkt_btn.custom_minimum_size = Vector2(0, 28)
	mkt_btn.pressed.connect(_on_list_market_pressed.bind(horse_id, horse_name, h))
	actions.add_child(mkt_btn)

	## Sell button (shows the coin value).
	var sell_price := HorseRacing.sell_price_for(
		float(h.get("life", 0)), float(h.get("speed", 0)), float(h.get("endurance", 0)))
	var sell_btn := Button.new()
	sell_btn.text = "🪙 Sell %s" % PlayerData.format_number(sell_price)
	sell_btn.add_theme_font_size_override("font_size", 9)
	sell_btn.custom_minimum_size = Vector2(0, 28)
	sell_btn.pressed.connect(_on_sell_pressed.bind(horse_id, horse_name, sell_btn))
	actions.add_child(sell_btn)

	return panel


# ── Training ──────────────────────────────────────────────────────

func _on_train_pressed(horse_id: String, horse_name: String) -> void:
	## While a session is still being saved, the counts may not be final yet.
	if _training_busy:
		_set_status("Saving the last training session… try again in a moment.")
		return
	## A small picker: one button per training kind, disabled if unavailable.
	var dialog := AcceptDialog.new()
	dialog.title = "Train %s" % horse_name
	dialog.ok_button_text = "Close"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.custom_minimum_size = Vector2(260, 0)

	for kind in HorseRacing.TRAINING_ORDER:
		var d := HorseRacing.training_def(kind)
		var avail := HorseRacing.can_train(horse_id, kind)
		var h := HorseRacing.horse_by_id(horse_id)
		var at_cap := false
		if not h.is_empty():
			at_cap = float(h.get(str(d.get("stat", "")), 0)) >= float(d.get("ceiling", 0))
		var btn := Button.new()
		var suffix := ""
		if at_cap:
			suffix = "  (maxed)"
		else:
			var rem := HorseRacing.training_sessions_remaining(horse_id, kind)
			suffix = "  (%d/3 left)" % rem
		btn.text = "%s %s — %s%s" % [
			str(d.get("icon", "")), str(d.get("name", kind)), str(d.get("blurb", "")), suffix]
		btn.disabled = not avail
		btn.custom_minimum_size = Vector2(0, 40)
		btn.add_theme_font_size_override("font_size", 11)
		btn.pressed.connect(func():
			dialog.queue_free()
			_start_training(horse_id, horse_name, kind))
		box.add_child(btn)

	## When the 3/day counters reset (UTC midnight, not local midnight), and a
	## note that guild paddock sessions count toward the same limit.
	var reset_lbl := Label.new()
	reset_lbl.text = "Each kind: 3 sessions per day, shared with the guild paddock. Counters %s." % \
		HorseRacing.training_reset_text()
	reset_lbl.add_theme_font_size_override("font_size", 10)
	reset_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reset_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(reset_lbl)

	dialog.add_child(box)
	add_child(dialog)
	dialog.popup_centered(Vector2i(300, 0))
	dialog.close_requested.connect(dialog.queue_free)
	dialog.confirmed.connect(dialog.queue_free)


## Life at or below this before a sprint/hurdle run triggers a "tired" warning.
const LOW_LIFE_WARN := 5.0


## Gate the mini-game behind a low-life warning for the life-draining kinds
## (sprint/hurdle). Groom costs no life and launches straight away.
func _start_training(horse_id: String, horse_name: String, kind: String) -> void:
	var drains_life := kind == "sprint" or kind == "hurdle"
	if drains_life:
		var h := HorseRacing.horse_by_id(horse_id)
		var life := float(h.get("life", 0))
		if life <= LOW_LIFE_WARN:
			var warn := ConfirmationDialog.new()
			warn.title = "%s is tired" % horse_name
			warn.dialog_text = "%s has only %.2f life left.\nTraining drains 1–5 life — if it hits 0, %s is RETIRED to the pasture for good.\n\nFeed it first, or train anyway?" % [horse_name, life, horse_name]
			warn.ok_button_text = "Train anyway"
			add_child(warn)
			warn.confirmed.connect(func():
				warn.queue_free()
				_launch_minigame(horse_id, horse_name, kind))
			warn.canceled.connect(warn.queue_free)
			warn.close_requested.connect(warn.queue_free)
			warn.popup_centered(Vector2i(340, 0))
			return
	_launch_minigame(horse_id, horse_name, kind)


func _launch_minigame(horse_id: String, horse_name: String, kind: String) -> void:
	var d := HorseRacing.training_def(kind)
	var breed := str(HorseRacing.horse_by_id(horse_id).get("breed", "thoroughbred"))
	var game: Control
	match kind:
		"hurdle":
			## Chrome-dino-style endless runner (jump hurdles until a miss).
			var hg := HurdleMinigameScene.new()
			hg.setup(breed, "%s — jump the hurdles!" % horse_name)
			game = hg
		"sprint":
			## Traffic-light reaction runner (tap on green, stop on red).
			var sg := SprintMinigameScene.new()
			sg.setup(breed, "%s — tap on green, stop on red!" % horse_name)
			game = sg
		_:
			## Groom is a brush-swipe game over the horse's breed sprite.
			var tg := TrainingMinigameScene.new()
			tg.setup("%s %s" % [str(d.get("icon", "")), str(d.get("name", kind))],
				"%s — brush over the horse!" % horse_name, Color(0.85, 0.6, 1.0))
			tg.set_breed(breed)
			game = tg
	add_child(game)
	game.finished.connect(func(score: int):
		if score < 0:
			_set_status("Training cancelled.")
			return
		await _apply_training(horse_id, horse_name, kind, score))


## True while a training result is being sent + the counts refreshed. Blocks
## re-opening the Train picker with stale "n/3 left" numbers.
var _training_busy := false


func _apply_training(horse_id: String, horse_name: String, kind: String, score: int) -> void:
	_set_status("Training %s…" % horse_name)
	_training_busy = true
	var res := await HorseRacing.train(horse_id, kind, score)
	_training_busy = false
	if not res.get("ok", false):
		_set_status(str(res.get("message", "Couldn't train.")))
		return

	var d := HorseRacing.training_def(kind)
	var gain := float(res.get("gain", 0))
	var life_cost := int(res.get("life_cost", 0))
	if bool(res.get("retired", false)):
		## The horse collapsed from exhaustion on this run — now in the pasture.
		var msg := "%s gave its all (+%.2f %s) but collapsed from exhaustion and was retired to the pasture." % [
			horse_name, gain, str(d.get("name", kind))]
		_set_status(msg)
		if get_node_or_null("/root/GameNotification") != null:
			GameNotification.show_message("%s Retired" % horse_name, msg)
	elif life_cost > 0:
		_set_status("%s trained! +%.2f %s (score %d, −%d life)" % [
			horse_name, gain, str(d.get("name", kind)), score, life_cost])
	else:
		_set_status("%s trained! +%.2f %s (score %d)" % [
			horse_name, gain, str(d.get("name", kind)), score])


func _on_feed_pressed(horse_id: String, horse_name: String) -> void:
	_set_status("Feeding %s…" % horse_name)
	var res := await HorseRacing.feed(horse_id)
	if res.get("ok", false):
		_set_status("Fed %s (+%d Life)." % [horse_name, int(res.get("restored", 0))])
	else:
		_set_status(str(res.get("message", "Couldn't feed.")))


func _on_sell_pressed(horse_id: String, horse_name: String, btn: Button) -> void:
	## Confirm (selling is permanent).
	var dialog := ConfirmationDialog.new()
	dialog.title = "Sell %s?" % horse_name
	dialog.dialog_text = "Sell %s back to the game for coins?\nThis is permanent." % horse_name
	dialog.ok_button_text = "Sell"
	add_child(dialog)
	dialog.confirmed.connect(func():
		dialog.queue_free()
		btn.disabled = true
		var res := await HorseRacing.sell(horse_id)
		if res.get("ok", false):
			_set_status("Sold %s for %s coins." % [horse_name, PlayerData.format_number(int(res.get("price", 0)))])
		else:
			_set_status(str(res.get("message", "Couldn't sell.")))
			btn.disabled = false)
	dialog.canceled.connect(dialog.queue_free)
	dialog.close_requested.connect(dialog.queue_free)
	dialog.popup_centered(Vector2i(320, 0))


func _refresh_coins() -> void:
	if _coins_label != null:
		_coins_label.text = "🪙 %s coins" % PlayerData.format_number(PlayerData.coins)
	_refresh_feed()
	_update_price()   ## re-evaluate Buy affordability when coins change


func _set_status(t: String) -> void:
	if _status != null:
		_status.text = t


# ── Horseshoes ────────────────────────────────────────────────────

## Opens a small picker to equip copper/iron horseshoe (or remove it). Each
## option shows how many you own + the bonus level it would grant (count-scaled).
func _on_horseshoe_pressed(horse_id: String, horse_name: String) -> void:
	var h := HorseRacing.horse_by_id(horse_id)
	var current := str(h.get("horseshoe", ""))

	var dialog := AcceptDialog.new()
	dialog.title = "Horseshoe — %s" % horse_name
	dialog.ok_button_text = "Close"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.custom_minimum_size = Vector2(280, 0)

	var blurb := Label.new()
	blurb.text = "Copper boosts race Speed, iron boosts Endurance. The bonus grows with how many of that shoe you own."
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_font_size_override("font_size", 10)
	blurb.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	box.add_child(blurb)

	for hs_type in HorseRacing.HORSESHOE_TYPES:
		var def := HorseRacing.horseshoe_def(hs_type)
		var owned := HorseRacing.horseshoe_count(hs_type)
		var lvl := HorseRacing.horseshoe_level(hs_type)
		var equipped: bool = (current == hs_type)
		var btn := Button.new()
		var tag: String = "  ✓ equipped" if equipped else ""
		btn.text = "%s %s  — own %d (Lv.%d)%s" % [
			str(def.get("icon", "")), str(def.get("name", hs_type)), owned, lvl, tag]
		btn.add_theme_font_size_override("font_size", 11)
		btn.custom_minimum_size = Vector2(0, 34)
		btn.disabled = owned <= 0 or equipped
		btn.pressed.connect(func():
			dialog.queue_free()
			await _do_equip_horseshoe(horse_id, horse_name, hs_type))
		box.add_child(btn)

	if current != "":
		var clear_btn := Button.new()
		clear_btn.text = "Remove horseshoe"
		clear_btn.add_theme_font_size_override("font_size", 10)
		clear_btn.custom_minimum_size = Vector2(0, 30)
		clear_btn.pressed.connect(func():
			dialog.queue_free()
			await _do_equip_horseshoe(horse_id, horse_name, ""))
		box.add_child(clear_btn)

	dialog.add_child(box)
	add_child(dialog)
	dialog.popup_centered(Vector2i(320, 0))
	dialog.close_requested.connect(dialog.queue_free)
	dialog.confirmed.connect(dialog.queue_free)


func _do_equip_horseshoe(horse_id: String, horse_name: String, hs_type: String) -> void:
	var res := await HorseRacing.equip_horseshoe(horse_id, hs_type)
	if not res.get("ok", false):
		_set_status(str(res.get("message", "Couldn't equip.")))
		return
	if hs_type == "":
		_set_status("Removed %s's horseshoe." % horse_name)
	else:
		_set_status("Equipped a %s on %s." % [
			str(HorseRacing.horseshoe_def(hs_type).get("name", "horseshoe")), horse_name])


# ── Horse market (list for tokens) ────────────────────────────────

## Opens a price dialog to list a horse on the player market. Pre-fills the
## suggested token price (coin buyback / 10); the player may set any value.
func _on_list_market_pressed(horse_id: String, horse_name: String, h: Dictionary) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "List %s on the Market" % horse_name
	dialog.ok_button_text = "Cancel"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.custom_minimum_size = Vector2(280, 0)

	var blurb := Label.new()
	blurb.text = "List this horse on the player market for 🎟 tokens. While listed it can't race, and retired horses can't be listed."
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_font_size_override("font_size", 10)
	blurb.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	box.add_child(blurb)

	var suggested := HorseRacing.horse_market_suggested_price(h)
	var sug_lbl := Label.new()
	sug_lbl.text = "Suggested: 🎟 %s" % PlayerData.format_number(suggested)
	sug_lbl.add_theme_font_size_override("font_size", 11)
	sug_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	box.add_child(sug_lbl)

	var price_edit := LineEdit.new()
	price_edit.placeholder_text = "price in tokens"
	price_edit.text = str(suggested)
	price_edit.add_theme_font_size_override("font_size", 12)
	box.add_child(price_edit)

	var list_btn := Button.new()
	list_btn.text = "List for Sale"
	list_btn.custom_minimum_size = Vector2(0, 40)
	list_btn.add_theme_font_size_override("font_size", 13)
	list_btn.pressed.connect(func():
		var price := int(price_edit.text.strip_edges())
		dialog.queue_free()
		await _do_list_market(horse_id, horse_name, price))
	box.add_child(list_btn)

	dialog.add_child(box)
	add_child(dialog)
	dialog.popup_centered(Vector2i(320, 0))
	dialog.close_requested.connect(dialog.queue_free)
	dialog.confirmed.connect(dialog.queue_free)


func _do_list_market(horse_id: String, horse_name: String, price: int) -> void:
	_set_status("Listing %s…" % horse_name)
	var res := await HorseRacing.list_horse(horse_id, price)
	if res.get("ok", false):
		_set_status("%s listed for 🎟 %s. See the Horse Market at the Race Track." % [
			horse_name, PlayerData.format_number(price)])
	else:
		_set_status(str(res.get("message", "Couldn't list.")))
