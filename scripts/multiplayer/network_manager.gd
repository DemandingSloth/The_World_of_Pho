extends Node

## Manages the multiplayer connection lifecycle, lobby state, and RPC routing.
## Acts as the bridge between network events and game logic.
## Register this script as an autoload singleton in Project Settings.

# ── Signals ───────────────────────────────────────────────────────────────────

## Emitted when a connection to a peer is successfully established.
signal connection_established(peer_id: int)

## Emitted when a connection attempt fails (timeout, refused, etc.).
signal connection_failed(reason: String)

## Emitted when a new player joins the lobby.
signal player_joined(player_info: Dictionary)

## Emitted when a player leaves the lobby or disconnects.
signal player_left(peer_id: int)

## Emitted when the lobby state changes (player joins, readies up, settings change).
signal lobby_state_changed(lobby: LobbyState)

## Emitted when the host starts the match and both players should transition.
signal match_starting(config: MatchConfig)

## Emitted when the connection is lost or intentionally closed.
signal disconnected(reason: String)

# ── Enums ─────────────────────────────────────────────────────────────────────

enum ConnectionState {
	DISCONNECTED,
	CONNECTING,
	CONNECTED,
	IN_MATCH,
}

# ── Constants ─────────────────────────────────────────────────────────────────

const MIN_PORT := 1024
const MAX_PORT := 65535
const MAX_CLIENTS := 1  ## 1v1 only
const CONNECTION_TIMEOUT_SEC := 10.0
const HEARTBEAT_INTERVAL_SEC := 1.0
const DISCONNECT_THRESHOLD_SEC := 5.0

# ── State ─────────────────────────────────────────────────────────────────────

var state: ConnectionState = ConnectionState.DISCONNECTED
var peer: ENetMultiplayerPeer = null
var local_peer_id: int = 0
var is_host: bool = false
var lobby: LobbyState = null

## Stores the local player's selected battle pieces (set during piece selection,
## persists across scene change to multiplayer_battle.tscn).
var local_battle_pieces: Array = []  ## Array of Dictionary {type, direction}

## Connection timeout timer — starts when client calls join_server().
var _connection_timer: Timer = null

## Heartbeat timer — ticks every 1 second after connection is established.
var _heartbeat_timer: Timer = null

## Timestamp (msec) of the last heartbeat response received from the peer.
var _last_heartbeat_response_msec: int = 0

## The round-trip latency measured from the most recent heartbeat exchange.
var _latency_ms: int = 0

## Timestamp (msec) when the most recent ping was sent (used to calculate RTT).
var _ping_sent_msec: int = 0


# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	# Connect to the SceneTree multiplayer signals once ready.
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)

	# Create the connection timeout timer (one-shot, starts on join_server).
	_connection_timer = Timer.new()
	_connection_timer.one_shot = true
	_connection_timer.wait_time = CONNECTION_TIMEOUT_SEC
	_connection_timer.timeout.connect(_on_connection_timeout)
	add_child(_connection_timer)

	# Create the heartbeat timer (repeating, starts after connection established).
	_heartbeat_timer = Timer.new()
	_heartbeat_timer.one_shot = false
	_heartbeat_timer.wait_time = HEARTBEAT_INTERVAL_SEC
	_heartbeat_timer.timeout.connect(_on_heartbeat_tick)
	add_child(_heartbeat_timer)


# ── Public API ────────────────────────────────────────────────────────────────


## Returns the most recently measured round-trip latency in milliseconds.
## Returns 0 if no heartbeat response has been received yet.
func get_latency_ms() -> int:
	return _latency_ms


