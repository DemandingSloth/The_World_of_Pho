extends Node

## Autoload: AndroidLifecycleManager
## Manages Android-specific lifecycle events, state persistence, and back button navigation.
## Handles: pause/resume, quick-save/restore, navigation stack, and PlayerData persistence.
## Also serves as the central coordination hub for cross-singleton wiring (Req 4.3, 6.4).

signal state_saved()
signal state_restored()

## Emitted when the app enters background. Other managers can connect for coordinated behavior.
## (Req 4.3: Background → all managers save/throttle)
signal app_backgrounded()

## Emitted when the app returns to foreground. Other managers can connect for coordinated behavior.
## (Req 6.4: Performance manager responds to lifecycle)
signal app_foregrounded()

const QUICK_SAVE_PATH := "user://quick_save.cfg"
const SAVE_TIMEOUT_SEC := 1.0
const SAVE_VERSION := 1

## If the app was backgrounded at least this long, show the prospector report
## on resume (same popup as a cold start) so players see what accrued while away.
const IDLE_PROSPECTOR_REPORT_SEC := 900.0  ## 15 minutes

var _navigation_stack: Array[String] = []
var _current_screen: String = "home"
var _battle_state_cache: Dictionary = {}

## Unix time the app was last backgrounded (0 = not currently backgrounded).
var _backgrounded_at: float = 0.0

## Emitted on foreground return when the app was idle >= IDLE_PROSPECTOR_REPORT_SEC.
## main.gd listens and shows the prospector report popup.
signal resumed_after_idle()


func _ready() -> void:
	## Listen for corrupted save data to show player notification (Req 7.5)
	PlayerData.save_corrupted.connect(_on_save_corrupted)

	## If corruption was detected during PlayerData._ready() (which runs before us),
	## show the notification once the scene tree is ready.
	if PlayerData.corruption_detected:
		_show_corruption_notification.call_deferred()

	## Attempt to restore state from a previous session (cold start recovery)
	var restored := restore_quick_state()
	if not restored.is_empty():
		_current_screen = restored.get("current_screen", "home")
		var stack = restored.get("navigation_stack", [])
		_navigation_stack.clear()
		for item in stack:
			_navigation_stack.append(str(item))
		_battle_state_cache = restored.get("battle_state", {})
		state_restored.emit()

	## Wire cross-singleton connections once all autoloads are initialized.
	_wire_singleton_connections.call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_on_application_paused()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_on_application_resumed()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_handle_back_button()


func _unhandled_input(event: InputEvent) -> void:
	## Handle back button via ui_cancel action (Android back maps to this)
	if event.is_action_pressed("ui_cancel"):
		_handle_back_button()
		get_viewport().set_input_as_handled()


## ── Navigation Stack ────────────────────────────────────────────────


## Push a new screen onto the navigation stack.
func push_screen(screen_name: String) -> void:
	if screen_name == "home":
		_navigation_stack.clear()
		_current_screen = "home"
		return
	if _current_screen != "" and _current_screen != screen_name:
		_navigation_stack.append(_current_screen)
	_current_screen = screen_name


## Pop the top screen from the navigation stack. Returns the previous screen name.
func pop_screen() -> String:
	if _navigation_stack.is_empty():
		return ""
	var previous := _navigation_stack[-1]
	_navigation_stack.remove_at(_navigation_stack.size() - 1)
	_current_screen = previous
	return previous


## Returns the current screen name.
func get_current_screen() -> String:
	return _current_screen


## Returns true if navigation stack has entries to go back to.
func can_go_back() -> bool:
	return not _navigation_stack.is_empty()


## ── Back Button Handling ────────────────────────────────────────────


func _handle_back_button() -> void:
	if _current_screen == "home" and _navigation_stack.is_empty():
		## On home screen with empty stack — exit application (Req 4.1)
		get_tree().quit()
	else:
		## On sub-screen — navigate back (Req 4.2)
		pop_screen()


