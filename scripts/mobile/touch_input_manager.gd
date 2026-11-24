extends Node
## Touch input manager autoload singleton.
## Handles all touch gesture recognition and dispatches game actions.
## Replaces mouse-click handling on Android.

signal piece_selected(piece: Piece)
signal cell_tapped(row: int, col: int)
signal piece_long_pressed(piece: Piece)
signal piece_rotate_requested(piece: Piece)
signal deselect_requested()

## Duration in milliseconds for a touch to be considered a long press.
const LONG_PRESS_DURATION_MS := 500
## Minimum time between taps on the same target to prevent accidental double-taps.
const DOUBLE_TAP_COOLDOWN_MS := 200
## Minimum touch target size in density-independent pixels.
const MIN_TOUCH_TARGET_DP := 48
## Maximum movement in pixels allowed during a tap before it becomes a drag.
const TAP_MOVE_THRESHOLD_PX := 20.0

var _long_press_timer: Timer
var _touch_start_pos: Vector2
var _touch_start_time: int
var _active_touches: Dictionary = {}  # touch_index -> TouchGestureState dict
var _last_tap_time: int = 0
var _last_tap_target: Dictionary = {}
var _long_press_fired: bool = false


func _ready() -> void:
	_long_press_timer = Timer.new()
	_long_press_timer.one_shot = true
	_long_press_timer.wait_time = LONG_PRESS_DURATION_MS / 1000.0
	_long_press_timer.timeout.connect(_on_long_press_timeout)
	add_child(_long_press_timer)

	# Add touch-to-game integration
	var integration_script := load("res://scripts/mobile/touch_game_integration.gd")
	if integration_script:
		var integration := Node.new()
		integration.name = "TouchGameIntegration"
		integration.set_script(integration_script)
		add_child(integration)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_screen_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_screen_drag(event as InputEventScreenDrag)


## Handles touch press and release events, routing to single or multi-touch logic.
func _handle_screen_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_register_touch_start(event)
		# Check for multi-touch rotation gesture
		if _active_touches.size() == 2:
			_handle_multi_touch(event)
		elif _active_touches.size() == 1:
			_start_long_press_detection()
	else:
		_handle_touch_release(event)


## Handles drag events — used to cancel long press if finger moves too far.
func _handle_screen_drag(event: InputEventScreenDrag) -> void:
	var idx := event.index
	if _active_touches.has(idx):
		_active_touches[idx]["current_position"] = event.position
		# Cancel long press if finger moved beyond threshold
		var start_pos: Vector2 = _active_touches[idx]["start_position"]
		if start_pos.distance_to(event.position) > TAP_MOVE_THRESHOLD_PX:
			_cancel_long_press()


## Registers a new touch start in the active touches dictionary.
func _register_touch_start(event: InputEventScreenTouch) -> void:
	var gesture_state := {
		"touch_index": event.index,
		"start_position": event.position,
		"start_time_msec": Time.get_ticks_msec(),
		"current_position": event.position,
		"is_long_press": false,
		"resolved_target": _resolve_tap_target(event.position),
	}
	_active_touches[event.index] = gesture_state
	_touch_start_pos = event.position
	_touch_start_time = Time.get_ticks_msec()
	_long_press_fired = false


## Handles a touch release — determines if it was a tap or long press.
func _handle_touch_release(event: InputEventScreenTouch) -> void:
	var idx := event.index

	if not _active_touches.has(idx):
		return

	var gesture: Dictionary = _active_touches[idx]
	_active_touches.erase(idx)

	# Stop long press timer if we were tracking single touch
	if _active_touches.is_empty():
		_long_press_timer.stop()

	# If long press already fired, don't process as a tap
	if gesture["is_long_press"] or _long_press_fired:
		return

	# Check if finger moved too far for a tap
	var start_pos: Vector2 = gesture["start_position"]
	if start_pos.distance_to(event.position) > TAP_MOVE_THRESHOLD_PX:
		return

	# This was a valid tap — handle it
	_handle_single_touch_tap(gesture)


