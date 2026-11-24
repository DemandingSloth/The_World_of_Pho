extends Node
## Mobile UI Overrides
## Applied at runtime by ResponsiveLayoutManager on Android devices.
## Enforces minimum touch target sizes, font sizes, spacing, inertial scrolling,
## and disables mouse/hover states for touch-only interaction.
##
## This script does NOT modify .tscn files. All overrides are applied dynamically
## via the scene tree at runtime. On desktop platforms, overrides are skipped.

## Confirmation button keywords used to identify buttons needing emphasis.
const CONFIRMATION_KEYWORDS := ["Start", "Buy", "Confirm", "Play", "Claim", "Next", "New"]

## Whether overrides are active (only true on Android or when forced for testing).
var _active: bool = false

## Cached dp_scale from ResponsiveLayoutManager.
var _dp_scale: float = 1.0

## Minimum sizes in dp units (multiplied by dp_scale at apply time).
const MIN_BUTTON_HEIGHT_DP := 48.0
const MIN_FONT_SIZE_SP := 14.0
const MIN_SPACING_DP := 8.0
const MIN_HAND_TILE_DP := 48.0
const CONFIRM_BUTTON_WIDTH_DP := 56.0
const CONFIRM_BUTTON_HEIGHT_DP := 48.0

## ScrollContainer deadzone for inertial feel on touch devices.
const SCROLL_DEADZONE := 4


func _ready() -> void:
	# With the screen-per-scene architecture, all UI sizes are designed for the
	# 420x900 viewport, and Godot's canvas_items stretch mode handles device scaling.
	# Mobile UI overrides are no longer needed for size enforcement.
	# Only keep touch-specific behaviors (hide cursor, scroll deadzone).
	_active = true
	_dp_scale = 1.0

	# Hide mouse cursor only on actual mobile devices (not desktop/editor)
	if OS.get_name() == "Android" or OS.get_name() == "iOS":
		Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)

	# Connect to tree changes for scroll container touch settings only
	get_tree().node_added.connect(_on_node_added_minimal)

	# Apply minimal touch overrides (scroll deadzone only)
	call_deferred("_apply_touch_overrides_to_tree")


## Called when ResponsiveLayoutManager recalculates layout (dp_scale may update).
## We keep _dp_scale at 1.0 because canvas_items stretch mode handles device scaling.
func refresh_dp_scale(new_dp_scale: float) -> void:
	# Intentionally not updating _dp_scale — canvas_items stretch mode handles scaling.
	# Only re-apply overrides for newly added nodes or structural changes.
	if _active:
		_apply_overrides_to_tree()


## Apply all mobile overrides to the current scene tree.
func _apply_overrides_to_tree() -> void:
	var root := get_tree().root
	if root == null:
		return
	_apply_overrides_recursive(root)


## Recursively apply overrides to a node and its children.
func _apply_overrides_recursive(node: Node) -> void:
	_apply_node_overrides(node)
	for child in node.get_children():
		_apply_overrides_recursive(child)


## Apply overrides to a single node based on its type.
func _apply_node_overrides(node: Node) -> void:
	if node is Button:
		_apply_button_overrides(node as Button)
	elif node is Label:
		_apply_label_overrides(node as Label)
	elif node is RichTextLabel:
		_apply_rich_text_overrides(node as RichTextLabel)
	elif node is GridContainer:
		_apply_grid_overrides(node as GridContainer)
	elif node is BoxContainer:
		_apply_box_container_overrides(node as BoxContainer)
	elif node is ScrollContainer:
		_apply_scroll_overrides(node as ScrollContainer)


## Enforce minimum button height of 48dp, font size of 14sp,
## and disable hover styles on Android.
func _apply_button_overrides(btn: Button) -> void:
	var min_height_px := MIN_BUTTON_HEIGHT_DP * _dp_scale

	# Enforce minimum height
	if btn.custom_minimum_size.y < min_height_px:
		btn.custom_minimum_size.y = min_height_px

	# Enforce minimum font size (14sp)
	_enforce_min_font_size_on_control(btn)

	# Check if this is a confirmation button and apply emphasis
	if _is_confirmation_button(btn):
		_apply_confirmation_style(btn)

	# Disable hover state — make hover style same as normal
	_disable_hover_style(btn)


## Enforce minimum font size of 14sp on labels.
func _apply_label_overrides(lbl: Label) -> void:
	_enforce_min_font_size_on_control(lbl)


## Enforce minimum font size on RichTextLabel.
func _apply_rich_text_overrides(rtl: RichTextLabel) -> void:
	var min_font_px := int(MIN_FONT_SIZE_SP * _dp_scale)
	var current_size := rtl.get_theme_font_size("normal_font_size")
	if current_size < min_font_px:
		rtl.add_theme_font_size_override("normal_font_size", min_font_px)


## Enforce minimum spacing in BoxContainers (VBox/HBox).
func _apply_box_container_overrides(container: BoxContainer) -> void:
	var min_spacing_px := int(MIN_SPACING_DP * _dp_scale)
	var current_separation := container.get_theme_constant("separation")
	if current_separation < min_spacing_px:
		container.add_theme_constant_override("separation", min_spacing_px)


