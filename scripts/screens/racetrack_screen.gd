extends BaseScreen
## Race Track screen (Horse Racing — Task 8). Two tabs:
##   RACES    — OPEN races (register one of your active horses) + BETTING races
##              (field locked, fixed odds; place a win bet in coins or tokens on
##              a race you have no horse in).
##   MY BETS  — your bets with settle/payout; coin winnings auto-credit; a
##              resolved race you bet on can be WATCHED (replay) within 12h.
## Built in code (BaseScreen subclass), overflow-safe. Server is authoritative
## via the HorseRacing autoload; this screen only reads it + fires its RPCs.

## Preloaded by path (avoids the global class_name cache in headless/fresh runs).
const RaceReplayScene := preload("res://scripts/horse_racing/race_replay.gd")

var _vbox: VBoxContainer = null
var _status: Label = null
var _list: VBoxContainer = null
var _tab := "races"
var _races_btn: Button = null
var _bets_btn: Button = null
var _market_btn: Button = null


func get_screen_name() -> String:
	return "racetrack"


func enter(_params: Dictionary = {}) -> void:
	_build_ui()
	if not HorseRacing.races_changed.is_connected(_on_data_changed):
		HorseRacing.races_changed.connect(_on_data_changed)
	if not HorseRacing.horses_changed.is_connected(_on_data_changed):
		HorseRacing.horses_changed.connect(_on_data_changed)
	_set_status("Loading races…")
	await HorseRacing.refresh()        ## need the player's active horses for registering
	await HorseRacing.refresh_races()
	## Recently-resolved races the player was in (results + replay for 12h).
	var rec := await HorseRacing.recent_results()
	_cached_results = rec.get("races", []) if rec.get("ok", false) else []
	## Credit any unclaimed cup coin prizes on arrival (once each).
	var cup := await HorseRacing.claim_cup_prizes()
	_cached_prizes = cup.get("prizes", []) if cup.get("ok", false) else []
	var credited := int(cup.get("credited", 0))
	_rebuild()
	if credited > 0:
		_set_status("🏆 Cup winnings credited: %s coins!" % PlayerData.format_number(credited))


func exit() -> void:
	if HorseRacing.races_changed.is_connected(_on_data_changed):
		HorseRacing.races_changed.disconnect(_on_data_changed)
	if HorseRacing.horses_changed.is_connected(_on_data_changed):
		HorseRacing.horses_changed.disconnect(_on_data_changed)
	for child in get_children():
		child.queue_free()
	_vbox = null; _status = null; _list = null
	_races_btn = null; _bets_btn = null; _market_btn = null


func _on_data_changed() -> void:
	_rebuild()


# ── UI shell ──────────────────────────────────────────────────────

func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.clip_contents = true
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.08, 0.08, 0.9)
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
	back_btn.custom_minimum_size = Vector2(110, 40)
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(func(): _get_navigator().navigate_back())
	top.add_child(back_btn)
	var title := Label.new()
	title.text = "🏁 Race Track"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.95, 0.8, 0.5))
	top.add_child(title)
	_vbox.add_child(top)

	## Tab row.
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	_races_btn = Button.new()
	_races_btn.text = "Races"
	_races_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_races_btn.add_theme_font_size_override("font_size", 13)
	_races_btn.pressed.connect(func(): _switch_tab("races"))
	tabs.add_child(_races_btn)
	_bets_btn = Button.new()
	_bets_btn.text = "My Bets"
	_bets_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bets_btn.add_theme_font_size_override("font_size", 13)
	_bets_btn.pressed.connect(func(): _switch_tab("bets"))
	tabs.add_child(_bets_btn)
	_market_btn = Button.new()
	_market_btn.text = "Horse Market"
	_market_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_market_btn.add_theme_font_size_override("font_size", 13)
	_market_btn.pressed.connect(func(): _switch_tab("market"))
	tabs.add_child(_market_btn)
	_vbox.add_child(tabs)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", Color(0.85, 0.85, 0.8))
	_vbox.add_child(_status)

	_vbox.add_child(HSeparator.new())

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	_list.clip_contents = true
	_vbox.add_child(_list)


