extends BaseScreen
## Pasture screen — a view-only home for retired horses. Horses move here when
## they're retired (e.g. after winning a cup, or manually). Shows each horse's
## final stats and career record. Capacity 20; server-authoritative via the
## HorseRacing autoload. Built in code (no .tscn layout), overflow-safe.

const PASTURE_CAPACITY := 20

var _vbox: VBoxContainer = null
var _list: VBoxContainer = null
var _status: Label = null

## ── Animated pasture strip (retired horses walking) ──────────────
const STRIP_HEIGHT := 300.0       ## tall scenery band so most of the scene shows
const WALK_HORSE_H := 18.0        ## ~1/4 of the hurdle game's 72px horse
const WALK_SPEED := 22.0          ## px/sec amble
const WALK_BAND := 26.0           ## vertical range they roam in (bottom 20-30px)
const WALK_FPS := 6.0             ## gait frame cycle

var _strip: Control = null        ## the scenery band (bg + walking horses)
## Each walker: { node:TextureRect, breed, x, dir(+1/-1), frame_t, y }
var _walkers: Array = []


func get_screen_name() -> String:
	return "pasture"


func enter(_params: Dictionary = {}) -> void:
	_build_ui()
	if not HorseRacing.horses_changed.is_connected(_on_horses_changed):
		HorseRacing.horses_changed.connect(_on_horses_changed)
	_set_status("Loading pasture…")
	await HorseRacing.refresh()
	_rebuild()


func exit() -> void:
	set_process(false)
	if HorseRacing.horses_changed.is_connected(_on_horses_changed):
		HorseRacing.horses_changed.disconnect(_on_horses_changed)
	for child in get_children():
		child.queue_free()
	_vbox = null; _list = null; _status = null
	_strip = null
	_walkers.clear()


func _on_horses_changed() -> void:
	_rebuild()


func _process(delta: float) -> void:
	if _strip == null or _walkers.is_empty():
		return
	var w_px: float = _strip.size.x
	if w_px <= 0.0:
		return
	for w in _walkers:
		var node: TextureRect = w.get("node")
		if not is_instance_valid(node):
			continue
		var x: float = float(w["x"]) + float(w["dir"]) * WALK_SPEED * delta
		## Turn around at the edges (keep the whole sprite on-screen).
		if x <= 2.0:
			x = 2.0
			w["dir"] = 1
			node.scale = Vector2(-1, 1)   ## face right
		elif x >= w_px - WALK_HORSE_H - 2.0:
			x = w_px - WALK_HORSE_H - 2.0
			w["dir"] = -1
			node.scale = Vector2(1, 1)    ## face left
		w["x"] = x
		node.position.x = x
		## Gait cycle.
		w["frame_t"] = float(w["frame_t"]) + delta * WALK_FPS
		node.texture = HorseRacing.breed_run_frame(str(w["breed"]), int(w["frame_t"]))


# ── UI build ──────────────────────────────────────────────────────

func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.clip_contents = true
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.1, 0.08, 0.9)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10; style.content_margin_right = 10
	style.content_margin_top = 8; style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.scroll_deadzone = 16
	panel.add_child(scroll)

	_vbox = VBoxContainer.new()
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_theme_constant_override("separation", 8)
	_vbox.clip_contents = true
	_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.add_child(_vbox)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(120, 40)
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(func(): _get_navigator().navigate_back())
	top.add_child(back_btn)
	var title := Label.new()
	title.text = "🌾 Pasture"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.7, 0.9, 0.6))
	top.add_child(title)
	_vbox.add_child(top)

	var hint := Label.new()
	hint.text = "Retired horses live out their days here. Their legends remain."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.8, 0.85, 0.8))
	_vbox.add_child(hint)

	## Animated scenery strip: nature backdrop with the retired horses walking
	## back and forth along the bottom. Horses are added in _rebuild_walkers().
	_strip = Control.new()
	_strip.custom_minimum_size = Vector2(0, STRIP_HEIGHT)
	_strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_strip.clip_contents = true
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(HorseRacing.PASTURE_BG_PATH):
		var bg := TextureRect.new()
		bg.texture = load(HorseRacing.PASTURE_BG_PATH) as Texture2D
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		## STRETCH_SCALE fills the whole band with the whole image (shows the full
		## scene — sky, mountains, trees, ground — rather than cropping to the top).
		bg.stretch_mode = TextureRect.STRETCH_SCALE
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_strip.add_child(bg)
	_vbox.add_child(_strip)
	set_process(true)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", Color(0.85, 0.85, 0.8))
	_vbox.add_child(_status)

	_vbox.add_child(HSeparator.new())

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	_list.clip_contents = true
	_vbox.add_child(_list)


