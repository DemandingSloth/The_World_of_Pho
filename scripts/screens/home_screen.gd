extends BaseScreen
## Home screen — displays player info, navigation buttons, and dynamic elements
## (XP bar, daily bonus, win streak). Reads all data from autoload singletons.
##
## Requirements: 1.2, 1.3, 1.5, 1.6, 8.1, 9.1, 9.3


@onready var vbox: VBoxContainer = $CenterWrapper/VBox
@onready var player_info_label: Label = $CenterWrapper/VBox/PlayerInfoLabel
@onready var coin_label: Label = $CenterWrapper/VBox/CoinLabel
@onready var town_btn: Button = $CenterWrapper/VBox/TownBtn
@onready var inventory_btn: Button = $CenterWrapper/VBox/InventoryBtn
@onready var marketplace_btn: Button = $CenterWrapper/VBox/MarketplaceBtn
@onready var achievements_btn: Button = $CenterWrapper/VBox/AchievementsBtn
@onready var settings_btn: Button = $CenterWrapper/VBox/SettingsBtn
@onready var guilds_btn: Button = $CenterWrapper/VBox/GuildsBtn

@onready var play_game_btn: Button = $CenterWrapper/VBox/PlayGameBtn
# @onready var online_battle_btn: Button = $CenterWrapper/VBox/OnlineBattleBtn
@onready var inventory_label: Label = $CenterWrapper/VBox/InventoryLabel


func _ready() -> void:
	# Cap the nav column to 400 px on wide screens (web / desktop).
	# CenterContainer centres the child but won't cap its width on its own;
	# we clamp it here and re-apply whenever the viewport resizes.
	_clamp_vbox_width()
	get_viewport().size_changed.connect(_clamp_vbox_width)


func _clamp_vbox_width() -> void:
	const MAX_W := 400.0
	var vp_w: float = get_viewport_rect().size.x
	var target_w: float = min(vp_w - 24.0, MAX_W)
	vbox.custom_minimum_size.x = target_w
	vbox.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# Force the actual size so the layout engine doesn't expand beyond target_w.
	vbox.set_deferred("size", Vector2(target_w, vbox.size.y))


func enter(params: Dictionary = {}) -> void:
	# Connect buttons with connection guards to prevent signal stacking
	if town_btn and not town_btn.pressed.is_connected(_on_town_pressed):
		town_btn.pressed.connect(_on_town_pressed)
	if inventory_btn and not inventory_btn.pressed.is_connected(_on_inventory_pressed):
		inventory_btn.pressed.connect(_on_inventory_pressed)
	if marketplace_btn and not marketplace_btn.pressed.is_connected(_on_marketplace_pressed):
		marketplace_btn.pressed.connect(_on_marketplace_pressed)
	if achievements_btn and not achievements_btn.pressed.is_connected(_on_achievements_pressed):
		achievements_btn.pressed.connect(_on_achievements_pressed)
	if settings_btn and not settings_btn.pressed.is_connected(_on_settings_pressed):
		settings_btn.pressed.connect(_on_settings_pressed)
	if guilds_btn and not guilds_btn.pressed.is_connected(_on_guilds_pressed):
		guilds_btn.pressed.connect(_on_guilds_pressed)
	if play_game_btn and not play_game_btn.pressed.is_connected(_on_play_game_pressed):
		play_game_btn.pressed.connect(_on_play_game_pressed)
#	if online_battle_btn and not online_battle_btn.pressed.is_connected(_on_online_battle_pressed):
#		online_battle_btn.pressed.connect(_on_online_battle_pressed)

	# Connect to PlayerData for live updates (Req 1.5)
	if not PlayerData.data_changed.is_connected(_refresh_display):
		PlayerData.data_changed.connect(_refresh_display)

	# Workshop entry — built dynamically to avoid editing the home scene.
	_build_workshop_button()

	# Active Bonuses overview — built dynamically (no scene edit).
	_build_active_bonuses_button()

	# Build dynamic UI elements safely
	_build_xp_bar()
	_build_daily_bonus_section()
	_build_streak_label()
	_build_tutorial_button()

	# Populate all displayed values from current state (Req 9.3)
	_refresh_display()

	# Show name prompt on first launch
	if not PlayerData.has_set_name:
		call_deferred("_show_name_prompt")
	elif get_node_or_null("/root/MarketplaceAccount") != null:
		## Link the in-game name with the online account (retries each time the
		## home screen opens until it succeeds — covers players who were offline).
		if not MarketplaceAccount.name_needs_change.is_connected(_on_name_needs_change):
			MarketplaceAccount.name_needs_change.connect(_on_name_needs_change)
		if MarketplaceAccount.pending_name_change_reason != "":
			call_deferred("_show_name_prompt", MarketplaceAccount.pending_name_change_reason)
		else:
			MarketplaceAccount.sync_identity()


func exit() -> void:
	# Disconnect all autoload signals (Req 1.6, 10.2)
	if PlayerData.data_changed.is_connected(_refresh_display):
		PlayerData.data_changed.disconnect(_refresh_display)
	if get_node_or_null("/root/MarketplaceAccount") != null \
			and MarketplaceAccount.name_needs_change.is_connected(_on_name_needs_change):
		MarketplaceAccount.name_needs_change.disconnect(_on_name_needs_change)


## The local name couldn't be claimed online (taken / no longer allowed) — ask
## the player for a new one. Free, and can't be skipped.
func _on_name_needs_change(reason: String) -> void:
	_show_name_prompt(reason)


func get_screen_name() -> String:
	return "home"


## Adds a Workshop button (matches the Town button's look) below Town.
func _build_workshop_button() -> void:
	var existing := vbox.get_node_or_null("WorkshopBtn")
	if existing != null:
		return
	var btn := Button.new()
	btn.name = "WorkshopBtn"
	btn.text = "Workshop"
	if town_btn:
		btn.size_flags_horizontal = town_btn.size_flags_horizontal
		btn.custom_minimum_size = town_btn.custom_minimum_size
		var fs := town_btn.get_theme_font_size("font_size")
		if fs > 0:
			btn.add_theme_font_size_override("font_size", fs)
	btn.pressed.connect(_on_workshop_pressed)
	vbox.add_child(btn)
	if town_btn:
		vbox.move_child(btn, town_btn.get_index() + 1)


