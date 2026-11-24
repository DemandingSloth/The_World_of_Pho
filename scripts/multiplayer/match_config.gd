class_name MatchConfig
extends Resource

## Encapsulates all configurable match parameters agreed upon in the lobby.
## Serializable for network transmission during lobby setup.

@export var terrain: Terrain.Type = Terrain.Type.INDOORS
@export var placement_time_limit: float = 120.0  ## seconds, 0 = no limit
@export var move_time_limit: float = 60.0        ## seconds per move, 0 = no limit
@export var max_hand_size: int = 20              ## max pieces each player can bring
@export var allow_king: bool = true
@export var max_king_count: int = 1


## Serializes the config into a network-safe Dictionary.
func serialize() -> Dictionary:
	return {
		"terrain": int(terrain),
		"placement_time_limit": placement_time_limit,
		"move_time_limit": move_time_limit,
		"max_hand_size": max_hand_size,
		"allow_king": allow_king,
		"max_king_count": max_king_count,
	}


## Reconstructs a MatchConfig from a serialized Dictionary.
static func deserialize(data: Dictionary) -> MatchConfig:
	var config := MatchConfig.new()
	config.terrain = data.get("terrain", Terrain.Type.INDOORS) as Terrain.Type
	config.placement_time_limit = data.get("placement_time_limit", 120.0)
	config.move_time_limit = data.get("move_time_limit", 60.0)
	config.max_hand_size = data.get("max_hand_size", 20)
	config.allow_king = data.get("allow_king", true)
	config.max_king_count = data.get("max_king_count", 1)
	return config


## Validates that all configuration values are within acceptable bounds.
## Returns true if the config is valid, false otherwise.
func validate() -> bool:
	# Time limits must be non-negative (0 means no limit, positive means active limit)
	if placement_time_limit < 0.0:
		return false
	if move_time_limit < 0.0:
		return false

	# Terrain must be a valid enum value
	var terrain_value := int(terrain)
	if terrain_value < 0 or terrain_value > int(Terrain.Type.DESERT):
		return false

	# Hand size must be between 3 and 20 (min pieces per Req 9.3, max per Req 9.2)
	if max_hand_size < 3 or max_hand_size > 20:
		return false

	# King count must be non-negative when kings are allowed
	if allow_king and max_king_count < 1:
		return false
	if max_king_count < 0:
		return false

	return true
