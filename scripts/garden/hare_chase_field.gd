class_name HareChaseField
extends Control
## Play field for the hare chase mini game.
##
## The player drags a straight line from one edge to another (outer wall or an
## earlier cut). On release the open area is split in two: the half WITHOUT the
## crate is closed off. If the hare is standing in the closed half, it is
## trapped and the game is lost. The hare is only checked when a cut is
## completed (it ignores the stroke while it is being drawn), so it can be
## caught on the wrong side. The game is won when the hare reaches the crate
## through its LEFT or RIGHT side (top/bottom contact just bounces it away).

signal caught()          ## Hare entered the crate (after its caught animation).
signal hare_trapped()    ## Hare was cut off (after its death animation).
signal hint(text: String)

const SHEET_DIR := "res://Assets/garden mini game/"
const CAGE_PATH := "res://Assets/garden mini game/cage.png"

## Sprite sheets are 32x32 frames; rows are front, back, left, right.
const FRAME := 32
const ROW_FRONT := 0
const ROW_BACK := 1
const ROW_LEFT := 2
const ROW_RIGHT := 3

const HARE_SCALE := 2.0
const HARE_RADIUS := 12.0
const CAGE_HEIGHT := 40.0
const CAGE_ASPECT := 526.0 / 488.0
const HOP_SPEED := 150.0
const SNAP_DIST := 30.0
const MIN_CUT_LEN := 48.0
const FIELD_PADDING := 2.0
const SIDE_ENTRY_SLACK := 4.0   ## Extra vertical forgiveness for a side entry.

const ANIMS := {
	"idle":  {"file": "Hare_Idle_with_shadow.png",  "frames": 4, "fps": 6.0,  "loop": true},
	"run":   {"file": "Hare_Run_with_shadow.png",   "frames": 6, "fps": 12.0, "loop": true},
	"hurt":  {"file": "Hare_Hurt_with_shadow.png",  "frames": 4, "fps": 8.0,  "loop": false},
	"death": {"file": "Hare_Death_with_shadow.png", "frames": 6, "fps": 7.0,  "loop": false},
}

enum State { WAITING, PLAYING, DYING, CAUGHT, DONE }

var _state: int = State.WAITING
var paused: bool = false

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _textures: Dictionary = {}
var _cage_tex: Texture2D = null

var _open_poly: PackedVector2Array = PackedVector2Array()
var _cuts: Array = []            ## Array of [Vector2, Vector2]

var _hare_pos: Vector2 = Vector2.ZERO
var _hare_dir: Vector2 = Vector2.RIGHT
var _facing_row: int = ROW_FRONT
var _anim: String = "idle"
var _anim_time: float = 0.0
var _hopping: bool = false
var _hop_left: float = 0.0
var _pause_left: float = 0.5
var _end_timer: float = 0.0

var _cage_rect: Rect2 = Rect2()

var _stroke_active: bool = false
var _stroke_a: Vector2 = Vector2.ZERO
var _stroke_b: Vector2 = Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	for key in ANIMS:
		var path: String = SHEET_DIR + str(ANIMS[key]["file"])
		_textures[key] = load(path)
	_cage_tex = load(CAGE_PATH) as Texture2D
	set_process(true)


## True once start_game() has been called and the game is not finished.
func is_active() -> bool:
	return _state == State.PLAYING


func is_finished() -> bool:
	return _state == State.DONE


## Sets up a fresh round using the field's current size.
func start_game() -> void:
	_rng.randomize()
	var field_size: Vector2 = size
	if field_size.x < 120.0 or field_size.y < 120.0:
		field_size = Vector2(320.0, 420.0)
	var rect: Rect2 = Rect2(Vector2.ZERO, field_size).grow(-FIELD_PADDING)
	_open_poly = HareChaseGeometry.rect_to_polygon(rect)
	_cuts.clear()
	_stroke_active = false

	_hare_pos = HareChaseGeometry.random_point_inside(_open_poly, HARE_RADIUS + 20.0, _rng)

	var cage_size: Vector2 = Vector2(CAGE_HEIGHT * CAGE_ASPECT, CAGE_HEIGHT)
	var cage_margin: float = cage_size.length() * 0.5 + HARE_RADIUS + 6.0
	var cage_center: Vector2 = _hare_pos
	for i in range(40):
		cage_center = HareChaseGeometry.random_point_inside(_open_poly, cage_margin, _rng)
		if cage_center.distance_to(_hare_pos) >= 140.0:
			break
	_cage_rect = Rect2(cage_center - cage_size * 0.5, cage_size)

	_hopping = false
	_pause_left = 0.6
	_facing_row = ROW_FRONT
	_set_anim("idle")
	_state = State.PLAYING
	queue_redraw()


