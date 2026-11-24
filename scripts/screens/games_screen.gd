extends BaseScreen
## Games screen — shows available mini-games the player can navigate to.
## Provides a "Play Game (Campaign)" button and a back button.
##
## Requirements: 1.2, 1.3, 1.5, 1.6


@onready var play_game_btn: Button = $MarginContainer/VBox/PlayGameBtn
@onready var back_btn: Button = $MarginContainer/VBox/BackBtn


func _ready() -> void:
	play_game_btn.pressed.connect(_on_play_game_pressed)
	back_btn.pressed.connect(_on_back_pressed)


func get_screen_name() -> String:
	return "games"


## ── Private: Button handlers ─────────────────────────────────────


func _on_play_game_pressed() -> void:
	_get_navigator().navigate_to("setup")


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()
