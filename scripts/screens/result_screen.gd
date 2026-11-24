extends BaseScreen
## Result screen — shown after winning a non-final battle in a campaign.
## Displays Victory title, score comparison, remaining pool size,
## and provides a Next Battle button to continue the campaign.
##
## Requirements: 1.2, 1.3, 6.5, 6.7, 9.1


@onready var result_title: Label = $MarginContainer/VBox/ResultTitle
@onready var result_detail: Label = $MarginContainer/VBox/ResultDetail
@onready var result_pool_label: Label = $MarginContainer/VBox/ResultPoolLabel
@onready var next_battle_btn: Button = $MarginContainer/VBox/NextBattleBtn
@onready var back_btn: Button = $MarginContainer/VBox/BackBtn


var _player_score: int = 0
var _enemy_score: int = 0
var _game_manager_ref: GameManager = null


func enter(params: Dictionary = {}) -> void:
	_player_score = params.get("player_score", 0)
	_enemy_score = params.get("enemy_score", 0)
	_game_manager_ref = params.get("game_manager_ref", null) as GameManager

	# Display victory message
	result_title.text = "Victory!"

	# Score comparison detail
	result_detail.text = "You scored %d points vs enemy's %d points." % [_player_score, _enemy_score]

	# Pool label — show remaining pieces from campaign pool
	var pool_count: int = 0
	if _game_manager_ref != null and _game_manager_ref.campaign != null:
		pool_count = _game_manager_ref.campaign.pool_size()
	result_pool_label.text = "Remaining pieces in pool: %d" % pool_count

	# Connect buttons
	next_battle_btn.pressed.connect(_on_next_battle_pressed)
	back_btn.pressed.connect(_on_back_pressed)


func exit() -> void:
	if next_battle_btn.pressed.is_connected(_on_next_battle_pressed):
		next_battle_btn.pressed.disconnect(_on_next_battle_pressed)
	if back_btn.pressed.is_connected(_on_back_pressed):
		back_btn.pressed.disconnect(_on_back_pressed)
	_game_manager_ref = null


func get_screen_name() -> String:
	return "result"


## ── Button Handlers ──────────────────────────────────────────────


func _on_next_battle_pressed() -> void:
	var params := {}
	if _game_manager_ref != null:
		params["enemy_count"] = _game_manager_ref.current_enemy_count
		params["terrain"] = _game_manager_ref.current_terrain
		params["continue_campaign"] = true
		params["board_size"] = BoardState.BOARD_SIZE  ## Preserve the board size across battles
	_get_navigator().navigate_to("battle", params)


func _on_back_pressed() -> void:
	_get_navigator().navigate_to("home")