# ── List rendering ────────────────────────────────────────────────

func _rebuild() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		c.queue_free()

	var retired := HorseRacing.retired_horses()
	_set_status("Pasture: %d / %d" % [retired.size(), PASTURE_CAPACITY])
	_rebuild_walkers(retired)

	if retired.is_empty():
		var empty := Label.new()
		empty.text = "No retired horses yet."
		empty.add_theme_font_size_override("font_size", 11)
		empty.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		_list.add_child(empty)
		return
	for h in retired:
		_list.add_child(_make_horse_row(h))


# ── Walking horses (scenery strip) ────────────────────────────────

## (Re)creates one small walking sprite per retired horse in the scenery strip.
func _rebuild_walkers(retired: Array) -> void:
	if _strip == null:
		return
	## Clear old walkers (keep the background, which is the first child).
	for w in _walkers:
		if is_instance_valid(w.get("node")):
			w["node"].queue_free()
	_walkers.clear()

	var i := 0
	for h in retired:
		var breed := str(h.get("breed", "thoroughbred"))
		var tex := HorseRacing.breed_run_frame(breed, 0)
		if tex == null:
			continue
		var hv := TextureRect.new()
		hv.texture = tex
		hv.custom_minimum_size = Vector2(WALK_HORSE_H, WALK_HORSE_H)
		hv.size = Vector2(WALK_HORSE_H, WALK_HORSE_H)
		hv.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		hv.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hv.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hv.pivot_offset = Vector2(WALK_HORSE_H / 2.0, WALK_HORSE_H / 2.0)
		## Spread them out + stagger start direction/position so they don't clump.
		var dir := 1 if (i % 2 == 0) else -1
		## Sheet faces left; flip to face travel direction (dir +1 = rightward).
		hv.scale = Vector2(-dir, 1)
		var start_x := 20.0 + float(i) * 34.0
		var y := STRIP_HEIGHT - WALK_HORSE_H - 4.0 - float(i % 3) * 6.0
		hv.position = Vector2(start_x, y)
		_strip.add_child(hv)
		_walkers.append({
			"node": hv, "breed": breed, "x": start_x, "dir": dir,
			"frame_t": randf() * 3.0, "y": y,
		})
		i += 1


func _make_horse_row(h: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.16, 0.13, 0.9)
	style.set_corner_radius_all(6)
	style.content_margin_left = 8; style.content_margin_right = 8
	style.content_margin_top = 6; style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)

	var tex := HorseRacing.breed_texture(str(h.get("breed", "")))
	if tex != null:
		var frame := TextureRect.new()
		frame.texture = tex
		frame.custom_minimum_size = Vector2(56, 56)
		frame.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(frame)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = str(h.get("name", "?"))
	name_lbl.clip_text = true
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", Color(0.9, 1.0, 0.7))
	info.add_child(name_lbl)

	var breed_lbl := Label.new()
	breed_lbl.text = str(HorseRacing.breed_def(str(h.get("breed", ""))).get("name", h.get("breed", "")))
	breed_lbl.add_theme_font_size_override("font_size", 10)
	breed_lbl.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9))
	info.add_child(breed_lbl)

	var speed := float(h.get("speed", 0))
	var endurance := float(h.get("endurance", 0))
	var life_cap := float(h.get("life_cap", 0))
	var wins := int(h.get("wins", 0))
	var races := int(h.get("races_run", 0))
	var stat_total := speed + endurance + life_cap

	var stats_lbl := Label.new()
	stats_lbl.text = "⚡ %.2f   🏃 %.2f   🏆 %d wins / %d races" % [speed, endurance, wins, races]
	stats_lbl.add_theme_font_size_override("font_size", 10)
	stats_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	info.add_child(stats_lbl)

	## Hover (desktop) / long-press shows the full career record + stat totals.
	var win_rate := (float(wins) / float(races) * 100.0) if races > 0 else 0.0
	var career := "%s the %s\n──────────────\nSpeed:  %.2f\nEndurance:  %.2f\nMax Life:  %.2f\nStat Total:  %.2f\n\nRecord:  %d wins / %d races  (%.0f%%)" % [
		str(h.get("name", "?")),
		str(HorseRacing.breed_def(str(h.get("breed", ""))).get("name", h.get("breed", ""))),
		speed, endurance, life_cap, stat_total, wins, races, win_rate]
	panel.tooltip_text = career
	info.tooltip_text = career

	return panel


func _set_status(t: String) -> void:
	if _status != null:
		_status.text = t
