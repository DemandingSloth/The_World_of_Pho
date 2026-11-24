class_name LobbyManager
extends RefCounted

## Manages the pre-match lobby where players configure match settings and signal
## readiness before starting a PvP battle.
## Tracks connected players, their readiness state, and match configuration.

# ── Signals ───────────────────────────────────────────────────────────────────

## Emitted when a player's ready state changes.
signal player_ready_changed(peer_id: int, ready: bool)

## Emitted when all registered players are ready to start.
signal all_players_ready

## Emitted when the match configuration is updated by the host.
signal settings_changed(config: MatchConfig)

# ── Constants ─────────────────────────────────────────────────────────────────

const MIN_PLAYERS := 2

# ── State ─────────────────────────────────────────────────────────────────────

## Maps peer_id -> PlayerInfo for all connected players.
var players: Dictionary = {}

## The current match configuration for the lobby.
var match_config: MatchConfig = null

## The peer_id of the host (always 1 in Godot's server model).
var host_id: int = 1


# ── Public API ────────────────────────────────────────────────────────────────


## Registers a player in the lobby with the given peer_id and PlayerInfo.
## If a player with the same peer_id already exists, their info is updated.
func register_player(peer_id: int, info: PlayerInfo) -> void:
	info.peer_id = peer_id
	players[peer_id] = info


## Removes a player from the lobby by peer_id.
## Does nothing if the peer_id is not registered.
func remove_player(peer_id: int) -> void:
	players.erase(peer_id)


## Sets the ready state for a player identified by peer_id.
## Emits player_ready_changed and, if all players are now ready, all_players_ready.
func set_player_ready(peer_id: int, ready: bool) -> void:
	if not players.has(peer_id):
		return

	var info: PlayerInfo = players[peer_id]
	info.is_ready = ready
	player_ready_changed.emit(peer_id, ready)

	if _are_all_players_ready():
		all_players_ready.emit()


## Updates the match configuration and emits the settings_changed signal.
func update_match_config(config: MatchConfig) -> void:
	match_config = config
	settings_changed.emit(config)


## Returns true only when at least 2 players are present and all are ready.
## This is the gate for starting a match (Requirements 1.4, 1.6, 2.2).
func can_start_match() -> bool:
	if get_player_count() < MIN_PLAYERS:
		return false
	return _are_all_players_ready()


## Returns the number of players currently registered in the lobby.
func get_player_count() -> int:
	return players.size()


# ── Private Helpers ───────────────────────────────────────────────────────────


## Returns true if all registered players have is_ready == true.
## Returns false if no players are registered.
func _are_all_players_ready() -> bool:
	if players.is_empty():
		return false
	for peer_id in players:
		var info: PlayerInfo = players[peer_id]
		if not info.is_ready:
			return false
	return true
