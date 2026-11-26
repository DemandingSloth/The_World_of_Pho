extends BaseScreen
## Mission Board screen — shows 3 active missions (easy, medium, hard).
## Players track progress and claim chest + coin rewards on completion.

var _slot_containers: Array = []  ## Array of 3 Control nodes, one per slot

## ── Online Special Missions tab ─────────────────────────────────
var _tab_bar: HBoxContainer = null
var _subtitle: Label = null                    ## Tab-dependent helper text
var _offline_container: VBoxContainer = null   ## Holds the 3 offline mission slots
var _online_container: VBoxContainer = null     ## Holds the server missions list
var _current_tab: String = "offline"


func get_screen_name() -> String:
	return "mission_board"


func show_top_bar() -> bool:
	return true


func enter(params: Dictionary = {}) -> void:
	_build_ui()
	MissionBoard.mission_updated.connect(_on_mission_updated)
	MissionBoard.mission_completed.connect(_on_mission_completed)


func exit() -> void:
	if MissionBoard.mission_updated.is_connected(_on_mission_updated):
		MissionBoard.mission_updated.disconnect(_on_mission_updated)
	if MissionBoard.mission_completed.is_connected(_on_mission_completed):
		MissionBoard.mission_completed.disconnect(_on_mission_completed)
	for child in get_children():
		child.queue_free()
	_slot_containers.clear()


## ── Build UI ───────────────────────────────────────────────────


func _build_ui() -> void:
	## Dark semi-transparent backdrop over the game background, matching the
	## Marketplace/Inventory, so text stays readable on the bright scenery.
	var bg := PanelContainer.new()
	bg.name = "BgPanel"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE  ## let taps reach the content
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0.08, 0.08, 0.12, 0.88)
	bg_style.set_corner_radius_all(6)
	bg.add_theme_stylebox_override("panel", bg_style)
	add_child(bg)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.clip_contents = true
	add_child(scroll)

	var vbox := VBoxContainer.new()
	## Fill width, but let height grow with content so the ScrollContainer scrolls.
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(vbox)

	## Back button
	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(200, 48)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(_on_back_pressed)
	vbox.add_child(back_btn)

	## Title
	var title := Label.new()
	title.text = "Mission Board"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	vbox.add_child(title)

	_subtitle = Label.new()
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_subtitle.add_theme_font_size_override("font_size", 11)
	_subtitle.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	vbox.add_child(_subtitle)

	## ── Tab bar: Offline (default) | Online Special ──────────────
	_tab_bar = HBoxContainer.new()
	_tab_bar.add_theme_constant_override("separation", 4)
	_tab_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var tab_offline := Button.new()
	tab_offline.name = "TabOffline"
	tab_offline.text = "Missions"
	tab_offline.custom_minimum_size = Vector2(140, 44)
	tab_offline.add_theme_font_size_override("font_size", 13)
	tab_offline.pressed.connect(_on_tab.bind("offline"))
	_tab_bar.add_child(tab_offline)
	var tab_online := Button.new()
	tab_online.name = "TabOnline"
	tab_online.text = "Online Special"
	tab_online.custom_minimum_size = Vector2(140, 44)
	tab_online.add_theme_font_size_override("font_size", 13)
	tab_online.pressed.connect(_on_tab.bind("online"))
	_tab_bar.add_child(tab_online)
	vbox.add_child(_tab_bar)

	## Offline missions live in their own container (unchanged behavior).
	_offline_container = VBoxContainer.new()
	_offline_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_offline_container.add_theme_constant_override("separation", 14)
	vbox.add_child(_offline_container)

	## Online missions container (populated on demand when the tab is shown).
	_online_container = VBoxContainer.new()
	_online_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_online_container.add_theme_constant_override("separation", 10)
	_online_container.visible = false
	vbox.add_child(_online_container)

	_slot_containers.clear()
	for i in range(3):
		var panel := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.1, 0.1, 0.15, 0.9)
		style.corner_radius_top_left = 6
		style.corner_radius_top_right = 6
		style.corner_radius_bottom_left = 6
		style.corner_radius_bottom_right = 6
		style.content_margin_left = 10
		style.content_margin_right = 10
		style.content_margin_top = 8
		style.content_margin_bottom = 8
		panel.add_theme_stylebox_override("panel", style)
		panel.name = "MissionSlot%d" % i
		_offline_container.add_child(panel)
		_slot_containers.append(panel)
		_refresh_slot(i)

	## Bottom spacer so the last slot's Reroll button clears the screen edge
	## (and the top bar) on smaller mobile viewports.
	var bottom_spacer := Control.new()
	bottom_spacer.custom_minimum_size = Vector2(0, 80)
	vbox.add_child(bottom_spacer)

	## Start on the offline tab (unchanged default behavior).
	_show_tab("offline")