func _switch_tab(tab: String) -> void:
	_tab = tab
	if tab == "bets":
		_set_status("Loading your bets…")
		var res := await HorseRacing.my_bets()
		_cached_bets = res.get("bets", []) if res.get("ok", false) else []
		var credited := int(res.get("credited", 0))
		## Also claim any unclaimed cup coin prizes (credited locally, once each).
		var cup := await HorseRacing.claim_cup_prizes()
		_cached_prizes = cup.get("prizes", []) if cup.get("ok", false) else []
		credited += int(cup.get("credited", 0))
		if credited > 0:
			_set_status("Winnings credited: %s coins!" % PlayerData.format_number(credited))
	elif tab == "market":
		_set_status("Loading horse market…")
		await HorseRacing.refresh_horse_market()
	else:
		await HorseRacing.refresh_races()
		var rec := await HorseRacing.recent_results()
		_cached_results = rec.get("races", []) if rec.get("ok", false) else []
	_rebuild()


func _highlight_tabs() -> void:
	if _races_btn != null:
		_races_btn.modulate = Color(1.0, 0.85, 0.3) if _tab == "races" else Color.WHITE
	if _bets_btn != null:
		_bets_btn.modulate = Color(1.0, 0.85, 0.3) if _tab == "bets" else Color.WHITE
	if _market_btn != null:
		_market_btn.modulate = Color(1.0, 0.85, 0.3) if _tab == "market" else Color.WHITE


# ── Rebuild ───────────────────────────────────────────────────────

var _cached_bets: Array = []
var _cached_prizes: Array = []
var _cached_results: Array = []   ## recently-resolved races the player was in


func _rebuild() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		c.queue_free()
	_highlight_tabs()
	if _tab == "bets":
		_rebuild_bets()
	elif _tab == "market":
		_rebuild_market()
	else:
		_rebuild_races()


func _rebuild_races() -> void:
	var opens := HorseRacing.open_races()
	var betting := HorseRacing.betting_races()
	_set_status("%d open · %d accepting bets" % [opens.size(), betting.size()])

	if betting.size() > 0:
		_list.add_child(_header("💰 Betting Now"))
		for r in betting:
			_list.add_child(_make_betting_row(r))
	if opens.size() > 0:
		_list.add_child(_header("🏇 Open — Enter a Horse"))
		for r in opens:
			_list.add_child(_make_open_row(r))
	if opens.is_empty() and betting.is_empty():
		_list.add_child(_muted("No races right now. Check back soon."))

	## Recently-finished races you were in — watch the replay (12h window).
	if not _cached_results.is_empty():
		_list.add_child(_header("🏁 Recent Results"))
		for rr in _cached_results:
			_list.add_child(_make_result_row(rr))


func _rebuild_bets() -> void:
	## Cup winnings first (if any).
	if not _cached_prizes.is_empty():
		_list.add_child(_header("🏆 Cup Winnings"))
		for p in _cached_prizes:
			_list.add_child(_make_prize_row(p))

	if _cached_bets.is_empty():
		if _cached_prizes.is_empty():
			_set_status("You haven't placed any bets yet.")
			_list.add_child(_muted("Bet on a race from the Races tab, or win a cup."))
		return
	_list.add_child(_header("🎟 Your Bets"))
	for b in _cached_bets:
		_list.add_child(_make_bet_row(b))