## Creates a server that listens on the specified port.
## Returns OK on success, or an error code on failure.
## Validates that the port is within the acceptable range (1024–65535).
func create_server(port: int) -> Error:
	if state != ConnectionState.DISCONNECTED:
		return ERR_ALREADY_IN_USE

	if not _is_valid_port(port):
		return ERR_INVALID_PARAMETER

	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		peer = null
		return err

	multiplayer.multiplayer_peer = peer
	is_host = true
	local_peer_id = 1
	state = ConnectionState.CONNECTED

	# Initialize lobby with host info
	lobby = LobbyState.new()
	lobby.lobby_code = LobbyState.generate_lobby_code()
	lobby.match_config = MatchConfig.new()

	# Set host player info (display_name can be updated later via UI).
	var host_player := PlayerInfo.new()
	host_player.peer_id = 1
	host_player.is_host = true
	host_player.display_name = "Host"
	lobby.host_info = host_player

	connection_established.emit(local_peer_id)
	return OK


## Joins a server at the specified address and port.
## Returns OK if the connection attempt started, or an error code on failure.
## The actual connection result is reported via connection_established or connection_failed.
func join_server(address: String, port: int) -> Error:
	if state != ConnectionState.DISCONNECTED:
		return ERR_ALREADY_IN_USE

	if address.is_empty():
		return ERR_INVALID_PARAMETER

	if not _is_valid_port(port):
		return ERR_INVALID_PARAMETER

	peer = ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		peer = null
		return err

	multiplayer.multiplayer_peer = peer
	is_host = false
	state = ConnectionState.CONNECTING

	# Start the connection timeout timer.
	_connection_timer.start()

	return OK


## Cleanly disconnects from the current match or lobby.
## Closes the ENet peer and resets all connection state.
func disconnect_from_match() -> void:
	_stop_heartbeat()
	_connection_timer.stop()

	if peer != null:
		peer.close()
		peer = null

	multiplayer.multiplayer_peer = null

	var previous_state := state
	state = ConnectionState.DISCONNECTED
	is_host = false
	local_peer_id = 0
	lobby = null

	if previous_state != ConnectionState.DISCONNECTED:
		disconnected.emit("Player disconnected")


# ── Signal Handlers ───────────────────────────────────────────────────────────


## Called on the server when a new peer connects.
func _on_peer_connected(peer_id: int) -> void:
	if is_host:
		# Reject if lobby already has a guest (session full per Requirement 2.6).
		if lobby != null and lobby.guest_info != null:
			# Force disconnect the new peer — lobby is full.
			peer.disconnect_peer(peer_id)
			return
		_start_heartbeat()


## Called on the server when a peer disconnects.
func _on_peer_disconnected(peer_id: int) -> void:
	if is_host and lobby != null:
		# Remove guest from lobby if the disconnected peer was the guest.
		if lobby.guest_info != null and lobby.guest_info.peer_id == peer_id:
			lobby.guest_info = null
			_broadcast_lobby_state()
	player_left.emit(peer_id)


## Called on the client when successfully connected to the server.
func _on_connected_to_server() -> void:
	_connection_timer.stop()
	state = ConnectionState.CONNECTED
	local_peer_id = multiplayer.get_unique_id()
	_start_heartbeat()
	connection_established.emit(local_peer_id)


## Called on the client when the connection attempt fails.
func _on_connection_failed() -> void:
	_connection_timer.stop()
	state = ConnectionState.DISCONNECTED
	peer = null
	multiplayer.multiplayer_peer = null
	local_peer_id = 0
	connection_failed.emit("Connection to server failed")


# ── Private Helpers ───────────────────────────────────────────────────────────


## Returns true if the port number is within the valid range (1024–65535).
func _is_valid_port(port: int) -> bool:
	return port >= MIN_PORT and port <= MAX_PORT


# ── Connection Timeout ────────────────────────────────────────────────────────


## Fired when the 10-second connection timeout expires without a successful connection.
func _on_connection_timeout() -> void:
	if state == ConnectionState.CONNECTING:
		# Tear down the failed connection attempt.
		if peer != null:
			peer.close()
			peer = null
		multiplayer.multiplayer_peer = null
		state = ConnectionState.DISCONNECTED
		local_peer_id = 0
		connection_failed.emit("Connection timed out")


# ── Heartbeat System ──────────────────────────────────────────────────────────


## Starts the heartbeat timer and initializes response tracking.
func _start_heartbeat() -> void:
	_last_heartbeat_response_msec = Time.get_ticks_msec()
	_latency_ms = 0
	_ping_sent_msec = 0
	_heartbeat_timer.start()