func _on_workshop_pressed() -> void:
	_get_navigator().navigate_to("workshop")


## Adds an "Active Bonuses" button (matches the other nav buttons) that opens a
## read-only overview of every active bonus and the combined totals.
func _build_active_bonuses_button() -> void:
	if vbox.has_node("ActiveBonusesBtn"):
		return
	var btn := Button.new()
	btn.name = "ActiveBonusesBtn"
	btn.text = "📊 Active Bonuses"
	if town_btn:
		btn.size_flags_horizontal = town_btn.size_flags_horizontal
		btn.custom_minimum_size = town_btn.custom_minimum_size
		var fs := town_btn.get_theme_font_size("font_size")
		if fs > 0:
			btn.add_theme_font_size_override("font_size", fs)
	btn.pressed.connect(_on_active_bonuses_pressed)
	vbox.add_child(btn)
	## Place it just below the Workshop button if present, else below Town.
	var anchor := vbox.get_node_or_null("WorkshopBtn")
	if anchor == null:
		anchor = town_btn
	if anchor:
		vbox.move_child(btn, anchor.get_index() + 1)


func _on_active_bonuses_pressed() -> void:
	_get_navigator().navigate_to("active_bonuses")


## Adds a Guilds button below Settings (matches the other nav buttons' look).
func _build_guilds_button() -> void:
	if vbox.has_node("GuildsBtn"):
		return
	var btn := Button.new()
	btn.name = "GuildsBtn"
	btn.text = "⚔️ Guilds"
	if settings_btn:
		btn.size_flags_horizontal = settings_btn.size_flags_horizontal
		btn.custom_minimum_size = settings_btn.custom_minimum_size
		var fs := settings_btn.get_theme_font_size("font_size")
		if fs > 0:
			btn.add_theme_font_size_override("font_size", fs)
	btn.pressed.connect(_on_guilds_pressed)
	vbox.add_child(btn)
	if settings_btn:
		vbox.move_child(btn, settings_btn.get_index() + 1)


func _on_guilds_pressed() -> void:
	_get_navigator().navigate_to("guilds")


## Adds a one-time "Start Guided Tutorial" button above Town, visible only until
## the player has started (or completed) the tutorial. Disappears after tapping.
func _build_tutorial_button() -> void:
	## Already shown or already used — don't show again.
	if PlayerData.tutorial_completed or PlayerData.tutorial_step_index >= 0 or PlayerData.tutorial_home_dismissed:
		return
	## Only build once per enter().
	if vbox.has_node("TutorialStartBtn"):
		return

	var btn := Button.new()
	btn.name = "TutorialStartBtn"
	btn.text = "📖 Start Guided Tutorial"
	if town_btn:
		btn.size_flags_horizontal = town_btn.size_flags_horizontal
		btn.custom_minimum_size = town_btn.custom_minimum_size
		var fs := town_btn.get_theme_font_size("font_size")
		if fs > 0:
			btn.add_theme_font_size_override("font_size", fs)
	btn.add_theme_color_override("font_color", Color(0.4, 1.0, 0.6))
	btn.pressed.connect(func():
		PlayerData.tutorial_home_dismissed = true
		PlayerData.save_data()
		var ts := get_node_or_null("/root/TutorialSystem")
		if ts != null and ts.has_method("start_tutorial"):
			ts.start_tutorial()
		btn.queue_free())
	vbox.add_child(btn)
	## Place it at the very top of vbox (index 0) so it's easy to spot.
	vbox.move_child(btn, 0)


## Builds a notification row: an on/off checkbox plus a set of "threshold"
## toggle buttons (radio-style) that pick how many items/rows must be ready
## before the alert fires. `options` is an array of [label, value] pairs.
## category is the PlayerData notification key (workshop/foundry/garden/orchard).
func _build_notif_threshold_row(category: String, label_text: String, options: Array) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)

	var cb := CheckBox.new()
	cb.text = label_text
	cb.add_theme_font_size_override("font_size", 12)
	cb.button_pressed = PlayerData.is_notification_enabled(category)
	cb.toggled.connect(func(on): PlayerData.set_notification_enabled(category, on))
	box.add_child(cb)

	## Threshold buttons on their own row, indented under the checkbox.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var indent := Control.new()
	indent.custom_minimum_size = Vector2(24, 0)
	row.add_child(indent)

	var prefix := Label.new()
	prefix.text = "Alert at:"
	prefix.add_theme_font_size_override("font_size", 11)
	prefix.add_theme_color_override("font_color", Color(0.8, 0.8, 0.75))
	row.add_child(prefix)

	var group := ButtonGroup.new()
	var current: int = PlayerData.get_notification_threshold(category)
	for opt in options:
		var opt_label: String = str(opt[0])
		var opt_value: int = int(opt[1])
		var btn := Button.new()
		btn.text = opt_label
		btn.toggle_mode = true
		btn.button_group = group
		btn.focus_mode = Control.FOCUS_NONE
		btn.add_theme_font_size_override("font_size", 11)
		btn.custom_minimum_size = Vector2(44, 30)
		btn.button_pressed = (opt_value == current)
		btn.pressed.connect(func(): PlayerData.set_notification_threshold(category, opt_value))
		row.add_child(btn)

	box.add_child(row)
	return box


func _on_settings_pressed() -> void:
	_show_settings_popup()