## ── Lifecycle Events ────────────────────────────────────────────────


func _on_application_paused() -> void:
	## Save state within 1-second budget (Req 4.3)
	save_quick_state()
	## Also persist all autoload data
	_persist_all_data()
	## Remember when we went to background so resume can measure idle time.
	_backgrounded_at = TrustedClock.now()
	## Notify other managers via signal for coordinated background behavior (Req 4.3)
	app_backgrounded.emit()


func _on_application_resumed() -> void:
	## Restore saved state on foreground return (Req 4.4)
	var restored := restore_quick_state()
	if not restored.is_empty():
		## Restore navigation state so get_current_screen() reflects where the player was
		_current_screen = restored.get("current_screen", _current_screen)
		var stack = restored.get("navigation_stack", null)
		if stack != null:
			_navigation_stack.clear()
			for item in stack:
				_navigation_stack.append(str(item))
		_battle_state_cache = restored.get("battle_state", {})
		state_restored.emit()

	## If we were backgrounded long enough, collect the prospector gems that
	## accrued while away and surface the report popup (same as a cold start).
	## collect_prospector_gems() uses real wall-clock timestamps, so the gems
	## already accrued during the pause — this just grabs them and shows them.
	if _backgrounded_at > 0.0:
		var idle := TrustedClock.now() - _backgrounded_at
		_backgrounded_at = 0.0
		if idle >= IDLE_PROSPECTOR_REPORT_SEC:
			var haul := PlayerData.collect_prospector_gems()
			if not haul.is_empty():
				PlayerData.offline_prospector_haul = haul
				resumed_after_idle.emit()

	## Notify other managers via signal for coordinated foreground behavior (Req 6.4)
	app_foregrounded.emit()


## ── Quick State Save/Restore ────────────────────────────────────────


## Serializes current game state to user://quick_save.cfg within 1-second budget.
## Covers: navigation stack, current screen, battle state, and mining state.
func save_quick_state() -> void:
	var start_time := Time.get_ticks_msec()
	var config := ConfigFile.new()

	## Header
	config.set_value("meta", "version", SAVE_VERSION)
	config.set_value("meta", "timestamp", TrustedClock.now())

	## Navigation state
	config.set_value("navigation", "current_screen", _current_screen)
	var stack_data: Array = []
	for item in _navigation_stack:
		stack_data.append(item)
	config.set_value("navigation", "navigation_stack", stack_data)

	## Battle state — serialize if a GameManager is active in the scene tree
	var game_manager := _find_game_manager()
	if game_manager != null and game_manager.current_phase != GameManager.Phase.CAMPAIGN_SETUP:
		var battle_data := serialize_battle_state(game_manager)
		config.set_value("battle", "state", battle_data)

	## Mining state — serialize if a MiningGame is active
	var mining_game := _find_mining_game()
	if mining_game != null and mining_game.is_game_active():
		var mining_data := _serialize_mining_state(mining_game)
		config.set_value("mining", "state", mining_data)

	## Write to disk
	var err := config.save(QUICK_SAVE_PATH)
	if err == OK:
		state_saved.emit()

	## Log timing for performance monitoring
	var elapsed := Time.get_ticks_msec() - start_time
	if elapsed > int(SAVE_TIMEOUT_SEC * 1000):
		push_warning("AndroidLifecycleManager: save_quick_state took %dms (budget: %dms)" % [elapsed, int(SAVE_TIMEOUT_SEC * 1000)])


## Deserializes and returns the saved game state from user://quick_save.cfg.
## Returns an empty dictionary if no save exists or the file is corrupted.
func restore_quick_state() -> Dictionary:
	var config := ConfigFile.new()
	var err := config.load(QUICK_SAVE_PATH)
	if err != OK:
		return {}

	## Validate version
	var version: int = config.get_value("meta", "version", 0)
	if version != SAVE_VERSION:
		return {}

	var result: Dictionary = {}
	result["version"] = version
	result["timestamp"] = config.get_value("meta", "timestamp", 0.0)
	result["current_screen"] = config.get_value("navigation", "current_screen", "home")
	result["navigation_stack"] = config.get_value("navigation", "navigation_stack", [])

	## Battle state
	var battle_data = config.get_value("battle", "state", {})
	if not battle_data.is_empty():
		result["battle_state"] = battle_data

	## Mining state
	var mining_data = config.get_value("mining", "state", {})
	if not mining_data.is_empty():
		result["mining_state"] = mining_data

	return result


