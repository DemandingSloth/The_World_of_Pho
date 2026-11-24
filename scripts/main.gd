extends Node
## Main scene script — thin shell that wires persistent elements together.
## Handles initial navigation, TopBar refresh on screen changes, and edge-swipe back gesture.
##
## Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 4.4, 4.5, 4.7, 11.2, 11.3, 11.4, 11.5

@onready var background: TextureRect = $Background
@onready var top_bar: TopBar = $TopBar
@onready var screen_container: Control = $ScreenContainer
@onready var navigator: ScreenNavigator = $ScreenNavigator

## How close to the screen edge (in pixels) a swipe must start to count as an edge swipe.
const EDGE_SWIPE_ZONE: float = 40.0
## Minimum horizontal travel (in pixels) to register as a back swipe.
const EDGE_SWIPE_MIN_DIST: float = 80.0
## Maximum vertical drift allowed — keeps accidental scrolls from triggering back.
const EDGE_SWIPE_MAX_VERTICAL: float = 60.0

var _swipe_start: Vector2 = Vector2.ZERO
var _swipe_active: bool = false


func _ready() -> void:
	# Store default background texture for restoration when screens don't override (Req 11.3)
	background.set_meta("default_texture", background.texture)

	# Wire navigator screen_changed to refresh top bar (Req 4.3, 4.4, 4.5, 4.7)
	navigator.screen_changed.connect(_on_screen_changed)

	# Show the prospector report when returning from a long background idle
	# (>= 15 min), reusing the same popup as a cold start.
	if AndroidLifecycleManager.has_signal("resumed_after_idle"):
		AndroidLifecycleManager.resumed_after_idle.connect(_show_offline_prospector_popup)

	# Determine initial screen from AndroidLifecycleManager state or default to home (Req 3.3, 3.4)
	var start_screen: String = AndroidLifecycleManager.get_current_screen()
	if start_screen == "":
		start_screen = "home"
	call_deferred("_navigate_initial", start_screen)


func _input(event: InputEvent) -> void:
	# Edge-swipe back gesture — left or right edge swipe navigates back,
	# except on the home screen where there is nowhere to go back to.
	var current := navigator.get_current_screen()
	if current == null or current.get_screen_name() == "home":
		return
	## Screens with drag gameplay near the edges (e.g. the hare chase, where cuts
	## start at the side walls) opt out so a stroke isn't read as "back".
	if not current.allows_edge_swipe_back():
		_swipe_active = false
		return

	var viewport_w: float = get_viewport().get_visible_rect().size.x

	if event is InputEventScreenTouch:
		if event.pressed:
			var x: float = event.position.x
			# Start tracking if touch begins within the edge zone on either side
			if x <= EDGE_SWIPE_ZONE or x >= viewport_w - EDGE_SWIPE_ZONE:
				_swipe_start = event.position
				_swipe_active = true
			else:
				_swipe_active = false
		else:
			_swipe_active = false

	elif event is InputEventScreenDrag and _swipe_active:
		var delta: Vector2 = event.position - _swipe_start
		var h_dist: float = absf(delta.x)
		var v_dist: float = absf(delta.y)

		# Once vertical drift exceeds limit, cancel — it's a scroll not a swipe
		if v_dist > EDGE_SWIPE_MAX_VERTICAL:
			_swipe_active = false
			return

		if h_dist >= EDGE_SWIPE_MIN_DIST:
			_swipe_active = false
			get_viewport().set_input_as_handled()
			# Only navigate back if there's actually somewhere to go
			if AndroidLifecycleManager.can_go_back():
				navigator.navigate_back()


func _navigate_initial(start_screen: String) -> void:
	navigator.navigate_to(start_screen)
	# Show offline prospector popup if gems were collected while away
	_show_offline_prospector_popup()


func _show_offline_prospector_popup() -> void:
	var haul: Dictionary = PlayerData.offline_prospector_haul
	if haul.is_empty():
		return

	## Build popup text
	var lines: Array = ["While you were away, your prospectors produced:"]
	var total := 0
	for gem_type in haul:
		var count: int = haul[gem_type]
		total += count
		lines.append("  • %s × %s" % [gem_type.replace("_", " ").capitalize(), PlayerData.format_number(count)])
	lines.append("\n%s gems added to inventory!" % PlayerData.format_number(total))

	## Build a custom window so we can fully control text colour
	var popup := Window.new()
	popup.title = "Prospector Report"
	popup.size = Vector2i(320, 300)
	popup.unresizable = true
	popup.always_on_top = true

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.12, 0.12, 0.18, 0.97)
	panel_style.content_margin_left = 12
	panel_style.content_margin_right = 12
	panel_style.content_margin_top = 12
	panel_style.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", panel_style)
	popup.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	## Scroll the (potentially long) gem list so a big haul can't push the
	## "Nice!" button off the bottom of the fixed-size window. The scroll takes
	## all remaining height; the button stays pinned below it.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	## Deadzone lets a touch swipe anywhere on the text pan the list on mobile.
	scroll.scroll_deadzone = 16
	vbox.add_child(scroll)

	var body_lbl := Label.new()
	body_lbl.text = "\n".join(lines)
	body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_lbl.add_theme_font_size_override("font_size", 13)
	body_lbl.add_theme_color_override("font_color", Color.WHITE)
	scroll.add_child(body_lbl)

	var nice_btn := Button.new()
	nice_btn.text = "Nice!"
	nice_btn.custom_minimum_size = Vector2(120, 40)
	nice_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	nice_btn.add_theme_font_size_override("font_size", 14)
	vbox.add_child(nice_btn)

	nice_btn.pressed.connect(popup.queue_free)
	popup.close_requested.connect(popup.queue_free)

	add_child(popup)
	popup.popup_centered()
	# Already applied to inventory at startup; don't treat this haul as a new collect later
	PlayerData.offline_prospector_haul = {}


func _on_screen_changed(_screen_name: String) -> void:
	# TopBar refresh is handled by ScreenNavigator._update_top_bar() already,
	# but we ensure it's called here as well for the signal-driven path (Req 4.3)
	top_bar.refresh()
