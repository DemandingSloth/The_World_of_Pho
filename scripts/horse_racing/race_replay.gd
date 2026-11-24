extends Control
class_name RaceReplay
## A modal race replay overlay. Animates each lane's horse across the track using
## the per-segment cumulative-distance samples stored by the server, then shows
## the finishing order. Self-contained; emits `closed` when dismissed.
##
## BACKGROUND: uses race_background.png — a purpose-drawn 5-lane racetrack that
## scrolls horizontally (two copies, looping) exactly like the Sprint mini-game,
## giving the feeling of continuous forward motion. Falls back to the training
## background if race_background.png hasn't been imported yet.
##
## DURATION: the playback is clamped to 30–45 seconds regardless of segment count,
## with the per-segment time derived from how many segments the race has (the
## server currently runs 6 segments per race).

signal closed()

const LANE_H := 34.0            ## px per lane row
const HORSE_H := 30.0           ## on-screen horse height
const TRACK_PAD := 60.0         ## left margin before start line; right finish gap
## Playback duration bounds (seconds). With 6 segments: 30s per lap.
const MIN_RACE_SECS := 30.0
const MAX_RACE_SECS := 45.0
## Background scroll speed (px/sec). Gives a feeling of forward motion.
const BG_SCROLL_SPEED := 220.0

var _replay: Dictionary = {}
var _placements: Array = []
var _title := "Race Replay"

var _track: Control = null
var _bg_a: TextureRect = null   ## two tiling copies of the race background
var _bg_b: TextureRect = null
var _bg_scroll := 0.0           ## running scroll offset
var _bg_w := 0.0                ## width of one background copy
var _info_lbl: Label = null
var _lane_nodes: Array = []     ## [{ horse:TextureRect, samples:Array, frame_t:float, breed:String }]
var _max_dist := 1.0
var _segments := 1

var _t := 0.0
var _dur := 1.0
var _seg_secs := MIN_RACE_SECS / 6.0  ## per-segment play time (recalculated in _ready)
var _playing := false
var _done := false


## Configure before adding to the tree.
func setup(title: String, replay: Dictionary, placements: Array) -> void:
	_title = title
	_replay = replay
	_placements = placements


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
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
	style.border_color = Color(0.9, 0.7, 0.4)
	style.content_margin_left = 10; style.content_margin_right = 10
	style.content_margin_top = 10; style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = _title
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.add_theme_color_override("font_color", Color(0.95, 0.85, 0.5))
	vbox.add_child(title_lbl)

	_info_lbl = Label.new()
	_info_lbl.text = "And they're off!"
	_info_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_lbl.add_theme_font_size_override("font_size", 11)
	_info_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	vbox.add_child(_info_lbl)

	var lanes: Array = _replay.get("lanes", [])
	_segments = max(1, int(_replay.get("segments", 6)))
	var lane_count: int = max(1, lanes.size())

	## Duration: 30–45s total, spread evenly across segments.
	## Fewer segments = more time per segment so the overall race stays long enough.
	_dur = clampf(float(_segments) * (MIN_RACE_SECS / 6.0), MIN_RACE_SECS, MAX_RACE_SECS)
	_seg_secs = _dur / float(_segments)

	## Track: clipped container — background + horses layer.
	_track = Control.new()
	_track.custom_minimum_size = Vector2(336, LANE_H * lane_count + 6)
	_track.clip_contents = true
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_track)

	## ── Scrolling background (two tiling copies, loops like the sprint) ──────
	## Prefer the dedicated race track background; fall back to the training bg.
	var bg_path := HorseRacing.RACE_BG_PATH if ResourceLoader.exists(HorseRacing.RACE_BG_PATH) \
	              else (HorseRacing.TRAINING_BG_PATH if ResourceLoader.exists(HorseRacing.TRAINING_BG_PATH) else "")
	if bg_path != "":
		var bg_tex := load(bg_path) as Texture2D
		if bg_tex != null:
			## Copy A starts at x=0, copy B starts at x=track_width (filled in _layout_bg).
			_bg_a = TextureRect.new()
			_bg_a.texture = bg_tex
			_bg_a.stretch_mode = TextureRect.STRETCH_SCALE
			_bg_a.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_bg_a.modulate = Color(1, 1, 1, 0.85)
			_track.add_child(_bg_a)

			_bg_b = TextureRect.new()
			_bg_b.texture = bg_tex
			_bg_b.stretch_mode = TextureRect.STRETCH_SCALE
			_bg_b.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_bg_b.modulate = Color(1, 1, 1, 0.85)
			_track.add_child(_bg_b)

	## ── Horses ────────────────────────────────────────────────────────────────
	_max_dist = 1.0
	for l in lanes:
		_max_dist = max(_max_dist, float(l.get("total", 0)))

	_lane_nodes = []
	for i in range(lanes.size()):
		var l: Dictionary = lanes[i]

		## Name tag at the left edge of the lane (stays fixed — shows who's in which lane).
		var tag := Label.new()
		tag.text = str(l.get("display_name", ""))
		tag.position = Vector2(2, i * LANE_H + 2)
		tag.add_theme_font_size_override("font_size", 8)
		tag.add_theme_color_override("font_color", Color(0.95, 0.95, 0.9, 0.9))
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_track.add_child(tag)

		var breed := str(l.get("breed", "thoroughbred"))
		var horse := TextureRect.new()
		horse.custom_minimum_size = Vector2(HORSE_H, HORSE_H)
		horse.size = Vector2(HORSE_H, HORSE_H)
		horse.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		horse.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		horse.mouse_filter = Control.MOUSE_FILTER_IGNORE
		## Sheet faces left; horses run left→right, so mirror.
		horse.pivot_offset = Vector2(HORSE_H / 2.0, HORSE_H / 2.0)
		horse.scale = Vector2(-1, 1)
		horse.texture = HorseRacing.breed_run_frame(breed, 0)
		horse.position = Vector2(TRACK_PAD, i * LANE_H + (LANE_H - HORSE_H) / 2.0)
		_track.add_child(horse)

		var samples: Array = l.get("samples", [])
		_lane_nodes.append({"horse": horse, "samples": samples, "frame_t": 0.0, "breed": breed})

	var skip := Button.new()
	skip.text = "Skip to Result"
	skip.custom_minimum_size = Vector2(0, 36)
	skip.add_theme_font_size_override("font_size", 12)
	skip.pressed.connect(_finish_playback)
	vbox.add_child(skip)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(0, 32)
	close_btn.add_theme_font_size_override("font_size", 11)
	close_btn.pressed.connect(_close)
	vbox.add_child(close_btn)

	_t = 0.0
	_bg_scroll = 0.0
	_playing = true
	set_process(true)


