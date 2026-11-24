extends BaseScreen

## Orchard screen — HUD stays viewport-centered; OrchardUI scrolls the plot grid.
## Connects to Orchard autoload signals for live plot updates.

var _orchard_ui: OrchardUI = null


func enter(params: Dictionary = {}) -> void:
	_build_ui()
	if get_node_or_null("/root/Orchard") != null:
		if not Orchard.orchard_updated.is_connected(_on_orchard_updated):
			Orchard.orchard_updated.connect(_on_orchard_updated)


func exit() -> void:
	if get_node_or_null("/root/Orchard") != null:
		if Orchard.orchard_updated.is_connected(_on_orchard_updated):
			Orchard.orchard_updated.disconnect(_on_orchard_updated)

	if _orchard_ui != null:
		_orchard_ui = null

	for child in get_children():
		child.queue_free()


func get_screen_name() -> String:
	return "orchard"


func show_top_bar() -> bool:
	return true


func get_background_override() -> String:
	return "res://Assets/Backgrounds/Summer1.png"


func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.name = "OrchardVBox"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 4)
	add_child(vbox)

	# Back button
	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(200, 48)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(_on_back_pressed)
	vbox.add_child(back_btn)

	# Title label
	var title := Label.new()
	title.text = "🌳 The Orchard"
	title.add_theme_font_size_override("font_size", 15)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# OrchardUI fills remaining space
	_orchard_ui = OrchardUI.new()
	_orchard_ui.name = "OrchardUI"
	_orchard_ui.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_orchard_ui.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_orchard_ui)

	_orchard_ui.coins_changed.connect(_on_coins_changed)


func _on_orchard_updated() -> void:
	pass


func _on_coins_changed() -> void:
	PlayerData.save_data()


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()