func _show_settings_popup() -> void:
	var popup := Window.new()
	popup.title = "Settings"
	popup.size = Vector2i(380, 560)
	popup.unresizable = true
	popup.always_on_top = true

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup.add_child(panel)

	## Scrollable body so the settings list can grow without overflowing the window.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var vbox_settings := VBoxContainer.new()
	vbox_settings.add_theme_constant_override("separation", 10)
	vbox_settings.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox_settings)

	var title_lbl := Label.new()
	title_lbl.text = "Settings"
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox_settings.add_child(title_lbl)

	# Current name display
	var current_lbl := Label.new()
	current_lbl.text = "Current Name: %s" % PlayerData.player_name
	current_lbl.add_theme_font_size_override("font_size", 12)
	current_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox_settings.add_child(current_lbl)

	# Name change section — ONE name for the game and the online market.
	var free_rename := get_node_or_null("/root/MarketplaceAccount") != null \
		and bool(MarketplaceAccount.free_name_change)
	var cost := 0 if free_rename else PlayerData.get_name_change_cost()
	var cost_lbl := Label.new()
	cost_lbl.text = ("Change name: FREE (one-time)" if free_rename
		else "Change name: %s coins" % PlayerData.format_number(cost)) \
		+ "\nUpdates your in-game and online market name. Needs internet."
	cost_lbl.add_theme_font_size_override("font_size", 11)
	cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cost_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox_settings.add_child(cost_lbl)

	var name_input := LineEdit.new()
	name_input.placeholder_text = "New name (2-16 characters)"
	name_input.max_length = 16
	name_input.add_theme_font_size_override("font_size", 14)
	name_input.custom_minimum_size.y = 40
	vbox_settings.add_child(name_input)

	var error_lbl := Label.new()
	error_lbl.add_theme_font_size_override("font_size", 11)
	error_lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	error_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox_settings.add_child(error_lbl)

	var change_btn := Button.new()
	change_btn.text = "Change Name (Free)" if free_rename \
		else "Change Name (%s)" % PlayerData.format_number(cost)
	change_btn.add_theme_font_size_override("font_size", 13)
	change_btn.custom_minimum_size.y = 36
	change_btn.disabled = PlayerData.coins < cost
	vbox_settings.add_child(change_btn)

	change_btn.pressed.connect(func():
		## Server first (uniqueness), then coins are charged + local name updated.
		change_btn.disabled = true
		error_lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		error_lbl.text = "Checking name…"
		var result: String = await PlayerData.change_name(name_input.text)
		if not is_instance_valid(change_btn):
			return
		if result != "":
			error_lbl.text = result
			change_btn.disabled = PlayerData.coins < cost
			return
		current_lbl.text = "Current Name: %s" % PlayerData.player_name
		var new_cost := PlayerData.get_name_change_cost()
		cost_lbl.text = "Change name: %s coins\nUpdates your in-game and online market name. Needs internet." % \
			PlayerData.format_number(new_cost)
		change_btn.text = "Change Name (%s)" % PlayerData.format_number(new_cost)
		change_btn.disabled = PlayerData.coins < new_cost
		error_lbl.text = "Name changed!"
		error_lbl.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	)
	popup.close_requested.connect(popup.queue_free)

	## Restore an online account with a recovery code (lost phone / reinstall).
	var account_restore_btn := Button.new()
	account_restore_btn.text = "🔑 Restore Account (recovery code)"
	account_restore_btn.add_theme_font_size_override("font_size", 12)
	account_restore_btn.custom_minimum_size.y = 36
	account_restore_btn.pressed.connect(func():
		_show_restore_account_popup(func(_name: String):
			if is_instance_valid(current_lbl):
				current_lbl.text = "Current Name: %s" % PlayerData.player_name))
	vbox_settings.add_child(account_restore_btn)

	# ── Notifications Section ────────────────────────────────────────
	var notif_sep := HSeparator.new()
	vbox_settings.add_child(notif_sep)

	var notif_title := Label.new()
	notif_title.text = "Notifications"
	notif_title.add_theme_font_size_override("font_size", 13)
	notif_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox_settings.add_child(notif_title)

	var daily_cb := CheckBox.new()
	daily_cb.text = "Daily bonus ready"
	daily_cb.add_theme_font_size_override("font_size", 12)
	daily_cb.button_pressed = PlayerData.is_notification_enabled("daily_bonus")
	daily_cb.toggled.connect(func(on): PlayerData.set_notification_enabled("daily_bonus", on))
	vbox_settings.add_child(daily_cb)

	## Garden: alert after N ready rows (1 / 5 / 10 / Full).
	vbox_settings.add_child(_build_notif_threshold_row(
		"garden", "Garden rows ready",
		[["1", 1], ["5", 5], ["10", 10], ["Full", 0]]))

	## Orchard: alert after N ready trees (10 / 50 / 100).
	vbox_settings.add_child(_build_notif_threshold_row(
		"orchard", "Orchard trees ready",
		[["10", 10], ["50", 50], ["100", 100]]))

	## Workshop saw: alert after N polished gems (10 / 50 / 100).
	vbox_settings.add_child(_build_notif_threshold_row(
		"workshop", "Saw gems polished",
		[["10", 10], ["50", 50], ["100", 100]]))

	## Workshop foundry: alert after N bars smelted (10 / 50 / 100).
	vbox_settings.add_child(_build_notif_threshold_row(
		"foundry", "Foundry bars ready",
		[["10", 10], ["50", 50], ["100", 100]]))

	var missions_cb := CheckBox.new()
	missions_cb.text = "Missions ready to claim"
	missions_cb.add_theme_font_size_override("font_size", 12)
	missions_cb.button_pressed = PlayerData.is_notification_enabled("missions")
	missions_cb.toggled.connect(func(on): PlayerData.set_notification_enabled("missions", on))
	vbox_settings.add_child(missions_cb)

	# ── Cheat Code Section ──────────────────────────────────────────
	var cheat_sep := HSeparator.new()
	vbox_settings.add_child(cheat_sep)

	var cheat_title := Label.new()
	cheat_title.text = "Cheat Code"
	cheat_title.add_theme_font_size_override("font_size", 13)
	cheat_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox_settings.add_child(cheat_title)

	var cheat_input := LineEdit.new()
	cheat_input.placeholder_text = "Enter code..."
	cheat_input.add_theme_font_size_override("font_size", 14)
	cheat_input.custom_minimum_size.y = 40
	vbox_settings.add_child(cheat_input)

	var cheat_msg := Label.new()
	cheat_msg.add_theme_font_size_override("font_size", 11)
	cheat_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox_settings.add_child(cheat_msg)

	var redeem_btn := Button.new()
	redeem_btn.text = "Redeem"
	redeem_btn.add_theme_font_size_override("font_size", 13)
	redeem_btn.custom_minimum_size.y = 36
	vbox_settings.add_child(redeem_btn)

	redeem_btn.pressed.connect(func():
		var code := cheat_input.text.strip_edges()
		if code == "SlothsCashStash":
			if PlayerData.cash_stash_lifetime_granted >= PlayerData.CASH_STASH_LIFETIME_CAP:
				cheat_msg.text = "Code has reached its lifetime limit."
				cheat_msg.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
				return
			_show_cash_stash_popup(cheat_input, cheat_msg)
			return
		var result := PlayerData.redeem_code(code)
		if result == "":
			cheat_msg.text = "✅ Code redeemed!"
			cheat_msg.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
			cheat_input.text = ""
		else:
			cheat_msg.text = result
			cheat_msg.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	)

	# ── Backup / Restore Section ─────────────────────────────────────
	var backup_sep := HSeparator.new()
	vbox_settings.add_child(backup_sep)

	var backup_title := Label.new()
	backup_title.text = "Backup / Restore Progress"
	backup_title.add_theme_font_size_override("font_size", 13)
	backup_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox_settings.add_child(backup_title)

	var backup_hint := Label.new()
	backup_hint.text = "Export a code to save your progress. Paste a code and Restore to load it (overwrites current progress)."
	backup_hint.add_theme_font_size_override("font_size", 10)
	backup_hint.add_theme_color_override("font_color", Color.BLACK)
	backup_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	backup_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox_settings.add_child(backup_hint)

	# Multi-line field holding the backup code (used for both export display and import input)
	var backup_field := TextEdit.new()
	backup_field.placeholder_text = "Export shows your code here. Use the Paste button to load a code to Restore."
	backup_field.custom_minimum_size = Vector2(0, 90)
	backup_field.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	backup_field.add_theme_font_size_override("font_size", 9)
	## Dark grey code text so it reads against the light panel background.
	backup_field.add_theme_color_override("font_color", Color(0.25, 0.25, 0.25))
	backup_field.add_theme_color_override("font_readonly_color", Color(0.25, 0.25, 0.25))
	## Hide the caret and its current-line highlight — in this read-only field
	## they render as a horizontal bar striking through the code text.
	backup_field.caret_type = TextEdit.CARET_TYPE_LINE
	backup_field.caret_blink = false
	backup_field.caret_draw_when_editable_disabled = false
	backup_field.highlight_current_line = false
	backup_field.add_theme_color_override("current_line_color", Color(0, 0, 0, 0))
	backup_field.add_theme_color_override("caret_color", Color(0, 0, 0, 0))
	## Read-only: on Android, pasting directly into a TextEdit can freeze the app.
	## The code is set programmatically via Export / the Paste button instead.
	backup_field.editable = false
	backup_field.context_menu_enabled = false
	backup_field.selecting_enabled = true  ## still allow selecting to copy manually
	vbox_settings.add_child(backup_field)

	var backup_msg := Label.new()
	backup_msg.add_theme_font_size_override("font_size", 11)
	backup_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	backup_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox_settings.add_child(backup_msg)

	var backup_btn_row := HBoxContainer.new()
	backup_btn_row.add_theme_constant_override("separation", 6)
	backup_btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox_settings.add_child(backup_btn_row)

	var export_btn := Button.new()
	export_btn.text = "Export"
	export_btn.add_theme_font_size_override("font_size", 12)
	export_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	export_btn.custom_minimum_size = Vector2(0, 36)
	backup_btn_row.add_child(export_btn)

	var copy_btn := Button.new()
	copy_btn.text = "Copy"
	copy_btn.add_theme_font_size_override("font_size", 12)
	copy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy_btn.custom_minimum_size = Vector2(0, 36)
	backup_btn_row.add_child(copy_btn)

	var paste_btn := Button.new()
	paste_btn.text = "Paste"
	paste_btn.add_theme_font_size_override("font_size", 12)
	paste_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	paste_btn.custom_minimum_size = Vector2(0, 36)
	backup_btn_row.add_child(paste_btn)

	var restore_btn := Button.new()
	restore_btn.text = "Restore"
	restore_btn.add_theme_font_size_override("font_size", 12)
	restore_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	restore_btn.custom_minimum_size = Vector2(0, 36)
	backup_btn_row.add_child(restore_btn)

	export_btn.pressed.connect(func():
		## Disable the button immediately to prevent double-taps.
		export_btn.disabled = true
		backup_msg.text = "⏳ Saving…"
		backup_msg.add_theme_color_override("font_color", Color(0.9, 0.9, 0.6))
		## Yield a frame so the label paints before the heavy work starts.
		await get_tree().process_frame

		## Flush every save to disk. Each save_data() is a disk write; spread
		## them across frames so the main thread doesn't stall for seconds.
		PlayerData.save_data()
		await get_tree().process_frame
		Garden.save_data()
		await get_tree().process_frame
		if get_node_or_null("/root/Orchard") != null:
			Orchard.save_data()
		if get_node_or_null("/root/Workshop") != null:
			Workshop.save_data()
		await get_tree().process_frame
		MissionBoard.save_data()
		Achievements.save_data()
		await get_tree().process_frame

		backup_msg.text = "⏳ Generating code…"
		await get_tree().process_frame

		## Now do the expensive encode (file reads + SHA-256 + JSON + Base64).
		var code := SaveBackup.export_code()
		export_btn.disabled = false
		if code == "":
			backup_msg.text = "Nothing to export yet."
			backup_msg.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			return
		backup_field.text = code
		backup_msg.text = "✅ Backup code ready — copy and keep it safe."
		backup_msg.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	)

	copy_btn.pressed.connect(func():
		if backup_field.text.strip_edges().is_empty():
			backup_msg.text = "Nothing to copy — Export first."
			backup_msg.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			return
		copy_btn.disabled = true
		backup_msg.text = "⏳ Copying…"
		backup_msg.add_theme_color_override("font_color", Color(0.9, 0.9, 0.6))
		## Yield so the label paints before the clipboard write (which can stall
		## for a moment on Android with a large string).
		await get_tree().process_frame
		DisplayServer.clipboard_set(backup_field.text)
		copy_btn.disabled = false
		backup_msg.text = "📋 Copied to clipboard."
		backup_msg.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	)

	paste_btn.pressed.connect(func():
		## Pull the code from the clipboard programmatically (avoids the native
		## TextEdit paste that freezes on Android).
		var clip := ""
		if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
			clip = DisplayServer.clipboard_get()
		if clip.strip_edges().is_empty():
			backup_msg.text = "Clipboard is empty — copy your backup code first."
			backup_msg.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			return
		backup_field.text = clip
		backup_msg.text = "📋 Pasted from clipboard — tap Restore to load it."
		backup_msg.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	)

	restore_btn.pressed.connect(func():
		var code := backup_field.text
		if code.strip_edges().is_empty():
			backup_msg.text = "Paste a backup code to restore."
			backup_msg.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			return
		# Confirm — restore overwrites all current progress.
		var confirm := ConfirmationDialog.new()
		confirm.title = "⚠️ Restore Progress"
		confirm.dialog_text = "This will overwrite ALL current progress with the backup. This cannot be undone.\n\nContinue?"
		confirm.ok_button_text = "Restore"
		add_child(confirm)
		_style_warning_dialog(confirm)
		# Pass state explicitly via bind() — nested lambdas don't reliably
		# capture the outer function's locals (backup_msg, code).
		confirm.confirmed.connect(_on_restore_confirmed.bind(code, backup_msg, confirm))
		confirm.canceled.connect(confirm.queue_free)
		confirm.popup_centered()
	)

	# ── Danger Zone: Delete All Progress ─────────────────────────────
	var danger_sep := HSeparator.new()
	vbox_settings.add_child(danger_sep)

	var delete_btn := Button.new()
	delete_btn.text = "🗑 Delete All Progress"
	delete_btn.add_theme_font_size_override("font_size", 13)
	delete_btn.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	delete_btn.custom_minimum_size = Vector2(0, 40)
	delete_btn.pressed.connect(_on_delete_all_pressed.bind(backup_msg))
	vbox_settings.add_child(delete_btn)

	add_child(popup)
	popup.popup_centered()


