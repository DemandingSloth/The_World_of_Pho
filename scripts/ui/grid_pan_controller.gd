class_name GridPanController
extends RefCounted

## Turns a ScrollContainer whose body is a grid of Buttons into a
## "touch-and-drag = pan, clean tap = act" surface.
##
## Why this exists: on Android the physical/gesture navigation bar sits over the
## bottom edge of the screen, and relying on Godot's built-in ScrollContainer
## touch-scroll (scroll_deadzone) made horizontal panning unreliable — the tile
## Buttons would often eat the drag, so wide grids couldn't be scrolled. This
## controller takes over the gesture explicitly:
##   • pointer down on a tile is remembered (no action yet)
##   • once the pointer moves past DRAG_THRESHOLD px, we scroll the container by
##     the finger delta ourselves and flag the gesture as a drag
##   • on release, if it was NOT a drag, we fire the tile's tap callback
##     (harvest / collect / plant / dig)
##
## Each tile Button should:
##   • keep mouse_filter = MOUSE_FILTER_PASS
##   • NOT connect its `pressed` signal to the action (the controller fires it)
##   • connect `gui_input` to GridPanController.handle_tile_input, binding the
##     tile's tap Callable:
##         btn.gui_input.connect(controller.handle_tile_input.bind(tap_callable))
##
## Optional long-press support: pass callables for began/moved/ended so screens
## can keep their existing hold-to-show-info popups.

## Pixels of movement before a press becomes a pan (and cancels the tap).
const DRAG_THRESHOLD := 10.0

var _scroll: ScrollContainer

## Gesture state
var _pointer_down := false
var _is_dragging := false
var _start_pos := Vector2.ZERO
var _last_pos := Vector2.ZERO

## Optional long-press hooks (Callables). Any may be null.
var _lp_began: Callable
var _lp_moved: Callable
var _lp_ended: Callable


func _init(scroll_container: ScrollContainer) -> void:
	_scroll = scroll_container


## Register optional long-press callbacks.
##   began(pos: Vector2) -> void   : pointer pressed on a tile
##   moved(dist: float) -> void    : pointer moved this far from start (to cancel)
##   ended() -> void               : pointer released / gesture cancelled
func set_long_press_hooks(began: Callable, moved: Callable, ended: Callable) -> void:
	_lp_began = began
	_lp_moved = moved
	_lp_ended = ended


## Connect this to each tile Button's `gui_input` signal, binding the tile's
## tap action as the final argument, e.g.:
##   btn.gui_input.connect(ctrl.handle_tile_input.bind(_on_tap.bind(r, c)))
##
## `cell` is an optional context value (e.g. Vector2i(row, col)) forwarded to the
## long-press "began" hook so screens know which tile is being held. Pass it by
## binding it before tap_action:
##   btn.gui_input.connect(ctrl.handle_tile_input.bind(Vector2i(r, c), _on_tap.bind(r, c)))
func handle_tile_input(event: InputEvent, cell: Variant, tap_action: Callable) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_begin(event.position, cell)
		else:
			_end(event.position, tap_action)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin(event.position, cell)
		else:
			_end(event.position, tap_action)
	elif event is InputEventScreenDrag:
		_move(event.position, event.relative)
	elif event is InputEventMouseMotion and _pointer_down:
		_move(event.position, event.relative)


func _begin(pos: Vector2, cell: Variant) -> void:
	_pointer_down = true
	_is_dragging = false
	_start_pos = pos
	_last_pos = pos
	if _lp_began.is_valid():
		_lp_began.call(cell)


func _move(pos: Vector2, relative: Vector2) -> void:
	if not _pointer_down:
		return

	var dist := pos.distance_to(_start_pos)
	if not _is_dragging and dist > DRAG_THRESHOLD:
		_is_dragging = true
		## Moving away from the tile cancels any pending long-press.
		if _lp_moved.is_valid():
			_lp_moved.call(dist)

	if _is_dragging and _scroll != null and is_instance_valid(_scroll):
		## Drag content with the finger: moving the finger right reveals content
		## to the left, so scroll offset decreases by the delta.
		_scroll.scroll_horizontal -= int(round(relative.x))
		_scroll.scroll_vertical -= int(round(relative.y))
		_last_pos = pos


func _end(pos: Vector2, tap_action: Callable) -> void:
	var was_dragging := _is_dragging
	_pointer_down = false
	_is_dragging = false
	if _lp_ended.is_valid():
		_lp_ended.call()
	## A clean tap (no significant movement) performs the tile action.
	if not was_dragging and pos.distance_to(_start_pos) <= DRAG_THRESHOLD:
		if tap_action.is_valid():
			tap_action.call()
