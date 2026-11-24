extends SceneTree

## Unit tests for MatchConfig and PlayerInfo validation.
## Run via: godot --headless --script tests/multiplayer/test_match_config_player_info.gd
##
## Validates: Requirements 9.2, 9.3, 10.2

var _tests_run := 0
var _tests_passed := 0
var _tests_failed := 0


func _init() -> void:
	print("\n========================================")
	print(" MatchConfig & PlayerInfo Unit Tests")
	print("========================================\n")

	_run_match_config_tests()
	_run_player_info_tests()
	_run_serialization_tests()

	print("\n========================================")
	print(" Results: %d passed, %d failed, %d total" % [_tests_passed, _tests_failed, _tests_run])
	print("========================================\n")

	if _tests_failed > 0:
		quit(1)
	else:
		quit(0)


# ─── Assertion Helpers ───────────────────────────────────────────────────────

func _assert_true(condition: bool, description: String) -> void:
	_tests_run += 1
	if condition:
		_tests_passed += 1
		print("  ✓ %s" % description)
	else:
		_tests_failed += 1
		print("  ✗ FAIL: %s" % description)


func _assert_false(condition: bool, description: String) -> void:
	_assert_true(not condition, description)


func _assert_eq(actual: Variant, expected: Variant, description: String) -> void:
	_tests_run += 1
	if actual == expected:
		_tests_passed += 1
		print("  ✓ %s" % description)
	else:
		_tests_failed += 1
		print("  ✗ FAIL: %s (expected: %s, got: %s)" % [description, str(expected), str(actual)])


# ─── MatchConfig Validation Tests ────────────────────────────────────────────

func _run_match_config_tests() -> void:
	print("── MatchConfig Validation ──")

	# Test: Default config is valid
	var config := MatchConfig.new()
	_assert_true(config.validate(), "Default MatchConfig is valid")

	# Test: Negative placement_time_limit is rejected
	config = MatchConfig.new()
	config.placement_time_limit = -1.0
	_assert_false(config.validate(), "Rejects negative placement_time_limit")

	# Test: Negative move_time_limit is rejected
	config = MatchConfig.new()
	config.move_time_limit = -5.0
	_assert_false(config.validate(), "Rejects negative move_time_limit")

	# Test: Zero time limits are valid (means no limit)
	config = MatchConfig.new()
	config.placement_time_limit = 0.0
	config.move_time_limit = 0.0
	_assert_true(config.validate(), "Zero time limits are valid (no limit)")

	# Test: Positive time limits are valid
	config = MatchConfig.new()
	config.placement_time_limit = 60.0
	config.move_time_limit = 30.0
	_assert_true(config.validate(), "Positive time limits are valid")

	# Test: Hand size below 3 is rejected
	config = MatchConfig.new()
	config.max_hand_size = 2
	_assert_false(config.validate(), "Rejects hand size below 3")

	# Test: Hand size of 0 is rejected
	config = MatchConfig.new()
	config.max_hand_size = 0
	_assert_false(config.validate(), "Rejects hand size of 0")

	# Test: Hand size above 20 is rejected
	config = MatchConfig.new()
	config.max_hand_size = 21
	_assert_false(config.validate(), "Rejects hand size above 20")

	# Test: Hand size of 3 (minimum) is valid
	config = MatchConfig.new()
	config.max_hand_size = 3
	_assert_true(config.validate(), "Hand size of 3 (minimum) is valid")

	# Test: Hand size of 20 (maximum) is valid
	config = MatchConfig.new()
	config.max_hand_size = 20
	_assert_true(config.validate(), "Hand size of 20 (maximum) is valid")

	# Test: Hand size of 10 (mid-range) is valid
	config = MatchConfig.new()
	config.max_hand_size = 10
	_assert_true(config.validate(), "Hand size of 10 (mid-range) is valid")

	# Test: Invalid terrain value (out of enum range) is rejected
	config = MatchConfig.new()
	config.terrain = 99 as Terrain.Type
	_assert_false(config.validate(), "Rejects invalid terrain value (99)")

	# Test: Negative terrain value is rejected
	config = MatchConfig.new()
	config.terrain = -1 as Terrain.Type
	_assert_false(config.validate(), "Rejects negative terrain value (-1)")

	# Test: Valid terrain DESERT (last enum) is accepted
	config = MatchConfig.new()
	config.terrain = Terrain.Type.DESERT
	_assert_true(config.validate(), "Valid terrain DESERT is accepted")

	# Test: Valid terrain INDOORS (first enum) is accepted
	config = MatchConfig.new()
	config.terrain = Terrain.Type.INDOORS
	_assert_true(config.validate(), "Valid terrain INDOORS is accepted")

	print("")


