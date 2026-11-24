extends BaseScreen
## Prospectors screen — buy and manage gem prospectors that passively produce gems.
## Each prospector produces 1 gem of its type every 30 minutes, accruing up to 24 hrs offline.

var _list_container: VBoxContainer = null
var _status_label: Label = null
var _collect_timer: Timer = null


func enter(params: Dictionary = {}) -> void:
	# Collect any pending ticks since the last collect (startup already claimed offline).
	var collected := PlayerData.collect_prospector_gems()

	_build_ui(collected)

	# Live tick timer — fire when the current production cycle actually completes
	_collect_timer = Timer.new()
	_collect_timer.one_shot = true
	_collect_timer.wait_time = maxf(PlayerData.get_prospector_next_tick_remaining(), 0.05)
	_collect_timer.timeout.connect(_on_collect_tick)
	add_child(_collect_timer)
	_collect_timer.start()

	PlayerData.data_changed.connect(_on_data_changed)


func exit() -> void:
	if PlayerData.data_changed.is_connected(_on_data_changed):
		PlayerData.data_changed.disconnect(_on_data_changed)
	for child in get_children():
		child.queue_free()
	_list_container = null
	_status_label = null
	_collect_timer = null


func get_screen_name() -> String:
	return "prospectors"


func _build_ui(collected: Dictionary) -> void:
	# Dark semi-transparent panel for readability
	var panel := PanelContainer.new()
	panel.name = "BgPanel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.08, 0.08, 0.12, 0.88)
	panel_style.corner_radius_top_left = 6
	panel_style.corner_radius_top_right = 6
	panel_style.corner_radius_bottom_left = 6
	panel_style.corner_radius_bottom_right = 6
	panel_style.content_margin_left = 8
	panel_style.content_margin_right = 8
	panel_style.content_margin_top = 6
	panel_style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", panel_style)
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "Prospectors"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	vbox.add_child(title)

	# Back button
	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(200, 48)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(_on_back_pressed)
	vbox.add_child(back_btn)

	# Description
	var desc := Label.new()
	desc.text = "Hire prospectors to passively mine gems for you.\nEach produces 1 gem every 30 minutes (up to 24hrs offline)."
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 11)
	desc.add_theme_color_override("font_color", Color(0.85, 0.85, 0.75))
	vbox.add_child(desc)

	# Collection report (if we just collected something)
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
	vbox.add_child(_status_label)
	_show_collection_report(collected)

	# Coins display
	var coins_label := Label.new()
	coins_label.name = "CoinsLabel"
	coins_label.text = "Coins: %s" % PlayerData.format_number(PlayerData.coins)
	coins_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	coins_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(coins_label)

	# Separator
	var sep := HSeparator.new()
	vbox.add_child(sep)

	# Prospector list
	_list_container = VBoxContainer.new()
	_list_container.add_theme_constant_override("separation", 8)
	vbox.add_child(_list_container)

	_rebuild_prospector_list()


func _rebuild_prospector_list() -> void:
	if _list_container == null:
		return
	for child in _list_container.get_children():
		child.queue_free()

	for i in range(PlayerData.PROSPECTOR_GEM_ORDER.size()):
		var gem_def: Dictionary = PlayerData.PROSPECTOR_GEM_ORDER[i]
		var gem_type: String = gem_def["gem_type"]
		var gem_value: int = gem_def["value"]
		var owned: int = PlayerData.get_prospector_count(gem_type)
		var price: int = PlayerData.get_prospector_price(gem_type)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		# Gem icon
		var icon_rect := TextureRect.new()
		var gem_tex: Texture2D = load("res://Assets/GoldPanning/Gemstones/%s.png" % gem_type)
		if gem_tex:
			icon_rect.texture = gem_tex
		icon_rect.custom_minimum_size = Vector2(40, 40)
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(icon_rect)

		# Info column
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var name_lbl := Label.new()
		name_lbl.text = "%s Prospector" % gem_type.replace("_", " ").capitalize()
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
		info.add_child(name_lbl)

		var detail_lbl := Label.new()
		detail_lbl.text = "Owned: %d  |  Gem value: %s  |  1 gem / 30 min each" % [owned, PlayerData.format_number(gem_value)]
		detail_lbl.add_theme_font_size_override("font_size", 10)
		detail_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
		info.add_child(detail_lbl)

		row.add_child(info)

		# Buy button
		var buy_btn := Button.new()
		buy_btn.text = "Buy\n%s" % PlayerData.format_number(price)
		buy_btn.add_theme_font_size_override("font_size", 10)
		buy_btn.custom_minimum_size = Vector2(64, 48)
		buy_btn.disabled = PlayerData.coins < price
		buy_btn.pressed.connect(_on_buy_prospector.bind(gem_type))
		row.add_child(buy_btn)

		_list_container.add_child(row)


func _on_buy_prospector(gem_type: String) -> void:
	var success := PlayerData.buy_prospector(gem_type)
	if success:
		_rebuild_prospector_list()
		_update_coins_label()
	else:
		if _status_label:
			_status_label.text = "Not enough coins!"
			_status_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))


func _on_collect_tick() -> void:
	var collected := PlayerData.collect_prospector_gems()
	if not collected.is_empty():
		_show_collection_report(collected)
		_rebuild_prospector_list()
		_update_coins_label()
	if _collect_timer:
		_collect_timer.wait_time = maxf(PlayerData.get_prospector_next_tick_remaining(), 0.05)
		_collect_timer.start()


func _on_data_changed() -> void:
	_update_coins_label()
	_rebuild_prospector_list()


func _update_coins_label() -> void:
	var coins_lbl = find_child("CoinsLabel", true, false)
	if coins_lbl:
		coins_lbl.text = "Coins: %s" % PlayerData.format_number(PlayerData.coins)


func _show_collection_report(collected: Dictionary) -> void:
	if _status_label == null:
		return
	if collected.is_empty():
		_status_label.text = ""
		return
	var parts: Array = []
	for gt in collected:
		parts.append("+%d %s" % [collected[gt], gt.replace("_", " ").capitalize()])
	_status_label.text = "Collected: %s" % ", ".join(parts)
	_status_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()
