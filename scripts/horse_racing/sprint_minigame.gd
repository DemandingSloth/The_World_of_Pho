extends Control
class_name SprintMinigame
## The SPRINT training mini-game: a traffic-light reaction runner. The horse runs
## the race track (no hurdles). A traffic light cycles RED/GREEN:
##   • GREEN: tap SPRINT as fast as you can — the horse accelerates and advances
##     through a "green section". Each completed green section = 1 point.
##   • RED:   STOP tapping — the horse eases to a walk.
## The run ENDS the moment either fault happens:
##   • you tap SPRINT while the light is RED (jumped the gun), or
##   • you fail to tap within REACT_WINDOW seconds after the light turns GREEN.
## Scoring (per the design): raw = (taps made while GREEN) × (green sections
## passed). That raw is mapped onto the server's 0..90 point scale (PERFECT_RAW
## raw == 90 points), and the integer feeds the shared formula round(score/10 +
## 1, 2) -> Speed gain (capped per session, clamped to the stat ceiling).
## Emits finished(score:int) (or -1 if cancelled) — same contract as the others.

signal finished(score: int)

## Light states. Cycle is GREEN -> YELLOW -> RED -> GREEN -> ... (yellow only
## sits between green and red; red goes straight back to green).
enum Light { GREEN, YELLOW, RED }

## Tuning.
const REACT_WINDOW := 0.5        ## s allowed between green on and the first tap
const GREEN_MIN := 1.1           ## min green-light duration (a "section")
const GREEN_MAX := 2.2           ## max green-light duration (randomised each time)
const YELLOW_DURATION := 0.5     ## fixed yellow flash — tapping here is safe
const RED_MIN := 0.7             ## min red-light duration
const RED_MAX := 1.8             ## max red-light duration (randomised each time)
const TAP_BOOST := 70.0          ## +px/sec per tap during green (visual speed)
const TAP_DECAY := 180.0         ## px/sec^2 the horse slows when not tapping
const WALK_SPEED := 60.0         ## px/sec the scroll never drops below (a walk)
const MAX_SPEED := 520.0         ## cap on the visual scroll speed
const RUN_FPS_BASE := 6.0        ## leg-cycle fps at a walk
const RUN_FPS_PER_SPEED := 0.03  ## extra fps per px/sec of scroll speed
const HORSE_SIZE := 72.0
const HORSE_X := 70.0
const GROUND_FRAC := 0.80

var _breed := "thoroughbred"
var _blurb := ""

var _field: Control = null
var _bg_a: TextureRect = null
var _bg_b: TextureRect = null
var _horse: TextureRect = null
var _light: Panel = null         ## the traffic-light lamp (colour = state)
var _info_lbl: Label = null
var _score_lbl: Label = null
var _sprint_btn: Button = null

var _bg_scroll := 0.0
var _bg_w := 0.0
var _run_t := 0.0
var _ground_y := 0.0

var _speed := WALK_SPEED          ## current visual scroll speed
var _light_state: int = Light.RED ## current light (starts red)
var _phase_t := 0.0               ## time left in the current light phase
var _since_green := 0.0           ## time since the light turned green (for REACT_WINDOW)
var _tapped_this_green := false   ## did the player tap during THIS green?
var _sections := 0                ## green sections successfully completed
var _green_taps := 0              ## total taps made while green (across all sections)

var _running := false
var _done := false