# ─── PlayerInfo Validation Tests ─────────────────────────────────────────────

func _run_player_info_tests() -> void:
	print("── PlayerInfo Validation ──")

	# Test: Valid PlayerInfo passes is_valid()
	var info := PlayerInfo.new()
	info.peer_id = 1
	info.display_name = "TestPlayer"
	info.level = 5
	_assert_true(info.is_valid(), "Valid PlayerInfo passes is_valid()")

	# Test: Empty display_name fails validation
	info = PlayerInfo.new()
	info.peer_id = 1
	info.display_name = ""
	info.level = 1
	_assert_false(info.is_valid(), "Empty display_name fails is_valid()")

	# Test: display_name exceeding 20 chars fails is_valid()
	info = PlayerInfo.new()
	info.peer_id = 1
	info.display_name = "ThisNameIsWayTooLongForDisplay"
	info.level = 1
	_assert_false(info.is_valid(), "display_name exceeding 20 chars fails is_valid()")

	# Test: display_name exactly 20 chars passes is_valid()
	info = PlayerInfo.new()
	info.peer_id = 1
	info.display_name = "ExactlyTwentyChars!!"
	info.level = 1
	_assert_true(info.is_valid(), "display_name exactly 20 chars passes is_valid()")

	# Test: _apply_validation truncates long display_name to 20 chars
	info = PlayerInfo.new()
	info.peer_id = 1
	info.display_name = "ThisNameIsWayTooLongForDisplay"
	info.level = 1
	info._apply_validation()
	_assert_eq(info.display_name.length(), 20, "_apply_validation truncates display_name to 20 chars")
	_assert_eq(info.display_name, "ThisNameIsWayTooLong", "_apply_validation truncates correctly")

	# Test: _apply_validation replaces empty name with "Unknown"
	info = PlayerInfo.new()
	info.peer_id = 1
	info.display_name = ""
	info.level = 1
	info._apply_validation()
	_assert_eq(info.display_name, "Unknown", "_apply_validation replaces empty name with 'Unknown'")

	# Test: peer_id < 1 fails is_valid()
	info = PlayerInfo.new()
	info.peer_id = 0
	info.display_name = "Player"
	info.level = 1
	_assert_false(info.is_valid(), "peer_id of 0 fails is_valid()")

	# Test: _apply_validation corrects peer_id < 1 to 1
	info = PlayerInfo.new()
	info.peer_id = 0
	info.display_name = "Player"
	info.level = 1
	info._apply_validation()
	_assert_eq(info.peer_id, 1, "_apply_validation corrects peer_id 0 to 1")

	# Test: level < 1 fails is_valid()
	info = PlayerInfo.new()
	info.peer_id = 1
	info.display_name = "Player"
	info.level = 0
	_assert_false(info.is_valid(), "level of 0 fails is_valid()")

	# Test: _apply_validation corrects level < 1 to 1
	info = PlayerInfo.new()
	info.peer_id = 1
	info.display_name = "Player"
	info.level = -5
	info._apply_validation()
	_assert_eq(info.level, 1, "_apply_validation corrects negative level to 1")

	print("")


# ─── Serialization Round-Trip Tests ──────────────────────────────────────────

