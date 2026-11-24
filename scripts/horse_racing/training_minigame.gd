extends Control
class_name TrainingMinigame
## The GROOM training mini-game: a brush-swipe game. The horse's breed sprite
## sits in the middle; a brush rests below it. Drag the brush ONTO the horse and
## swipe around — swipe distance accumulated WHILE the brush is over the horse
## builds the score. If the brush leaves the horse area more than twice (the 3rd
## exit ends it), the run is over. Score (brush strokes) feeds the shared server
## formula round(score/10 + 1, 2) -> life_cap gain. Emits finished(score:int)
## (or -1 if cancelled) — same contract as the sprint/hurdle games.
##
## Kept as `class_name TrainingMinigame` + setup(title, blurb, accent) so the
## Stable screen's groom branch wires in unchanged.

signal finished(score: int)

## Tuning.
const HORSE_SIZE := 150.0        ## on-screen horse square (big, to swipe over)
const BRUSH_SIZE := 56.0         ## on-screen brush square
const HORSE_INSET := 18.0        ## shrink the "over the horse" area in from the sprite edges
const PERFECT_DISTANCE := 2600.0 ## total on-horse swipe px that maps to the max score (90 pts)
const MAX_EXITS := 2             ## brush may leave the horse this many times; the next ends it
const STROKE_MIN := 4.0          ## ignore sub-pixel jitter below this per-frame move

var _accent: Color = Color(0.85, 0.6, 1.0)
var _title := "Groom"
var _blurb := ""

var _field: Control = null
var _horse: TextureRect = null
var _brush: Control = null       ## draggable brush (TextureRect art or a drawn placeholder)
var _title_lbl: Label = null
var _info_lbl: Label = null

var _horse_rect := Rect2()       ## the "over the horse" area in field-local coords
var _dragging := false
var _was_over := false           ## was the brush over the horse last sample?
var _last_pos := Vector2.ZERO    ## last brush centre while dragging
var _distance := 0.0             ## accumulated on-horse swipe distance
var _exits := 0                  ## times the brush left the horse area
var _running := false
var _done := false


func setup(title: String, blurb: String, accent: Color) -> void:
	_title = title
	_blurb = blurb
	_accent = accent


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(340, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.11, 0.15, 0.98)
	style.set_corner_radius_all(10)
	style.set_border_width_all(2)
	style.border_color = _accent
	style.content_margin_left = 14; style.content_margin_right = 14
	style.content_margin_top = 14; style.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	_title_lbl = Label.new()
	_title_lbl.text = _title if _title != "" else "✨ Groom"
	_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_lbl.add_theme_font_size_override("font_size", 18)
	_title_lbl.add_theme_color_override("font_color", _accent)
	vbox.add_child(_title_lbl)

	_info_lbl = Label.new()
	_info_lbl.text = "Drag the brush over the horse and swipe!" if _blurb == "" else _blurb
	_info_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_lbl.add_theme_font_size_override("font_size", 11)
	_info_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	vbox.add_child(_info_lbl)

	## Playfield: horse centred near the top, brush resting below it.
	_field = Control.new()
	_field.custom_minimum_size = Vector2(300, 260)
	_field.clip_contents = true
	_field.mouse_filter = Control.MOUSE_FILTER_STOP
	_field.gui_input.connect(_on_field_input)
	vbox.add_child(_field)

	_horse = TextureRect.new()
	_horse.custom_minimum_size = Vector2(HORSE_SIZE, HORSE_SIZE)
	_horse.size = Vector2(HORSE_SIZE, HORSE_SIZE)
	_horse.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_horse.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_horse.mouse_filter = Control.MOUSE_FILTER_IGNORE
	## `_breed_tex` is set via the title text? No — groom gets the breed through
	## the blurb-free path; the Stable screen passes a breed-less title, so we
	## accept an optional breed via set_breed() below. Default: a neutral icon.
	_horse.texture = _breed_tex
	_field.add_child(_horse)

	_brush = _make_brush()
	_field.add_child(_brush)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(0, 32)
	cancel.add_theme_font_size_override("font_size", 11)
	cancel.pressed.connect(_cancel)
	vbox.add_child(cancel)

	await get_tree().process_frame
	_field.resized.connect(_layout_field)
	_layout_field()
	_running = true


## Optional: give the groom game the horse's breed sprite. Called by the Stable
## screen right after setup(); safe before _ready (stored) or after (applied).
var _breed := ""
var _breed_tex: Texture2D = null
func set_breed(breed: String) -> void:
	_breed = breed
	_breed_tex = HorseRacing.breed_texture(breed)
	if _horse != null:
		_horse.texture = _breed_tex


