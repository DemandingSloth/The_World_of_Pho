class_name PanningStats
## Manages panning-specific persisted statistics (lifetime counts, round count)
## stored within PlayerData's save file under the [panning] section.

const SAVE_SECTION := "panning"

const GEM_TYPES: Array[String] = [
	"gold",
	"blue_stone",
	"pink_stone",
	"violet_stone",
	"black_pearl",
	"emerald",
	"ruby",
	"diamond",
]

var lifetime_rounds: int = 0
var gem_counts: Dictionary = {}  # gem_type -> int


func _init() -> void:
	_reset_to_defaults()


## Loads panning stats from the given ConfigFile.
## Handles missing keys (defaults to 0) and corrupted data (resets to zeros).
func load_from_config(config: ConfigFile) -> void:
	if config == null:
		_reset_to_defaults()
		return

	# Load lifetime rounds with validation
	var loaded_rounds = config.get_value(SAVE_SECTION, "lifetime_rounds", 0)
	if loaded_rounds is int and loaded_rounds >= 0:
		lifetime_rounds = loaded_rounds
	else:
		# Corrupted — reset everything to zeros
		_reset_to_defaults()
		return

	# Load each gem count with validation
	var corrupted := false
	for gem_type in GEM_TYPES:
		var key := "gem_" + gem_type
		var loaded_count = config.get_value(SAVE_SECTION, key, 0)
		if loaded_count is int and loaded_count >= 0:
			gem_counts[gem_type] = loaded_count
		else:
			corrupted = true
			break

	if corrupted:
		_reset_to_defaults()


## Saves panning stats to the given ConfigFile.
## Writes lifetime_rounds and all 8 gem counts to the [panning] section.
func save_to_config(config: ConfigFile) -> void:
	if config == null:
		return
	config.set_value(SAVE_SECTION, "lifetime_rounds", lifetime_rounds)
	for gem_type in GEM_TYPES:
		var key := "gem_" + gem_type
		config.set_value(SAVE_SECTION, key, gem_counts.get(gem_type, 0))


## Increments the lifetime panning round count by 1.
func increment_round() -> void:
	lifetime_rounds += 1


## Increments the collection count for the given gem type by 1.
## If gem_type is not recognized, does nothing.
func increment_gem(gem_type: String) -> void:
	if gem_type in GEM_TYPES:
		gem_counts[gem_type] = gem_counts.get(gem_type, 0) + 1


## Returns true when all 8 gem type counts are >= 1.
func has_all_gem_types() -> bool:
	for gem_type in GEM_TYPES:
		if gem_counts.get(gem_type, 0) < 1:
			return false
	return true


## Resets all stats to zero defaults.
func _reset_to_defaults() -> void:
	lifetime_rounds = 0
	gem_counts.clear()
	for gem_type in GEM_TYPES:
		gem_counts[gem_type] = 0
