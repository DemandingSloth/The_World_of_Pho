extends CanvasLayer

## TutorialOverlay — Full-screen CanvasLayer UI that renders the dark overlay,
## highlight cutout, text bubble, and skip/confirm controls during active tutorial steps.
##
## Requirements: 2.1, 2.2, 2.3, 2.5, 4.1

## ── Signals ────────────────────────────────────────────────────
signal continue_pressed
signal skip_requested
signal skip_confirmed
signal skip_cancelled

## ── Constants ──────────────────────────────────────────────────
const VIEWPORT_SIZE := Vector2(420.0, 900.0)
const MARGIN := 12.0

## ── Node References ────────────────────────────────────────────
@onready var dark_overlay: ColorRect = $DarkOverlay
@onready var highlight_frame: Control = $HighlightFrame
@onready var text_bubble: PanelContainer = $TextBubble
@onready var step_text: Label = $TextBubble/VBox/StepText
@onready var continue_btn: Button = $TextBubble/VBox/ContinueBtn
@onready var skip_btn: Button = $SkipBtn
@onready var confirm_dialog: PanelContainer = $ConfirmDialog
@onready var yes_btn: Button = $ConfirmDialog/VBox/HBox/YesBtn
@onready var no_btn: Button = $ConfirmDialog/VBox/HBox/NoBtn

## ── State ──────────────────────────────────────────────────────
var _cutout_rect: Rect2 = Rect2()
var _allow_interaction: bool = false


## ── Lifecycle ──────────────────────────────────────────────────

func _ready() -> void:
	# Wire button signals (guard against missing nodes)
	if continue_btn != null:
		continue_btn.pressed.connect(_on_continue_pressed)
	if skip_btn != null:
		skip_btn.pressed.connect(_on_skip_pressed)
	if yes_btn != null:
		yes_btn.pressed.connect(_on_yes_pressed)
	if no_btn != null:
		no_btn.pressed.connect(_on_no_pressed)

	# Start hidden
	visible = false


## ── Public Interface ───────────────────────────────────────────

## Returns whether touches should pass through to the game UI.
func is_interaction_allowed() -> bool:
	return _allow_interaction


## Display a tutorial step: position the cutout around the target element,
## set the text bubble content, and position the bubble.
func show_step(step: Dictionary) -> void:
	visible = true
	if confirm_dialog != null:
		confirm_dialog.visible = false

	_allow_interaction = step.get("allow_interaction", false)
	if dark_overlay != null:
		dark_overlay.color = Color(0, 0, 0, 0.35) if _allow_interaction else Color(0, 0, 0, 0.7)

	# Resolve target node from the current screen
	var target_node: Control = _resolve_target(step.get("target_path", ""))
	var highlight_padding: float = step.get("highlight_padding", 8.0)

	if target_node != null:
		# Compute cutout rect from target's global rect + padding
		var target_rect := target_node.get_global_rect()
		_cutout_rect = Rect2(
			target_rect.position - Vector2(highlight_padding, highlight_padding),
			target_rect.size + Vector2(highlight_padding * 2, highlight_padding * 2)
		)
		# Show highlight frame around the target
		if highlight_frame != null:
			highlight_frame.visible = true
			highlight_frame.position = _cutout_rect.position
			highlight_frame.size = _cutout_rect.size
	else:
		# No valid target — hide highlight, use empty cutout (Req 12.1 error handling)
		_cutout_rect = Rect2()
		if highlight_frame != null:
			highlight_frame.visible = false

	# Set step text (Req 2.3)
	step_text.text = step.get("text", "")

	# Show/hide continue button based on action_required
	var action_required: bool = step.get("action_required", false)
	var custom_btn_text: String = step.get("continue_text", "")
	if action_required and target_node != null:
		# Only block advance when target exists and player must interact with it
		continue_btn.text = custom_btn_text if custom_btn_text != "" else "Do the action above"
		continue_btn.disabled = true
	else:
		# Allow continue: either no action required, or target is missing (Req 12.1)
		continue_btn.text = custom_btn_text if custom_btn_text != "" else "Tap to continue"
		continue_btn.disabled = false

	# Position the text bubble using preferred direction.
	var preferred: String = step.get("bubble_position", "below")
	await get_tree().process_frame  # Wait for layout to settle

	## Use the REAL viewport size, not a hardcoded constant — the old 420x900
	## assumption pushed the bubble off-screen on devices with other resolutions
	## (which made the overlay look blank). Also give the bubble a sane width so
	## it's always readable regardless of screen size.
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var bubble_w: float = minf(vp.x - MARGIN * 2.0, 400.0)
	text_bubble.custom_minimum_size.x = bubble_w
	text_bubble.size.x = bubble_w
	var bubble_size := text_bubble.size

	if target_node == null or _allow_interaction:
		## No target (most of the new tutorial) or free-interaction: center-bottom.
		text_bubble.position = Vector2(
			(vp.x - bubble_size.x) / 2.0,
			vp.y - bubble_size.y - MARGIN - 40.0
		)
	elif preferred == "top":
		text_bubble.position = Vector2((vp.x - bubble_size.x) / 2.0, MARGIN + 50.0)
	else:
		var bubble_pos := _compute_bubble_position(_cutout_rect, bubble_size, preferred)
		## Clamp to the real viewport so it can never land off-screen.
		bubble_pos.x = clampf(bubble_pos.x, MARGIN, maxf(MARGIN, vp.x - bubble_size.x - MARGIN))
		bubble_pos.y = clampf(bubble_pos.y, MARGIN, maxf(MARGIN, vp.y - bubble_size.y - MARGIN))
		text_bubble.position = bubble_pos