## A cup coin-prize row (already credited locally by claim_cup_prizes).
func _make_prize_row(p: Dictionary) -> Control:
	var parts := _race_panel()
	var panel: PanelContainer = parts[0]
	var v: VBoxContainer = parts[1]
	var place := int(p.get("finish_place", 0))
	var medal := "🥇" if place == 1 else ("🥈" if place == 2 else ("🥉" if place == 3 else "🏅"))
	var line := Label.new()
	line.text = "%s %s — %s place" % [medal, str(p.get("race_name", "Cup")), _ordinal(place)]
	line.add_theme_font_size_override("font_size", 12)
	line.add_theme_color_override("font_color", Color(0.95, 0.9, 0.7))
	v.add_child(line)
	var amt := Label.new()
	amt.text = "+%s coins" % PlayerData.format_number(int(p.get("prize_coins", 0)))
	amt.add_theme_font_size_override("font_size", 11)
	amt.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))
	v.add_child(amt)
	return panel


# ── Row builders ──────────────────────────────────────────────────

## An ordinal label for a finish place (1 -> "1st", 11 -> "11th", 23 -> "23rd").
func _ordinal(n: int) -> String:
	if n <= 0:
		return str(n)
	var suffix := "th"
	if n % 100 < 11 or n % 100 > 13:
		match n % 10:
			1: suffix = "st"
			2: suffix = "nd"
			3: suffix = "rd"
	return "%d%s" % [n, suffix]


func _header(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.9, 0.9, 0.6))
	return l


func _muted(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	return l


func _race_panel() -> Array:
	## Returns [panel, inner_vbox] with the shared card styling.
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.14, 0.12, 0.14, 0.9)
	style.set_corner_radius_all(6)
	style.content_margin_left = 8; style.content_margin_right = 8
	style.content_margin_top = 6; style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(v)
	return [panel, v]


## An OPEN race: shows field count + a Register button (your active horses).
## For cups, also shows the tier band + the top prize + breed reward.
func _make_open_row(r: Dictionary) -> Control:
	var parts := _race_panel()
	var panel: PanelContainer = parts[0]
	var v: VBoxContainer = parts[1]

	var is_cup := str(r.get("kind", "")) == "cup"
	var tier := int(r.get("tier", 0))

	var entries: Array = r.get("entries", [])
	var name_lbl := Label.new()
	var icon := ""
	if is_cup:
		var def := HorseRacing.cup_tier_def(tier)
		icon = "%s " % str(def.get("icon", "🏆"))
	name_lbl.text = "%s%s  (%d/%d entered)" % [
		icon, str(r.get("name", "Race")), entries.size(), int(r.get("field_size", 8))]
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", Color(0.95, 0.9, 0.7))
	v.add_child(name_lbl)

	## Countdown to registration close / field lock (when betting opens).
	var closes := str(r.get("closes_at", ""))
	if closes != "":
		var lock := Label.new()
		lock.text = "⏳ Entry closes in %s" % HorseRacing.format_countdown(HorseRacing.seconds_until(closes))
		lock.add_theme_font_size_override("font_size", 10)
		lock.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
		v.add_child(lock)

	if is_cup:
		## Entry band.
		var min_t := int(r.get("min_total", 0))
		var max_t := int(r.get("max_total", 0))
		var band := "Stat-total %d+" % min_t if max_t <= 0 else "Stat-total %d–%d" % [min_t, max_t]
		v.add_child(_muted("Entry: %s" % band))
		## Prizes.
		var first := int(r.get("first_prize", 0))
		var breed := str(r.get("prize_breed", ""))
		var bdef := HorseRacing.breed_def(breed)
		var breed_name := str(bdef.get("name", breed.capitalize())) if not bdef.is_empty() else breed
		var prize := Label.new()
		prize.text = "🥇 %s  🥈 %s  🥉 %s coins  +  winner's %s foal*" % [
			PlayerData.format_number(first), PlayerData.format_number(int(first / 2)),
			PlayerData.format_number(int(first / 4)), breed_name]
		prize.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		prize.add_theme_font_size_override("font_size", 10)
		prize.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
		v.add_child(prize)
		v.add_child(_muted("*foal only if your stable has room — otherwise just the coins."))

	var reg_btn := Button.new()
	reg_btn.text = "Enter a Horse"
	reg_btn.add_theme_font_size_override("font_size", 11)
	reg_btn.custom_minimum_size = Vector2(0, 34)
	reg_btn.pressed.connect(_on_register_pressed.bind(str(r.get("id", "")), is_cup, tier))
	v.add_child(reg_btn)
	return panel


