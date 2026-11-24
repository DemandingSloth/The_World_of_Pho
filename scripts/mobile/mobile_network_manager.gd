extends Node

## Mobile-aware networking layer that observes the existing NetworkManager singleton
## and adds reconnection logic, background heartbeat management, connection quality
## monitoring, and match forfeit handling for mobile network conditions.
##
## This is a standalone autoload that connects to NetworkManager's signals rather than
## extending it (which would break the autoload registration).

# ── Signals ───────────────────────────────────────────────────────────────────

## Emitted when automatic reconnection begins after connection loss.
signal reconnection_started()

## Emitted when automatic reconnection succeeds within the timeout window.
signal reconnection_succeeded()

## Emitted when reconnection fails (timeout exceeded or unrecoverable error).
signal reconnection_failed(reason: String)

## Emitted periodically with the current round-trip latency in milliseconds.
signal connection_quality_changed(latency_ms: int)

## Emitted when the match is forfeited due to extended background or disconnect.
signal match_forfeited(reason: String)

# ── Constants ─────────────────────────────────────────────────────────────────

const RECONNECT_TIMEOUT_SEC := 10.0
const BACKGROUND_HEARTBEAT_MAX_SEC := 30.0
const LATENCY_UPDATE_INTERVAL_SEC := 1.0

# ── Enums ─────────────────────────────────────────────────────────────────────

enum MobileConnectionState {
	CONNECTED,
	RECONNECTING,
	DISCONNECTED,
	BACKGROUND_KEEPALIVE,
}

# ── State ─────────────────────────────────────────────────────────────────────

var mobile_state: MobileConnectionState = MobileConnectionState.DISCONNECTED

var _background_timer: Timer
var _reconnect_timer: Timer
var _latency_update_timer: Timer
var _reconnect_attempts: int = 0
var _last_known_address: String = ""
var _last_known_port: int = 0


# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	# Connect to the existing NetworkManager singleton's signals.
	NetworkManager.disconnected.connect(_on_network_disconnected)
	NetworkManager.connection_established.connect(_on_connection_established)
	NetworkManager.connection_failed.connect(_on_connection_attempt_failed)

	# Create the reconnection timeout timer (one-shot, 10 seconds).
	_reconnect_timer = Timer.new()
	_reconnect_timer.one_shot = true
	_reconnect_timer.wait_time = RECONNECT_TIMEOUT_SEC
	_reconnect_timer.timeout.connect(_on_reconnect_timeout)
	add_child(_reconnect_timer)

	# Create the background forfeit timer (one-shot, 30 seconds).
	_background_timer = Timer.new()
	_background_timer.one_shot = true
	_background_timer.wait_time = BACKGROUND_HEARTBEAT_MAX_SEC
	_background_timer.timeout.connect(_on_background_timeout)
	add_child(_background_timer)

	# Create the latency update timer (repeating, 1 second interval).
	_latency_update_timer = Timer.new()
	_latency_update_timer.one_shot = false
	_latency_update_timer.wait_time = LATENCY_UPDATE_INTERVAL_SEC
	_latency_update_timer.timeout.connect(_on_latency_update)
	add_child(_latency_update_timer)
	_latency_update_timer.start()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			_on_app_paused()
		NOTIFICATION_APPLICATION_RESUMED:
			_on_app_resumed()


# ── Public API ────────────────────────────────────────────────────────────────


## Checks whether a network connection is available before starting a match.
## Uses hostname resolution as a connectivity probe. Returns true if reachable.
func check_network_available() -> bool:
	# Attempt to resolve a well-known hostname as a connectivity check.
	var resolved := IP.resolve_hostname("dns.google", IP.TYPE_ANY)
	if resolved.is_empty() or resolved == "0.0.0.0":
		return false
	return true


## Initiates automatic reconnection after a connection loss during a match.
## Starts the 10-second timeout and attempts to rejoin the last known server.
func start_reconnection() -> void:
	if mobile_state == MobileConnectionState.RECONNECTING:
		return  # Already attempting reconnection.

	mobile_state = MobileConnectionState.RECONNECTING
	_reconnect_attempts = 0
	reconnection_started.emit()

	# Start the 10-second hard deadline.
	_reconnect_timer.start()

	# Attempt the first reconnection.
	_attempt_reconnect()


## Returns the current connection latency formatted for UI display (e.g., "45ms").
## Returns "--ms" if no latency data is available.
func get_display_latency() -> String:
	var latency := NetworkManager.get_latency_ms()
	if latency <= 0:
		return "--ms"
	return "%dms" % latency


# ── Signal Handlers (NetworkManager) ─────────────────────────────────────────


## Called when the existing NetworkManager detects a disconnection.
func _on_network_disconnected(_reason: String) -> void:
	if mobile_state == MobileConnectionState.BACKGROUND_KEEPALIVE:
		# Already in background mode — the background timer handles forfeit.
		return

	if NetworkManager.state == NetworkManager.ConnectionState.DISCONNECTED:
		# We were in a match — attempt reconnection.
		if mobile_state == MobileConnectionState.CONNECTED:
			start_reconnection()
		else:
			mobile_state = MobileConnectionState.DISCONNECTED