## Applies cream-on-dark styling to a dialog so its text is legible on the
## game's dark theme, and sizes it to fit within the current viewport.
func _style_warning_dialog(dialog: AcceptDialog) -> void:
	const CREAM := Color(0.96, 0.93, 0.82)
	var lbl := dialog.get_label()
	if lbl:
		lbl.add_theme_color_override("font_color", CREAM)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	## Keep warnings above the settings window so they can't hide behind it.
	dialog.always_on_top = true
	## Constrain the dialog to the viewport so it never spills off-screen.
	var vp := get_viewport().get_visible_rect().size
	var target_w: int = int(min(vp.x - 40.0, 320.0))
	dialog.max_size = Vector2i(int(vp.x - 20.0), int(vp.y - 40.0))
	dialog.size = Vector2i(target_w, 0)  ## height auto-fits the wrapped text
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.12, 0.10, 0.10, 0.98)
	bg.border_color = Color(0.8, 0.3, 0.3, 0.8)
	bg.set_border_width_all(2)
	bg.set_corner_radius_all(8)
	bg.content_margin_left = 16
	bg.content_margin_right = 16
	bg.content_margin_top = 14
	bg.content_margin_bottom = 14
	dialog.add_theme_stylebox_override("panel", bg)


## First warning: no backup / corrupted backup means progress is gone forever.
func _on_delete_all_pressed(backup_msg: Label) -> void:
	var warn1 := ConfirmationDialog.new()
	warn1.title = "⚠️ Delete ALL Progress?"
	warn1.dialog_text = "This permanently deletes ALL your local progress (game, garden, orchard, workshop, missions, achievements).\n\nYour online marketplace account — tokens and active listings — is NOT affected. Contact the developer if you need that erased.\n\nIf you do NOT have a backup code — or your backup is corrupted — you will have to RESTART from scratch.\n\nAre you absolutely sure?"
	warn1.ok_button_text = "Yes, continue"
	add_child(warn1)
	_style_warning_dialog(warn1)
	warn1.confirmed.connect(_on_delete_all_warn2.bind(backup_msg, warn1))
	warn1.canceled.connect(warn1.queue_free)
	warn1.popup_centered()