func setup(breed: String, blurb: String) -> void:
	_breed = breed
	_blurb = blurb


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
	panel.custom_minimum_size = Vector2(360, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.11, 0.15, 0.98)
	style.set_corner_radius_all(10)
	style.set_border_width_all(2)
	style.border_color = Color(1.0, 0.75, 0.35)
	style.content_margin_left = 12; style.content_margin_right = 12
	style.content_margin_top = 12; style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "🏃 Sprint"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(1.0, 0.75, 0.35))
	vbox.add_child(title)

	_info_lbl = Label.new()
	_info_lbl.text = "Tap fast on GREEN. Stop on RED!" if _blurb == "" else _blurb
	_info_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_lbl.add_theme_font_size_override("font_size", 11)
	_info_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	vbox.add_child(_info_lbl)

	## Playfield (scrolling track + horse + the traffic light lamp).
	_field = Control.new()
	_field.custom_minimum_size = Vector2(336, 180)
	_field.clip_contents = true
	_field.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_field)

	var bg_tex: Texture2D = null
	if ResourceLoader.exists(HorseRacing.TRAINING_BG_PATH):
		bg_tex = load(HorseRacing.TRAINING_BG_PATH) as Texture2D
	_bg_a = _make_bg(bg_tex)
	_bg_b = _make_bg(bg_tex)
	_field.add_child(_bg_a)
	_field.add_child(_bg_b)

	_horse = TextureRect.new()
	_horse.custom_minimum_size = Vector2(HORSE_SIZE, HORSE_SIZE)
	_horse.size = Vector2(HORSE_SIZE, HORSE_SIZE)
	_horse.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_horse.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_horse.mouse_filter = Control.MOUSE_FILTER_IGNORE
	## Sheet faces left; horse runs left->right, so mirror horizontally.
	_horse.pivot_offset = Vector2(HORSE_SIZE / 2.0, HORSE_SIZE / 2.0)
	_horse.scale = Vector2(-1, 1)
	_horse.texture = HorseRacing.breed_run_frame(_breed, 0)
	_field.add_child(_horse)

	## Traffic-light lamp — a big coloured dot in the top-right of the field.
	_light = Panel.new()
	_light.custom_minimum_size = Vector2(44, 44)
	_light.size = Vector2(44, 44)
	_light.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_field.add_child(_light)

	## Big SPRINT button (and the whole field taps too, via the button only to
	## keep "tap = sprint" unambiguous for scoring).
	_sprint_btn = Button.new()
	_sprint_btn.text = "SPRINT"
	_sprint_btn.custom_minimum_size = Vector2(0, 52)
	_sprint_btn.add_theme_font_size_override("font_size", 20)
	_sprint_btn.pressed.connect(_on_sprint)
	vbox.add_child(_sprint_btn)

	_score_lbl = Label.new()
	_score_lbl.text = "Sections: 0   Taps: 0"
	_score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_score_lbl.add_theme_font_size_override("font_size", 12)
	_score_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	vbox.add_child(_score_lbl)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(0, 30)
	cancel.add_theme_font_size_override("font_size", 11)
	cancel.pressed.connect(_cancel)
	vbox.add_child(cancel)

	await get_tree().process_frame
	_field.resized.connect(_layout_field)
	_layout_field()
	## Start on RED for a beat, then the cycle begins.
	_set_light(Light.RED)
	_phase_t = randf_range(RED_MIN, RED_MAX)
	_running = true
	set_process(true)