func _process(delta: float) -> void:
	if not _playing or _track == null:
		return

	## ── Scroll the background (loops seamlessly) ─────────────────────────────
	if _bg_a != null and _bg_b != null:
		var tw: float = _track.size.x
		if tw <= 0.0:
			tw = float(_track.custom_minimum_size.x)
		var th: float = _track.size.y
		if th <= 0.0:
			th = float(_track.custom_minimum_size.y)

		## Size each copy to the track dimensions on the first valid frame.
		if _bg_w <= 0.0 and tw > 0.0:
			_bg_a.size = Vector2(tw, th)
			_bg_b.size = Vector2(tw, th)
			_bg_a.position = Vector2(0, 0)
			_bg_b.position = Vector2(tw, 0)
			_bg_w = tw

		if _bg_w > 0.0:
			_bg_scroll += BG_SCROLL_SPEED * delta
			## Wrap: when copy A scrolls fully off the left, jump it to the right of B.
			var off_a := -_bg_scroll
			var off_b := _bg_w - _bg_scroll
			## Normalise so A is always the "left" copy.
			if off_a <= -_bg_w:
				_bg_scroll -= _bg_w
				off_a = -_bg_scroll
				off_b = _bg_w - _bg_scroll
			_bg_a.position.x = off_a
			_bg_b.position.x = off_b

	## ── Advance horses ───────────────────────────────────────────────────────
	_t += delta
	var tw2: float = _track.size.x
	if tw2 <= 0.0:
		tw2 = float(_track.custom_minimum_size.x)
	var usable: float = max(1.0, tw2 - TRACK_PAD - HORSE_H - 4.0)

	var prog: float = (_t / _dur) * float(_segments)
	for n in _lane_nodes:
		var dist := _sample_dist(n["samples"], prog)
		var x := TRACK_PAD + (dist / _max_dist) * usable
		n["horse"].position.x = x
		n["frame_t"] = float(n["frame_t"]) + delta * 10.0
		n["horse"].texture = HorseRacing.breed_run_frame(n["breed"], int(n["frame_t"]))

	if _t >= _dur:
		_finish_playback()


## Interpolated cumulative distance at a fractional segment index.
func _sample_dist(samples: Array, prog: float) -> float:
	if samples.is_empty():
		return 0.0
	if prog <= 0.0:
		return 0.0
	var n := samples.size()
	if prog >= float(n):
		return float(samples[n - 1])
	var i := int(floor(prog))
	var frac := prog - float(i)
	var lo := float(samples[i - 1]) if i >= 1 else 0.0
	var hi := float(samples[i]) if i < n else float(samples[n - 1])
	return lerp(lo, hi, frac)


func _finish_playback() -> void:
	if not _playing:
		return
	_playing = false
	set_process(false)
	## Snap every horse to its final position.
	var tw: float = _track.size.x
	if tw <= 0.0:
		tw = float(_track.custom_minimum_size.x)
	var usable: float = max(1.0, tw - TRACK_PAD - HORSE_H - 4.0)
	for n in _lane_nodes:
		var s: Array = n["samples"]
		var fin := float(s[s.size() - 1]) if not s.is_empty() else 0.0
		n["horse"].position.x = TRACK_PAD + (fin / _max_dist) * usable
	## Show the podium.
	var lines: Array = []
	for p in _placements:
		var place := int(p.get("finish_place", 0))
		if place >= 1 and place <= 3:
			var medals: Array = ["🥇", "🥈", "🥉"]
			var medal: String = str(medals[place - 1])
			var mine: String = "  (yours)" if bool(p.get("mine", false)) else ""
			lines.append("%s %s%s" % [medal, str(p.get("display_name", "?")), mine])
	if _info_lbl != null:
		_info_lbl.text = "Finish!\n" + "\n".join(lines) if not lines.is_empty() else "Finish!"


func _close() -> void:
	if _done:
		return
	_done = true
	closed.emit()
	queue_free()
