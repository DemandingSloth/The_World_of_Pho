extends Node
## Responsive layout manager autoload singleton.
## Manages dynamic layout calculations based on screen size, orientation, and safe area insets.
## Adapts UI layout for phones (< 600dp width) and tablets (>= 600dp width).

signal orientation_changed(is_portrait: bool)
signal layout_recalculated()

const PHONE_WIDTH_THRESHOLD_DP := 600
const MIN_TILE_SIZE_DP := 40
const MIN_FONT_SIZE_SP := 14
const MIN_BUTTON_HEIGHT_DP := 48
const MIN_ELEMENT_SPACING_DP := 8
const BOARD_COLUMNS := 6

## Current orientation state. True when device is in portrait mode.
var is_portrait: bool = true
## True when the device screen width is less than 600dp (phone-sized).
var is_phone: bool = true
## The display safe area rect accounting for notch/cutout regions.
var safe_area: Rect2i = Rect2i()
## Computed board tile size in pixels after applying dp_scale and minimum constraints.
var tile_size_px: int = 0
## Density-independent pixel scale factor computed from screen DPI.
## Multiply dp values by this to get pixel values.
var dp_scale: float = 1.0


## Reference to the mobile UI overrides handler (Android only).
var _mobile_ui_overrides: Node = null


func _ready() -> void:
	_compute_dp_scale()
	_update_layout()
	get_tree().root.size_changed.connect(_on_viewport_size_changed)
	_setup_mobile_ui_overrides()
	# Apply phone portrait layout after a frame (scene fully loaded)
	call_deferred("_apply_phone_portrait_layout")


func _on_viewport_size_changed() -> void:
	_update_layout()
	_apply_phone_portrait_layout()


## Calculates the tile size in pixels for a grid given available width and column count.
## Returns the larger of (available_width / columns) and (MIN_TILE_SIZE_DP * dp_scale),
## ensuring tiles are never smaller than the minimum density-independent size.
func calculate_tile_size(available_width: float, columns: int) -> int:
	if columns <= 0:
		columns = 1
	var proportional_size := available_width / float(columns)
	var min_size_px := MIN_TILE_SIZE_DP * dp_scale
	return int(maxf(proportional_size, min_size_px))


## Returns the display safe area as a Rect2i using DisplayServer.
## On platforms without notch/cutout, this returns the full screen rect.
func get_safe_area_insets() -> Rect2i:
	safe_area = DisplayServer.get_display_safe_area()
	return safe_area


## Applies the appropriate layout to the board and side panel based on orientation.
## Portrait: stacks board above side panel vertically.
## Landscape: places board beside side panel horizontally.
func apply_layout(board_section: Control, side_panel: Control) -> void:
	if board_section == null or side_panel == null:
		return

	var viewport_size := _get_viewport_size()
	var safe := get_safe_area_insets()

	# Calculate usable area accounting for safe area insets
	var safe_left := safe.position.x
	var safe_top := safe.position.y
	var safe_right := viewport_size.x - (safe.position.x + safe.size.x)
	var safe_bottom := viewport_size.y - (safe.position.y + safe.size.y)

	# Ensure insets are non-negative (safe_area might equal full screen)
	safe_left = maxi(safe_left, 0)
	safe_top = maxi(safe_top, 0)
	safe_right = maxi(safe_right, 0)
	safe_bottom = maxi(safe_bottom, 0)

	var usable_width := viewport_size.x - safe_left - safe_right
	var usable_height := viewport_size.y - safe_top - safe_bottom

	if is_portrait:
		# Stack board above side panel vertically
		var board_height := usable_height * 0.6
		var panel_height := usable_height * 0.4

		board_section.position = Vector2(safe_left, safe_top)
		board_section.size = Vector2(usable_width, board_height)

		side_panel.position = Vector2(safe_left, safe_top + board_height)
		side_panel.size = Vector2(usable_width, panel_height)
	else:
		# Place board beside side panel horizontally
		var board_width := usable_width * 0.6
		var panel_width := usable_width * 0.4

		board_section.position = Vector2(safe_left, safe_top)
		board_section.size = Vector2(board_width, usable_height)

		side_panel.position = Vector2(safe_left + board_width, safe_top)
		side_panel.size = Vector2(panel_width, usable_height)


## Returns true if the current screen width qualifies as a phone (< 600dp).
func is_phone_screen() -> bool:
	var viewport_size := _get_viewport_size()
	var width_dp := viewport_size.x / dp_scale
	return width_dp < PHONE_WIDTH_THRESHOLD_DP


## Computes dp_scale from the screen DPI. Falls back to 1.0 if DPI is unavailable.
func _compute_dp_scale() -> void:
	var screen_dpi := DisplayServer.screen_get_dpi()
	if screen_dpi > 0:
		# Android baseline density is 160 DPI
		dp_scale = screen_dpi / 160.0
	else:
		dp_scale = 1.0


## Internal: recalculates all layout state when the viewport changes.
func _update_layout() -> void:
	var viewport_size := _get_viewport_size()
	var width_dp := viewport_size.x / dp_scale

	# Detect orientation
	var new_is_portrait := viewport_size.y >= viewport_size.x
	var orientation_did_change := (new_is_portrait != is_portrait)
	is_portrait = new_is_portrait

	# Detect phone vs tablet
	is_phone = width_dp < PHONE_WIDTH_THRESHOLD_DP

	# Update safe area
	get_safe_area_insets()

	# Calculate board tile size using available width minus safe area horizontal insets
	var safe_left := maxi(safe_area.position.x, 0)
	var safe_right := maxi(int(viewport_size.x) - (safe_area.position.x + safe_area.size.x), 0)
	var available_width := viewport_size.x - safe_left - safe_right

	# In landscape, board only gets ~60% of usable width
	if not is_portrait:
		available_width = available_width * 0.6

	tile_size_px = calculate_tile_size(available_width, BOARD_COLUMNS)

	# Refresh mobile UI overrides with updated dp_scale
	_refresh_mobile_overrides()

	# Emit signals
	if orientation_did_change:
		orientation_changed.emit(is_portrait)

	layout_recalculated.emit()


## Helper to get the current viewport size as Vector2.
func _get_viewport_size() -> Vector2:
	return get_tree().root.get_visible_rect().size


## Sets up the mobile UI overrides node.
func _setup_mobile_ui_overrides() -> void:
	var script: Variant = load("res://scripts/mobile/mobile_ui_overrides.gd")
	if script == null:
		push_warning("MobileUIOverrides: Could not load mobile_ui_overrides.gd")
		return

	_mobile_ui_overrides = Node.new()
	_mobile_ui_overrides.name = "MobileUIOverrides"
	_mobile_ui_overrides.set_script(script)
	add_child(_mobile_ui_overrides)


## Notifies the mobile UI overrides to refresh when dp_scale changes.
func _refresh_mobile_overrides() -> void:
	if _mobile_ui_overrides != null and _mobile_ui_overrides.has_method("refresh_dp_scale"):
		_mobile_ui_overrides.refresh_dp_scale(dp_scale)


## ── Phone Portrait Layout ────────────────────────────────────────────────


## Legacy phone portrait layout adjustment.
## No longer needed with the screen-per-scene architecture — each screen now
## handles its own responsive layout (e.g., battle_screen calls apply_layout()
## directly). Kept as a no-op to avoid breaking existing signal connections.
func _apply_phone_portrait_layout() -> void:
	pass