## ── Tabs: Offline | Online Special ──────────────────────────────

func _on_tab(tab_name: String) -> void:
	_show_tab(tab_name)


func _show_tab(tab_name: String) -> void:
	_current_tab = tab_name
	if _offline_container:
		_offline_container.visible = (tab_name == "offline")
	if _online_container:
		_online_container.visible = (tab_name == "online")
	## Highlight the active tab.
	if _tab_bar:
		var t_off := _tab_bar.get_node_or_null("TabOffline")
		var t_on := _tab_bar.get_node_or_null("TabOnline")
		if t_off:
			t_off.modulate = Color(1.0, 0.85, 0.2) if tab_name == "offline" else Color.WHITE
		if t_on:
			t_on.modulate = Color(1.0, 0.85, 0.2) if tab_name == "online" else Color.WHITE
	## Subtitle text is tab-dependent: reroll wording only applies to offline.
	if _subtitle:
		if tab_name == "online":
			_subtitle.text = "Complete online missions to earn marketplace tokens.\nUntouched missions refresh after 24h; once you make progress you get 48h to finish. Requires an internet connection."
		else:
			_subtitle.text = "Complete missions for coins and chests.\nMissions refresh 48hrs after being issued. Reroll to swap one early."
	if tab_name == "online":
		_load_online_missions()


## Fetches and renders the online special missions (read-only). Shows a clear
## message when offline or when there are none.
func _load_online_missions() -> void:
	if _online_container == null:
		return
	for child in _online_container.get_children():
		child.queue_free()

	## Not registered / no backend configured -> explain, don't error out.
	if get_node_or_null("/root/MarketplaceAccount") == null \
			or get_node_or_null("/root/SupabaseClient") == null \
			or not SupabaseClient.is_configured():
		_add_online_notice("Online missions require an internet connection.\nMarketplace is not available.")
		return

	_add_online_notice("Loading online missions…")

	var res: Dictionary = await MarketplaceAccount.get_mission_status()
	## The container may have been freed if the player left the screen.
	if _online_container == null or not is_instance_valid(_online_container):
		return
	for child in _online_container.get_children():
		child.queue_free()

	if not res.get("ok", false):
		_add_online_notice("Couldn't reach the mission server.\nCheck your connection and try again.")
		return

	var missions: Array = res.get("missions", [])
	if missions.is_empty():
		_add_online_notice("No online missions available right now.\nCheck back soon!")
		return

	## Refresh countdown: each mission slot has its own 24h window and completed
	## ones are replaced instantly, so show the soonest upcoming rollover.
	_add_online_refresh_header(missions)

	for m in missions:
		if m is Dictionary:
			_add_online_mission_row(m)


## Adds a single header line showing how long until this set of missions
## rotates, derived from the soonest expires_at across the set.
func _add_online_refresh_header(missions: Array) -> void:
	var soonest := ""
	for m in missions:
		if m is Dictionary:
			var e := str(m.get("expires_at", ""))
			if e != "" and (soonest == "" or e < soonest):
				soonest = e
	if soonest == "":
		return
	var remaining := _format_time_until(soonest)
	if remaining == "":
		return
	var lbl := Label.new()
	## Per-slot 24h windows: this is the soonest slot to roll over. Completed
	## missions are replaced instantly on claim.
	lbl.text = "🔄 Next mission refreshes in %s" % remaining
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.8, 0.95))
	_online_container.add_child(lbl)