## Hide the overlay entirely.
func hide_overlay() -> void:
	visible = false


## Show the skip confirmation dialog. (Req 4.2)
func show_confirm_dialog() -> void:
	confirm_dialog.visible = true


## Hide the skip confirmation dialog. (Req 4.4)
func hide_confirm_dialog() -> void:
	confirm_dialog.visible = false


## Returns the current highlight cutout rect. (Req 2.2)
func get_cutout_rect() -> Rect2:
	return _cutout_rect


## Returns the current text bubble rect. (Req 2.3)
func get_bubble_rect() -> Rect2:
	return Rect2(text_bubble.position, text_bubble.size)


## ── Bubble Position Layout Algorithm ───────────────────────────

## Compute the best position for the text bubble relative to the cutout.
## Tries the preferred direction first, then falls back through other options.
## Clamps within viewport with margin. Falls back to bottom-center if all overlap.
func _compute_bubble_position(cutout_rect: Rect2, bubble_size: Vector2, preferred: String) -> Vector2:
	var pos := Vector2.ZERO

	# Build direction list: preferred first, then remaining in fallback order
	var directions: Array[String] = [preferred]
	for dir in ["below", "above", "right", "left"]:
		if dir != preferred:
			directions.append(dir)

	for dir in directions:
		match dir:
			"below":
				pos = Vector2(cutout_rect.position.x, cutout_rect.end.y + MARGIN)
			"above":
				pos = Vector2(cutout_rect.position.x, cutout_rect.position.y - bubble_size.y - MARGIN)
			"right":
				pos = Vector2(cutout_rect.end.x + MARGIN, cutout_rect.position.y)
			"left":
				pos = Vector2(cutout_rect.position.x - bubble_size.x - MARGIN, cutout_rect.position.y)

		# Clamp within viewport
		pos.x = clampf(pos.x, MARGIN, VIEWPORT_SIZE.x - bubble_size.x - MARGIN)
		pos.y = clampf(pos.y, MARGIN, VIEWPORT_SIZE.y - bubble_size.y - MARGIN)

		# Check no overlap with cutout
		var bubble_rect := Rect2(pos, bubble_size)
		if not bubble_rect.intersects(cutout_rect):
			return pos

	# Fallback: place at bottom center
	pos = Vector2((VIEWPORT_SIZE.x - bubble_size.x) / 2.0, VIEWPORT_SIZE.y - bubble_size.y - MARGIN)
	return pos


## ── Private Helpers ────────────────────────────────────────────

## Resolve the target node path relative to the current active screen.
func _resolve_target(target_path: String) -> Control:
	if target_path == "":
		return null

	if not is_inside_tree():
		push_warning("TutorialOverlay: Not in scene tree, cannot resolve target")
		return null

	# Get the current screen from ScreenNavigator via Main/ScreenContainer
	var screen_container := get_tree().root.get_node_or_null("Main/ScreenContainer")
	if screen_container == null:
		push_warning("TutorialOverlay: Could not find Main/ScreenContainer")
		return null

	if screen_container.get_child_count() == 0:
		push_warning("TutorialOverlay: ScreenContainer has no active screen")
		return null

	var current_screen: Control = screen_container.get_child(0) as Control
	if current_screen == null:
		return null

	var target := current_screen.get_node_or_null(NodePath(target_path)) as Control
	if target == null:
		push_warning("TutorialOverlay: Target path '%s' not found on screen '%s'" % [target_path, current_screen.name])
	return target


## ── Button Signal Handlers ─────────────────────────────────────

func _on_continue_pressed() -> void:
	continue_pressed.emit()


func _on_skip_pressed() -> void:
	skip_requested.emit()


func _on_yes_pressed() -> void:
	skip_confirmed.emit()


func _on_no_pressed() -> void:
	skip_cancelled.emit()
