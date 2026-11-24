extends CanvasLayer

## Autoload: DiamondRingNotification
## Displays a temporary notification at center-top when a Diamond Ring drops.
## Listens to PlayerData.diamond_ring_awarded signal and shows a panel for 3+
## seconds with a fade-out animation. Positioned to not block garden interaction.

const DISPLAY_DURATION := 3.0  ## Seconds the notification stays fully visible
const FADE_DURATION := 0.8     ## Seconds for fade-out animation
const NOTIFICATION_MARGIN_TOP := 80  ## Pixels from top of screen

var _panel: PanelContainer = null
var _tween: Tween = null


func _ready() -> void:
	layer = 100  ## Render above all other UI
	PlayerData.diamond_ring_awarded.connect(_on_diamond_ring_awarded)


func _on_diamond_ring_awarded() -> void:
	## If a notification is already visible, remove it before showing a new one
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
		_panel = null
	if _tween != null and _tween.is_valid():
		_tween.kill()
		_tween = null

	_show_notification()


func _show_notification() -> void:
	## Build the notification panel
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.offset_top = NOTIFICATION_MARGIN_TOP
	_panel.offset_bottom = NOTIFICATION_MARGIN_TOP

	## Style: dark semi-transparent background with rounded corners
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

	## Content layout
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_panel.add_child(hbox)

	## Diamond Ring icon
	var icon_tex: Texture2D = load("res://Assets/diamond_ring.png")
	if icon_tex:
		var icon := TextureRect.new()
		icon.texture = icon_tex
		icon.custom_minimum_size = Vector2(40, 40)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hbox.add_child(icon)

	## Text content
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	hbox.add_child(vbox)

	var title_label := Label.new()
	title_label.text = "💎 Diamond Ring Found!"
	title_label.add_theme_font_size_override("font_size", 16)
	title_label.add_theme_color_override("font_color", Color(0.9, 0.85, 1.0))
	vbox.add_child(title_label)

	var desc_label := Label.new()
	desc_label.text = "A rare ring that boosts crop growth by 25%!"
	desc_label.add_theme_font_size_override("font_size", 11)
	desc_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	vbox.add_child(desc_label)

	add_child(_panel)

	## Animate: wait DISPLAY_DURATION then fade out
	_tween = create_tween()
	_tween.tween_interval(DISPLAY_DURATION)
	_tween.tween_property(_panel, "modulate:a", 0.0, FADE_DURATION)
	_tween.tween_callback(_cleanup)


func _cleanup() -> void:
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
		_panel = null
	_tween = null
