class_name TurnIndicator
extends CanvasLayer

## Displays turn state, countdown timers, and opponent info during multiplayer battles.
## Shows at TOP-CENTER of screen as a compact overlay.
## Reads from MultiplayerGameManager each frame for responsive updates (<200ms).

# ── Constants ─────────────────────────────────────────────────────────────────

const COLOR_YOUR_TURN := Color(0.2, 0.9, 0.2)         # Green — it's your move
const COLOR_OPPONENT_TURN := Color(0.6, 0.6, 0.6)     # Gray — waiting
const COLOR_TIMER_NORMAL := Color(1.0, 1.0, 1.0)      # White
const COLOR_TIMER_URGENT := Color(0.95, 0.3, 0.2)     # Red — last 10 seconds
const MAX_DISPLAY_NAME_LENGTH := 20

# ── Node References ───────────────────────────────────────────────────────────

@onready var opponent_label: Label = $PanelContainer/MarginContainer/VBox/OpponentLabel
@onready var turn_label: Label = $PanelContainer/MarginContainer/VBox/TurnLabel
@onready var timer_label: Label = $PanelContainer/MarginContainer/VBox/TimerLabel
@onready var waiting_label: Label = $PanelContainer/MarginContainer/VBox/WaitingLabel

# ── State ─────────────────────────────────────────────────────────────────────

## Reference to the active MultiplayerGameManager. Set externally or found via group.
var game_manager: MultiplayerGameManager = null


# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	layer = 100
	_update_opponent_name()
	_update_display()


func _process(_delta: float) -> void:
	if game_manager == null:
		_try_find_game_manager()
		if game_manager == null:
			return
	_update_display()


# ── Private ───────────────────────────────────────────────────────────────────


## Attempts to locate the MultiplayerGameManager in the scene tree.
func _try_find_game_manager() -> void:
	var nodes := get_tree().get_nodes_in_group("multiplayer_game_manager")
	if nodes.size() > 0 and nodes[0] is MultiplayerGameManager:
		game_manager = nodes[0] as MultiplayerGameManager
		_update_opponent_name()
		return
	# Fallback: search by node name from root
	var mgr: Node = get_tree().root.find_child("MultiplayerGameManager", true, false)
	if mgr is MultiplayerGameManager:
		game_manager = mgr as MultiplayerGameManager
		_update_opponent_name()


## Updates the opponent name label from NetworkManager lobby state.
func _update_opponent_name() -> void:
	if opponent_label == null:
		return

	var display_name := _get_opponent_display_name()
	opponent_label.text = "vs " + display_name


## Resolves the opponent's display name from NetworkManager lobby state.
## Truncates to MAX_DISPLAY_NAME_LENGTH characters.
func _get_opponent_display_name() -> String:
	var network_manager: Node = get_node_or_null("/root/NetworkManager")
	if network_manager == null:
		return "Opponent"

	var lobby: LobbyState = network_manager.lobby
	if lobby == null:
		return "Opponent"

	var is_host: bool = network_manager.is_host
	var opponent_info: PlayerInfo = null

	if is_host:
		opponent_info = lobby.guest_info
	else:
		opponent_info = lobby.host_info

	if opponent_info == null:
		return "Opponent"

	var name: String = opponent_info.display_name
	if name.is_empty():
		# Fallback to peer ID
		return "Peer_%d" % opponent_info.peer_id

	if name.length() > MAX_DISPLAY_NAME_LENGTH:
		name = name.substr(0, MAX_DISPLAY_NAME_LENGTH)

	return name


## Main display update — called every frame for responsiveness.
func _update_display() -> void:
	var phase: MultiplayerGameManager.PvPPhase = game_manager.pvp_phase

	match phase:
		MultiplayerGameManager.PvPPhase.PVP_PLACEMENT:
			_show_placement_state()
		MultiplayerGameManager.PvPPhase.MOVEMENT:
			_show_movement_state()
		_:
			_show_idle_state()


## During placement: show placement timer countdown.
func _show_placement_state() -> void:
	var time_remaining: float = game_manager.placement_timer
	var seconds: int = ceili(time_remaining)

	turn_label.text = "Placement Phase"
	turn_label.add_theme_color_override("font_color", COLOR_YOUR_TURN)

	timer_label.text = "Placement: %ds" % seconds
	timer_label.visible = true
	if time_remaining <= 10.0:
		timer_label.add_theme_color_override("font_color", COLOR_TIMER_URGENT)
	else:
		timer_label.add_theme_color_override("font_color", COLOR_TIMER_NORMAL)

	waiting_label.visible = false


## During movement: show turn indicator and move timer.
func _show_movement_state() -> void:
	var local_peer_id: int = _get_local_peer_id()
	var current_turn_owner: Piece.Owner = game_manager.movement_current_turn
	var local_owner: int = game_manager._peer_to_owner(local_peer_id)
	var is_my_turn: bool = (int(current_turn_owner) == local_owner)

	if is_my_turn:
		turn_label.text = "Your Turn"
		turn_label.add_theme_color_override("font_color", COLOR_YOUR_TURN)
		turn_label.add_theme_font_size_override("font_size", 16)

		# Show 60-second countdown
		var time_remaining: float = game_manager.move_timer
		var seconds: int = ceili(time_remaining)
		timer_label.text = "%ds" % seconds
		timer_label.visible = true
		if time_remaining <= 10.0:
			timer_label.add_theme_color_override("font_color", COLOR_TIMER_URGENT)
		else:
			timer_label.add_theme_color_override("font_color", COLOR_TIMER_NORMAL)

		waiting_label.visible = false
	else:
		turn_label.text = "Opponent's Turn"
		turn_label.add_theme_color_override("font_color", COLOR_OPPONENT_TURN)
		turn_label.add_theme_font_size_override("font_size", 14)

		timer_label.visible = false
		waiting_label.text = "Waiting for opponent's move..."
		waiting_label.visible = true


## When not in placement or movement — hide active indicators.
func _show_idle_state() -> void:
	turn_label.text = ""
	timer_label.visible = false
	waiting_label.visible = false


## Returns the local player's network peer ID.
func _get_local_peer_id() -> int:
	var network_manager: Node = get_node_or_null("/root/NetworkManager")
	if network_manager:
		return network_manager.local_peer_id
	return 1  # Fallback to host