## ── Per-frame update ────────────────────────────────────────────

func _process(delta: float) -> void:
	if paused or _state == State.WAITING or _state == State.DONE:
		return
	_anim_time += delta
	match _state:
		State.PLAYING:
			_update_hare(delta)
		State.DYING:
			_end_timer -= delta
			if _end_timer <= 0.0:
				_state = State.DONE
				hare_trapped.emit()
		State.CAUGHT:
			_end_timer -= delta
			if _end_timer <= 0.0:
				_state = State.DONE
				caught.emit()
	queue_redraw()


func _update_hare(delta: float) -> void:
	if _hopping:
		_hop_left -= delta
		var next_pos: Vector2 = _hare_pos + _hare_dir * HOP_SPEED * delta
		var contact: int = _cage_contact(next_pos)
		if contact == 1:
			_begin_caught()
			return
		elif contact == 2:
			_pick_direction()
		elif HareChaseGeometry.contains_with_margin(_open_poly, next_pos, HARE_RADIUS * 0.8):
			_hare_pos = next_pos
		else:
			_pick_direction()
		if _hop_left <= 0.0:
			_hopping = false
			_pause_left = _rng.randf_range(0.25, 0.8)
			_set_anim("idle")
	else:
		_pause_left -= delta
		if _pause_left <= 0.0:
			_pick_direction()
			_hopping = true
			_hop_left = _rng.randf_range(0.45, 1.0)
			_set_anim("run")


## Chooses a new hop direction: half the time fully random, otherwise toward a
## random spot in the open area (keeps the hare from hugging the walls).
func _pick_direction() -> void:
	var dir: Vector2 = Vector2.RIGHT.rotated(_rng.randf_range(0.0, TAU))
	if _rng.randf() < 0.5:
		var target: Vector2 = HareChaseGeometry.random_point_inside(
			_open_poly, HARE_RADIUS + 8.0, _rng)
		var to_target: Vector2 = target - _hare_pos
		if to_target.length() > 1.0:
			dir = to_target.normalized().rotated(_rng.randf_range(-0.5, 0.5))
	_hare_dir = dir
	if absf(dir.x) >= absf(dir.y):
		_facing_row = ROW_RIGHT if dir.x > 0.0 else ROW_LEFT
	else:
		_facing_row = ROW_FRONT if dir.y > 0.0 else ROW_BACK


## 0 = no contact, 1 = side entry (win), 2 = top/bottom contact (blocked).
func _cage_contact(pos: Vector2) -> int:
	var closest: Vector2 = Vector2(
		clampf(pos.x, _cage_rect.position.x, _cage_rect.end.x),
		clampf(pos.y, _cage_rect.position.y, _cage_rect.end.y))
	if pos.distance_to(closest) > HARE_RADIUS:
		return 0
	if pos.y >= _cage_rect.position.y - SIDE_ENTRY_SLACK \
			and pos.y <= _cage_rect.end.y + SIDE_ENTRY_SLACK:
		return 1
	return 2


func _begin_caught() -> void:
	_hare_pos = _cage_rect.get_center()
	_hopping = false
	_state = State.CAUGHT
	_set_anim("hurt")
	_end_timer = 0.9


func _begin_trapped() -> void:
	_hopping = false
	_stroke_active = false
	_state = State.DYING
	_set_anim("death")
	_end_timer = 1.5


func _set_anim(name: String) -> void:
	if _anim != name:
		_anim = name
		_anim_time = 0.0


## ── Input (mouse + touch) ───────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if _state != State.PLAYING or paused:
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_stroke_begin(mb.position)
		else:
			_stroke_end(mb.position)
	elif event is InputEventMouseMotion:
		if _stroke_active:
			_stroke_b = (event as InputEventMouseMotion).position
	elif not Input.is_emulating_mouse_from_touch():
		if event is InputEventScreenTouch:
			var st: InputEventScreenTouch = event as InputEventScreenTouch
			if st.pressed:
				_stroke_begin(st.position)
			else:
				_stroke_end(st.position)
		elif event is InputEventScreenDrag:
			if _stroke_active:
				_stroke_b = (event as InputEventScreenDrag).position


func _stroke_begin(pos: Vector2) -> void:
	_stroke_active = true
	_stroke_a = pos
	_stroke_b = pos