## ── Battle State Serialization ──────────────────────────────────────


## Serializes the full battle state from a GameManager instance.
func serialize_battle_state(game_manager: GameManager) -> Dictionary:
	var data: Dictionary = {}

	## Phase
	data["phase"] = int(game_manager.current_phase)

	## Board grid — 8x8 array of piece data or null
	var board_grid: Array = []
	if game_manager.board != null:
		for r in range(BoardState.BOARD_SIZE):
			var row_data: Array = []
			for c in range(BoardState.BOARD_SIZE):
				var piece: Piece = game_manager.board.get_piece(r, c)
				if piece != null:
					row_data.append(_serialize_piece(piece))
				else:
					row_data.append(null)
			board_grid.append(row_data)
	data["board_grid"] = board_grid

	## Player hand
	var player_hand_data: Array = []
	if game_manager.player_hand != null:
		for piece in game_manager.player_hand.pieces:
			player_hand_data.append(_serialize_piece(piece))
	data["player_hand"] = player_hand_data

	## Enemy hand
	var enemy_hand_data: Array = []
	if game_manager.enemy_hand != null:
		for piece in game_manager.enemy_hand.pieces:
			enemy_hand_data.append(_serialize_piece(piece))
	data["enemy_hand"] = enemy_hand_data

	## Placement turn
	data["placement_turn"] = int(game_manager.placement_turn)

	## Movement state
	var movement_data: Dictionary = {}
	if game_manager.movement != null:
		movement_data["current_turn"] = int(game_manager.movement.current_turn)
		movement_data["current_round"] = game_manager.movement.current_round
		movement_data["phase_complete"] = game_manager.movement.phase_complete
		## Serialize moved_pieces as board positions (since piece refs won't persist)
		var moved_positions: Array = []
		if game_manager.board != null:
			for piece_ref in game_manager.movement.moved_pieces:
				var pos := game_manager.board.find_piece(piece_ref)
				if pos[0] != -1:
					moved_positions.append(pos)
		movement_data["moved_pieces"] = moved_positions
	data["movement_state"] = movement_data

	## Campaign state
	var campaign_data: Dictionary = {}
	if game_manager.campaign != null:
		campaign_data["current_battle"] = game_manager.campaign.current_battle
		campaign_data["wins"] = game_manager.campaign.wins
		var enemy_seq: Array = []
		for enemy_type in game_manager.campaign.enemy_sequence:
			enemy_seq.append(int(enemy_type))
		campaign_data["enemy_sequence"] = enemy_seq
		campaign_data["terrain"] = int(game_manager.current_terrain)
		campaign_data["is_active"] = game_manager.campaign.is_active
	data["campaign_state"] = campaign_data

	return data