## Parses an ISO8601 UTC timestamp (e.g. "2026-09-06T12:34:56+00:00" or with a
## trailing Z / fractional seconds) and returns a compact "Xd Yh" / "Xh Ym" /
## "Xm" string until then. Returns "" if already past or unparseable.
func _format_time_until(iso_utc: String) -> String:
	var s := iso_utc.strip_edges()
	## Normalize: drop timezone suffix and fractional seconds; Time expects
	## "YYYY-MM-DDTHH:MM:SS".
	s = s.replace("Z", "")
	var plus := s.find("+")
	if plus > 0:
		s = s.substr(0, plus)
	var dot := s.find(".")
	if dot > 0:
		s = s.substr(0, dot)
	var target := Time.get_unix_time_from_datetime_string(s)
	if target <= 0:
		return ""
	var now := TrustedClock.now()
	var secs := int(target - now)
	if secs <= 0:
		return "soon"
	var days := secs / 86400
	if days > 0:
		var hours := (secs % 86400) / 3600
		return "%dd %dh" % [days, hours]
	return FormatUtils.format_duration(float(secs))


func _add_online_notice(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.75))
	_online_container.add_child(lbl)


## Builds one online-mission card: title, description, reward, live progress,
## and a Claim button (enabled once the server-verified progress meets target).
func _add_online_mission_row(m: Dictionary) -> void:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.14, 0.20, 0.9)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10; style.content_margin_right = 10
	style.content_margin_top = 8; style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	_online_container.add_child(panel)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)
	panel.add_child(inner)

	var title_lbl := Label.new()
	title_lbl.text = str(m.get("title", "Mission"))
	title_lbl.add_theme_font_size_override("font_size", 14)
	title_lbl.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
	inner.add_child(title_lbl)

	var desc_lbl := Label.new()
	desc_lbl.text = str(m.get("description", ""))
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.add_theme_font_size_override("font_size", 12)
	desc_lbl.add_theme_color_override("font_color", Color(0.92, 0.92, 0.88))
	inner.add_child(desc_lbl)

	var reward_lbl := Label.new()
	var base_reward := int(m.get("reward_tokens", 0))
	if PlayerData.boost_active("traders_tongue"):
		## Trader's Tongue is active: the server will pay double on claim.
		reward_lbl.text = "Reward: %s marketplace tokens  (%s × 2 🗣️ Trader's Tongue, %s left)" % [
			PlayerData.format_number(base_reward * 2), PlayerData.format_number(base_reward),
			FormatUtils.format_duration(PlayerData.boost_seconds_remaining("traders_tongue"))]
		reward_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		reward_lbl.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
	else:
		reward_lbl.text = "Reward: %s marketplace tokens" % PlayerData.format_number(base_reward)
		reward_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	reward_lbl.add_theme_font_size_override("font_size", 11)
	inner.add_child(reward_lbl)
	_add_online_mission_progress(inner, m)


## Adds the progress line + Claim button to an online mission card.
## Split out to keep _add_online_mission_row readable.
func _add_online_mission_progress(inner: VBoxContainer, m: Dictionary) -> void:
	## Progress + Claim.
	var target := int(m.get("target", 1))
	var progress := mini(int(m.get("progress", 0)), target)
	var claimed := bool(m.get("claimed", false))

	var prog_lbl := Label.new()
	prog_lbl.text = "Progress: %d / %d" % [progress, target]
	prog_lbl.add_theme_font_size_override("font_size", 11)
	prog_lbl.add_theme_color_override("font_color", Color(0.85, 0.9, 0.85))
	inner.add_child(prog_lbl)

	var mission_id := str(m.get("id", ""))
	if claimed:
		var done_lbl := Label.new()
		done_lbl.text = "✅ Claimed"
		done_lbl.add_theme_font_size_override("font_size", 12)
		done_lbl.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
		inner.add_child(done_lbl)
	else:
		var claim_btn := Button.new()
		claim_btn.text = "Claim Reward" if progress >= target else "Not finished yet"
		claim_btn.disabled = progress < target
		claim_btn.add_theme_font_size_override("font_size", 12)
		claim_btn.custom_minimum_size = Vector2(0, 40)
		claim_btn.pressed.connect(_on_claim_online_mission.bind(mission_id))
		inner.add_child(claim_btn)