## A BETTING race: lists lanes with odds + a Bet button (unless you're entered).
func _make_betting_row(r: Dictionary) -> Control:
	var parts := _race_panel()
	var panel: PanelContainer = parts[0]
	var v: VBoxContainer = parts[1]

	var name_lbl := Label.new()
	name_lbl.text = str(r.get("name", "Race"))
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", Color(0.95, 0.9, 0.7))
	v.add_child(name_lbl)

	## Countdown to post time — when betting closes and the race runs.
	var bet_closes := str(r.get("bet_closes_at", ""))
	if bet_closes != "":
		var race_in := Label.new()
		race_in.text = "⏱ Race in %s  (betting closes then)" % \
			HorseRacing.format_countdown(HorseRacing.seconds_until(bet_closes))
		race_in.add_theme_font_size_override("font_size", 10)
		race_in.add_theme_color_override("font_color", Color(1.0, 0.8, 0.5))
		v.add_child(race_in)

	var mine_in := bool(r.get("mine_in_race", false))
	if mine_in:
		v.add_child(_muted("Your horse is in this race — you can't bet on it. Watch it after it runs (My Bets / results)."))

	for e in r.get("entries", []):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var tex := HorseRacing.breed_texture(str(e.get("breed", "")))
		if tex != null:
			var frame := TextureRect.new()
			frame.texture = tex
			frame.custom_minimum_size = Vector2(32, 32)
			frame.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
			frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(frame)
		var nm := Label.new()
		## ⭐ marks a horse boosted by the horse-guild pairing bonus.
		var paired := bool(e.get("pairing_bonus", false))
		nm.text = ("⭐ " if paired else "") + str(e.get("display_name", "?"))
		nm.clip_text = true
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.add_theme_font_size_override("font_size", 11)
		## Default readable light color for EVERY entry (NPCs + other players);
		## yours is tinted green, paired is gold. Without this default the name
		## used the near-black theme color and was invisible on the dark card.
		if bool(e.get("mine", false)):
			nm.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
		elif paired:
			nm.add_theme_color_override("font_color", Color(0.95, 0.85, 0.4))
		else:
			nm.add_theme_color_override("font_color", Color(0.9, 0.9, 0.92))
		if paired:
			nm.tooltip_text = "Guild pairing bonus: +5% speed & endurance"
		row.add_child(nm)
		var odds_lbl := Label.new()
		odds_lbl.text = "%.2fx" % float(e.get("odds", 0))
		odds_lbl.add_theme_font_size_override("font_size", 11)
		odds_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
		row.add_child(odds_lbl)
		if not mine_in:
			var bet_btn := Button.new()
			bet_btn.text = "Bet"
			bet_btn.add_theme_font_size_override("font_size", 10)
			bet_btn.custom_minimum_size = Vector2(48, 28)
			bet_btn.pressed.connect(_on_bet_pressed.bind(
				str(r.get("id", "")), int(e.get("lane", 0)),
				str(e.get("display_name", "")), float(e.get("odds", 0))))
			row.add_child(bet_btn)
		v.add_child(row)
	return panel


