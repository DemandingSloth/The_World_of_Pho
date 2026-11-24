extends BaseScreen
## Achievements screen — displays all achievements with progress, supports live updates.
## Reads all data from the Achievements autoload singleton.
##
## Requirements: 1.2, 1.3, 1.5, 1.6, 9.1, 9.3


@onready var ach_grid: VBoxContainer = $VBox/AchScroll/AchPanel/AchGrid
@onready var ach_panel: PanelContainer = $VBox/AchScroll/AchPanel
@onready var back_btn: Button = $VBox/TopRow/BackBtn
@onready var top_row: HBoxContainer = $VBox/TopRow

var _hide_completed: bool = false
var _toggle_btn: Button = null


func enter(params: Dictionary = {}) -> void:
	# Connect back button
	back_btn.pressed.connect(_on_back_pressed)

	# Add hide-completed toggle button to TopRow
	_toggle_btn = Button.new()
	_toggle_btn.name = "HideCompletedBtn"
	_toggle_btn.add_theme_font_size_override("font_size", 11)
	_toggle_btn.custom_minimum_size = Vector2(110, 40)
	_toggle_btn.toggle_mode = true
	_toggle_btn.toggled.connect(_on_hide_completed_toggled)
	top_row.add_child(_toggle_btn)
	# Insert before BackBtn so order is: Title | Hide Toggle | Back
	top_row.move_child(_toggle_btn, back_btn.get_index())
	_update_toggle_label()

	# Apply dark panel background for readability
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.08, 0.08, 0.12, 0.9)
	panel_style.corner_radius_top_left = 6
	panel_style.corner_radius_top_right = 6
	panel_style.corner_radius_bottom_left = 6
	panel_style.corner_radius_bottom_right = 6
	panel_style.content_margin_left = 8
	panel_style.content_margin_right = 8
	panel_style.content_margin_top = 6
	panel_style.content_margin_bottom = 6
	ach_panel.add_theme_stylebox_override("panel", panel_style)

	# Connect to Achievements signal for live updates while on screen (Req 1.5)
	Achievements.achievement_unlocked.connect(_on_achievement_unlocked)

	# Build the achievements list from current state (Req 9.3)
	_rebuild_achievements_list()


func exit() -> void:
	# Disconnect all autoload signals (Req 1.6, 10.2)
	if Achievements.achievement_unlocked.is_connected(_on_achievement_unlocked):
		Achievements.achievement_unlocked.disconnect(_on_achievement_unlocked)

	# Clean up dynamically added button
	if _toggle_btn != null and is_instance_valid(_toggle_btn):
		_toggle_btn.queue_free()
		_toggle_btn = null


func get_screen_name() -> String:
	return "achievements"


## ── Private: Build/rebuild achievement list ──────────────────────


func _rebuild_achievements_list() -> void:
	# Clear existing entries
	for child in ach_grid.get_children():
		child.queue_free()

	# Build from Achievements autoload (Req 9.1)
	var all_achievements := Achievements.get_all_achievements()
	for data in all_achievements:
		# Skip completed achievements when filter is active
		if _hide_completed and data["is_complete"]:
			continue

		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 2)

		# Title + level/status
		var title_lbl := Label.new()
		title_lbl.add_theme_font_size_override("font_size", 13)
		title_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
		if data["type"] == "tiered":
			var level_text := "Level %d/%d" % [data["current_level"], data["max_level"]] if data["current_level"] > 0 else "Not started"
			title_lbl.text = "  %s — %s" % [data["title"], level_text]
		else:
			var status := "✓ Complete" if data["is_complete"] else "Incomplete"
			title_lbl.text = "  %s — %s" % [data["title"], status]
		row.add_child(title_lbl)

		# Description + progress
		var desc_lbl := Label.new()
		desc_lbl.add_theme_font_size_override("font_size", 11)
		desc_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.8))
		if data["type"] == "tiered":
			var threshold: int = data["threshold"]
			var desc_text: String = data["description"] % threshold
			desc_lbl.text = "  %s (Progress: %d/%d)" % [desc_text, data["progress"], threshold]
		else:
			var threshold: int = data["threshold"]
			if threshold > 1 and not data["is_complete"]:
				desc_lbl.text = "  %s (Progress: %d/%d)" % [data["description"], data["progress"], threshold]
			else:
				desc_lbl.text = "  %s" % data["description"]
		row.add_child(desc_lbl)

		ach_grid.add_child(row)

		# Separator
		var sep := HSeparator.new()
		ach_grid.add_child(sep)


## ── Private: Signal handlers ─────────────────────────────────────


func _on_achievement_unlocked(_achievement_id: String, _level: int, _chest_level: int) -> void:
	# Rebuild list to reflect the update
	_rebuild_achievements_list()


func _on_hide_completed_toggled(pressed: bool) -> void:
	_hide_completed = pressed
	_update_toggle_label()
	_rebuild_achievements_list()


func _update_toggle_label() -> void:
	if _toggle_btn == null:
		return
	if _hide_completed:
		_toggle_btn.text = "Show All"
		_toggle_btn.modulate = Color(1.0, 0.75, 0.3)
	else:
		_toggle_btn.text = "Hide Done"
		_toggle_btn.modulate = Color.WHITE


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()
