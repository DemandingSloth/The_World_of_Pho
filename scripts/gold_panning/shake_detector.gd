class_name ShakeDetector
extends RefCounted

## Detects horizontal shake gestures (repeated swipes) within a time window.
## A shake is recognized when 3+ horizontal swipes of ≥80px occur within 1 second,
## with each swipe crossing the provided target rectangle.

const SWIPE_MIN_DISTANCE := 80.0   # pixels horizontal
const TIME_WINDOW := 1.0           # seconds
const REQUIRED_SWIPES := 3         # swipes within window

var _swipe_timestamps: Array[float] = []
var _touch_start_pos: Vector2 = Vector2.ZERO
var _is_tracking: bool = false
var _max_horizontal_distance: float = 0.0
var _touch_crossed_target: bool = false


## Process an input event and return true if a shake gesture is detected.
## target_rect defines the area that swipes must cross to count.
## Handles both touch (mobile) and mouse (desktop) input.
func process_input(event: InputEvent, target_rect: Rect2) -> bool:
	if event is InputEventScreenTouch:
		return _handle_touch(event, target_rect)
	elif event is InputEventScreenDrag:
		return _handle_drag(event, target_rect)
	elif event is InputEventMouseButton:
		return _handle_mouse_button(event, target_rect)
	elif event is InputEventMouseMotion:
		return _handle_mouse_motion(event, target_rect)
	return false


## Clear all tracking state.
func reset() -> void:
	_swipe_timestamps.clear()
	_touch_start_pos = Vector2.ZERO
	_is_tracking = false
	_max_horizontal_distance = 0.0
	_touch_crossed_target = false


func _handle_touch(event: InputEventScreenTouch, target_rect: Rect2) -> bool:
	if event.pressed:
		# Touch began — start tracking a potential swipe
		_touch_start_pos = event.position
		_is_tracking = true
		_max_horizontal_distance = 0.0
		_touch_crossed_target = target_rect.has_point(event.position)
		return false
	else:
		# Touch released — evaluate the swipe
		if not _is_tracking:
			return false

		_is_tracking = false

		# Check if the release point is in the target
		if not _touch_crossed_target:
			_touch_crossed_target = target_rect.has_point(event.position)

		# Compute final horizontal distance
		var h_distance := absf(event.position.x - _touch_start_pos.x)
		if h_distance > _max_horizontal_distance:
			_max_horizontal_distance = h_distance

		# Valid swipe: crossed target and traveled far enough horizontally
		if _touch_crossed_target and _max_horizontal_distance >= SWIPE_MIN_DISTANCE:
			return _register_swipe()

		return false


func _handle_drag(event: InputEventScreenDrag, target_rect: Rect2) -> bool:
	if not _is_tracking:
		return false

	# Update whether drag has crossed the target area
	if not _touch_crossed_target:
		_touch_crossed_target = target_rect.has_point(event.position)

	# Track maximum horizontal distance from start
	var h_distance := absf(event.position.x - _touch_start_pos.x)
	if h_distance > _max_horizontal_distance:
		_max_horizontal_distance = h_distance

	return false


func _register_swipe() -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	_swipe_timestamps.append(now)

	# Remove timestamps outside the time window
	_prune_old_timestamps(now)

	# Check if we have enough swipes within the window
	if _swipe_timestamps.size() >= REQUIRED_SWIPES:
		_swipe_timestamps.clear()
		return true

	return false


func _prune_old_timestamps(now: float) -> void:
	while _swipe_timestamps.size() > 0 and (now - _swipe_timestamps[0]) > TIME_WINDOW:
		_swipe_timestamps.remove_at(0)


## ── Mouse input support (desktop testing) ────────────────────────


func _handle_mouse_button(event: InputEventMouseButton, target_rect: Rect2) -> bool:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false

	if event.pressed:
		# Mouse button down — start tracking
		_touch_start_pos = event.position
		_is_tracking = true
		_max_horizontal_distance = 0.0
		_touch_crossed_target = target_rect.has_point(event.position)
		return false
	else:
		# Mouse button released — evaluate the swipe
		if not _is_tracking:
			return false

		_is_tracking = false

		if not _touch_crossed_target:
			_touch_crossed_target = target_rect.has_point(event.position)

		var h_distance := absf(event.position.x - _touch_start_pos.x)
		if h_distance > _max_horizontal_distance:
			_max_horizontal_distance = h_distance

		if _touch_crossed_target and _max_horizontal_distance >= SWIPE_MIN_DISTANCE:
			return _register_swipe()

		return false


func _handle_mouse_motion(event: InputEventMouseMotion, target_rect: Rect2) -> bool:
	if not _is_tracking:
		return false

	if not _touch_crossed_target:
		_touch_crossed_target = target_rect.has_point(event.position)

	var h_distance := absf(event.position.x - _touch_start_pos.x)
	if h_distance > _max_horizontal_distance:
		_max_horizontal_distance = h_distance

	return false