## Second warning: this is irreversible and the developer cannot recover it.
## Deferred so it shows AFTER the first dialog finishes closing this frame,
## otherwise the new popup can be suppressed by the closing one.
func _on_delete_all_warn2(backup_msg: Label, warn1: ConfirmationDialog) -> void:
	if is_instance_valid(warn1):
		warn1.queue_free()
	_show_delete_warn2.call_deferred(backup_msg)


func _show_delete_warn2(backup_msg: Label) -> void:
	var warn2 := ConfirmationDialog.new()
	warn2.title = "⚠️ Final Warning"
	warn2.dialog_text = "This action CANNOT be undone.\n\nThe developer CANNOT override this or recover your data if something goes wrong. Once deleted, your progress is gone for good.\n\nDelete everything now?"
	warn2.ok_button_text = "Delete Everything"
	add_child(warn2)
	_style_warning_dialog(warn2)
	warn2.confirmed.connect(_on_delete_all_confirmed.bind(backup_msg, warn2))
	warn2.canceled.connect(warn2.queue_free)
	warn2.popup_centered()


## Both warnings accepted — wipe everything and refresh the UI.
func _on_delete_all_confirmed(backup_msg: Label, warn2: ConfirmationDialog) -> void:
	SaveBackup.delete_all_progress()
	PlayerData.data_changed.emit()
	_refresh_display()
	if is_instance_valid(backup_msg):
		backup_msg.text = "Local progress deleted. Your online marketplace account was left intact."
		backup_msg.add_theme_color_override("font_color", Color(0.96, 0.93, 0.82))
	if is_instance_valid(warn2):
		warn2.queue_free()