## Claims an online mission reward (server re-verifies eligibility), then reloads
## the online tab to reflect the claimed state + new balance.
func _on_claim_online_mission(mission_id: String) -> void:
	var res: Dictionary = await MarketplaceAccount.claim_mission(mission_id)
	if get_node_or_null("/root/GameNotification") != null:
		if res.get("ok", false):
			var bonus := int(res.get("bonus", 0))
			var base := int(res.get("base_reward", 0))
			## Total paid = base + bonus (fall back to "reward" for older servers).
			var total := maxi(int(res.get("reward", 0)), base + bonus)
			var msg := "+%s marketplace tokens" % PlayerData.format_number(total)
			if bonus > 0:
				msg = "+%s marketplace tokens  (%s × 2 🗣️ Trader's Tongue)" % [
					PlayerData.format_number(total), PlayerData.format_number(total - bonus)]
			GameNotification.show_message("Mission reward ✅", msg)
		else:
			GameNotification.show_message("Mission ❌", str(res.get("error", "Claim failed")))
	## Refresh the online list so the claimed mission shows as done.
	if _current_tab == "online":
		_load_online_missions()


func _refresh_slot(slot: int) -> void:
	if slot >= _slot_containers.size():
		return
	var panel: PanelContainer = _slot_containers[slot]
	## Clear existing content
	for child in panel.get_children():
		child.queue_free()

	var diff_names := ["Easy", "Medium", "Hard"]
	var diff_colors := [Color(0.3, 0.85, 0.3), Color(1.0, 0.75, 0.1), Color(1.0, 0.35, 0.35)]
	var chest_labels := ["Lv.4 Chest", "Lv.7 Chest", "Lv.10 Chest"]

	var m = MissionBoard.missions[slot]

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 6)
	panel.add_child(inner)

	if m == null:
		var placeholder := Label.new()
		placeholder.text = "Loading mission..."
		placeholder.add_theme_font_size_override("font_size", 12)
		inner.add_child(placeholder)
		return

	## Difficulty header
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)
	inner.add_child(header_row)

	var diff_lbl := Label.new()
	diff_lbl.text = diff_names[m["difficulty"]]
	diff_lbl.add_theme_font_size_override("font_size", 14)
	diff_lbl.add_theme_color_override("font_color", diff_colors[m["difficulty"]])
	header_row.add_child(diff_lbl)

	var chest_lbl := Label.new()
	chest_lbl.text = "— %s" % chest_labels[m["difficulty"]]
	chest_lbl.add_theme_font_size_override("font_size", 11)
	chest_lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.7))
	chest_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(chest_lbl)

	## Mission description
	var desc_lbl := Label.new()
	desc_lbl.text = m["target_label"]
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.add_theme_font_size_override("font_size", 13)
	desc_lbl.add_theme_color_override("font_color", Color(1.0, 0.95, 0.8))
	inner.add_child(desc_lbl)

	## Progress bar
	var progress: int = int(m["progress"])
	var required: int = int(m["required"])
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = required
	bar.value = progress
	bar.custom_minimum_size = Vector2(0, 20)
	inner.add_child(bar)

	## Progress text
	var prog_lbl := Label.new()
	prog_lbl.text = "%s / %s" % [PlayerData.format_number(progress), PlayerData.format_number(required)]
	prog_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prog_lbl.add_theme_font_size_override("font_size", 11)
	inner.add_child(prog_lbl)

	## Coin reward display
	var coin_reward: int = required * MissionBoard.COIN_PER_ITEM[m["difficulty"]]
	var reward_lbl := Label.new()
	reward_lbl.text = "Reward: +%s coins + %s" % [PlayerData.format_number(coin_reward), chest_labels[m["difficulty"]]]
	reward_lbl.add_theme_font_size_override("font_size", 10)
	reward_lbl.add_theme_color_override("font_color", Color(0.9, 0.85, 0.5))
	inner.add_child(reward_lbl)

	## Claim button or time remaining
	var claimed: bool = bool(m["claimed"])
	if claimed:
		var claimed_lbl := Label.new()
		claimed_lbl.text = "✅ Completed — new mission incoming..."
		claimed_lbl.add_theme_font_size_override("font_size", 11)
		claimed_lbl.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
		inner.add_child(claimed_lbl)
	elif progress >= required:
		var claim_btn := Button.new()
		claim_btn.text = "Claim Reward!"
		claim_btn.custom_minimum_size = Vector2(0, 40)
		claim_btn.add_theme_font_size_override("font_size", 13)
		claim_btn.modulate = Color(1.0, 0.9, 0.2)
		claim_btn.pressed.connect(_on_claim_pressed.bind(slot))
		inner.add_child(claim_btn)
	else:
		## Show time remaining until expiry
		var secs := MissionBoard.get_time_remaining(slot)
		var hrs := int(secs / 3600)
		var mins := int(fmod(secs, 3600) / 60)
		var time_lbl := Label.new()
		time_lbl.text = "Expires in: %dh %dm" % [hrs, mins]
		time_lbl.add_theme_font_size_override("font_size", 10)
		time_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		inner.add_child(time_lbl)

		var accepted: bool = bool(m.get("accepted", false))
		var mission_type: int = int(m["type"])

		## Determine destination label
		var dest_label := ""
		match mission_type:
			MissionBoard.MissionType.GEMS:        dest_label = "Gold Panning"
			MissionBoard.MissionType.CROPS:       dest_label = "Garden"
			MissionBoard.MissionType.EXPEDITIONS: dest_label = "Mining"
			MissionBoard.MissionType.DEEP_MINE:   dest_label = "Deep Mine"
			MissionBoard.MissionType.POLISH, MissionBoard.MissionType.SMELT: dest_label = "Workshop"
			MissionBoard.MissionType.FRUIT, MissionBoard.MissionType.CHOP:   dest_label = "Orchard"
			MissionBoard.MissionType.SELL_POLISHED, MissionBoard.MissionType.SELL_BARS: dest_label = "Marketplace"
			MissionBoard.MissionType.PROSPECTORS: dest_label = "Prospectors"
			MissionBoard.MissionType.DEPOSIT:     dest_label = "Business District"
			MissionBoard.MissionType.GAME_EASY, MissionBoard.MissionType.GAME_MEDIUM, \
			MissionBoard.MissionType.GAME_HARD, MissionBoard.MissionType.GAME_BRUTAL, \
			MissionBoard.MissionType.BEAT_WOLVES, MissionBoard.MissionType.BEAT_BEARS, \
			MissionBoard.MissionType.BEAT_NPCS, MissionBoard.MissionType.WIN_TERRAIN: dest_label = "Game of Pho"

		if not accepted:
			## Accept button — stamps accepted_at then navigates
			var accept_btn := Button.new()
			accept_btn.text = "Accept & Go → %s" % dest_label
			accept_btn.add_theme_font_size_override("font_size", 12)
			accept_btn.custom_minimum_size = Vector2(0, 40)
			accept_btn.modulate = Color(0.4, 0.9, 1.0)
			accept_btn.pressed.connect(_on_accept_pressed.bind(slot, mission_type))
			inner.add_child(accept_btn)
		else:
			## Already accepted — show accepted timestamp and Go button
			var accepted_at: float = float(m.get("accepted_at", 0.0))
			if accepted_at > 0.0:
				var elapsed_secs := int(TrustedClock.now() - accepted_at)
				var e_hrs := elapsed_secs / 3600
				var e_mins := (elapsed_secs % 3600) / 60
				var accepted_lbl := Label.new()
				accepted_lbl.text = "⏱ Accepted %dh %dm ago" % [e_hrs, e_mins]
				accepted_lbl.add_theme_font_size_override("font_size", 10)
				accepted_lbl.add_theme_color_override("font_color", Color(0.5, 0.9, 0.6))
				inner.add_child(accepted_lbl)

			var go_btn := Button.new()
			go_btn.text = "Go → %s" % dest_label
			go_btn.add_theme_font_size_override("font_size", 12)
			go_btn.custom_minimum_size = Vector2(0, 36)
			go_btn.pressed.connect(_on_go_pressed.bind(mission_type))
			inner.add_child(go_btn)

		## Reroll button — pay to swap this mission for a new one (daily-limited).
		var reroll_btn := Button.new()
		var remaining := PlayerData.get_mission_refreshes_remaining()
		var limit := PlayerData.get_mission_refresh_limit()
		reroll_btn.text = "🔄 Reroll (%dc) — %d/%d left" % [
			PlayerData.MISSION_REFRESH_COST, remaining, limit]
		reroll_btn.add_theme_font_size_override("font_size", 10)
		reroll_btn.custom_minimum_size = Vector2(0, 32)
		reroll_btn.disabled = not PlayerData.can_refresh_mission()
		reroll_btn.pressed.connect(_on_reroll_pressed.bind(slot))
		inner.add_child(reroll_btn)


