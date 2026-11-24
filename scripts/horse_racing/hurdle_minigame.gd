extends Control
class_name HurdleMinigame
## The HURDLE training mini-game: a Chrome-dino-style endless runner. The horse
## runs left->right along the race track while hurdles scroll in from the right;
## the player taps JUMP to hop over them. Clearing hurdles builds the score;
## clipping one is a miss. Emits `finished(score)` with a 0..100 performance
## score (or -1 if cancelled) — same contract as TrainingMinigame, so the Stable
## screen handles it identically. Fully local; the server re-derives the real
## Endurance gain from the reported score and clamps it.

signal finished(score: int)

## Tuning.
## ENDLESS survival: hurdles keep coming until the player clips one. The run's
## score is driven by how many were CLEARED — PERFECT_CLEARS clears (or more)
## maps to the max 0..100 score; fewer scales linearly. The server then turns
## that 0..100 into the real Endurance gain (hurdle: +1..+3/day) and applies the
## once-per-day cap. So a flawless-but-tired player still only gains the daily max.
const PERFECT_CLEARS := 12       ## clears that count as a perfect (score 100) run
const SCROLL_SPEED := 260.0      ## px/sec the world scrolls left (base)
const SPEED_RAMP := 7.0          ## +px/sec added per hurdle cleared (difficulty ramp)
const MAX_SCROLL_SPEED := 520.0  ## cap on the ramped scroll speed
const RUN_FPS := 12.0            ## horse leg-cycle frames per second
const GRAVITY := 2400.0          ## px/sec^2
const JUMP_VELOCITY := -759.0    ## initial jump impulse (negative = up). Peak ≈
                                 ## vel²/(2·GRAVITY) ≈ 120px (≈20px lower than the
                                 ## old 820 → 140px arc); still clears the 56px hurdle.
const HORSE_SIZE := 72.0         ## on-screen horse square
const HURDLE_W := 46.0           ## on-screen hurdle width
const HURDLE_H := 56.0           ## on-screen hurdle height
const HORSE_X := 70.0            ## horse's fixed x (left side)
const GROUND_FRAC := 0.80        ## track-lane baseline as a fraction of the SCALED bg height
                                 ## (0 = top of art, 1 = bottom; ~0.80 lands on the asphalt road band)
const FIRST_GAP := 1.3           ## seconds before the first hurdle
const MIN_GAP := 0.70            ## min seconds between hurdles (tightens as speed ramps)
const MAX_GAP := 1.5             ## max seconds between hurdles

## ── Hitbox tuning (THIS is the "collision box" — no physics nodes here) ───────
## Both sprites draw their art centred inside a larger node box (and the hurdle
## PNG has big transparent margins), so collision uses INSET boxes tighter than
## the node rects. Increase an inset to shrink that box (more forgiving); shrink
## it toward 0 for a tighter fit. All in on-screen px.
const HORSE_PAD_X := 16.0        ## trim off each side of the horse box (nose/tail air)
const HORSE_FOOT_PAD := 6.0      ## trim above the horse's feet (bottom of its box)
const HURDLE_PAD_X := 10.0       ## trim off each side of the hurdle box (transparent margin)
const HURDLE_TOP_PAD := 10.0     ## trim off the TOP of the hurdle box, so just-clearing counts as clear

var _breed := "thoroughbred"
var _blurb := ""

## Playfield (set once we know our size).
var _field: Control = null
var _bg_a: TextureRect = null
var _bg_b: TextureRect = null
var _horse: TextureRect = null
var _info_lbl: Label = null
var _jump_btn: Button = null

var _hurdle_tex: Texture2D = null
var _hurdles: Array = []         ## [{ node:TextureRect, passed:bool }]

var _bg_scroll := 0.0
var _bg_w := 0.0                 ## scaled width of each bg copy (for the scroll loop)
var _run_t := 0.0
var _ground_y := 0.0
var _horse_y := 0.0              ## vertical offset from ground (0 = on ground)
var _horse_vy := 0.0
var _on_ground := true

var _cleared := 0                ## hurdles successfully jumped (the run's result)
var _next_spawn := FIRST_GAP     ## seconds until the next hurdle spawns
var _spawn_t := 0.0
var _scroll_speed := SCROLL_SPEED  ## current (ramped) scroll speed

var _running := false
var _done := false


