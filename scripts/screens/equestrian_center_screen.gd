extends BaseScreen
## Equestrian Center hub — reached from Town. Four areas:
##   Stable      — buy/name/view/sell your active horses
##   Training    — mini-games (Task 3)
##   Pasture     — retired horses (view-only)
##   RaceTrack   — races, betting, replays (Task 8)
## Pure navigation hub; built in code (no .tscn layout) like the money gun screen.

const AREA_ICON_DIR := "res://Assets/Horse Racing/"


func get_screen_name() -> String:
	return "equestrian"


func enter(_params: Dictionary = {}) -> void:
	_build_ui()


func exit() -> void:
	for child in get_children():
		child.queue_free()


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

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	vbox.clip_contents = true
	panel.add_child(vbox)

	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(160, 44)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(func(): _get_navigator().navigate_back())
	vbox.add_child(back_btn)

	var title := Label.new()
	title.text = "🐴 Equestrian Center"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.9, 0.8, 0.5))
	vbox.add_child(title)

	var hint := Label.new()
	hint.text = "Buy, train, and race horses. Equip horseshoes, trade on the Horse Market (Race Track), and win cups for mythical breeds."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	vbox.add_child(hint)

	vbox.add_child(HSeparator.new())

	## Area buttons.
	for entry in [
		["stable",    "🐎 Stable",         "stable.png"],
		["pasture",   "🌾 Pasture",        "pasture.png"],
		["racetrack", "🏁 Race Track",     "racetrack.png"],
	]:
		vbox.add_child(_make_area_button(entry[0], entry[1], entry[2]))

	## Training lives on the Stable screen per-horse for now (a horse must be
	## selected to train), so the hub links Stable/Pasture/RaceTrack. A dedicated
	## Training area button is added in Task 3 if we build a standalone screen.


func _make_area_button(screen: String, label: String, icon_file: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(0, 56)
	btn.add_theme_font_size_override("font_size", 15)
	var icon_path := AREA_ICON_DIR + icon_file
	if ResourceLoader.exists(icon_path):
		btn.icon = load(icon_path)
		btn.add_theme_constant_override("icon_max_width", 32)
	btn.pressed.connect(func(): _get_navigator().navigate_to(screen))
	return btn
