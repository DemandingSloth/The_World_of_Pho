class_name PlayerInfo
extends RefCounted

## Represents a player in the multiplayer lobby and match.
## Serializable for network transmission between host and client.

const MAX_DISPLAY_NAME_LENGTH := 20

var peer_id: int = 0
var display_name: String = ""
var level: int = 1
var is_ready: bool = false
var is_host: bool = false


## Serializes the player info into a network-safe Dictionary.
func serialize() -> Dictionary:
	return {
		"peer_id": peer_id,
		"display_name": display_name,
		"level": level,
		"is_ready": is_ready,
		"is_host": is_host,
	}


## Reconstructs a PlayerInfo from a serialized Dictionary.
static func deserialize(data: Dictionary) -> PlayerInfo:
	var info := PlayerInfo.new()
	info.peer_id = data.get("peer_id", 0)
	info.display_name = data.get("display_name", "Unknown")
	info.level = data.get("level", 1)
	info.is_ready = data.get("is_ready", false)
	info.is_host = data.get("is_host", false)
	info._apply_validation()
	return info


## Validates and corrects player info values.
## - peer_id must be > 0
## - display_name must be non-empty, truncated to 20 chars
## - level must be >= 1
func _apply_validation() -> void:
	if peer_id < 1:
		peer_id = 1

	if display_name.is_empty():
		display_name = "Unknown"

	if display_name.length() > MAX_DISPLAY_NAME_LENGTH:
		display_name = display_name.left(MAX_DISPLAY_NAME_LENGTH)

	if level < 1:
		level = 1


## Returns true if the player info passes all validation checks without correction.
func is_valid() -> bool:
	if peer_id < 1:
		return false
	if display_name.is_empty():
		return false
	if display_name.length() > MAX_DISPLAY_NAME_LENGTH:
		return false
	if level < 1:
		return false
	return true
