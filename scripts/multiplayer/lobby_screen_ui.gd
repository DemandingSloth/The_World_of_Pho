class_name LobbyScreenUI
extends MarginContainer

## Lobby waiting screen — shows connection info, player list, ready state,
## and handles transitions to piece selection or back to multiplayer menu.
## Connects to NetworkManager (autoload) for lobby state changes.

# ── Node references ───────────────────────────────────────────────────────────

@onready var title_label        : Label  = $VBox/TitleLabel
@onready var lobby_code_label   : Label  = $VBox/LobbyCodeLabel
@onready var connection_label   : Label  = $VBox/ConnectionLabel

@onready var host_name_label    : Label  = $VBox/HostRow/HostNameLabel
@onready var host_ready_label   : Label  = $VBox/HostRow/HostReadyLabel
@onready var guest_name_label   : Label  = $VBox/GuestRow/GuestNameLabel
@onready var guest_ready_label  : Label  = $VBox/GuestRow/GuestReadyLabel

@onready var status_label       : Label  = $VBox/StatusLabel
@onready var ready_btn          : Button = $VBox/BtnRow/ReadyBtn
@onready var cancel_btn         : Button = $VBox/BtnRow/CancelBtn

# ── Constants ─────────────────────────────────────────────────────────────────

const MULTIPLAYER_MENU_PATH := "res://scenes/multiplayer/multiplayer_menu.tscn"
const PIECE_SELECTION_PATH := "res://scenes/multiplayer/piece_selection.tscn"

# ── State ─────────────────────────────────────────────────────────────────────

var _is_ready: bool = false

# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	## Button connections
	ready_btn.pressed.connect(_on_ready_pressed)
	cancel_btn.pressed.connect(_on_cancel_pressed)

	## NetworkManager signal connections
	NetworkManager.lobby_state_changed.connect(_on_lobby_state_changed)
	NetworkManager.player_joined.connect(_on_player_joined)
	NetworkManager.player_left.connect(_on_player_left)
	NetworkManager.disconnected.connect(_on_disconnected)

	## Initialize UI based on current lobby state
	_update_ui_from_lobby()

	## If we are the client, register with the host
	if not NetworkManager.is_host:
		_register_with_host()


func _exit_tree() -> void:
	## Disconnect signals to prevent errors if NetworkManager persists
	if NetworkManager.lobby_state_changed.is_connected(_on_lobby_state_changed):
		NetworkManager.lobby_state_changed.disconnect(_on_lobby_state_changed)
	if NetworkManager.player_joined.is_connected(_on_player_joined):
		NetworkManager.player_joined.disconnect(_on_player_joined)
	if NetworkManager.player_left.is_connected(_on_player_left):
		NetworkManager.player_left.disconnect(_on_player_left)
	if NetworkManager.disconnected.is_connected(_on_disconnected):
		NetworkManager.disconnected.disconnect(_on_disconnected)


# ── UI Update ─────────────────────────────────────────────────────────────────


## Refreshes all UI elements based on the current NetworkManager.lobby state.
func _update_ui_from_lobby() -> void:
	var lobby := NetworkManager.lobby

	if lobby == null:
		status_label.text = "No lobby data"
		return

	## Lobby code
	lobby_code_label.text = "Lobby Code: %s" % lobby.lobby_code

	## Connection info (host IP/port)
	if NetworkManager.is_host:
		var local_ip := _get_local_ip()
		connection_label.text = "Share with opponent — IP: %s  Port: 7000" % local_ip
	else:
		connection_label.text = "Connected to host"

	## Host player info
	if lobby.host_info:
		host_name_label.text = lobby.host_info.display_name
		host_ready_label.text = "Ready" if lobby.host_info.is_ready else "Not Ready"
	else:
		host_name_label.text = "Host"
		host_ready_label.text = "Not Ready"

	## Guest player info
	if lobby.guest_info:
		guest_name_label.text = lobby.guest_info.display_name
		guest_ready_label.text = "Ready" if lobby.guest_info.is_ready else "Not Ready"
		status_label.text = ""
	else:
		guest_name_label.text = "Waiting for opponent..."
		guest_ready_label.text = ""
		status_label.text = "Waiting for opponent"

	## Ready button text reflects current state
	ready_btn.text = "Unready" if _is_ready else "Ready"

	## Check if both players are ready → transition (host-initiated)
	_check_both_ready(lobby)