func _make_brush() -> Control:
	## Prefer the real brush art; otherwise draw a simple placeholder so the game
	## is playable before brush.png exists.
	if ResourceLoader.exists(HorseRacing.BRUSH_PATH):
		var tr := TextureRect.new()
		tr.texture = load(HorseRacing.BRUSH_PATH) as Texture2D
		tr.custom_minimum_size = Vector2(BRUSH_SIZE, BRUSH_SIZE)
		tr.size = Vector2(BRUSH_SIZE, BRUSH_SIZE)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return tr
	## Placeholder: a rounded panel with a label.
	var p := Panel.new()
	p.custom_minimum_size = Vector2(BRUSH_SIZE, BRUSH_SIZE)
	p.size = Vector2(BRUSH_SIZE, BRUSH_SIZE)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.75, 0.55, 0.3)
	st.set_corner_radius_all(10)
	st.set_border_width_all(2)
	st.border_color = Color(0.4, 0.28, 0.15)
	p.add_theme_stylebox_override("panel", st)
	var lbl := Label.new()
	lbl.text = "🧹"
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(lbl)
	return p


func _layout_field() -> void:
	var w: float = _field.size.x
	var h: float = _field.size.y
	if w <= 0.0:
		w = _field.custom_minimum_size.x
	if h <= 0.0:
		h = _field.custom_minimum_size.y

	## Horse centred horizontally, near the top.
	var hx := (w - HORSE_SIZE) / 2.0
	var hy := 10.0
	if _horse != null:
		_horse.position = Vector2(hx, hy)
	## "Over the horse" area (inset a little so edges are forgiving).
	_horse_rect = Rect2(
		hx + HORSE_INSET, hy + HORSE_INSET,
		HORSE_SIZE - 2.0 * HORSE_INSET, HORSE_SIZE - 2.0 * HORSE_INSET)

	## Brush resting centred below the horse.
	if _brush != null and not _dragging:
		_brush.position = Vector2((w - BRUSH_SIZE) / 2.0, h - BRUSH_SIZE - 8.0)


func _brush_center() -> Vector2:
	return _brush.position + Vector2(BRUSH_SIZE, BRUSH_SIZE) / 2.0


func _on_field_input(event: InputEvent) -> void:
	if not _running:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_drag(event.position)
		else:
			_end_drag()
	elif event is InputEventScreenTouch:
		if event.pressed:
			_begin_drag(event.position)
		else:
			_end_drag()
	elif event is InputEventMouseMotion and _dragging:
		_move_brush(event.position)
	elif event is InputEventScreenDrag and _dragging:
		_move_brush(event.position)


func _begin_drag(field_pos: Vector2) -> void:
	_dragging = true
	_brush.position = field_pos - Vector2(BRUSH_SIZE, BRUSH_SIZE) / 2.0
	_last_pos = _brush_center()
	_was_over = _horse_rect.has_point(_last_pos)


func _end_drag() -> void:
	_dragging = false
	## Snap the brush back to its rest spot below the horse.
	_layout_field()


func _move_brush(field_pos: Vector2) -> void:
	_brush.position = field_pos - Vector2(BRUSH_SIZE, BRUSH_SIZE) / 2.0
	var c := _brush_center()
	var over := _horse_rect.has_point(c)

	if over:
		## Accumulate swipe distance only while over the horse.
		var step := c.distance_to(_last_pos)
		if step >= STROKE_MIN:
			_distance += step
			_update_info()
			## Fully groomed (100%) — end the run successfully.
			if _distance >= PERFECT_DISTANCE:
				_was_over = over
				_last_pos = c
				_finish()
				return
	else:
		## Count an exit the moment the brush leaves the horse (edge-triggered).
		if _was_over:
			_exits += 1
			_update_info()
			if _exits > MAX_EXITS:
				_finish()
				return
	_was_over = over
	_last_pos = c


func _update_info() -> void:
	if _info_lbl != null:
		var left := MAX_EXITS - _exits + 1  ## exits remaining before game over
		_info_lbl.text = "Groomed %d%%   •   %d slip%s left" % [
			int(min(100.0, _distance / PERFECT_DISTANCE * 100.0)),
			max(0, left), "" if left == 1 else "s"]


func _finish() -> void:
	if _done:
		return
	_done = true
	_running = false
	_dragging = false
	## Map on-horse distance -> the server point scale (PERFECT_DISTANCE == 90
	## points -> the max +10.00 gain). More than perfect is fine (server caps).
	var pct := int(min(100.0, _distance / PERFECT_DISTANCE * 100.0))
	var score := int(round(_distance / PERFECT_DISTANCE * 90.0))
	if _info_lbl != null:
		_info_lbl.text = ("All groomed! 100%%" if pct >= 100
			else "Done — groomed %d%%." % pct)
	await get_tree().create_timer(0.6).timeout
	finished.emit(score)
	queue_free()


func _cancel() -> void:
	if _done:
		return
	_done = true
	_running = false
	finished.emit(-1)
	queue_free()
