class_name MatchResultUI
extends MarginContainer

## Displays the match outcome (Victory / Defeat / Draw), scores, points awarded,
## battle log, and provides Rematch and Return to Menu buttons.
## Connects to MultiplayerGameManager.match_ended signal to receive result data.
## Also manages the 30-second rematch countdown UI (Requirements 8.1, 8.4).

# ── Signals ───────────────────────────────────────────────────────────────────

## Emitted when the player presses the Rematch button.
signal rematch_requested

## Emitted when the player presses the Return to Menu button.
signal return_to_menu_requested

# ── Node References ───────────────────────────────────────────────────────────

@onready var outcome_label: Label = $VBox/OutcomeLabel
@onready var host_score_label: Label = $VBox/ScoresRow/HostScoreLabel
@onready var guest_score_label: Label = $VBox/ScoresRow/GuestScoreLabel
@onready var points_label: Label = $VBox/PointsLabel
@onready var battle_log_text: RichTextLabel = $VBox/BattleLogText
@onready var rematch_btn: Button = $VBox/BtnRow/RematchBtn
@onready var menu_btn: Button = $VBox/BtnRow/MenuBtn
@onready var countdown_label: Label = $VBox/CountdownLabel if has_node("VBox/CountdownLabel") else null
@onready var waiting_label: Label = $VBox/WaitingLabel if has_node("VBox/WaitingLabel") else null

# ── State ─────────────────────────────────────────────────────────────────────

## The result data dictionary received from MultiplayerGameManager.
var result_data: Dictionary = {}

## Reference to the game manager for rematch state queries.
var game_manager: MultiplayerGameManager = null

## Whether the local player has accepted the rematch.
var _local_accepted: bool = false


# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	rematch_btn.pressed.connect(_on_rematch_pressed)
	menu_btn.pressed.connect(_on_menu_pressed)

	# Hide by default until result data is provided.
	visible = false

	# Hide rematch sub-elements until countdown starts.
	if countdown_label:
		countdown_label.visible = false
	if waiting_label:
		waiting_label.visible = false


func _process(_delta: float) -> void:
	if not visible:
		return
	if game_manager == null:
		return

	# Update countdown timer display
	if game_manager.is_rematch_active():
		var remaining: float = game_manager.get_rematch_time_remaining()
		if countdown_label:
			countdown_label.visible = true
			countdown_label.text = "Rematch: %ds" % int(ceil(remaining))

		# Show "Waiting for opponent" if we accepted but they haven't
		if waiting_label:
			if game_manager.is_waiting_for_opponent_rematch():
				waiting_label.visible = true
				waiting_label.text = "Waiting for opponent to accept..."
			else:
				waiting_label.visible = false

		# Disable rematch button after accepting
		if _local_accepted:
			rematch_btn.disabled = true
	else:
		if countdown_label:
			countdown_label.visible = false
		if waiting_label:
			waiting_label.visible = false


# ── Public API ────────────────────────────────────────────────────────────────


## Shows the match result screen with the given result data.
## Expected keys in data:
##   - outcome: "victory" | "defeat" | "draw"
##   - host_score: int
##   - guest_score: int
##   - points_awarded: int
##   - battle_log: Array[String]
## Also starts the 30-second rematch countdown (Requirement 8.1).
func show_result(data: Dictionary) -> void:
	result_data = data
	_local_accepted = false
	_update_display()
	visible = true

	# Enable the rematch button
	rematch_btn.disabled = false

	# Start the rematch countdown via the game manager
	if game_manager:
		game_manager.start_rematch_countdown()


# ── Private Helpers ───────────────────────────────────────────────────────────


## Updates all UI elements based on result_data.
func _update_display() -> void:
	var outcome: String = result_data.get("outcome", "draw")

	# Set outcome text and color
	match outcome:
		"victory":
			outcome_label.text = "Victory!"
			outcome_label.add_theme_color_override("font_color", Color(0.2, 0.9, 0.2))
		"defeat":
			outcome_label.text = "Defeat!"
			outcome_label.add_theme_color_override("font_color", Color(0.9, 0.2, 0.2))
		"draw":
			outcome_label.text = "Draw!"
			outcome_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.2))

	# Display scores
	var host_score: int = result_data.get("host_score", 0)
	var guest_score: int = result_data.get("guest_score", 0)
	host_score_label.text = "Host: %d" % host_score
	guest_score_label.text = "Guest: %d" % guest_score

	# Display points awarded
	var points: int = result_data.get("points_awarded", 0)
	points_label.text = "+%d pts" % points

	# Display battle log
	var log_entries: Array = result_data.get("battle_log", [])
	battle_log_text.clear()
	for entry in log_entries:
		battle_log_text.append_text(str(entry) + "\n")


## Called when the Rematch button is pressed.
## Calls into the game manager's rematch system and disables the button.
func _on_rematch_pressed() -> void:
	_local_accepted = true
	rematch_btn.disabled = true
	rematch_requested.emit()
	if game_manager:
		game_manager.request_rematch()


## Called when the Return to Menu button is pressed.
## Declines the rematch and signals return to menu.
func _on_menu_pressed() -> void:
	return_to_menu_requested.emit()
	if game_manager:
		game_manager.decline_rematch()