## Enforce minimum spacing and minimum child sizes in GridContainers.
func _apply_grid_overrides(grid: GridContainer) -> void:
	var min_spacing_px := int(MIN_SPACING_DP * _dp_scale)

	# Enforce grid separation
	var h_sep := grid.get_theme_constant("h_separation")
	var v_sep := grid.get_theme_constant("v_separation")
	if h_sep < min_spacing_px:
		grid.add_theme_constant_override("h_separation", min_spacing_px)
	if v_sep < min_spacing_px:
		grid.add_theme_constant_override("v_separation", min_spacing_px)

	# Check if this is a hand grid (name contains "Hand") — enforce 48x48dp tiles
	if "Hand" in grid.name or "hand" in grid.name:
		_enforce_hand_grid_tile_sizes(grid)


## Enforce hand grid tile minimum of 48x48dp per tile.
func _enforce_hand_grid_tile_sizes(grid: GridContainer) -> void:
	var min_tile_px := MIN_HAND_TILE_DP * _dp_scale
	for child in grid.get_children():
		if child is Control:
			var ctrl := child as Control
			if ctrl.custom_minimum_size.x < min_tile_px:
				ctrl.custom_minimum_size.x = min_tile_px
			if ctrl.custom_minimum_size.y < min_tile_px:
				ctrl.custom_minimum_size.y = min_tile_px


## Configure ScrollContainer for inertial scrolling on touch devices.
func _apply_scroll_overrides(scroll: ScrollContainer) -> void:
	# Set scroll deadzone for inertial feel
	scroll.scroll_deadzone = SCROLL_DEADZONE


## Enforce minimum font size on a Control that supports theme font size overrides.
func _enforce_min_font_size_on_control(ctrl: Control) -> void:
	var min_font_px := int(MIN_FONT_SIZE_SP * _dp_scale)

	# Try to get current font size from theme override
	var current_size := ctrl.get_theme_font_size("font_size")

	# If no override exists, current_size will be the inherited theme default
	# Only override if explicitly smaller than minimum
	if current_size < min_font_px:
		ctrl.add_theme_font_size_override("font_size", min_font_px)


## Disable hover style on a button by making hover look like normal.
func _disable_hover_style(btn: Button) -> void:
	# Get the normal stylebox (could be override or theme default)
	var normal_style := btn.get_theme_stylebox("normal")
	if normal_style != null:
		btn.add_theme_stylebox_override("hover", normal_style)

	# Also remove hover font color distinction
	var normal_color := btn.get_theme_color("font_color")
	btn.add_theme_color_override("font_hover_color", normal_color)


## Check if a button is a confirmation/action button by its text.
func _is_confirmation_button(btn: Button) -> bool:
	var text := btn.text.strip_edges()
	for keyword in CONFIRMATION_KEYWORDS:
		if text.begins_with(keyword) or text == keyword:
			return true
	return false


## Apply confirmation button styling: 56x48dp minimum, distinct visual emphasis.
func _apply_confirmation_style(btn: Button) -> void:
	var min_w := CONFIRM_BUTTON_WIDTH_DP * _dp_scale
	var min_h := CONFIRM_BUTTON_HEIGHT_DP * _dp_scale

	if btn.custom_minimum_size.x < min_w:
		btn.custom_minimum_size.x = min_w
	if btn.custom_minimum_size.y < min_h:
		btn.custom_minimum_size.y = min_h

	# Apply distinct visual emphasis with a bold stylebox
	var emphasis_style := StyleBoxFlat.new()
	emphasis_style.bg_color = Color(0.20, 0.50, 0.25)  # Green emphasis
	emphasis_style.border_width_left = 2
	emphasis_style.border_width_right = 2
	emphasis_style.border_width_top = 2
	emphasis_style.border_width_bottom = 2
	emphasis_style.border_color = Color(0.40, 0.75, 0.40)
	emphasis_style.corner_radius_top_left = 4
	emphasis_style.corner_radius_top_right = 4
	emphasis_style.corner_radius_bottom_left = 4
	emphasis_style.corner_radius_bottom_right = 4
	emphasis_style.content_margin_left = 8
	emphasis_style.content_margin_right = 8
	emphasis_style.content_margin_top = 4
	emphasis_style.content_margin_bottom = 4

	btn.add_theme_stylebox_override("normal", emphasis_style)
	btn.add_theme_stylebox_override("hover", emphasis_style)

	var pressed_style := emphasis_style.duplicate() as StyleBoxFlat
	pressed_style.bg_color = Color(0.15, 0.40, 0.20)
	btn.add_theme_stylebox_override("pressed", pressed_style)

	# Bold font color for emphasis
	btn.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	btn.add_theme_color_override("font_pressed_color", Color(0.9, 0.9, 0.9))


## Called by the tree signal when a new node is added at runtime.
func _on_node_added(node: Node) -> void:
	if not _active:
		return
	# Apply overrides to the newly added node and its subtree
	_apply_overrides_recursive(node)


## ── Minimal touch-only overrides (no size modifications) ─────────


## Apply only touch-specific settings (scroll deadzone) to the entire tree.
func _apply_touch_overrides_to_tree() -> void:
	var root := get_tree().root
	if root == null:
		return
	_apply_touch_recursive(root)


func _apply_touch_recursive(node: Node) -> void:
	if node is ScrollContainer:
		(node as ScrollContainer).scroll_deadzone = SCROLL_DEADZONE
	elif node is Button:
		# Disable hover state on touch devices (no mouse hover on mobile)
		_disable_hover_style(node as Button)
	for child in node.get_children():
		_apply_touch_recursive(child)


## Minimal callback for newly added nodes — only apply scroll deadzone and disable hover.
func _on_node_added_minimal(node: Node) -> void:
	if not _active:
		return
	if node is ScrollContainer:
		(node as ScrollContainer).scroll_deadzone = SCROLL_DEADZONE
	elif node is Button:
		_disable_hover_style(node as Button)
