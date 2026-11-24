extends BaseScreen
## Campaign setup screen — lets the player choose difficulty (enemy count),
## terrain type, and enemy type before starting a campaign battle.
##
## Requirements: 1.2, 1.3, 6.3, 9.1


@onready var terrain_option: OptionButton = $MarginContainer/SetupVBox/TerrainOption
@onready var start_campaign_btn: Button = $MarginContainer/SetupVBox/StartCampaignBtn
@onready var back_to_home_btn: Button = $MarginContainer/SetupVBox/BackToHomeBtn
@onready var tutorial_btn: Button = $MarginContainer/SetupVBox/TutorialBtn
@onready var btn_easy: Button = $MarginContainer/SetupVBox/EnemyCountBtns/BtnEasy
@onready var btn_medium: Button = $MarginContainer/SetupVBox/EnemyCountBtns/BtnMedium
@onready var btn_hard: Button = $MarginContainer/SetupVBox/EnemyCountBtns/BtnHard
@onready var btn_brutal: Button = $MarginContainer/SetupVBox/EnemyCountBtns/BtnBrutal

var selected_enemy_count: int = -1
var selected_board_size: int = 4  ## Default to 4x4
var enemy_type_option: OptionButton
var _board_size_btns: Array = []


func enter(params: Dictionary = {}) -> void:
	# Populate terrain dropdown (Req 6.3)
	terrain_option.clear()
	terrain_option.add_item("Random", 99)
	for t in Terrain.Type.values():
		terrain_option.add_item(Terrain.get_terrain_name(t as Terrain.Type), t)
	terrain_option.selected = 0

	# Build enemy type dropdown (for testing)
	_build_enemy_type_dropdown()

	# Build board size selector
	_build_board_size_selector()

	# Connect difficulty buttons
	btn_easy.pressed.connect(_on_enemy_count_btn.bind(1))
	btn_medium.pressed.connect(_on_enemy_count_btn.bind(3))
	btn_hard.pressed.connect(_on_enemy_count_btn.bind(5))
	btn_brutal.pressed.connect(_on_enemy_count_btn.bind(9))

	# Connect action buttons
	start_campaign_btn.pressed.connect(_on_start_campaign)
	back_to_home_btn.pressed.connect(_on_back_to_home)
	tutorial_btn.pressed.connect(_on_tutorial)

	# Start with campaign button disabled until difficulty is selected
	start_campaign_btn.disabled = true
	selected_enemy_count = -1


func exit() -> void:
	pass


func get_screen_name() -> String:
	return "setup"


## ── Private Helpers ─────────────────────────────────────────────────


func _build_enemy_type_dropdown() -> void:
	var setup_vbox: VBoxContainer = $MarginContainer/SetupVBox

	var enemy_label := Label.new()
	enemy_label.name = "EnemyTypeLabel"
	enemy_label.text = "Enemy Type:"
	enemy_label.add_theme_font_size_override("font_size", 13)
	setup_vbox.add_child(enemy_label)
	setup_vbox.move_child(enemy_label, terrain_option.get_index() + 1)

	enemy_type_option = OptionButton.new()
	enemy_type_option.name = "EnemyTypeOption"
	enemy_type_option.add_theme_font_size_override("font_size", 13)
	enemy_type_option.add_item("Mixed (auto)", 99)
	enemy_type_option.add_item("Wolf Pack", EnemyDefinitions.EnemyType.WOLF)
	enemy_type_option.add_item("Bear", EnemyDefinitions.EnemyType.BEAR)
	enemy_type_option.add_item("NPC Rival", EnemyDefinitions.EnemyType.NPC)
	enemy_type_option.selected = 0
	setup_vbox.add_child(enemy_type_option)
	setup_vbox.move_child(enemy_type_option, enemy_label.get_index() + 1)


func _build_board_size_selector() -> void:
	var setup_vbox: VBoxContainer = $MarginContainer/SetupVBox

	var size_label := Label.new()
	size_label.name = "BoardSizeLabel"
	size_label.text = "Board Size:"
	size_label.add_theme_font_size_override("font_size", 13)
	setup_vbox.add_child(size_label)
	setup_vbox.move_child(size_label, terrain_option.get_index() + 1)

	var size_row := HBoxContainer.new()
	size_row.name = "BoardSizeBtns"
	size_row.add_theme_constant_override("separation", 8)
	size_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	_board_size_btns.clear()
	for s in [4, 6]:
		var btn := Button.new()
		btn.text = "%dx%d" % [s, s]
		btn.add_theme_font_size_override("font_size", 13)
		btn.custom_minimum_size = Vector2(60, 36)
		btn.pressed.connect(_on_board_size_btn.bind(s))
		size_row.add_child(btn)
		_board_size_btns.append(btn)

	setup_vbox.add_child(size_row)
	setup_vbox.move_child(size_row, size_label.get_index() + 1)

	# Highlight default (5x5)
	_update_board_size_highlight()


func _on_board_size_btn(size: int) -> void:
	selected_board_size = size
	_update_board_size_highlight()


func _update_board_size_highlight() -> void:
	var sizes := [4, 6]
	for i in range(_board_size_btns.size()):
		_board_size_btns[i].modulate = Color(1.0, 0.85, 0.2) if sizes[i] == selected_board_size else Color.WHITE


func _on_enemy_count_btn(count: int) -> void:
	selected_enemy_count = count
	start_campaign_btn.disabled = false

	# Highlight selected button
	var mapping := {btn_easy: 1, btn_medium: 3, btn_hard: 5, btn_brutal: 9}
	for btn in [btn_easy, btn_medium, btn_hard, btn_brutal]:
		btn.modulate = Color(1.0, 0.85, 0.2) if mapping[btn] == count else Color.WHITE


func _on_start_campaign() -> void:
	if selected_enemy_count < 0:
		return

	# Resolve terrain selection
	var terrain_id: int = terrain_option.get_selected_id()
	var terrain: Terrain.Type
	if terrain_id == 99:
		# Random terrain
		var all_terrains := Terrain.Type.values()
		terrain = all_terrains[randi() % all_terrains.size()] as Terrain.Type
	else:
		terrain = terrain_id as Terrain.Type

	# Resolve enemy type selection
	var enemy_id: int = enemy_type_option.get_selected_id()
	var forced_enemy: int = -1
	if enemy_id != 99:
		forced_enemy = enemy_id

	## Starting a brand-new game from setup — clear any stale/abandoned run so the
	## battle scene begins fresh instead of resuming a leftover gauntlet.
	PlayerData.active_campaign = {}

	# Navigate directly to battle with campaign params (Req 6.3)
	var params := {
		"enemy_count": selected_enemy_count,
		"terrain": terrain,
		"forced_enemy": forced_enemy as EnemyDefinitions.EnemyType,
		"board_size": selected_board_size,
	}
	_get_navigator().navigate_to("battle", params)


func _on_back_to_home() -> void:
	_get_navigator().navigate_back()


func _on_tutorial() -> void:
	_get_navigator().navigate_to("tutorial")