## Deserializes battle state and restores it into a GameManager instance.
func deserialize_battle_state(data: Dictionary, game_manager: GameManager) -> void:
	if data.is_empty():
		return

	## Restore phase
	game_manager.current_phase = data.get("phase", 0) as GameManager.Phase

	## Restore terrain
	var campaign_data: Dictionary = data.get("campaign_state", {})
	game_manager.current_terrain = campaign_data.get("terrain", 0) as Terrain.Type

	## Restore board
	game_manager.board = BoardState.new()
	var board_grid: Array = data.get("board_grid", [])
	for r in range(mini(board_grid.size(), BoardState.BOARD_SIZE)):
		var row_data: Array = board_grid[r]
		for c in range(mini(row_data.size(), BoardState.BOARD_SIZE)):
			if row_data[c] != null:
				var piece := _deserialize_piece(row_data[c])
				if piece != null:
					game_manager.board.grid[r][c] = piece

	## Restore player hand
	game_manager.player_hand = Hand.new()
	var player_hand_data: Array = data.get("player_hand", [])
	for piece_data in player_hand_data:
		var piece := _deserialize_piece(piece_data)
		if piece != null:
			game_manager.player_hand.pieces.append(piece)

	## Restore enemy hand
	game_manager.enemy_hand = Hand.new()
	var enemy_hand_data: Array = data.get("enemy_hand", [])
	for piece_data in enemy_hand_data:
		var piece := _deserialize_piece(piece_data)
		if piece != null:
			game_manager.enemy_hand.pieces.append(piece)

	## Restore placement turn
	game_manager.placement_turn = data.get("placement_turn", 0) as Piece.Owner

	## Restore movement state
	game_manager.movement = Movement.new(game_manager.board)
	var movement_data: Dictionary = data.get("movement_state", {})
	if not movement_data.is_empty():
		game_manager.movement.current_turn = movement_data.get("current_turn", 0) as Piece.Owner
		game_manager.movement.current_round = movement_data.get("current_round", 1)
		game_manager.movement.phase_complete = movement_data.get("phase_complete", false)
		## Restore moved_pieces from positions
		var moved_positions: Array = movement_data.get("moved_pieces", [])
		for pos in moved_positions:
			if pos is Array and pos.size() >= 2:
				var piece := game_manager.board.get_piece(pos[0], pos[1])
				if piece != null:
					game_manager.movement.moved_pieces[piece] = true

	## Restore campaign state
	if not campaign_data.is_empty():
		game_manager.campaign = CampaignManager.new()
		game_manager.campaign.current_battle = campaign_data.get("current_battle", 0)
		game_manager.campaign.wins = campaign_data.get("wins", 0)
		game_manager.campaign.is_active = campaign_data.get("is_active", false)
		var enemy_seq: Array = campaign_data.get("enemy_sequence", [])
		game_manager.campaign.enemy_sequence.clear()
		for et in enemy_seq:
			game_manager.campaign.enemy_sequence.append(int(et))


## ── Mining State Serialization ──────────────────────────────────────


func _serialize_mining_state(mining_game: MiningGame) -> Dictionary:
	var data: Dictionary = {}
	data["grid_width"] = mining_game.grid_width
	data["grid_height"] = mining_game.grid_height
	data["mine_count"] = mining_game.mine_count
	data["flags_placed"] = mining_game._flags_placed
	data["cells_revealed"] = mining_game._cells_revealed
	data["player_digs"] = mining_game._player_digs

	## Serialize cells as 2D array of cell state dictionaries
	var cells: Array = []
	for r in range(mining_game.grid_height):
		var row_data: Array = []
		for c in range(mining_game.grid_width):
			var cell: Dictionary = mining_game._cells[r][c]
			row_data.append({
				"is_mine": cell["is_mine"],
				"adjacent_count": cell["adjacent_count"],
				"state": int(cell["state"]),
			})
		cells.append(row_data)
	data["cells"] = cells

	return data


## ── Piece Serialization Helpers ─────────────────────────────────────


func _serialize_piece(piece: Piece) -> Dictionary:
	return {
		"type": int(piece.type),
		"owner": int(piece.owner),
		"direction": int(piece.direction),
	}


func _deserialize_piece(data) -> Piece:
	if data == null or not data is Dictionary:
		return null
	var piece_type: int = int(data.get("type", 0))
	var piece_owner: int = int(data.get("owner", 0))
	var piece := Piece.create(piece_type as Piece.Type, piece_owner as Piece.Owner)
	piece.direction = int(data.get("direction", 0)) as PieceDefinition.Direction
	return piece


## ── Data Persistence ────────────────────────────────────────────────


