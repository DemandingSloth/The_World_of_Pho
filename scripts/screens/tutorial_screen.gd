extends BaseScreen
## Tutorial screen — tabbed "How to Play" view showing piece definitions and game rules.
## Uses TutorialData helper to pull live data from PieceRegistry.
##
## Requirements: 1.2, 1.3, 1.5, 1.6


@onready var tab_pieces_btn: Button = $VBox/TabBar/TabPieces
@onready var tab_rules_btn: Button = $VBox/TabBar/TabRules
@onready var back_btn: Button = $VBox/TopBar/BackBtn
@onready var tutorial_content: VBoxContainer = $VBox/TutorialScroll/TutorialContent


func _ready() -> void:
	tab_pieces_btn.pressed.connect(_build_tutorial_pieces)
	tab_rules_btn.pressed.connect(_build_tutorial_rules)
	back_btn.pressed.connect(_on_back_pressed)


func enter(params: Dictionary = {}) -> void:
	_build_tutorial_pieces()


func exit() -> void:
	pass


func get_screen_name() -> String:
	return "tutorial"


## ── Private: Tab builders ────────────────────────────────────────


func _build_tutorial_pieces() -> void:
	_clear_content()
	tab_pieces_btn.modulate = Color(1.0, 0.85, 0.2)
	tab_rules_btn.modulate = Color.WHITE

	for entry in TutorialData.get_piece_entries():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		# Piece icon button
		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(52, 52)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var icon := PieceSprites.get_icon(
			Piece.create(entry["type"], Piece.Owner.PLAYER).get_sprite_index())
		if icon:
			icon_btn.icon = icon
			icon_btn.expand_icon = true
		var icon_style := StyleBoxFlat.new()
		icon_style.bg_color = Color(0.18, 0.18, 0.28)
		icon_style.border_width_left = 1
		icon_style.border_width_right = 1
		icon_style.border_width_top = 1
		icon_style.border_width_bottom = 1
		icon_style.border_color = Color(0.35, 0.35, 0.5)
		icon_btn.add_theme_stylebox_override("normal", icon_style)
		row.add_child(icon_btn)

		# Piece info
		var vbox := VBoxContainer.new()
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var name_lbl := Label.new()
		name_lbl.text = "%s  —  %s" % [entry["name"], entry["points"]]
		name_lbl.add_theme_font_size_override("font_size", 13)
		name_lbl.modulate = Color(1.0, 0.9, 0.5)
		vbox.add_child(name_lbl)

		var effect_lbl := Label.new()
		effect_lbl.text = entry["effect"]
		effect_lbl.add_theme_font_size_override("font_size", 11)
		effect_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(effect_lbl)

		var tip_lbl := Label.new()
		tip_lbl.text = "Tip: " + entry["tip"]
		tip_lbl.add_theme_font_size_override("font_size", 10)
		tip_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tip_lbl.modulate = Color(0.7, 0.9, 0.7)
		vbox.add_child(tip_lbl)

		row.add_child(vbox)
		tutorial_content.add_child(row)

		var sep := HSeparator.new()
		tutorial_content.add_child(sep)


func _build_tutorial_rules() -> void:
	_clear_content()
	tab_pieces_btn.modulate = Color.WHITE
	tab_rules_btn.modulate = Color(1.0, 0.85, 0.2)

	for section in TutorialData.get_rules_sections():
		var title_lbl := Label.new()
		title_lbl.text = section["title"]
		title_lbl.add_theme_font_size_override("font_size", 14)
		title_lbl.modulate = Color(1.0, 0.85, 0.3)
		tutorial_content.add_child(title_lbl)

		var body_lbl := Label.new()
		body_lbl.text = section["body"]
		body_lbl.add_theme_font_size_override("font_size", 11)
		body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tutorial_content.add_child(body_lbl)

		var sep := HSeparator.new()
		tutorial_content.add_child(sep)


func _clear_content() -> void:
	for child in tutorial_content.get_children():
		child.queue_free()


## ── Private: Navigation ──────────────────────────────────────────


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()