## Stops the heartbeat timer.
func _stop_heartbeat() -> void:
	_heartbeat_timer.stop()


## Called every HEARTBEAT_INTERVAL_SEC (1 second). Sends a ping and checks for
## disconnection based on DISCONNECT_THRESHOLD_SEC (5 seconds without response).
func _on_heartbeat_tick() -> void:
	if state == ConnectionState.DISCONNECTED:
		_stop_heartbeat()
		return

	# Check if the peer has gone silent for too long.
	var now_msec := Time.get_ticks_msec()
	var elapsed_since_response := (now_msec - _last_heartbeat_response_msec) / 1000.0
	if elapsed_since_response >= DISCONNECT_THRESHOLD_SEC:
		_handle_heartbeat_timeout()
		return

	# Send a ping to the connected peer.
	_ping_sent_msec = now_msec
	if multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_send_ping.rpc()


## Handles peer classified as disconnected due to heartbeat timeout (Requirement 7.5).
func _handle_heartbeat_timeout() -> void:
	_stop_heartbeat()
	# Emit the disconnected signal so higher-level systems can react.
	disconnected.emit("Peer timed out (no heartbeat response)")


## RPC: Ping sent to the remote peer. The recipient responds with a pong.
@rpc("any_peer", "unreliable")
func _send_ping() -> void:
	# Respond immediately with a pong back to the sender.
	var sender_id := multiplayer.get_remote_sender_id()
	_send_pong.rpc_id(sender_id)


## RPC: Pong received from the remote peer, confirming they are alive.
@rpc("any_peer", "unreliable")
func _send_pong() -> void:
	var now_msec := Time.get_ticks_msec()
	_last_heartbeat_response_msec = now_msec
	# Calculate round-trip time from the last ping we sent.
	if _ping_sent_msec > 0:
		_latency_ms = now_msec - _ping_sent_msec


# ── Lobby RPC Handlers ────────────────────────────────────────────────────────


## RPC: Called by the client after connecting to register their player info with the host.
## The host validates the registration and either accepts (updating lobby state) or
## rejects the connection if the lobby is already full (Requirement 2.6).
@rpc("any_peer", "reliable")
func register_player(player_info_data: Dictionary) -> void:
	if not is_host:
		return  # Only the host processes registrations.

	var sender_id := multiplayer.get_remote_sender_id()

	# Reject if lobby already has a guest (session full per Requirement 2.6).
	if lobby == null:
		return
	if lobby.guest_info != null:
		peer.disconnect_peer(sender_id)
		return

	# Deserialize and validate the player info from the client.
	var info := PlayerInfo.deserialize(player_info_data)
	info.peer_id = sender_id  # Enforce the actual peer ID from the network layer.
	info.is_host = false

	# Register the guest in the lobby.
	lobby.guest_info = info

	# Emit player_joined with serialized info so listeners can react.
	player_joined.emit(info.serialize())

	# Broadcast updated lobby state to all peers.
	_broadcast_lobby_state()


## RPC: Called by the host (authority) to push updated lobby state to clients.
## Clients receive this and update their local lobby state accordingly.
@rpc("authority", "reliable")
func lobby_state_updated(lobby_data: Dictionary) -> void:
	if is_host:
		return  # Host doesn't process its own broadcast.

	# Deserialize the lobby state from the host.
	lobby = LobbyState.deserialize(lobby_data)

	# Emit lobby_state_changed so UI and other systems can react.
	lobby_state_changed.emit(lobby)


## Broadcasts the current lobby state to all connected clients.
## Called on the host whenever lobby state changes (player joins, leaves, settings change).
func _broadcast_lobby_state() -> void:
	if not is_host:
		return
	if lobby == null:
		return

	var lobby_data := lobby.serialize()

	# Send to all connected clients via the authority RPC.
	lobby_state_updated.rpc(lobby_data)

	# Also emit locally on the host so host-side UI updates.
	lobby_state_changed.emit(lobby)