## Persist all autoload data to user:// storage (Req 4.6, 7.2)
func _persist_all_data() -> void:
	PlayerData.save_data()
	if Garden:
		Garden.save_data()
	if Achievements:
		Achievements.save_data()
	if MissionBoard:
		MissionBoard.save_data()


## ── Corrupted Save Notification ──────────────────────────────────────


## Called when PlayerData detects and recovers from corrupted save data.
func _on_save_corrupted() -> void:
	_show_corruption_notification.call_deferred()


## Displays a notification to the player informing them that save data was corrupted
## and has been reset to defaults. (Req 7.5)
func _show_corruption_notification() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Data Reset"
	dialog.dialog_text = "Your save data was corrupted and could not be loaded.\nYour progress has been reset to default values."
	dialog.ok_button_text = "OK"
	## Ensure dialog is freed when closed
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	## Add to scene tree and show
	get_tree().root.add_child(dialog)
	dialog.popup_centered()


## ── Scene Tree Helpers ──────────────────────────────────────────────


func _find_game_manager() -> GameManager:
	## Search the scene tree for a GameManager node
	var root := get_tree().current_scene
	if root == null:
		return null
	return _find_node_of_type(root, "GameManager") as GameManager


func _find_mining_game() -> MiningGame:
	## Search the scene tree for a MiningGame node
	var root := get_tree().current_scene
	if root == null:
		return null
	return _find_node_of_type(root, "MiningGame") as MiningGame


func _find_node_of_type(node: Node, type_name: String) -> Node:
	if node.get_class() == type_name or node.get_script() != null and _script_has_class(node, type_name):
		return node
	for child in node.get_children():
		var result := _find_node_of_type(child, type_name)
		if result != null:
			return result
	return null


func _script_has_class(node: Node, type_name: String) -> bool:
	var script = node.get_script()
	if script == null:
		return false
	var script_class: String = script.get_global_name()
	return script_class == type_name


## ── Cross-Singleton Wiring ──────────────────────────────────────────


## Establishes signal connections between mobile singletons for coordinated behavior.
## Called deferred from _ready() so all autoloads are initialized.
func _wire_singleton_connections() -> void:
	# ── AndroidLifecycleManager → PerformanceManager (Req 6.4) ──
	# PerformanceManager already handles its own _notification(), but this connection
	# ensures ordering: AndroidLifecycleManager saves state first, then throttles.
	var perf_mgr := get_node_or_null("/root/PerformanceManager")
	if perf_mgr != null:
		if not app_backgrounded.is_connected(perf_mgr.throttle_background):
			app_backgrounded.connect(perf_mgr.throttle_background)
		if not app_foregrounded.is_connected(perf_mgr.resume_foreground):
			app_foregrounded.connect(perf_mgr.resume_foreground)

	# ── AndroidLifecycleManager → MobileNetworkManager (Req 5.4) ──
	# MobileNetworkManager already handles its own _notification(), but this
	# connection provides explicit ordering after state persistence is complete.
	var net_mgr := get_node_or_null("/root/MobileNetworkManager")
	if net_mgr != null:
		if net_mgr.has_method("_on_app_paused") and not app_backgrounded.is_connected(net_mgr._on_app_paused):
			app_backgrounded.connect(net_mgr._on_app_paused)
		if net_mgr.has_method("_on_app_resumed") and not app_foregrounded.is_connected(net_mgr._on_app_resumed):
			app_foregrounded.connect(net_mgr._on_app_resumed)

	# ── ResponsiveLayoutManager.orientation_changed → Board refresh (Req 3.1) ──
	var layout_mgr := get_node_or_null("/root/ResponsiveLayoutManager")
	if layout_mgr != null and layout_mgr.has_signal("orientation_changed"):
		if not layout_mgr.orientation_changed.is_connected(_on_orientation_changed):
			layout_mgr.orientation_changed.connect(_on_orientation_changed)

	# ── ResponsiveLayoutManager.layout_recalculated → TouchInputManager (Req 2.1) ──
	# When layout changes, touch targets may shift. Clear any in-progress gestures.
	var touch_mgr := get_node_or_null("/root/TouchInputManager")
	if layout_mgr != null and touch_mgr != null:
		if layout_mgr.has_signal("layout_recalculated") and touch_mgr.has_method("_on_layout_changed"):
			if not layout_mgr.layout_recalculated.is_connected(touch_mgr._on_layout_changed):
				layout_mgr.layout_recalculated.connect(touch_mgr._on_layout_changed)

	# Verify all singletons are loaded and report status
	_verify_mobile_stack()