## Checks if both players are ready and initiates transition to piece selection.
## Only the host triggers the scene change; the client receives it via RPC.
func _check_both_ready(lobby: LobbyState) -> void:
	if lobby.host_info == null or lobby.guest_info == null:
		return
	if not lobby.host_info.is_ready or not lobby.guest_info.is_ready:
		return

	## Both ready — transition to piece selection
	status_label.text = "Both players ready! Starting..."
	ready_btn.disabled = true
	cancel_btn.disabled = true

	if NetworkManager.is_host:
		## Small delay so both players see the "starting" status
		await get_tree().create_timer(0.5).timeout
		_transition_to_piece_selection.rpc()


# ── Client Registration ───────────────────────────────────────────────────────


## Client sends its player info to the host upon entering the lobby.
func _register_with_host() -> void:
	var info := PlayerInfo.new()
	info.peer_id = NetworkManager.local_peer_id
	info.display_name = "Guest"
	info.is_host = false
	info.is_ready = false

	NetworkManager.register_player.rpc_id(1, info.serialize())


# ── Button Handlers ───────────────────────────────────────────────────────────


func _on_ready_pressed() -> void:
	_is_ready = not _is_ready
	ready_btn.text = "Unready" if _is_ready else "Ready"

	if NetworkManager.is_host:
		## Host updates lobby state directly
		if NetworkManager.lobby and NetworkManager.lobby.host_info:
			NetworkManager.lobby.host_info.is_ready = _is_ready
			NetworkManager._broadcast_lobby_state()
	else:
		## Client sends ready state to host
		_set_ready_on_host.rpc_id(1, _is_ready)


func _on_cancel_pressed() -> void:
	## Disconnect and return to multiplayer menu (Requirement 1.6)
	NetworkManager.disconnect_from_match()
	get_tree().change_scene_to_file(MULTIPLAYER_MENU_PATH)


# ── NetworkManager Signal Handlers ────────────────────────────────────────────


func _on_lobby_state_changed(lobby: LobbyState) -> void:
	## Sync local ready state from lobby data for the client
	if not NetworkManager.is_host and lobby != null:
		if lobby.guest_info != null:
			_is_ready = lobby.guest_info.is_ready
	_update_ui_from_lobby()


func _on_player_joined(_player_info: Dictionary) -> void:
	_update_ui_from_lobby()


func _on_player_left(_peer_id: int) -> void:
	_is_ready = false
	ready_btn.text = "Ready"
	_update_ui_from_lobby()


func _on_disconnected(reason: String) -> void:
	## If disconnected while in lobby, return to menu (Requirement 2.4)
	status_label.text = "Disconnected: %s" % reason
	await get_tree().create_timer(1.5).timeout
	get_tree().change_scene_to_file(MULTIPLAYER_MENU_PATH)


# ── RPCs ──────────────────────────────────────────────────────────────────────


## Client → Host: notify the host of the client's ready state.
@rpc("any_peer", "reliable")
func _set_ready_on_host(ready: bool) -> void:
	if not NetworkManager.is_host:
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if NetworkManager.lobby and NetworkManager.lobby.guest_info:
		if NetworkManager.lobby.guest_info.peer_id == sender_id:
			NetworkManager.lobby.guest_info.is_ready = ready
			NetworkManager._broadcast_lobby_state()


## Host → All: tells all peers to transition to piece selection.
@rpc("authority", "reliable", "call_local")
func _transition_to_piece_selection() -> void:
	get_tree().change_scene_to_file(PIECE_SELECTION_PATH)


## Returns the local machine's LAN IP address for display.
func _get_local_ip() -> String:
	var addresses := IP.get_local_addresses()
	for addr in addresses:
		## Filter for typical LAN IPv4 addresses (192.168.x.x or 10.x.x.x)
		if addr.begins_with("192.168.") or addr.begins_with("10."):
			return addr
	## Fallback: return first non-loopback address
	for addr in addresses:
		if addr != "127.0.0.1" and not addr.contains(":"):
			return addr
	return "127.0.0.1"