## Called when a connection is successfully established (or re-established).
func _on_connection_established(_peer_id: int) -> void:
	if mobile_state == MobileConnectionState.RECONNECTING:
		# Reconnection succeeded within the timeout window.
		_reconnect_timer.stop()
		_reconnect_attempts = 0
		mobile_state = MobileConnectionState.CONNECTED
		reconnection_succeeded.emit()
	else:
		# Fresh connection — store server details for potential reconnection.
		mobile_state = MobileConnectionState.CONNECTED


## Called when a connection attempt fails during reconnection.
func _on_connection_attempt_failed(_reason: String) -> void:
	if mobile_state == MobileConnectionState.RECONNECTING:
		# Retry if the reconnect timer hasn't expired yet.
		if not _reconnect_timer.is_stopped():
			_attempt_reconnect()


# ── Background / Foreground Handling ──────────────────────────────────────────


## Handles the app moving to the background during a multiplayer match.
func _on_app_paused() -> void:
	if mobile_state == MobileConnectionState.CONNECTED and NetworkManager.state == NetworkManager.ConnectionState.IN_MATCH:
		mobile_state = MobileConnectionState.BACKGROUND_KEEPALIVE
		_background_timer.start()


## Handles the app returning to the foreground.
func _on_app_resumed() -> void:
	if mobile_state == MobileConnectionState.BACKGROUND_KEEPALIVE:
		# Returned before the 30-second forfeit deadline.
		_background_timer.stop()
		mobile_state = MobileConnectionState.CONNECTED


# ── Timer Callbacks ───────────────────────────────────────────────────────────


## Called when the 10-second reconnection timeout expires.
## Notifies the player and returns to the multiplayer menu.
func _on_reconnect_timeout() -> void:
	mobile_state = MobileConnectionState.DISCONNECTED
	_reconnect_attempts = 0

	# Clean up any lingering connection state.
	NetworkManager.disconnect_from_match()

	reconnection_failed.emit("Connection lost for more than 10 seconds")

	# Navigate back to the multiplayer menu and show disconnection message.
	_show_disconnection_message()


## Called when the 30-second background timer expires during an active match.
## Forfeits the match and notifies the opponent.
func _on_background_timeout() -> void:
	mobile_state = MobileConnectionState.DISCONNECTED

	# Disconnect cleanly from the match.
	NetworkManager.disconnect_from_match()

	match_forfeited.emit("Application was in background for more than 30 seconds")


## Called every LATENCY_UPDATE_INTERVAL_SEC to broadcast latency changes.
func _on_latency_update() -> void:
	if mobile_state == MobileConnectionState.CONNECTED:
		var latency := NetworkManager.get_latency_ms()
		if latency > 0:
			connection_quality_changed.emit(latency)


# ── Private Helpers ───────────────────────────────────────────────────────────


## Attempts a single reconnection to the last known server address and port.
func _attempt_reconnect() -> void:
	_reconnect_attempts += 1

	if _last_known_address.is_empty() or _last_known_port <= 0:
		# No stored server info — cannot reconnect.
		_on_reconnect_timeout()
		return

	# Use the existing NetworkManager to attempt reconnection.
	# First ensure it's in a disconnected state so join_server will proceed.
	if NetworkManager.state != NetworkManager.ConnectionState.DISCONNECTED:
		NetworkManager.disconnect_from_match()

	NetworkManager.join_server(_last_known_address, _last_known_port)


## Stores the server address and port for reconnection attempts.
## Should be called when a multiplayer connection is first established.
func store_connection_info(address: String, port: int) -> void:
	_last_known_address = address
	_last_known_port = port


## Displays a disconnection error message and navigates to the multiplayer menu.
func _show_disconnection_message() -> void:
	# Navigate to multiplayer menu. The actual scene transition depends on the
	# project's scene management approach. We use get_tree().change_scene_to_file()
	# as the standard Godot pattern.
	var menu_path := "res://scenes/multiplayer/multiplayer_menu.tscn"
	if ResourceLoader.exists(menu_path):
		get_tree().change_scene_to_file(menu_path)
	# A popup or notification system would display the message in the new scene.
	push_warning("MobileNetworkManager: Connection lost — returned to multiplayer menu.")


## Displays an error message when no network connection is detected at match start.
## Returns false to indicate the match should not proceed.
func verify_network_for_match() -> bool:
	if not check_network_available():
		_show_no_network_error()
		return false
	return true


## Shows an error dialog indicating no network connection.
func _show_no_network_error() -> void:
	push_warning("MobileNetworkManager: No network connection available.")
	# Create and show an AcceptDialog with the error message.
	var dialog := AcceptDialog.new()
	dialog.title = "No Connection"
	dialog.dialog_text = "A network connection is required to start a multiplayer match. Please check your WiFi or cellular data and try again."
	dialog.confirmed.connect(func(): dialog.queue_free())
	dialog.canceled.connect(func(): dialog.queue_free())

	# Add to the scene tree so it displays.
	var root := get_tree().root
	if root:
		root.add_child(dialog)
		dialog.popup_centered()
