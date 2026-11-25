extends BaseScreen
## Garden screen — HUD stays viewport-centered; GardenUI scrolls only the plot grid.
## Connects to Garden autoload signals for live plot updates.
##
## Requirements: 1.2, 1.3, 1.5, 1.6, 9.1, 9.4, 11.1, 11.2


## ── Dynamic UI references (built in enter()) ─────────────────────
var _garden_ui: GardenUI = null


func enter(params: Dictionary = {}) -> void:
	# Hare heist: each ready crop rolls a small chance of being stolen. If a heist
	# is pending (new, or left unresolved last visit), send the player to the
	# chase mini game instead of building the garden.
	if Garden.roll_hare_heist():
		_get_navigator().navigate_to("hare_chase")
		return

	# Build the screen layout
	_build_ui()

	# Connect to Garden autoload signal for live updates (Req 9.1, 9.4)
	if not Garden.garden_updated.is_connected(_on_garden_updated):
		Garden.garden_updated.connect(_on_garden_updated)


func exit() -> void:
	# Disconnect Garden signals (Req 1.6)
	if Garden.garden_updated.is_connected(_on_garden_updated):
		Garden.garden_updated.disconnect(_on_garden_updated)

	# Clean up GardenUI reference
	if _garden_ui != null:
		_garden_ui = null

	# Clear dynamically built children
	for child in get_children():
		child.queue_free()


func get_screen_name() -> String:
	return "garden"


func show_top_bar() -> bool:
	return true


func get_background_override() -> String:
	return "res://Assets/Backgrounds/Summer1.png"


## ── Private: Build UI ────────────────────────────────────────────


func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.name = "GardenVBox"
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
	title.text = "Garden"
	title.theme_type_variation = &"HudLabel"
	title.add_theme_font_size_override("font_size", 14)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# GardenUI fills the remaining space. Its HUD is viewport-width; only the
	# plot grid scrolls (Req 11.1, 11.2).
	_garden_ui = GardenUI.new()
	_garden_ui.name = "GardenUI"
	_garden_ui.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_garden_ui.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_garden_ui)

	# Connect GardenUI coins_changed to refresh top bar via PlayerData
	_garden_ui.coins_changed.connect(_on_coins_changed)


## ── Private: Signal handlers ─────────────────────────────────────


func _on_garden_updated() -> void:
	if _garden_ui != null and is_instance_valid(_garden_ui):
		_garden_ui._rebuild_all()


func _on_coins_changed() -> void:
	# Trigger PlayerData save after harvest/purchase actions (Req 9.4)
	PlayerData.save_data()


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()