## Configure before adding to the tree.
func setup(breed: String, blurb: String) -> void:
	_breed = breed
	_blurb = blurb


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	## Dim backdrop (click = jump too, for a big hit target).
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
	style.border_color = Color(0.5, 0.85, 0.5)
	style.content_margin_left = 12; style.content_margin_right = 12
	style.content_margin_top = 12; style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "🚧 Hurdles"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.5, 0.85, 0.5))
	vbox.add_child(title)

	_info_lbl = Label.new()
	_info_lbl.text = "Tap JUMP to clear the hurdles!" if _blurb == "" else _blurb
	_info_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_lbl.add_theme_font_size_override("font_size", 11)
	_info_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	vbox.add_child(_info_lbl)

	## The scrolling playfield — a clipped box holding the two bg copies, the
	## horse, and spawned hurdles. Fixed aspect-ish size.
	_field = Control.new()
	_field.custom_minimum_size = Vector2(336, 180)
	_field.clip_contents = true
	_field.mouse_filter = Control.MOUSE_FILTER_STOP
	_field.gui_input.connect(_on_field_input)   ## tap anywhere on the field = jump
	vbox.add_child(_field)

	var bg_tex: Texture2D = null
	if ResourceLoader.exists(HorseRacing.TRAINING_BG_PATH):
		bg_tex = load(HorseRacing.TRAINING_BG_PATH) as Texture2D
	_bg_a = _make_bg(bg_tex)
	_bg_b = _make_bg(bg_tex)
	_field.add_child(_bg_a)
	_field.add_child(_bg_b)

	if ResourceLoader.exists(HorseRacing.HURDLE_PATH):
		_hurdle_tex = load(HorseRacing.HURDLE_PATH) as Texture2D

	_horse = TextureRect.new()
	_horse.custom_minimum_size = Vector2(HORSE_SIZE, HORSE_SIZE)
	_horse.size = Vector2(HORSE_SIZE, HORSE_SIZE)
	_horse.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_horse.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_horse.mouse_filter = Control.MOUSE_FILTER_IGNORE
	## The sheet sprites face LEFT; the horse runs left->right, so mirror it
	## horizontally. Pivot at the centre keeps the flip in place.
	_horse.pivot_offset = Vector2(HORSE_SIZE / 2.0, HORSE_SIZE / 2.0)
	_horse.scale = Vector2(-1, 1)
	_horse.texture = HorseRacing.breed_run_frame(_breed, 0)
	_field.add_child(_horse)

	_jump_btn = Button.new()
	_jump_btn.text = "JUMP"
	_jump_btn.custom_minimum_size = Vector2(0, 48)
	_jump_btn.add_theme_font_size_override("font_size", 18)
	_jump_btn.pressed.connect(_do_jump)
	vbox.add_child(_jump_btn)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(0, 30)
	cancel.add_theme_font_size_override("font_size", 11)
	cancel.pressed.connect(_cancel)
	vbox.add_child(cancel)

	## Lay out once the field has a real size, and again whenever it resizes
	## (the container's layout pass may not have run on the first frame).
	_field.resized.connect(_layout_field)
	await get_tree().process_frame
	_layout_field()
	_running = true
	set_process(true)