func _run_serialization_tests() -> void:
	print("── Serialization Round-Trip ──")

	# Test: MatchConfig serialize/deserialize round-trip preserves all fields
	var config := MatchConfig.new()
	config.terrain = Terrain.Type.FOREST
	config.placement_time_limit = 90.0
	config.move_time_limit = 45.0
	config.max_hand_size = 15
	config.allow_king = false
	config.max_king_count = 2

	var serialized := config.serialize()
	var restored := MatchConfig.deserialize(serialized)

	_assert_eq(int(restored.terrain), int(Terrain.Type.FOREST), "MatchConfig round-trip preserves terrain")
	_assert_eq(restored.placement_time_limit, 90.0, "MatchConfig round-trip preserves placement_time_limit")
	_assert_eq(restored.move_time_limit, 45.0, "MatchConfig round-trip preserves move_time_limit")
	_assert_eq(restored.max_hand_size, 15, "MatchConfig round-trip preserves max_hand_size")
	_assert_eq(restored.allow_king, false, "MatchConfig round-trip preserves allow_king")
	_assert_eq(restored.max_king_count, 2, "MatchConfig round-trip preserves max_king_count")

	# Test: MatchConfig round-trip with default values
	config = MatchConfig.new()
	serialized = config.serialize()
	restored = MatchConfig.deserialize(serialized)

	_assert_eq(int(restored.terrain), int(Terrain.Type.INDOORS), "MatchConfig default round-trip preserves terrain")
	_assert_eq(restored.placement_time_limit, 120.0, "MatchConfig default round-trip preserves placement_time_limit")
	_assert_eq(restored.move_time_limit, 60.0, "MatchConfig default round-trip preserves move_time_limit")
	_assert_eq(restored.max_hand_size, 20, "MatchConfig default round-trip preserves max_hand_size")
	_assert_eq(restored.allow_king, true, "MatchConfig default round-trip preserves allow_king")
	_assert_eq(restored.max_king_count, 1, "MatchConfig default round-trip preserves max_king_count")

	# Test: PlayerInfo serialize/deserialize round-trip preserves all fields
	var info := PlayerInfo.new()
	info.peer_id = 42
	info.display_name = "BattleMaster"
	info.level = 10
	info.is_ready = true
	info.is_host = true

	var info_serialized := info.serialize()
	var info_restored := PlayerInfo.deserialize(info_serialized)

	_assert_eq(info_restored.peer_id, 42, "PlayerInfo round-trip preserves peer_id")
	_assert_eq(info_restored.display_name, "BattleMaster", "PlayerInfo round-trip preserves display_name")
	_assert_eq(info_restored.level, 10, "PlayerInfo round-trip preserves level")
	_assert_eq(info_restored.is_ready, true, "PlayerInfo round-trip preserves is_ready")
	_assert_eq(info_restored.is_host, true, "PlayerInfo round-trip preserves is_host")

	# Test: PlayerInfo deserialize applies validation (truncates long name)
	var long_name_data := {
		"peer_id": 5,
		"display_name": "AVeryLongPlayerNameThatExceedsTwenty",
		"level": 3,
		"is_ready": false,
		"is_host": false,
	}
	var info_from_long := PlayerInfo.deserialize(long_name_data)
	_assert_eq(info_from_long.display_name.length(), 20, "PlayerInfo deserialize truncates long display_name")
	_assert_eq(info_from_long.peer_id, 5, "PlayerInfo deserialize preserves peer_id")
	_assert_eq(info_from_long.level, 3, "PlayerInfo deserialize preserves level")

	# Test: PlayerInfo deserialize applies validation (empty name becomes Unknown)
	var empty_name_data := {
		"peer_id": 7,
		"display_name": "",
		"level": 1,
		"is_ready": false,
		"is_host": false,
	}
	var info_from_empty := PlayerInfo.deserialize(empty_name_data)
	_assert_eq(info_from_empty.display_name, "Unknown", "PlayerInfo deserialize replaces empty name with 'Unknown'")

	# Test: PlayerInfo deserialize with missing keys uses defaults
	var partial_data := {"peer_id": 3}
	var info_partial := PlayerInfo.deserialize(partial_data)
	_assert_eq(info_partial.peer_id, 3, "PlayerInfo deserialize with partial data preserves peer_id")
	_assert_eq(info_partial.display_name, "Unknown", "PlayerInfo deserialize with missing display_name uses 'Unknown'")
	_assert_eq(info_partial.level, 1, "PlayerInfo deserialize with missing level uses 1")
	_assert_eq(info_partial.is_ready, false, "PlayerInfo deserialize with missing is_ready uses false")
	_assert_eq(info_partial.is_host, false, "PlayerInfo deserialize with missing is_host uses false")

	# Test: MatchConfig deserialize with missing keys uses defaults
	var empty_config_data := {}
	var config_from_empty := MatchConfig.deserialize(empty_config_data)
	_assert_eq(int(config_from_empty.terrain), int(Terrain.Type.INDOORS), "MatchConfig deserialize with empty dict uses default terrain")
	_assert_eq(config_from_empty.placement_time_limit, 120.0, "MatchConfig deserialize with empty dict uses default placement_time_limit")
	_assert_eq(config_from_empty.move_time_limit, 60.0, "MatchConfig deserialize with empty dict uses default move_time_limit")
	_assert_eq(config_from_empty.max_hand_size, 20, "MatchConfig deserialize with empty dict uses default max_hand_size")

	print("")