## Handles the confirmed "Restore" action. Receives references explicitly via
## bind() so it doesn't depend on lambda capture of the settings popup's locals.
func _on_restore_confirmed(code: String, backup_msg: Label, confirm: ConfirmationDialog) -> void:
	var err := SaveBackup.import_code(code)
	if is_instance_valid(backup_msg):
		if err != "":
			backup_msg.text = err
			backup_msg.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		else:
			backup_msg.text = "✅ Progress restored!"
			backup_msg.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	if err == "":
		SaveBackup.reload_all_autoloads()
		PlayerData.data_changed.emit()
		_refresh_display()
	if is_instance_valid(confirm):
		confirm.queue_free()


## ── Private: Refresh display from autoload data ──────────────────


func _refresh_display() -> void:
	player_info_label.text = "   %s  —  Level %d/%d" % [PlayerData.player_name, PlayerData.level, PlayerData.peak_level]
	coin_label.text = "   Coins: %s" % PlayerData.format_number(PlayerData.coins)

	var consumable_tools := PlayerData.get_tool_count(PlayerData.ToolType.MAGNIFYING_GLASS) + PlayerData.get_tool_count(PlayerData.ToolType.SHOVEL)
	inventory_label.text = "   Inventory:\n     Pho tiles: %d\n     Seeds/Saplings: %d\n     Tools: %d" % [
		PlayerData.get_inventory_size(), Garden.get_total_seeds_and_saplings(), consumable_tools]
	inventory_label.add_theme_color_override("font_color", Color(0.0, 0.0, 0.5))
	inventory_label.visible = false

	if PlayerData.level < 4:
		play_game_btn.text = "🔒 Play Game of Pho — Lv.4"
		play_game_btn.modulate = Color(0.7, 0.7, 0.7)
	else:
		play_game_btn.text = "Play Game of Pho"
		play_game_btn.modulate = Color.WHITE

	_update_xp_bar()
	_update_daily_bonus_ui()
	_update_streak_label()


## ── Private: XP Bar ──────────────────────────────────────────────


func _build_xp_bar() -> void:
	if vbox.has_node("XPBar"):
		return
		
	var xp_container := HBoxContainer.new()
	xp_container.name = "XPBar"
	xp_container.add_theme_constant_override("separation", 6)

	var xp_label := Label.new()
	xp_label.name = "XPLabel"
	xp_label.theme_type_variation = &"HudLabel"
	xp_label.add_theme_font_size_override("font_size", 11)
	xp_container.add_child(xp_label)

	var bar := ProgressBar.new()
	bar.name = "XPProgress"
	bar.custom_minimum_size = Vector2(150, 16)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.max_value = PlayerData.xp_for_next_level()
	bar.show_percentage = false
	xp_container.add_child(bar)

	var insert_idx := coin_label.get_index() + 1
	vbox.add_child(xp_container)
	vbox.move_child(xp_container, insert_idx)


func _update_xp_bar() -> void:
	var xp_bar_node: HBoxContainer = vbox.get_node_or_null("XPBar")
	if xp_bar_node == null:
		return
	var xp_label: Label = xp_bar_node.get_node("XPLabel")
	var bar: ProgressBar = xp_bar_node.get_node("XPProgress")
	var current_lvl_start: int = PlayerData.cumulative_xp_for_level(PlayerData.level)
	var next_lvl_start: int = PlayerData.cumulative_xp_for_level(PlayerData.level + 1)
	if PlayerData.level >= PlayerData.MAX_LEVEL:
		## Level capped: XP still accumulates (and can be spent); show a full bar.
		xp_label.text = "   XP: %s (MAX LEVEL)" % PlayerData.format_number(PlayerData.xp)
		bar.min_value = 0
		bar.max_value = 1
		bar.value = 1
		return
	xp_label.text = "   XP: %s / %s" % [PlayerData.format_number(PlayerData.xp), PlayerData.format_number(next_lvl_start)]
	bar.min_value = current_lvl_start
	bar.max_value = next_lvl_start
	bar.value = PlayerData.xp


## ── Private: Daily Bonus ─────────────────────────────────────────


func _build_daily_bonus_section() -> void:
	if vbox.has_node("DailyBonusSection"):
		return

	var section := VBoxContainer.new()
	section.name = "DailyBonusSection"
	section.add_theme_constant_override("separation", 4)

	var title_label := Label.new()
	title_label.name = "DailyTitle"
	title_label.text = "── Bonuses ──"
	title_label.theme_type_variation = &"HudGoldLabel"
	title_label.add_theme_font_size_override("font_size", 12)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	section.add_child(title_label)

	var btn_row := HBoxContainer.new()
	btn_row.name = "DailyRow"
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 10)

	var daily_btn := Button.new()
	daily_btn.name = "DailyBtn"
	daily_btn.custom_minimum_size = Vector2(64, 64)
	daily_btn.focus_mode = Control.FOCUS_NONE
	daily_btn.pressed.connect(_on_claim_daily_bonus)

	var tex := load("res://Assets/daily_bonus.png")
	if tex:
		var sprite := TextureRect.new()
		sprite.texture = tex
		sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
		sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
		daily_btn.add_child(sprite)

	btn_row.add_child(daily_btn)

	var info_label := Label.new()
	info_label.name = "DailyInfo"
	info_label.theme_type_variation = &"HudLabel"
	info_label.add_theme_font_size_override("font_size", 11)
	btn_row.add_child(info_label)

	section.add_child(btn_row)

	var insert_idx := inventory_label.get_index()
	vbox.add_child(section)
	vbox.move_child(section, insert_idx)


func _update_daily_bonus_ui() -> void:
	var section_node: VBoxContainer = vbox.get_node_or_null("DailyBonusSection")
	if section_node == null:
		return
	var daily_btn: Button = section_node.get_node("DailyRow/DailyBtn")
	var info_label: Label = section_node.get_node("DailyRow/DailyInfo")

	if PlayerData.can_claim_daily():
		daily_btn.disabled = false
		daily_btn.modulate = Color.WHITE
		var next_reward := PlayerData.get_daily_bonus_amount()
		info_label.text = "Daily Bonus: +%s\nStreak: %d days\nClick to claim!" % [
			PlayerData.format_number(next_reward), PlayerData.get_daily_streak()]
	else:
		daily_btn.disabled = true
		daily_btn.modulate = Color(0.5, 0.5, 0.5)
		var cooldown := PlayerData.get_daily_cooldown_remaining()
		info_label.text = "Daily Bonus: claimed!\nStreak: %d days\nNext in: %s" % [
			PlayerData.get_daily_streak(), FormatUtils.format_duration(cooldown)]