func _make_bg(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _layout_field() -> void:
	var w: float = _field.size.x
	var h: float = _field.size.y
	if w <= 0.0:
		w = _field.custom_minimum_size.x
	if h <= 0.0:
		h = _field.custom_minimum_size.y

	## Cover-scale the bg to the field and bottom-align (road always visible).
	var tex := _bg_a.texture if _bg_a != null else null
	var bg_w := w
	var bg_h := h
	if tex != null and tex.get_width() > 0 and tex.get_height() > 0:
		var ar := float(tex.get_width()) / float(tex.get_height())
		bg_w = w
		bg_h = w / ar
		if bg_h < h:
			bg_h = h
			bg_w = h * ar
	var top_y := h - bg_h
	for bg in [_bg_a, _bg_b]:
		if bg != null:
			bg.size = Vector2(bg_w, bg_h)
			bg.position = Vector2(0, top_y)
	if _bg_b != null:
		_bg_b.position = Vector2(bg_w, top_y)
	_bg_w = bg_w

	_ground_y = top_y + bg_h * GROUND_FRAC
	if _horse != null:
		_horse.position = Vector2(HORSE_X, _ground_y - HORSE_SIZE)
	if _light != null:
		_light.position = Vector2(w - 56, 12)


func _set_light(state: int) -> void:
	_light_state = state
	var st := StyleBoxFlat.new()
	st.set_corner_radius_all(22)
	st.set_border_width_all(3)
	st.border_color = Color(0, 0, 0, 0.6)
	match state:
		Light.GREEN:  st.bg_color = Color(0.2, 0.95, 0.3)
		Light.YELLOW: st.bg_color = Color(0.98, 0.85, 0.2)
		_:            st.bg_color = Color(0.95, 0.2, 0.2)
	_light.add_theme_stylebox_override("panel", st)


func _process(delta: float) -> void:
	if not _running:
		return
	var w: float = _field.size.x
	if w <= 0.0:
		w = _field.custom_minimum_size.x

	## Advance the light phase.
	_phase_t -= delta
	if _light_state == Light.GREEN:
		_since_green += delta
		## Fault: no tap within the reaction window after green turns on.
		if not _tapped_this_green and _since_green >= REACT_WINDOW:
			_end_run("Too slow off the line!")
			return
	if _phase_t <= 0.0:
		match _light_state:
			Light.GREEN:
				## Green section completed (it got a tap, else it'd have faulted
				## above). Count the section, then flash YELLOW (safe) before red.
				_sections += 1
				_update_score_lbl()
				_set_light(Light.YELLOW)
				_phase_t = YELLOW_DURATION
			Light.YELLOW:
				## Yellow always leads to RED.
				_set_light(Light.RED)
				_phase_t = randf_range(RED_MIN, RED_MAX)
			_:  ## RED -> straight back to GREEN (no yellow on this edge).
				_set_light(Light.GREEN)
				_since_green = 0.0
				_tapped_this_green = false
				_phase_t = randf_range(GREEN_MIN, GREEN_MAX)

	## Horse speed: taps push it up (handled in _on_sprint); here it decays and
	## is floored at a walk when green-and-tapping has stopped.
	_speed = max(WALK_SPEED, _speed - TAP_DECAY * delta)

	## Scroll the two bg copies.
	var loop_w: float = _bg_w if _bg_w > 0.0 else w
	_bg_scroll += _speed * delta
	if _bg_scroll >= loop_w:
		_bg_scroll -= loop_w
	if _bg_a != null and _bg_b != null:
		_bg_a.position.x = -_bg_scroll
		_bg_b.position.x = -_bg_scroll + loop_w

	## Animate the gait faster the quicker the horse is moving.
	_run_t += delta * (RUN_FPS_BASE + _speed * RUN_FPS_PER_SPEED)
	if _horse != null:
		_horse.texture = HorseRacing.breed_run_frame(_breed, int(_run_t))


func _on_sprint() -> void:
	if not _running:
		return
	match _light_state:
		Light.GREEN:
			## Count the tap (score is taps × sections) and boost the horse.
			_tapped_this_green = true
			_green_taps += 1
			_speed = min(MAX_SPEED, _speed + TAP_BOOST)
			_update_score_lbl()
		Light.YELLOW:
			## Yellow doesn't care — safe tap, no score, no fault.
			pass
		_:
			## Fault: tapped on red.
			_end_run("Jumped the gun on RED!")


func _update_score_lbl() -> void:
	if _score_lbl != null:
		_score_lbl.text = "Sections: %d   Taps: %d" % [_sections, _green_taps]


func _end_run(reason: String) -> void:
	if _done:
		return
	_done = true
	_running = false
	set_process(false)
	if _sprint_btn != null:
		_sprint_btn.disabled = true
	if _info_lbl != null:
		_info_lbl.text = reason
	## Score = taps while green × green sections passed.
	var raw := _green_taps * _sections
	if _score_lbl != null:
		_score_lbl.text = "%d taps × %d sections = %d" % [_green_taps, _sections, raw]
	## Map raw -> the server point scale (PERFECT_RAW == 90 points -> max +10.00
	## gain). Fewer scale down; more than perfect is fine (server caps the gain).
	const PERFECT_RAW := 40.0
	var score := int(round(float(raw) / PERFECT_RAW * 90.0))
	await get_tree().create_timer(0.8).timeout
	finished.emit(score)
	queue_free()


func _cancel() -> void:
	if _done:
		return
	_done = true
	_running = false
	set_process(false)
	finished.emit(-1)
	queue_free()
