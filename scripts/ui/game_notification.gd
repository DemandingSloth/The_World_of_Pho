extends CanvasLayer

## Autoload: GameNotification
## Generic in-app notification banner shown at center-top of the screen.
## Call GameNotification.show_message(title, desc) from anywhere to surface a
## short, auto-dismissing banner. Messages queue so they don't overlap.
##
## Modeled on DiamondRingNotification, but reusable for daily bonus / garden /
## orchard readiness alerts.

const DISPLAY_DURATION := 3.0  ## Seconds a short banner stays fully visible
const FADE_DURATION := 0.6     ## Seconds for fade-out animation
const NOTIFICATION_MARGIN_TOP := 80  ## Pixels from top of screen

## Long descriptions (wider than this) marquee-scroll horizontally instead of
## truncating, so the whole message can be read.
const DESC_MAX_WIDTH := 300.0      ## Visible width of the description area (px)
const SCROLL_SPEED := 60.0         ## Marquee speed (px/sec)
const SCROLL_START_HOLD := 0.8     ## Pause before scrolling starts
const SCROLL_END_HOLD := 1.0       ## Hold after the last word is visible

var _panel: PanelContainer = null
var _tween: Tween = null
var _queue: Array = []  ## Pending messages: [{title, desc, icon, target}]
var _current_target: String = ""  ## Screen the visible banner navigates to on tap
## Marquee state for the current banner (null when the desc fits without scroll).
var _scroll_label: Label = null
var _scroll_distance: float = 0.0


func _ready() -> void:
	layer = 100  ## Render above all other UI


## Public entry point. icon_path is optional (path to a Texture2D).
## target_screen is an optional ScreenNavigator screen name; when set, tapping
## the banner navigates there (e.g. "garden", "orchard", "workshop", "home").
func show_message(title: String, desc: String = "", icon_path: String = "", target_screen: String = "") -> void:
	_queue.append({"title": title, "desc": desc, "icon": icon_path, "target": target_screen})
	## If nothing is showing, start immediately.
	if _panel == null or not is_instance_valid(_panel):
		_show_next()


func _show_next() -> void:
	if _queue.is_empty():
		return
	var msg: Dictionary = _queue.pop_front()
	_current_target = str(msg.get("target", ""))
	_build_panel(str(msg.get("title", "")), str(msg.get("desc", "")), str(msg.get("icon", "")))


func _build_panel(title: String, desc: String, icon_path: String) -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.offset_top = NOTIFICATION_MARGIN_TOP
	_panel.offset_bottom = NOTIFICATION_MARGIN_TOP
	## If the banner has a target screen, make it tappable (capture taps and
	## navigate). Otherwise let taps pass through to the game underneath.
	if _current_target != "":
		_panel.mouse_filter = Control.MOUSE_FILTER_STOP
		_panel.gui_input.connect(_on_panel_gui_input)
	else:
		_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.15, 0.92)
	style.border_color = Color(0.6, 0.8, 1.0, 0.7)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.content_margin_left = 20
	style.content_margin_right = 20
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	_panel.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(hbox)

	if icon_path != "":
		var icon_tex: Texture2D = load(icon_path)
		if icon_tex:
			var icon := TextureRect.new()
			icon.texture = icon_tex
			icon.custom_minimum_size = Vector2(40, 40)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			hbox.add_child(icon)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(vbox)

	var title_label := Label.new()
	title_label.text = title
	title_label.add_theme_font_size_override("font_size", 16)
	title_label.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(title_label)

	## The description: if it's short enough to fit within DESC_MAX_WIDTH it shows
	## normally; if it's longer (e.g. the Valentine's Valor messages), it scrolls
	## horizontally so the whole message can be read.
	var scroll_time := 0.0
	if desc != "":
		var desc_label := Label.new()
		desc_label.text = desc
		desc_label.add_theme_font_size_override("font_size", 11)
		desc_label.add_theme_color_override("font_color", Color(0.75, 0.9, 0.8))
		desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var desc_fs := 11
		var desc_font := desc_label.get_theme_font("font")
		if desc_font == null:
			desc_font = ThemeDB.fallback_font
		var text_w := desc_font.get_string_size(desc, HORIZONTAL_ALIGNMENT_LEFT, -1, desc_fs).x

		if text_w <= DESC_MAX_WIDTH:
			## Fits — plain label.
			vbox.add_child(desc_label)
		else:
			## Overflows — clip to DESC_MAX_WIDTH and marquee the label leftward.
			var clip := Control.new()
			clip.custom_minimum_size = Vector2(DESC_MAX_WIDTH, 0)
			clip.clip_contents = true
			clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			desc_label.autowrap_mode = TextServer.AUTOWRAP_OFF
			desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			desc_label.position = Vector2.ZERO
			clip.add_child(desc_label)
			## Give the clip a height so it lays out in the vbox.
			clip.custom_minimum_size.y = desc_font.get_height(desc_fs) + 2
			vbox.add_child(clip)
			## Store the scroll parameters; the tween is built below once the
			## panel is in the tree and sized.
			_scroll_label = desc_label
			_scroll_distance = text_w - DESC_MAX_WIDTH
			scroll_time = _scroll_distance / SCROLL_SPEED

	add_child(_panel)

	## Timing:
	##  • Fade in.
	##  • If scrolling: hold briefly, scroll the text fully left, then hold 1s
	##    after the last word is visible.
	##  • Else: hold the fixed display duration.
	##  • Fade out, advance.
	_panel.modulate.a = 0.0
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate:a", 1.0, FADE_DURATION)
	if _scroll_label != null and scroll_time > 0.0:
		## Brief pause so the start is readable, then marquee left.
		_tween.tween_interval(SCROLL_START_HOLD)
		_tween.tween_property(_scroll_label, "position:x", -_scroll_distance, scroll_time)\
			.set_trans(Tween.TRANS_LINEAR)
		## Stay 1 second after the last word is visible.
		_tween.tween_interval(SCROLL_END_HOLD)
	else:
		_tween.tween_interval(DISPLAY_DURATION)
	_tween.tween_property(_panel, "modulate:a", 0.0, FADE_DURATION)
	_tween.tween_callback(_cleanup_and_advance)


func _cleanup_and_advance() -> void:
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null
	_tween = null
	_current_target = ""
	_scroll_label = null
	_scroll_distance = 0.0
	_show_next()


## Handles taps on a targeted banner: navigate to its subject, then dismiss.
func _on_panel_gui_input(event: InputEvent) -> void:
	var tapped := false
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		tapped = true
	elif event is InputEventScreenTouch and event.pressed:
		tapped = true
	if not tapped:
		return
	if _panel != null and is_instance_valid(_panel):
		_panel.accept_event()
	var target := _current_target
	## Dismiss the banner immediately, then navigate.
	if _tween != null and is_instance_valid(_tween):
		_tween.kill()
	_cleanup_and_advance()
	if target != "":
		_navigate_to(target)


## Navigates to a screen via the active ScreenNavigator (sibling of the current
## scene). No-op if the navigator can't be found or the screen is unknown.
func _navigate_to(screen_name: String) -> void:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return
	var nav := tree.current_scene.get_node_or_null("ScreenNavigator")
	if nav == null or not nav.has_method("navigate_to"):
		return
	nav.navigate_to(screen_name)