## Processes a single-finger tap after release.
func _handle_single_touch_tap(gesture: Dictionary) -> void:
	var target: Dictionary = gesture["resolved_target"]
	var now := Time.get_ticks_msec()

	# Enforce double-tap cooldown on same target
	if _is_same_target(target, _last_tap_target):
		if (now - _last_tap_time) < DOUBLE_TAP_COOLDOWN_MS:
			return

	_last_tap_time = now
	_last_tap_target = target

	# Dispatch based on target type
	match target.get("type", "none"):
		"hand_piece":
			var piece = target.get("piece")
			if piece != null:
				piece_selected.emit(piece)
		"board_cell":
			var row: int = target.get("row", -1)
			var col: int = target.get("col", -1)
			if row >= 0 and col >= 0:
				cell_tapped.emit(row, col)
		"mining_tile":
			# Mining tiles also emit cell_tapped for the mining grid
			var row: int = target.get("row", -1)
			var col: int = target.get("col", -1)
			if row >= 0 and col >= 0:
				cell_tapped.emit(row, col)
		"button":
			# Buttons handle their own press — no signal needed from us
			pass
		"none":
			deselect_requested.emit()


## Handles multi-touch gesture — detects two-finger tap for piece rotation.
func _handle_multi_touch(_event: InputEventScreenTouch) -> void:
	_cancel_long_press()

	if _active_touches.size() != 2:
		return

	# Get both touch states
	var touches := _active_touches.values()
	var target_a: Dictionary = touches[0].get("resolved_target", {})
	var target_b: Dictionary = touches[1].get("resolved_target", {})

	# Both fingers must target the same piece for rotation
	var piece_a = target_a.get("piece")
	var piece_b = target_b.get("piece")

	if piece_a != null and piece_a == piece_b:
		if piece_a.is_rotatable():
			piece_rotate_requested.emit(piece_a)


## Starts the long-press timer for single-touch detection.
func _start_long_press_detection() -> void:
	_long_press_timer.stop()
	_long_press_timer.start()


## Cancels long-press detection (finger moved or multi-touch started).
func _cancel_long_press() -> void:
	_long_press_timer.stop()


## Fired when the long-press timer expires while finger is still down.
func _on_long_press_timeout() -> void:
	if _active_touches.size() != 1:
		return

	var gesture: Dictionary = _active_touches.values()[0]
	var start_pos: Vector2 = gesture["start_position"]
	var current_pos: Vector2 = gesture["current_position"]

	# Verify finger hasn't moved significantly
	if start_pos.distance_to(current_pos) > TAP_MOVE_THRESHOLD_PX:
		return

	# Mark as long press
	gesture["is_long_press"] = true
	_long_press_fired = true

	var target: Dictionary = gesture["resolved_target"]
	var piece = target.get("piece")
	if piece != null:
		piece_long_pressed.emit(piece)


## Resolves a tap position to a game target by checking nodes at that location.
## Uses the node groups: "board_cells", "hand_tiles", "mining_tiles" to identify targets.
## Falls back to Control hit-testing for buttons and other interactive elements.
func _resolve_tap_target(position: Vector2) -> Dictionary:
	var result := {
		"type": "none",
		"row": -1,
		"col": -1,
		"piece": null,
		"control": null,
	}

	# Check hand tiles first (higher priority for piece selection)
	var hand_tiles := get_tree().get_nodes_in_group("hand_tiles")
	for node in hand_tiles:
		if node is Control and _control_contains_point(node as Control, position):
			if _is_valid_touch_target(node as Control):
				result["type"] = "hand_piece"
				result["control"] = node
				# Try to get piece data from the control
				if node.has_meta("piece"):
					result["piece"] = node.get_meta("piece")
				elif node.has_method("get_piece"):
					result["piece"] = node.get_piece()
				return result

	# Check board cells
	var board_cells := get_tree().get_nodes_in_group("board_cells")
	for node in board_cells:
		if node is Control and _control_contains_point(node as Control, position):
			if _is_valid_touch_target(node as Control):
				result["type"] = "board_cell"
				result["control"] = node
				if node.has_meta("row"):
					result["row"] = node.get_meta("row")
				if node.has_meta("col"):
					result["col"] = node.get_meta("col")
				if node.has_meta("piece"):
					result["piece"] = node.get_meta("piece")
				elif node.has_method("get_piece"):
					result["piece"] = node.get_piece()
				return result

	# Check mining tiles
	var mining_tiles := get_tree().get_nodes_in_group("mining_tiles")
	for node in mining_tiles:
		if node is Control and _control_contains_point(node as Control, position):
			if _is_valid_touch_target(node as Control):
				result["type"] = "mining_tile"
				result["control"] = node
				if node.has_meta("row"):
					result["row"] = node.get_meta("row")
				if node.has_meta("col"):
					result["col"] = node.get_meta("col")
				return result

	# Check for any interactive Control under the tap point (buttons, etc.)
	var root := get_tree().root
	var hit_control := _find_control_at_position(root, position)
	if hit_control != null and _is_interactive_control(hit_control):
		if _is_valid_touch_target(hit_control):
			result["type"] = "button"
			result["control"] = hit_control
			return result

	# No target found — tap on empty space
	return result