## A single bet row in the My Bets tab.
func _make_bet_row(b: Dictionary) -> Control:
	var parts := _race_panel()
	var panel: PanelContainer = parts[0]
	var v: VBoxContainer = parts[1]

	var cur := "🪙" if str(b.get("currency", "")) == "coins" else "🎟"
	var line := Label.new()
	line.text = "%s %s on lane %d @ %.2fx" % [
		cur, PlayerData.format_number(int(b.get("stake", 0))),
		int(b.get("lane", 0)), float(b.get("odds", 0))]
	line.add_theme_font_size_override("font_size", 12)
	line.add_theme_color_override("font_color", Color(0.95, 0.9, 0.7))
	v.add_child(line)

	## Race + date so each bet row is distinguishable.
	var when := float(b.get("resolved_at", 0.0))
	var when_label := "Finished"
	if when <= 0.0:
		when = float(b.get("placed_at", 0.0))
		when_label = "Placed"
	var meta_parts: Array = []
	if str(b.get("race_name", "")) != "":
		meta_parts.append(str(b.get("race_name", "")))
	if when > 0.0:
		meta_parts.append("%s %s" % [when_label, _format_local_datetime(when)])
	if not meta_parts.is_empty():
		var meta := Label.new()
		meta.text = "  •  ".join(meta_parts)
		meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		meta.add_theme_font_size_override("font_size", 10)
		meta.add_theme_color_override("font_color", Color(0.7, 0.8, 0.95))
		v.add_child(meta)

	var status := Label.new()
	status.add_theme_font_size_override("font_size", 10)
	if not bool(b.get("settled", false)):
		status.text = "Pending — race status: %s" % str(b.get("race_status", "?"))
		status.add_theme_color_override("font_color", Color(0.8, 0.8, 0.6))
	elif bool(b.get("won", false)):
		status.text = "WON  +%s %s" % [
			PlayerData.format_number(int(b.get("payout", 0))),
			"coins" if str(b.get("currency", "")) == "coins" else "tokens"]
		status.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))
	else:
		status.text = "Lost"
		status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))
	v.add_child(status)

	## Watch button for a resolved race (replay may be gone after 12h; we check).
	if str(b.get("race_status", "")) == "resolved":
		var watch := Button.new()
		watch.text = "▶ Watch Replay"
		watch.add_theme_font_size_override("font_size", 10)
		watch.custom_minimum_size = Vector2(0, 30)
		watch.pressed.connect(_on_watch_pressed.bind(str(b.get("race_id", ""))))
		v.add_child(watch)
	return panel


## Formats a UTC unix timestamp in the player's local time, e.g. "Oct 16, 8:23 PM".
func _format_local_datetime(unix_utc: float) -> String:
	var bias_min := int(Time.get_time_zone_from_system().get("bias", 0))
	var d := Time.get_datetime_dict_from_unix_time(int(unix_utc) + bias_min * 60)
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var hour := int(d.get("hour", 0))
	var ampm := "AM" if hour < 12 else "PM"
	var h12 := hour % 12
	if h12 == 0:
		h12 = 12
	return "%s %d, %d:%02d %s" % [months[clampi(int(d.get("month", 1)) - 1, 0, 11)],
		int(d.get("day", 1)), h12, int(d.get("minute", 0)), ampm]


# ── Register flow ─────────────────────────────────────────────────

func _on_register_pressed(race_id: String, is_cup: bool = false, tier: int = 0) -> void:
	## Active horses not already in a race. For a cup, a horse is only shown as
	## eligible when its HIGHEST tier matches this cup's tier (server enforces it;
	## we grey out the rest so the player sees why).
	var choices: Array = []
	for h in HorseRacing.active_horses():
		var hid := str(h.get("id", ""))
		if not HorseRacing.horse_in_any_race(hid):
			choices.append(h)
	if choices.is_empty():
		_set_status("No eligible horses — all are retired, in a race, or you own none.")
		return

	var dialog := AcceptDialog.new()
	dialog.title = "Enter which horse?"
	dialog.ok_button_text = "Close"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.custom_minimum_size = Vector2(260, 0)
	for h in choices:
		var hid := str(h.get("id", ""))
		var total := HorseRacing.horse_stat_total(hid)
		var eligible := true
		var reason := ""
		if is_cup:
			var htier := HorseRacing.horse_cup_tier(hid)
			eligible = htier == tier
			if htier == 0:
				reason = "  (needs more training)"
			elif htier != tier:
				reason = "  (belongs in %s)" % str(HorseRacing.cup_tier_def(htier).get("name", "another cup"))
		var btn := Button.new()
		btn.text = "%s  (Σ%.2f ⚡%.2f 🏃%.2f ❤%.2f)%s" % [
			str(h.get("name", "?")), total, float(h.get("speed", 0)),
			float(h.get("endurance", 0)), float(h.get("life", 0)), reason]
		btn.custom_minimum_size = Vector2(0, 38)
		btn.add_theme_font_size_override("font_size", 11)
		btn.disabled = not eligible
		if eligible:
			btn.pressed.connect(func():
				dialog.queue_free()
				await _do_register(race_id, hid, str(h.get("name", ""))))
		box.add_child(btn)
	dialog.add_child(box)
	add_child(dialog)
	dialog.popup_centered(Vector2i(320, 0))
	dialog.close_requested.connect(dialog.queue_free)
	dialog.confirmed.connect(dialog.queue_free)


