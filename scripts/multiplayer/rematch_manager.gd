class_name RematchManager
extends Node

## Manages the rematch flow after a match ends.
## Displays a 30-second countdown timer during which both players can accept
## or decline a rematch. When both accept, retains connection and returns to
## piece selection. When one declines or the timer expires, disconnects both
## and returns to multiplayer menu.
##
## Requirements: 8.1, 8.2, 8.3, 8.4

# ── Signals ───────────────────────────────────────────────────────────────────

## Emitted when a peer accepts the rematch.
signal rematch_accepted(peer_id: int)

## Emitted when a peer declines the rematch.
signal rematch_declined(peer_id: int)

## Emitted when both players accept — game should return to piece selection.
signal rematch_started

## Emitted when the 30-second countdown expires without both accepting.
signal rematch_expired

# ── Constants ─────────────────────────────────────────────────────────────────

## Duration of the rematch acceptance window in seconds (Requirement 8.1).
const REMATCH_TIMEOUT_SEC: float = 30.0

## Path to the piece selection scene (rematch destination).
const PIECE_SELECTION_SCENE: String = "res://scenes/multiplayer/piece_selection.tscn"

## Path to the multiplayer menu scene (decline/timeout destination).
const MULTIPLAYER_MENU_SCENE: String = "res://scenes/multiplayer/multiplayer_menu.tscn"

# ── State ─────────────────────────────────────────────────────────────────────

## Whether the rematch countdown is currently active.
var rematch_active: bool = false

## Remaining seconds in the rematch countdown.
var rematch_timer: float = 0.0

## Whether the host (peer_id=1) has accepted the rematch.
var host_accepted: bool = false

## Whether the guest has accepted the rematch.
var guest_accepted: bool = false

## Peer ID of the guest player (set externally before starting countdown).
var guest_peer_id: int = 0


# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _process(delta: float) -> void:
	if not rematch_active:
		return

	rematch_timer -= delta
	if rematch_timer <= 0.0:
		rematch_timer = 0.0
		_on_rematch_timeout()


# ── Public API ────────────────────────────────────────────────────────────────


## Begins the 30-second rematch acceptance window.
## Call this after the match result is displayed to both players.
func start_rematch_countdown() -> void:
	rematch_active = true
	rematch_timer = REMATCH_TIMEOUT_SEC
	host_accepted = false
	guest_accepted = false


## Marks the given peer as accepting the rematch.
## When both accept, emits rematch_started and transitions to piece selection.
func accept_rematch(peer_id: int) -> void:
	if not rematch_active:
		return

	if peer_id == 1:
		host_accepted = true
	else:
		guest_accepted = true

	rematch_accepted.emit(peer_id)

	# Notify the other player that this peer accepted
	if multiplayer and multiplayer.has_multiplayer_peer():
		_rematch_accepted_rpc.rpc(peer_id)

	# Check if both players have accepted
	if host_accepted and guest_accepted:
		_on_both_accepted()


## Marks the given peer as declining the rematch.
## Immediately ends the rematch window for both players.
func decline_rematch(peer_id: int) -> void:
	if not rematch_active:
		return

	rematch_active = false
	rematch_declined.emit(peer_id)

	# Notify the other player that this peer declined
	if multiplayer and multiplayer.has_multiplayer_peer():
		_decline_rematch_rpc.rpc(peer_id)

	_disconnect_and_return_to_menu()


## Returns the time remaining in the rematch countdown (for UI display).
func get_time_remaining() -> float:
	return rematch_timer


## Resets the rematch manager to its initial state (for cleanup).
func reset() -> void:
	rematch_active = false
	rematch_timer = 0.0
	host_accepted = false
	guest_accepted = false


# ── RPC Handlers ──────────────────────────────────────────────────────────────


## RPC: Called by a peer to request a rematch (client → host or host → client).
@rpc("any_peer", "reliable")
func _request_rematch_rpc() -> void:
	var sender_id: int = multiplayer.get_remote_sender_id()
	accept_rematch(sender_id)


## RPC: Called by a peer to decline a rematch (client → host or host → client).
@rpc("any_peer", "reliable")
func _decline_rematch_rpc(peer_id: int) -> void:
	if not rematch_active:
		return

	rematch_active = false
	rematch_declined.emit(peer_id)
	_disconnect_and_return_to_menu()


## RPC: Broadcast to notify that a peer accepted (so UI can update).
@rpc("any_peer", "reliable")
func _rematch_accepted_rpc(peer_id: int) -> void:
	# Update local state based on who accepted
	if peer_id == 1:
		host_accepted = true
	else:
		guest_accepted = true

	rematch_accepted.emit(peer_id)

	# Check if both have now accepted (client-side check)
	if host_accepted and guest_accepted:
		_on_both_accepted()


## RPC: Host confirms the rematch to both players — transition to piece selection.
@rpc("authority", "reliable")
func _rematch_confirmed_rpc() -> void:
	# Client-side: transition to piece selection scene
	rematch_active = false
	rematch_started.emit()
	_navigate_to_piece_selection()


# ── Private Helpers ───────────────────────────────────────────────────────────


## Called when both players have accepted the rematch within the time window.
## Retains the connection and transitions both players to piece selection.
func _on_both_accepted() -> void:
	rematch_active = false
	rematch_started.emit()

	# Host broadcasts the confirmed rematch to the guest
	if multiplayer and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_rematch_confirmed_rpc.rpc()

	_navigate_to_piece_selection()


## Called when the 30-second timer expires without both players accepting.
## Disconnects both players and returns to multiplayer menu (Requirement 8.3).
func _on_rematch_timeout() -> void:
	rematch_active = false
	rematch_expired.emit()
	_disconnect_and_return_to_menu()


## Disconnects from the network and navigates to the multiplayer menu.
func _disconnect_and_return_to_menu() -> void:
	# Disconnect through NetworkManager if available
	var network_manager: Node = get_node_or_null("/root/NetworkManager")
	if network_manager and network_manager.has_method("disconnect_from_match"):
		network_manager.disconnect_from_match()

	# Navigate to multiplayer menu
	if is_inside_tree() and ResourceLoader.exists(MULTIPLAYER_MENU_SCENE):
		get_tree().change_scene_to_file(MULTIPLAYER_MENU_SCENE)


## Navigates to the piece selection scene (retaining the connection).
func _navigate_to_piece_selection() -> void:
	if is_inside_tree() and ResourceLoader.exists(PIECE_SELECTION_SCENE):
		get_tree().change_scene_to_file(PIECE_SELECTION_SCENE)
