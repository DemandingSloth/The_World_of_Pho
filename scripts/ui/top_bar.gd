class_name TopBar
extends PanelContainer
## Persistent top bar displaying player info (coins, level, XP)
## and a quick-access hotbar (Home, Town, Marketplace, Missions, Garden, Mines).
## Stays visible on EVERY screen, displayed over top.

@onready var coin_label: Label = get_node_or_null("VBox/StatsHBox/CoinLabel")
@onready var level_label: Label = get_node_or_null("VBox/StatsHBox/LevelLabel")
@onready var xp_bar: ProgressBar = get_node_or_null("VBox/StatsHBox/XPBar")

# TopBar Buttons (order: Home, Town, Marketplace, Missions, Garden, Mines)
@onready var home_btn: Button = get_node_or_null("VBox/HotbarHBox/Home")
@onready var marketplace_btn: Button = get_node_or_null("VBox/HotbarHBox/Marketplace")
@onready var mission_board_btn: Button = get_node_or_null("VBox/HotbarHBox/MissionBoardBtn")
@onready var garden_btn: Button = get_node_or_null("VBox/HotbarHBox/GardenBtn")
@onready var mines_btn: Button = get_node_or_null("VBox/HotbarHBox/MinesBtn")
@onready var guilds_btn: Button = get_node_or_null("VBox/HotbarHBox/GuildsBtn")

var _current_active_screen: String = ""


func _ready() -> void:
	PlayerData.data_changed.connect(refresh)
	PlayerData.leveled_up.connect(_on_player_leveled_up)
	_connect_hotbar_buttons()
	refresh()


func _on_player_leveled_up(_new_level: int, _rewards: Array) -> void:
	refresh()
	_update_mines_button_state()


func _connect_hotbar_buttons() -> void:
	_connect_button(home_btn, "home")
	_connect_button(guilds_btn, "guilds")
	_connect_button(marketplace_btn, "marketplace")
	_connect_button(mission_board_btn, "mission_board")
	_connect_button(garden_btn, "garden")
	_connect_button(mines_btn, "mining")


func _connect_button(btn: Button, screen_name: String) -> void:
	if btn == null:
		return
	if btn.pressed.is_connected(_on_hotbar_pressed.bind(screen_name)):
		btn.pressed.disconnect(_on_hotbar_pressed.bind(screen_name))
	btn.pressed.connect(_on_hotbar_pressed.bind(screen_name))



func _update_mines_button_state() -> void:
	## Mines (expeditions) unlock at Lv.2, matching the mining screen's own gate.
	if mines_btn:
		var unlocked: bool = PlayerData.level >= 2
		mines_btn.disabled = not unlocked
		mines_btn.text = "Mines" if unlocked else "🔒 Lv.2"


func _on_hotbar_pressed(target_screen: String) -> void:
	print("--- Hotbar Pressed: ", target_screen)
	var nav := _get_navigator()
	if nav == null:
		print("ERROR: ScreenNavigator not found!")
		return
	var current := nav.get_current_screen()
	print("Current screen name: ", current.get_screen_name() if current else "null")
	if current != null and current.get_screen_name() == target_screen:
		print("Already on target screen. Aborting.")
		return
	nav.navigate_to(target_screen)


func set_active_screen(screen_name: String) -> void:
	## Treat guild_detail as belonging to the guilds button for highlighting.
	var mapped := "guilds" if screen_name == "guild_detail" else screen_name
	_current_active_screen = mapped
	_update_button_highlights()


func _update_button_highlights() -> void:
	var btn_map := {
		"home": home_btn,
		"guilds": guilds_btn,
		"marketplace": marketplace_btn,
		"mission_board": mission_board_btn,
		"garden": garden_btn,
		"mining": mines_btn,
	}
	for s_name in btn_map:
		var btn: Button = btn_map[s_name]
		if btn != null:
			if s_name == _current_active_screen:
				btn.modulate = Color(1.3, 1.3, 0.7)  ## Highlight active screen
			else:
				btn.modulate = Color(1.0, 1.0, 1.0)


func _get_navigator() -> ScreenNavigator:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	return tree.current_scene.get_node_or_null("ScreenNavigator") as ScreenNavigator


## Updates all displayed values from PlayerData.
func refresh() -> void:
	if coin_label:
		coin_label.text = "🪙 %s" % PlayerData.format_number(PlayerData.coins)
		coin_label.add_theme_color_override("font_color", Color.WHITE)
	if level_label:
		level_label.text = "Lv.%d" % PlayerData.level
		level_label.add_theme_color_override("font_color", Color.WHITE)
	if xp_bar:
		var current_lvl_start: int = PlayerData.cumulative_xp_for_level(PlayerData.level)
		var next_lvl_start: int = PlayerData.cumulative_xp_for_level(PlayerData.level + 1)
		if PlayerData.level >= PlayerData.MAX_LEVEL:
			## Level capped: show a full bar.
			xp_bar.min_value = 0
			xp_bar.max_value = 1
			xp_bar.value = 1
		else:
			xp_bar.min_value = current_lvl_start
			xp_bar.max_value = next_lvl_start
			xp_bar.value = PlayerData.xp
	_update_mines_button_state()