func _do_register(race_id: String, horse_id: String, horse_name: String) -> void:
	_set_status("Entering %s…" % horse_name)
	var res := await HorseRacing.register(race_id, horse_id)
	if res.get("ok", false):
		_set_status("%s entered the race (lane %d)!" % [horse_name, int(res.get("lane", 0))])
	else:
		_set_status(str(res.get("message", "Couldn't enter.")))


# ── Bet flow ──────────────────────────────────────────────────────

func _on_bet_pressed(race_id: String, lane: int, horse_name: String, odds: float) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Bet on %s" % horse_name
	dialog.ok_button_text = "Cancel"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.custom_minimum_size = Vector2(280, 0)

	var odds_lbl := Label.new()
	odds_lbl.text = "Odds: %.2fx  (payout = stake × odds)" % odds
	odds_lbl.add_theme_font_size_override("font_size", 11)
	odds_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	box.add_child(odds_lbl)

	## Currency toggle.
	var cur_row := HBoxContainer.new()
	cur_row.add_theme_constant_override("separation", 6)
	var cur_lbl := Label.new()
	cur_lbl.text = "Pay with:"
	cur_lbl.add_theme_font_size_override("font_size", 11)
	cur_row.add_child(cur_lbl)
	var cur_opt := OptionButton.new()
	cur_opt.add_item("🪙 Coins", 0)
	cur_opt.add_item("🎟 Tokens", 1)
	cur_opt.add_theme_font_size_override("font_size", 11)
	cur_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cur_row.add_child(cur_opt)
	box.add_child(cur_row)

	var stake_lbl := Label.new()
	stake_lbl.text = "Stake:"
	stake_lbl.add_theme_font_size_override("font_size", 11)
	box.add_child(stake_lbl)
	var stake_edit := LineEdit.new()
	stake_edit.placeholder_text = "amount"
	stake_edit.text = "1000"
	stake_edit.add_theme_font_size_override("font_size", 12)
	box.add_child(stake_edit)

	var place_btn := Button.new()
	place_btn.text = "Place Bet"
	place_btn.custom_minimum_size = Vector2(0, 40)
	place_btn.add_theme_font_size_override("font_size", 13)
	place_btn.pressed.connect(func():
		var stake := int(stake_edit.text.strip_edges())
		var currency := "coins" if cur_opt.selected == 0 else "tokens"
		dialog.queue_free()
		await _do_bet(race_id, lane, currency, stake, horse_name, odds))
	box.add_child(place_btn)

	dialog.add_child(box)
	add_child(dialog)
	dialog.popup_centered(Vector2i(320, 0))
	dialog.close_requested.connect(dialog.queue_free)
	dialog.confirmed.connect(dialog.queue_free)


func _do_bet(race_id: String, lane: int, currency: String, stake: int, horse_name: String, odds: float) -> void:
	_set_status("Placing bet…")
	var res := await HorseRacing.place_bet(race_id, lane, currency, stake)
	if res.get("ok", false):
		_set_status("Bet placed: %s on %s @ %.2fx." % [
			PlayerData.format_number(stake), horse_name, odds])
	else:
		_set_status(str(res.get("message", "Couldn't place bet.")))