func _stroke_end(pos: Vector2) -> void:
	if not _stroke_active:
		return
	_stroke_active = false
	_stroke_b = pos
	_apply_cut(_stroke_a, _stroke_b)


## Evaluates a completed stroke and either rejects it (with a hint), closes off
## the far side, or traps the hare.
func _apply_cut(raw_a: Vector2, raw_b: Vector2) -> void:
	var res: Dictionary = HareChaseGeometry.try_cut(
		_open_poly, raw_a, raw_b, SNAP_DIST, MIN_CUT_LEN)
	if not bool(res["ok"]):
		match str(res["reason"]):
			"edge":
				hint.emit("Cuts must go from one edge to another.")
			"short":
				hint.emit("That cut is too short.")
			_:
				hint.emit("That cut doesn't split the area.")
		return

	var a: Vector2 = res["a"]
	var b: Vector2 = res["b"]
	if HareChaseGeometry.segment_hits_rect(a, b, _cage_rect.grow(4.0)):
		hint.emit("You can't cut through the crate.")
		return

	var polys: Array = res["polys"]
	var poly1: PackedVector2Array = polys[0]
	var poly2: PackedVector2Array = polys[1]
	var cage_center: Vector2 = _cage_rect.get_center()
	var keep: PackedVector2Array = poly1
	if not HareChaseGeometry.contains(poly1, cage_center, 0.5):
		keep = poly2

	## The wall is placed: the hare is checked now (and only now).
	if not HareChaseGeometry.contains(keep, _hare_pos, 1.0):
		_cuts.append([a, b])
		_open_poly = keep
		_begin_trapped()
		return

	_cuts.append([a, b])
	_open_poly = keep
	_nudge_hare_inside()
	hint.emit("")


## If the new wall is right next to the hare, push it just inside.
func _nudge_hare_inside() -> void:
	var margin: float = HARE_RADIUS * 0.8
	var d: float = HareChaseGeometry.boundary_distance(_open_poly, _hare_pos)
	if d < margin:
		var toward: Vector2 = HareChaseGeometry.centroid(_open_poly) - _hare_pos
		if toward.length() > 0.001:
			_hare_pos += toward.normalized() * (margin - d + 1.0)


## ── Drawing ─────────────────────────────────────────────────────

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.09, 0.07, 0.9))
	if _state == State.WAITING or _open_poly.size() < 3:
		return

	draw_colored_polygon(_open_poly, Color(0.30, 0.58, 0.27, 0.95))

	## Outline of the open area.
	var outline: PackedVector2Array = _open_poly.duplicate()
	outline.append(_open_poly[0])
	draw_polyline(outline, Color(0.95, 0.88, 0.55), 3.0)

	## Placed cuts (fences).
	for c in _cuts:
		draw_line(c[0], c[1], Color(0.62, 0.40, 0.18), 5.0)

	## Crate.
	if _cage_tex != null:
		draw_texture_rect(_cage_tex, _cage_rect, false)

	## Hare.
	_draw_hare()

	## Stroke preview.
	if _stroke_active:
		var res: Dictionary = HareChaseGeometry.try_cut(
			_open_poly, _stroke_a, _stroke_b, SNAP_DIST, MIN_CUT_LEN)
		var valid: bool = bool(res["ok"])
		if valid:
			valid = not HareChaseGeometry.segment_hits_rect(
				res["a"], res["b"], _cage_rect.grow(4.0))
		var col: Color = Color(0.4, 1.0, 0.4, 0.95) if valid else Color(1.0, 0.4, 0.4, 0.9)
		draw_line(_stroke_a, _stroke_b, col, 3.0)


func _draw_hare() -> void:
	var info: Dictionary = ANIMS[_anim]
	var frames: int = int(info["frames"])
	var fps: float = float(info["fps"])
	var frame: int = int(_anim_time * fps)
	if bool(info["loop"]):
		frame = frame % frames
	else:
		frame = mini(frame, frames - 1)
	var tex: Texture2D = _textures.get(_anim) as Texture2D
	if tex == null:
		return
	var src: Rect2 = Rect2(float(frame * FRAME), float(_facing_row * FRAME),
		float(FRAME), float(FRAME))
	var dest_size: Vector2 = Vector2(FRAME, FRAME) * HARE_SCALE
	var dest: Rect2 = Rect2(_hare_pos - dest_size * 0.5, dest_size)
	draw_texture_rect_region(tex, dest, src)
