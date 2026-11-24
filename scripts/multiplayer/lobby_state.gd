class_name LobbyState
extends RefCounted

## Represents the current state of a multiplayer lobby session.
## Contains host and guest player info, match configuration, and a lobby code.
## Serializable for network transmission between host and client.

const LOBBY_CODE_LENGTH := 6
const LOBBY_CODE_CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

var host_info: PlayerInfo = null
var guest_info: PlayerInfo = null  ## null if no guest connected
var match_config: MatchConfig = null
var lobby_code: String = ""  ## 6-char alphanumeric code for display


## Serializes the lobby state into a network-safe Dictionary.
func serialize() -> Dictionary:
	return {
		"host": host_info.serialize() if host_info else {},
		"guest": guest_info.serialize() if guest_info else {},
		"config": match_config.serialize() if match_config else {},
		"code": lobby_code,
	}


## Reconstructs a LobbyState from a serialized Dictionary.
static func deserialize(data: Dictionary) -> LobbyState:
	var state := LobbyState.new()

	var host_data: Dictionary = data.get("host", {})
	if not host_data.is_empty():
		state.host_info = PlayerInfo.deserialize(host_data)

	var guest_data: Dictionary = data.get("guest", {})
	if not guest_data.is_empty():
		state.guest_info = PlayerInfo.deserialize(guest_data)

	var config_data: Dictionary = data.get("config", {})
	if not config_data.is_empty():
		state.match_config = MatchConfig.deserialize(config_data)

	state.lobby_code = data.get("code", "")
	return state


## Generates a random 6-character alphanumeric lobby code.
static func generate_lobby_code() -> String:
	var code := ""
	for i in LOBBY_CODE_LENGTH:
		code += LOBBY_CODE_CHARS[randi() % LOBBY_CODE_CHARS.length()]
	return code


## Returns true if the lobby code is valid (exactly 6 uppercase alphanumeric characters).
func is_valid_lobby_code() -> bool:
	if lobby_code.length() != LOBBY_CODE_LENGTH:
		return false
	for i in lobby_code.length():
		if not LOBBY_CODE_CHARS.contains(lobby_code[i]):
			return false
	return true