## Returns true if the Control's global rect contains the given point.
func _control_contains_point(control: Control, point: Vector2) -> bool:
	var rect := control.get_global_rect()
	return rect.has_point(point)


## Checks if a Control meets the minimum touch target size of 48dp.
## Returns true if both width and height are >= MIN_TOUCH_TARGET_DP * dp_scale.
func _is_valid_touch_target(control: Control) -> bool:
	if control == null:
		return false
	var dp := get_dp_scale()
	var min_size_px := MIN_TOUCH_TARGET_DP * dp
	var rect := control.get_global_rect()
	return rect.size.x >= min_size_px and rect.size.y >= min_size_px


## Returns the dp scale factor for density-independent calculations.
## Delegates to ResponsiveLayoutManager if available, otherwise computes from screen DPI.
func get_dp_scale() -> float:
	if Engine.has_singleton("ResponsiveLayoutManager"):
		return ResponsiveLayoutManager.dp_scale
	# Check if ResponsiveLayoutManager is accessible as autoload
	var rlm = get_node_or_null("/root/ResponsiveLayoutManager")
	if rlm != null and "dp_scale" in rlm:
		return rlm.dp_scale
	# Fallback: compute from screen DPI (160 DPI = 1.0 dp scale)
	var screen_dpi := DisplayServer.screen_get_dpi()
	if screen_dpi > 0:
		return screen_dpi / 160.0
	return 1.0


## Recursively finds the deepest Control node at the given position.
func _find_control_at_position(node: Node, position: Vector2) -> Control:
	var result: Control = null

	# Traverse children in reverse (top-most drawn last = highest z-index)
	for i in range(node.get_child_count() - 1, -1, -1):
		var child := node.get_child(i)
		if child is Control:
			var ctrl := child as Control
			if ctrl.visible and ctrl.get_global_rect().has_point(position):
				# Check deeper children first
				var deeper := _find_control_at_position(ctrl, position)
				if deeper != null:
					return deeper
				# This control itself is a candidate
				if _is_interactive_control(ctrl):
					return ctrl
		elif child.get_child_count() > 0:
			var deeper := _find_control_at_position(child, position)
			if deeper != null:
				return deeper

	return result


## Returns true if a Control is considered interactive (button, link, etc.).
func _is_interactive_control(control: Control) -> bool:
	if control == null:
		return false
	return (
		control is BaseButton
		or control is LinkButton
		or control is TextureButton
		or control.focus_mode != Control.FOCUS_NONE
	)


## Checks if two resolved targets refer to the same element.
func _is_same_target(target_a: Dictionary, target_b: Dictionary) -> bool:
	if target_a.is_empty() or target_b.is_empty():
		return false
	if target_a.get("type") != target_b.get("type"):
		return false
	match target_a.get("type", "none"):
		"board_cell", "mining_tile":
			return target_a.get("row") == target_b.get("row") and target_a.get("col") == target_b.get("col")
		"hand_piece":
			return target_a.get("piece") == target_b.get("piece")
		"button":
			return target_a.get("control") == target_b.get("control")
	return false


## Called when ResponsiveLayoutManager recalculates layout (orientation change, resize).
## Clears stale touch state since touch targets may have moved. (Req 2.1)
func _on_layout_changed() -> void:
	# Cancel any in-progress long press detection
	_cancel_long_press()
	# Clear active touches — positions are now stale relative to new layout
	_active_touches.clear()
	_long_press_fired = false
	# Clear last tap target since its position may have shifted
	_last_tap_target = {}