# ── Watch replay ──────────────────────────────────────────────────

func _on_watch_pressed(race_id: String) -> void:
	_set_status("Loading replay…")
	var res := await HorseRacing.race_result(race_id)
	if not res.get("ok", false):
		_set_status(str(res.get("message", "Couldn't load the race.")))
		return
	if not bool(res.get("has_replay", false)):
		## Replay purged (>12h). Show the finishing order as text.
		var lines: Array = []
		for p in res.get("placements", []):
			lines.append("%d. %s%s" % [
				int(p.get("finish_place", 0)), str(p.get("display_name", "?")),
				"  (yours)" if bool(p.get("mine", false)) else ""])
		GameNotification.show_message("Race Result", "\n".join(lines) if not lines.is_empty() else "No result.")
		_set_status("Replay expired — showing final order.")
		return

	var replay: Dictionary = res.get("replay", {})
	var placements: Array = res.get("placements", [])
	var r := RaceReplayScene.new()
	r.setup("🏁 Race Replay", replay, placements)
	add_child(r)
	_set_status("")


func _set_status(t: String) -> void:
	if _status != null:
		_status.text = t


# ── Horse Market tab ──────────────────────────────────────────────

func _rebuild_market() -> void:
	var listings: Array = HorseRacing.horse_market
	_set_status("🎟 %s tokens · %d horse(s) for sale" % [
		PlayerData.format_number(HorseRacing.horse_market_balance), listings.size()])
	if listings.is_empty():
		_list.add_child(_muted("No horses for sale right now. List one from the Stable."))
		return
	for l in listings:
		_list.add_child(_make_market_row(l))


func _make_market_row(l: Dictionary) -> Control:
	var parts := _race_panel()
	var panel: PanelContainer = parts[0]
	var v: VBoxContainer = parts[1]

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	var tex := HorseRacing.breed_texture(str(l.get("breed", "")))
	if tex != null:
		var frame := TextureRect.new()
		frame.texture = tex
		frame.custom_minimum_size = Vector2(40, 40)
		frame.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		top.add_child(frame)

	var nm := Label.new()
	var breed_name := str(HorseRacing.breed_def(str(l.get("breed", ""))).get("name", l.get("breed", "")))
	nm.text = "%s  (%s)" % [str(l.get("name", "?")), breed_name]
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.add_theme_font_size_override("font_size", 12)
	nm.add_theme_color_override("font_color", Color(0.95, 0.9, 0.7))
	top.add_child(nm)
	v.add_child(top)

	var stats := Label.new()
	stats.text = "⚡%.2f  🏃%.2f  ❤%.2f/%.2f  🏆%d/%d  —  by %s" % [
		float(l.get("speed", 0)), float(l.get("endurance", 0)),
		float(l.get("life", 0)), float(l.get("life_cap", 0)),
		int(l.get("wins", 0)), int(l.get("races_run", 0)), str(l.get("seller_name", "?"))]
	stats.add_theme_font_size_override("font_size", 10)
	stats.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	v.add_child(stats)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var price := Label.new()
	price.text = "🎟 %s" % PlayerData.format_number(int(l.get("price", 0)))
	price.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	price.add_theme_font_size_override("font_size", 12)
	price.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	row.add_child(price)

	if bool(l.get("mine", false)):
		var unlist := Button.new()
		unlist.text = "Unlist"
		unlist.add_theme_font_size_override("font_size", 10)
		unlist.custom_minimum_size = Vector2(80, 30)
		unlist.pressed.connect(_on_unlist_pressed.bind(str(l.get("listing_id", ""))))
		row.add_child(unlist)
	else:
		var buy := Button.new()
		buy.text = "Buy"
		buy.add_theme_font_size_override("font_size", 11)
		buy.custom_minimum_size = Vector2(80, 30)
		buy.disabled = HorseRacing.horse_market_balance < int(l.get("price", 0))
		buy.pressed.connect(_on_buy_market_pressed.bind(
			str(l.get("listing_id", "")), str(l.get("name", "")), int(l.get("price", 0))))
		row.add_child(buy)
	v.add_child(row)
	return panel