func _on_claim_daily_bonus() -> void:
	var reward := PlayerData.claim_daily_bonus()
	if reward > 0:
		var popup := AcceptDialog.new()
		popup.title = "Daily Bonus!"
		popup.dialog_text = "Day %d streak! +%d coins!" % [PlayerData.get_daily_streak(), reward]
		popup.confirmed.connect(func():
			popup.queue_free()
			_refresh_display()
		)
		add_child(popup)
		popup.popup_centered()
		_refresh_display()


## ── Private: Streak Label ────────────────────────────────────────


func _build_streak_label() -> void:
	if vbox.has_node("StreakLabel"):
		return

	var streak_lbl := Label.new()
	streak_lbl.name = "StreakLabel"
	streak_lbl.theme_type_variation = &"HudLabel"
	streak_lbl.add_theme_font_size_override("font_size", 11)

	var insert_idx := inventory_label.get_index() + 1
	vbox.add_child(streak_lbl)
	vbox.move_child(streak_lbl, insert_idx)


func _update_streak_label() -> void:
	var streak_lbl: Label = vbox.get_node_or_null("StreakLabel")
	if streak_lbl == null:
		return
	streak_lbl.text = "   🔥 Win Streak: %d (Best: %d)  |  Mining: %d (Best: %d)" % [
		Achievements._current_streak, Achievements.best_win_streak,
		Achievements._current_mining_streak, Achievements.best_mining_streak]


## ── Private: Button handlers ─────────────────────────────────────


func _on_town_pressed() -> void:
	_get_navigator().navigate_to("town")


func _on_inventory_pressed() -> void:
	_get_navigator().navigate_to("inventory")


func _on_marketplace_pressed() -> void:
	_get_navigator().navigate_to("marketplace")


func _on_achievements_pressed() -> void:
	_get_navigator().navigate_to("achievements")


func _on_play_game_pressed() -> void:
	if PlayerData.level < 4:
		coin_label.text = "Coins: %s  (Unlocks at Lv.4!)" % PlayerData.format_number(PlayerData.coins)
		return
	if PlayerData.get_inventory_size() == 0:
		coin_label.text = "Coins: %s  (Buy tiles first!)" % PlayerData.format_number(PlayerData.coins)
		return
	_get_navigator().navigate_to("setup")


func _on_online_battle_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/multiplayer/multiplayer_menu.tscn")


## ── Name prompt (first launch) ───────────────────────────────────


## Shows the name prompt. `reason` empty = first launch (then starts the
## tutorial). Non-empty = the current name can't be claimed online and the
## player must pick a new one (free). Only one prompt is shown at a time.
func _show_name_prompt(reason: String = "") -> void:
	if get_node_or_null("NamePrompt") != null:
		return
	var is_repick := reason != ""
	var popup := Window.new()
	popup.name = "NamePrompt"
	popup.title = "Choose a New Name" if is_repick else "Welcome!"
	popup.size = Vector2i(360, 350)
	popup.unresizable = true
	popup.always_on_top = true

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup.add_child(panel)

	var vbox_prompt := VBoxContainer.new()
	vbox_prompt.add_theme_constant_override("separation", 10)
	panel.add_child(vbox_prompt)

	var title_lbl := Label.new()
	title_lbl.text = "Choose Your Name"
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox_prompt.add_child(title_lbl)

	var info_lbl := Label.new()
	if is_repick:
		info_lbl.text = "Your name \"%s\" can't be used online:\n%s\nPick a new one — it's free." % [
			PlayerData.player_name, reason]
	else:
		info_lbl.text = "This is your name in the game and the online market.\nPlease keep it friendly — no profanity!"
	info_lbl.add_theme_font_size_override("font_size", 11)
	info_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox_prompt.add_child(info_lbl)

	var name_input := LineEdit.new()
	name_input.placeholder_text = "Enter your name (2-16 characters)"
	name_input.max_length = 16
	name_input.add_theme_font_size_override("font_size", 14)
	name_input.custom_minimum_size.y = 40
	vbox_prompt.add_child(name_input)

	var error_lbl := Label.new()
	error_lbl.name = "ErrorLabel"
	error_lbl.add_theme_font_size_override("font_size", 11)
	error_lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	error_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox_prompt.add_child(error_lbl)

	var confirm_btn := Button.new()
	confirm_btn.text = "Confirm"
	confirm_btn.add_theme_font_size_override("font_size", 14)
	confirm_btn.custom_minimum_size.y = 40
	vbox_prompt.add_child(confirm_btn)

	confirm_btn.pressed.connect(func():
		## Checks the name online (unique + rules) and reserves it. Offline:
		## saved locally and reserved the next time the game is online.
		confirm_btn.disabled = true
		error_lbl.text = "Checking name…"
		var result: String = await PlayerData.claim_initial_name(name_input.text)
		if not is_instance_valid(popup):
			return
		confirm_btn.disabled = false
		if result != "":
			error_lbl.text = result
			return
		popup.queue_free()
		_refresh_display()
		if is_repick:
			return
		PlayerData.tutorial_home_dismissed = true
		PlayerData.save_data()
		## Start the tutorial after the popup fully closes (deferred so the
		## Window is out of the tree before the overlay is added).
		var ts := get_node_or_null("/root/TutorialSystem")
		if ts != null and ts.has_method("start_tutorial"):
			ts.call_deferred("start_tutorial")
	)

	## Returning player (lost phone / reinstall)? Restore instead of starting a
	## new account — the restored account's name becomes their name.
	var account_restore_btn := Button.new()
	account_restore_btn.text = "🔑 I have a recovery code"
	account_restore_btn.add_theme_font_size_override("font_size", 12)
	account_restore_btn.custom_minimum_size.y = 34
	vbox_prompt.add_child(account_restore_btn)
	account_restore_btn.pressed.connect(func():
		_show_restore_account_popup(func(_name: String):
			if is_instance_valid(popup):
				popup.queue_free()
			_refresh_display()
			## Returning player: skip the new-player tutorial prompt.
			PlayerData.tutorial_home_dismissed = true
			PlayerData.save_data()))

	popup.close_requested.connect(func():
		error_lbl.text = "Please enter a name to continue."
	)

	add_child(popup)
	popup.popup_centered()