func _make_bg(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	## Scale by WIDTH + pin to the BOTTOM so the road band is always visible;
	## the clouds up top are what clips if the field is short. (See _layout_field.)
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## Size the two bg copies to the field + place the horse on the track lane.
## The background is scaled to the field WIDTH (preserving the source aspect) and
## anchored to the BOTTOM, so the road at the bottom of the art is always shown
## and only the sky/clouds up top get clipped when the field is shorter than the
## scaled image. The horse's ground line is placed on that road band.
func _layout_field() -> void:
	var w: float = _field.size.x
	var h: float = _field.size.y
	if w <= 0.0:
		w = _field.custom_minimum_size.x
	if h <= 0.0:
		h = _field.custom_minimum_size.y

	## "Cover" scale: the bg must be at least as wide AND tall as the field so
	## there's never empty space, then we BOTTOM-align so the road is always
	## shown (clouds up top clip). Each copy is `bg_w` wide for seamless scroll.
	var tex := _bg_a.texture if _bg_a != null else null
	var bg_w := w
	var bg_h := h
	if tex != null and tex.get_width() > 0 and tex.get_height() > 0:
		var ar := float(tex.get_width()) / float(tex.get_height())
		## Start fit-to-width; if that leaves it shorter than the field, fit-to-height.
		bg_w = w
		bg_h = w / ar
		if bg_h < h:
			bg_h = h
			bg_w = h * ar
	var top_y := h - bg_h   ## bottom-aligned (<= 0; clips the top)

	for bg in [_bg_a, _bg_b]:
		if bg != null:
			bg.size = Vector2(bg_w, bg_h)
			bg.position = Vector2(0, top_y)
	if _bg_b != null:
		_bg_b.position = Vector2(bg_w, top_y)
	_bg_w = bg_w

	## Put the horse's feet on the road. The source art's road band centre sits a
	## bit below the vertical middle of the image; GROUND_FRAC maps into the
	## SCALED bg (measured from its top), then offset by the bg's top position.
	_ground_y = top_y + bg_h * GROUND_FRAC
	if _horse != null:
		_horse.position = Vector2(HORSE_X, _ground_y - HORSE_SIZE)


func _process(delta: float) -> void:
	if not _running:
		return
	var w: float = _field.size.x
	if w <= 0.0:
		w = _field.custom_minimum_size.x
	var h: float = _field.size.y
	if h <= 0.0:
		h = _field.custom_minimum_size.y

	## Scroll the two background copies leftward at the current (ramped) speed,
	## looping by the bg copy WIDTH (cover-scaling can make it wider than field).
	var loop_w: float = _bg_w if _bg_w > 0.0 else w
	_bg_scroll += _scroll_speed * delta
	if _bg_scroll >= loop_w:
		_bg_scroll -= loop_w
	if _bg_a != null and _bg_b != null:
		_bg_a.position.x = -_bg_scroll
		_bg_b.position.x = -_bg_scroll + loop_w

	## Animate the running gait (only while grounded, for a nice "tuck" in air).
	if _on_ground:
		_run_t += delta * RUN_FPS
		if _horse != null:
			_horse.texture = HorseRacing.breed_run_frame(_breed, int(_run_t))

	## Jump physics.
	if not _on_ground:
		_horse_vy += GRAVITY * delta
		_horse_y += _horse_vy * delta
		if _horse_y >= 0.0:
			_horse_y = 0.0
			_horse_vy = 0.0
			_on_ground = true
	if _horse != null:
		_horse.position.y = (_ground_y - HORSE_SIZE) + _horse_y

	## Endless spawning: a new hurdle every _next_spawn seconds (gap tightens as
	## the speed ramps so it keeps getting harder until the player misses).
	_spawn_t += delta
	if _spawn_t >= _next_spawn:
		_spawn_t = 0.0
		## Gap scales inversely with the speed ramp, floored at MIN_GAP.
		var gap_scale: float = SCROLL_SPEED / max(1.0, _scroll_speed)
		_next_spawn = max(MIN_GAP, randf_range(MIN_GAP, MAX_GAP) * gap_scale)
		_spawn_hurdle(w)

	## Move hurdles; a clip ends the run immediately.
	_update_hurdles(delta)


func _spawn_hurdle(field_w: float) -> void:
	var node := TextureRect.new()
	node.texture = _hurdle_tex
	node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	node.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	node.custom_minimum_size = Vector2(HURDLE_W, HURDLE_H)
	node.size = Vector2(HURDLE_W, HURDLE_H)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.position = Vector2(field_w + HURDLE_W, _ground_y - HURDLE_H)
	_field.add_child(node)
	_hurdles.append({"node": node, "passed": false})


func _update_hurdles(delta: float) -> void:
	## Tight horse hitbox (inset from the node rect; feet = box bottom).
	var horse_left := HORSE_X + HORSE_PAD_X
	var horse_right := HORSE_X + HORSE_SIZE - HORSE_PAD_X
	var horse_top := (_ground_y - HORSE_SIZE) + _horse_y
	var horse_bottom := horse_top + HORSE_SIZE - HORSE_FOOT_PAD

	var still: Array = []
	for e in _hurdles:
		var node: TextureRect = e["node"]
		if not is_instance_valid(node):
			continue
		node.position.x -= _scroll_speed * delta
		var hx := node.position.x
		## Tight hurdle hitbox (inset from the node rect).
		var h_left := hx + HURDLE_PAD_X
		var h_right := hx + HURDLE_W - HURDLE_PAD_X
		var h_top := node.position.y + HURDLE_TOP_PAD

		## Collision window: horizontal overlap of the two tight boxes.
		var overlap_x := h_right > horse_left and h_left < horse_right
		if overlap_x and not e["passed"]:
			## Clipped only if the horse's feet dip BELOW the hurdle's top edge
			## while horizontally overlapping. A clean jump keeps feet above h_top.
			if horse_bottom > h_top:
				## MISS — the run ends here; score = hurdles cleared so far.
				_flash_info("Clipped! Cleared %d." % _cleared)
				_hurdles = still
				_finish()
				return
		## Once the hurdle's right edge passes the horse's left edge, it's behind
		## us — count it as cleared, speed up for the next one.
		if h_right < horse_left and not e["passed"]:
			e["passed"] = true
			_cleared += 1
			_scroll_speed = min(MAX_SCROLL_SPEED, SCROLL_SPEED + _cleared * SPEED_RAMP)
			_flash_info("Cleared %d!" % _cleared)

		## Keep until fully off-screen left.
		if h_right < -4.0:
			node.queue_free()
		else:
			still.append(e)
	_hurdles = still


func _on_field_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_do_jump()
	elif event is InputEventScreenTouch and event.pressed:
		_do_jump()


func _do_jump() -> void:
	if not _running or not _on_ground:
		return
	_on_ground = false
	_horse_vy = JUMP_VELOCITY


func _flash_info(t: String) -> void:
	if _info_lbl != null:
		_info_lbl.text = t


func _finish() -> void:
	if _done:
		return
	_done = true
	_running = false
	set_process(false)
	if _jump_btn != null:
		_jump_btn.disabled = true
	## Map clears -> the server's point scale: PERFECT_CLEARS clears == 90 points
	## (the value that yields the max +10.00 gain via round(score/10 + 1, 2)).
	## Fewer clears scale down linearly; more than PERFECT_CLEARS is still fine
	## (the server caps the gain). score = cleared / PERFECT_CLEARS * 90.
	var score := int(round(float(_cleared) / float(max(1, PERFECT_CLEARS)) * 90.0))
	_flash_info("Cleared %d hurdles!" % _cleared)
	await get_tree().create_timer(0.6).timeout
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