## ── Signal Handlers ────────────────────────────────────────────


func _on_mission_updated(slot: int) -> void:
	_refresh_slot(slot)


func _on_mission_completed(slot: int) -> void:
	_refresh_slot(slot)


func _on_claim_pressed(slot: int) -> void:
	MissionBoard.claim_mission(slot)
	_refresh_slot(slot)


func _on_reroll_pressed(slot: int) -> void:
	if MissionBoard.refresh_mission(slot):
		## Rerolling changes the shared daily allowance, so refresh every slot's
		## button label/state, not just this one. (_replace_mission already
		## re-renders the rerolled slot via mission_updated.)
		for i in range(_slot_containers.size()):
			_refresh_slot(i)


func _on_accept_pressed(slot: int, mission_type: int) -> void:
	MissionBoard.accept_mission(slot)
	_refresh_slot(slot)
	_on_go_pressed(mission_type)


func _on_go_pressed(mission_type: int) -> void:
	match mission_type:
		MissionBoard.MissionType.GEMS:
			## Gems can be earned at any level (reward chests), but the "Go"
			## button should route to a real gem source. Prefer Gold Panning
			## (Lv.3); if it's not unlocked, fall back to whatever mine feature
			## the player has open, and finally to home if none are available.
			_get_navigator().navigate_to(_gem_mission_destination())
		MissionBoard.MissionType.CROPS:
			_get_navigator().navigate_to("garden")
		MissionBoard.MissionType.GAME_EASY, MissionBoard.MissionType.GAME_MEDIUM, \
		MissionBoard.MissionType.GAME_HARD, MissionBoard.MissionType.GAME_BRUTAL, \
		MissionBoard.MissionType.BEAT_WOLVES, MissionBoard.MissionType.BEAT_BEARS, \
		MissionBoard.MissionType.BEAT_NPCS, MissionBoard.MissionType.WIN_TERRAIN:
			if PlayerData.get_inventory_size() == 0:
				return
			_get_navigator().navigate_to("setup")
		MissionBoard.MissionType.EXPEDITIONS:
			_get_navigator().navigate_to("mining")
		MissionBoard.MissionType.DEEP_MINE:
			_get_navigator().navigate_to("deep_mine")
		MissionBoard.MissionType.POLISH:
			_get_navigator().navigate_to("workshop")
		MissionBoard.MissionType.SMELT:
			_get_navigator().navigate_to("workshop")
		MissionBoard.MissionType.FRUIT:
			_get_navigator().navigate_to("orchard")
		MissionBoard.MissionType.CHOP:
			_get_navigator().navigate_to("orchard")
		MissionBoard.MissionType.SELL_POLISHED:
			_get_navigator().navigate_to("marketplace")
		MissionBoard.MissionType.SELL_BARS:
			_get_navigator().navigate_to("marketplace")
		MissionBoard.MissionType.PROSPECTORS:
			## Respect the level gate — same lock as the mining screen button.
			if PlayerData.level >= 10:
				_get_navigator().navigate_to("prospectors")
			else:
				_get_navigator().navigate_to("mining")
		MissionBoard.MissionType.DEPOSIT:
			_get_navigator().navigate_to("business_district")


## Picks the best gem-related screen the player can currently access.
## Order of preference: Gold Panning (Lv.3) -> Deep Mine (Lv.20) -> Prospectors
## (Lv.10) -> Mining expeditions (Lv.2) -> Home. Falls back down the list based
## on the player's level so tapping "Go" never lands on a locked screen.
func _gem_mission_destination() -> String:
	var lvl: int = PlayerData.level
	if lvl >= 3:
		return "gold_panning"
	## No Gold Panning yet — send them to whatever mine feature is open.
	if get_node_or_null("/root/DeepMine") != null and DeepMine.is_unlocked():
		return "deep_mine"
	if lvl >= 10:
		return "prospectors"
	if lvl >= 2:
		return "mining"
	return "home"


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()