## ── Restore account (recovery code) ──────────────────────────────

## Popup where a player enters their recovery code to move their online
## account (tokens, listings, guild, name) onto this device. `on_restored(name)`
## runs after a successful restore.
func _show_restore_account_popup(on_restored: Callable = Callable()) -> void:
	if get_node_or_null("RestorePopup") != null:
		return
	var popup := Window.new()
	popup.name = "RestorePopup"
	popup.title = "Restore Account"
	popup.size = Vector2i(360, 320)
	popup.unresizable = true
	popup.always_on_top = true

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var info := Label.new()
	info.text = "Enter the recovery code you saved when your account was created.\nThis moves your online account (name, tokens, listings, guild) to this device."
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_theme_font_size_override("font_size", 11)
	box.add_child(info)

	var code_input := LineEdit.new()
	code_input.placeholder_text = "Recovery code"
	code_input.max_length = 32
	code_input.add_theme_font_size_override("font_size", 14)
	code_input.custom_minimum_size.y = 40
	box.add_child(code_input)

	var status := Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_font_size_override("font_size", 11)
	status.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	box.add_child(status)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(0, 40)
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(popup.queue_free)
	row.add_child(cancel_btn)
	var go_btn := Button.new()
	go_btn.text = "Restore"
	go_btn.custom_minimum_size = Vector2(0, 40)
	go_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(go_btn)

	go_btn.pressed.connect(func():
		if get_node_or_null("/root/MarketplaceAccount") == null:
			status.text = "Online accounts are unavailable."
			return
		go_btn.disabled = true
		status.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
		status.text = "Restoring…"
		var res: Dictionary = await MarketplaceAccount.restore_from_code(code_input.text)
		if not is_instance_valid(popup):
			return
		go_btn.disabled = false
		if not res.get("ok", false):
			status.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			status.text = str(res.get("error", "Restore failed."))
			return
		popup.queue_free()
		if get_node_or_null("/root/GameNotification") != null:
			GameNotification.show_message("Account restored ✅",
				"Welcome back, %s! (%s tokens)" % [str(res.get("username", "")),
				PlayerData.format_number(int(res.get("token_balance", 0)))])
		_refresh_display()
		if on_restored.is_valid():
			on_restored.call(str(res.get("username", ""))))
	popup.close_requested.connect(popup.queue_free)

	add_child(popup)
	popup.popup_centered()


## ── Cash Stash Cheat Popup ───────────────────────────────────────


func _show_cash_stash_popup(cheat_input: LineEdit, cheat_msg: Label) -> void:
	var remaining := PlayerData.CASH_STASH_LIFETIME_CAP - PlayerData.cash_stash_lifetime_granted
	var popup := Window.new()
	popup.title = "💰 Sloth's Cash Stash"
	popup.size = Vector2i(340, 240)
	popup.unresizable = true
	popup.always_on_top = true

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup.add_child(panel)

	var vbox_stash := VBoxContainer.new()
	vbox_stash.add_theme_constant_override("separation", 10)
	panel.add_child(vbox_stash)

	var info_lbl := Label.new()
	info_lbl.text = "Enter an amount between 1 and 5,000,000.\n(Lifetime remaining: %s coins)" % PlayerData.format_number(remaining)
	info_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_lbl.add_theme_font_size_override("font_size", 12)
	vbox_stash.add_child(info_lbl)

	var amount_input := LineEdit.new()
	amount_input.placeholder_text = "e.g. 500k, 2.5m, 1000000"
	amount_input.max_length = 10
	amount_input.add_theme_font_size_override("font_size", 14)
	amount_input.custom_minimum_size.y = 40
	vbox_stash.add_child(amount_input)

	var error_lbl := Label.new()
	error_lbl.add_theme_font_size_override("font_size", 11)
	error_lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	error_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox_stash.add_child(error_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	vbox_stash.add_child(btn_row)

	var confirm_btn := Button.new()
	confirm_btn.text = "Confirm"
	confirm_btn.custom_minimum_size = Vector2(110, 36)
	confirm_btn.add_theme_font_size_override("font_size", 13)
	btn_row.add_child(confirm_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(110, 36)
	cancel_btn.add_theme_font_size_override("font_size", 13)
	btn_row.add_child(cancel_btn)

	confirm_btn.pressed.connect(func():
		var text := amount_input.text.strip_edges()
		var amount := _parse_shorthand_number(text)
		if amount < 0:
			error_lbl.text = "Invalid format. Try: 500k, 2.5m, 1000000"
			return
		var granted := PlayerData.redeem_cash_stash("SlothsCashStash", amount)
		if granted < 0:
			error_lbl.text = "Amount must be between 1 and 5,000,000."
			return
		cheat_input.text = ""
		if granted < amount:
			cheat_msg.text = "You requested more than you had available.\nGranted remaining balance: %s" % PlayerData.format_number(granted)
		else:
			cheat_msg.text = "✅ %s coins granted!" % PlayerData.format_number(granted)
		cheat_msg.add_theme_color_override("font_color", Color(0.0, 0.213, 0.006, 1.0))
		popup.queue_free()
	)

	cancel_btn.pressed.connect(popup.queue_free)
	popup.close_requested.connect(popup.queue_free)

	add_child(popup)
	popup.popup_centered()


## ── Shorthand Number Parser ──────────────────────────────────────


func _parse_shorthand_number(text: String) -> int:
	if text.is_empty():
		return -1
	var lower := text.to_lower().strip_edges()
	var multiplier := 1
	var numeric := lower
	if lower.ends_with("m"):
		multiplier = 1_000_000
		numeric = lower.left(lower.length() - 1)
	elif lower.ends_with("k"):
		multiplier = 1_000
		numeric = lower.left(lower.length() - 1)
	if not numeric.is_valid_float():
		return -1
	var value := int(numeric.to_float() * multiplier)
	return value