func _on_unlist_pressed(listing_id: String) -> void:
	_set_status("Unlisting…")
	var res := await HorseRacing.cancel_horse_listing(listing_id)
	if res.get("ok", false):
		_set_status("Horse unlisted.")
	else:
		_set_status(str(res.get("message", "Couldn't unlist.")))
	_rebuild()


func _on_buy_market_pressed(listing_id: String, horse_name: String, price: int) -> void:
	## Confirm, then buy.
	var dialog := AcceptDialog.new()
	dialog.title = "Buy %s?" % horse_name
	dialog.dialog_text = "Buy %s for 🎟 %s tokens?" % [horse_name, PlayerData.format_number(price)]
	dialog.ok_button_text = "Buy"
	dialog.add_cancel_button("Cancel")
	add_child(dialog)
	dialog.popup_centered(Vector2i(320, 0))
	dialog.confirmed.connect(func():
		dialog.queue_free()
		await _do_buy_market(listing_id, horse_name))
	dialog.canceled.connect(dialog.queue_free)
	dialog.close_requested.connect(dialog.queue_free)


func _do_buy_market(listing_id: String, horse_name: String) -> void:
	_set_status("Buying %s…" % horse_name)
	var res := await HorseRacing.buy_horse_listing(listing_id)
	if res.get("ok", false):
		if bool(res.get("in_stable", true)):
			_set_status("Bought %s! It's in your stable." % horse_name)
		else:
			_set_status("Bought %s, but your stable didn't refresh. Reopen the Stable to see it." % horse_name)
	else:
		_set_status(str(res.get("message", "Couldn't buy.")))
	_rebuild()


# ── Recent-results row (Races tab) ────────────────────────────────

## A resolved race the player was in: shows the race name + winner, a tag for
## how they were involved, and a Watch Replay button (12h window). Falls back to
## a text result once the replay is purged (handled by _on_watch_pressed).
func _make_result_row(rr: Dictionary) -> Control:
	var parts := _race_panel()
	var panel: PanelContainer = parts[0]
	var v: VBoxContainer = parts[1]

	var is_cup := str(rr.get("kind", "")) == "cup"
	var name_lbl := Label.new()
	name_lbl.text = "%s%s" % ["🏆 " if is_cup else "", str(rr.get("name", "Race"))]
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", Color(0.95, 0.9, 0.7))
	v.add_child(name_lbl)

	## Winner line (🥇) + a note on how you were involved.
	var winner: Dictionary = rr.get("winner", {})
	var wname := str(winner.get("display_name", "?"))
	var wtag := "  (yours!)" if bool(winner.get("mine", false)) else ""
	var win_lbl := Label.new()
	win_lbl.text = "🥇 %s%s" % [wname, wtag]
	win_lbl.add_theme_font_size_override("font_size", 11)
	win_lbl.add_theme_color_override("font_color",
		Color(0.4, 1.0, 0.6) if bool(winner.get("mine", false)) else Color(0.9, 0.9, 0.92))
	v.add_child(win_lbl)

	var involved: Array = []
	if bool(rr.get("mine_entered", false)):
		involved.append("you raced")
	if bool(rr.get("mine_bet", false)):
		involved.append("you bet")
	if not involved.is_empty():
		v.add_child(_muted(" · ".join(involved)))

	var watch := Button.new()
	if bool(rr.get("has_replay", false)):
		watch.text = "▶ Watch Replay"
	else:
		watch.text = "View Result"   ## replay purged (>12h) — show final order
	watch.add_theme_font_size_override("font_size", 11)
	watch.custom_minimum_size = Vector2(0, 32)
	watch.pressed.connect(_on_watch_pressed.bind(str(rr.get("id", ""))))
	v.add_child(watch)
	return panel