## Called when the device orientation changes. Refreshes the active board display.
## (Req 3.1: Layout responds to orientation changes)
func _on_orientation_changed(_is_portrait: bool) -> void:
	# Find the active game UI and refresh its board display
	var game_ui := _find_node_with_script_in_tree("battle_screen.gd")
	if game_ui != null and game_ui.has_method("_refresh_board"):
		game_ui._refresh_board()

	var mp_ui := _find_node_with_script_in_tree("multiplayer_battle_ui.gd")
	if mp_ui != null and mp_ui.has_method("_refresh_board"):
		mp_ui._refresh_board()


## Searches the scene tree for a node whose script path ends with the given filename.
func _find_node_with_script_in_tree(script_name: String) -> Node:
	var root := get_tree().root
	if root == null:
		return null
	return _search_for_script(root, script_name)


func _search_for_script(node: Node, script_name: String) -> Node:
	var script = node.get_script()
	if script != null and script is Script:
		var path: String = script.resource_path
		if path.ends_with(script_name):
			return node
	for child in node.get_children():
		var found := _search_for_script(child, script_name)
		if found != null:
			return found
	return null


## ── Mobile Stack Verification ───────────────────────────────────────


## Checks that all expected mobile singletons are loaded and logs their status.
## Runs once on startup as a diagnostic aid. Logs warnings for missing singletons.
func _verify_mobile_stack() -> void:
	var expected_singletons := [
		"AndroidLifecycleManager",
		"PerformanceManager",
		"MobileNetworkManager",
		"ResponsiveLayoutManager",
		"TouchInputManager",
	]

	var all_present := true
	for singleton_name in expected_singletons:
		var node := get_node_or_null("/root/" + singleton_name)
		if node == null:
			push_warning("MobileStack: Missing autoload singleton '%s'" % singleton_name)
			all_present = false

	if all_present:
		print("[MobileStack] All 5 mobile singletons loaded and wired successfully.")
	else:
		push_warning("[MobileStack] Some mobile singletons are missing. Mobile features may not work correctly.")

	# Verify signal connections are active
	var perf_mgr := get_node_or_null("/root/PerformanceManager")
	if perf_mgr != null and app_backgrounded.is_connected(perf_mgr.throttle_background):
		print("[MobileStack] AndroidLifecycleManager → PerformanceManager: connected")

	var net_mgr := get_node_or_null("/root/MobileNetworkManager")
	if net_mgr != null and net_mgr.has_method("_on_app_paused") and app_backgrounded.is_connected(net_mgr._on_app_paused):
		print("[MobileStack] AndroidLifecycleManager → MobileNetworkManager: connected")

	var layout_mgr := get_node_or_null("/root/ResponsiveLayoutManager")
	if layout_mgr != null and layout_mgr.has_signal("orientation_changed"):
		if layout_mgr.orientation_changed.is_connected(_on_orientation_changed):
			print("[MobileStack] ResponsiveLayoutManager.orientation_changed → board refresh: connected")

	var touch_mgr := get_node_or_null("/root/TouchInputManager")
	if touch_mgr != null and layout_mgr != null:
		if touch_mgr.has_method("_on_layout_changed") and layout_mgr.layout_recalculated.is_connected(touch_mgr._on_layout_changed):
			print("[MobileStack] ResponsiveLayoutManager.layout_recalculated → TouchInputManager: connected")
