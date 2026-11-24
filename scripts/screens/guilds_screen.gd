extends BaseScreen
## Guilds lobby screen.
## Shows two states:
##   • Not in a guild → search / browse / create panel
##   • In a guild     → navigate straight to guild_detail
##
## Requirements: Guilds §7 (client structure), §2.1 (create), §2.1 join/leave lifecycle.

@onready var _vbox: VBoxContainer = $MarginContainer/VBox
@onready var _status_label: Label = $MarginContainer/VBox/StatusLabel
@onready var _loading_label: Label = $MarginContainer/VBox/LoadingLabel
@onready var _in_guild_panel: VBoxContainer = $MarginContainer/VBox/InGuildPanel
@onready var _no_guild_panel: VBoxContainer = $MarginContainer/VBox/NoGuildPanel

# In-guild panel widgets
@onready var _guild_name_label: Label = $MarginContainer/VBox/InGuildPanel/GuildNameLabel
@onready var _guild_spec_label: Label = $MarginContainer/VBox/InGuildPanel/GuildSpecLabel
@onready var _guild_members_label: Label = $MarginContainer/VBox/InGuildPanel/GuildMembersLabel
@onready var _open_guild_btn: Button = $MarginContainer/VBox/InGuildPanel/OpenGuildBtn
@onready var _leave_guild_btn: Button = $MarginContainer/VBox/InGuildPanel/LeaveGuildBtn

# No-guild panel widgets
@onready var _search_field: LineEdit = $MarginContainer/VBox/NoGuildPanel/SearchHBox/SearchField
@onready var _spec_filter_btn: OptionButton = $MarginContainer/VBox/NoGuildPanel/SearchHBox/SpecFilter
@onready var _search_btn: Button = $MarginContainer/VBox/NoGuildPanel/SearchHBox/SearchBtn
@onready var _results_list: VBoxContainer = $MarginContainer/VBox/NoGuildPanel/ResultsList
@onready var _create_btn: Button = $MarginContainer/VBox/NoGuildPanel/CreateBtn
@onready var _back_btn: Button = $MarginContainer/VBox/BackBtn


func get_screen_name() -> String:
	return "guilds"


func enter(_params: Dictionary = {}) -> void:
	## FAST-PATH: if cached membership already says we're in a guild, go straight
	## to the detail screen on this very frame — never render the lobby (which
	## contains the Create button) for an in-guild player, not even briefly.
	## Fast keyboard users must not get a window to start a second guild.
	if get_node_or_null("/root/GuildManager") != null and GuildManager.is_in_guild():
		_get_navigator().navigate_to("guild_detail")
		return

	if not GuildManager.guild_data_changed.is_connected(_refresh_ui):
		GuildManager.guild_data_changed.connect(_refresh_ui)

	_back_btn.pressed.connect(_on_back_pressed)
	_open_guild_btn.pressed.connect(_on_open_guild_pressed)
	## Leave/Disband moved to the guild_detail Roster panel (this lobby's
	## InGuildPanel is bypassed — enter() redirects straight to guild_detail when
	## already in a guild). Button kept in the scene but permanently hidden.
	_leave_guild_btn.visible = false
	_search_btn.pressed.connect(_on_search_pressed)
	_create_btn.pressed.connect(_on_create_pressed)

	## Populate the spec filter once (All / Gardening / Mining / Horse). The
	## match blocks in _on_search_pressed / recommendations read get_item_text.
	if _spec_filter_btn.item_count == 0:
		_spec_filter_btn.add_item("All")
		_spec_filter_btn.add_item("Gardening")
		_spec_filter_btn.add_item("Mining")
		_spec_filter_btn.add_item("Horse")

	## Hide BOTH panels (show only the loading label) until the refresh resolves,
	## so the Create panel can't flash during the await for a stale/slow state.
	_show_loading(true)
	await GuildManager.refresh_all()

	## Membership may have resolved to "in a guild" after the refresh (e.g. the
	## cache was empty on entry). Jump to the detail screen rather than showing
	## the lobby + Create button for a frame.
	if GuildManager.is_in_guild():
		_get_navigator().navigate_to("guild_detail")
		return

	_show_loading(false)
	_refresh_ui()


func exit() -> void:
	if GuildManager.guild_data_changed.is_connected(_refresh_ui):
		GuildManager.guild_data_changed.disconnect(_refresh_ui)


# ── UI ──────────────────────────────────────────────────────────

func _refresh_ui() -> void:
	var in_guild := GuildManager.is_in_guild()
	_in_guild_panel.visible = in_guild
	_no_guild_panel.visible = not in_guild
	# The create button lives in NoGuildPanel, so it is already hidden while in
	# a guild; set it explicitly too so a late/stale state can't leave it shown.
	_create_btn.visible = not in_guild
	_status_label.visible = false

	if in_guild:
		_guild_name_label.text = GuildManager.guild_name()
		var spec := GuildManager.guild_specialization()
		_guild_spec_label.text = "Specialization: %s" % spec.capitalize()
		_guild_members_label.text = "%d / %d members" % [
			GuildManager.guild_member_count(), GuildManager.guild_capacity()]
		## Leave/Disband now lives on the guild_detail Roster panel.
		_leave_guild_btn.visible = false
	else:
		# Not in a guild: recommend the most active guilds to join, unless the
		# player has an active search typed in (don't clobber their results).
		if _search_field.text.strip_edges() == "":
			_show_recommended_guilds()
		_refresh_sale_panel()


# ── Your guild for sale (migration 103) ─────────────────────────

var _sale_panel: VBoxContainer = null
var _sale_loading := false


## Shows a "Your guild is for sale" box with a Reclaim button at the top of the
## lobby when the player has a guild listed, and disables Create meanwhile.
func _refresh_sale_panel() -> void:
	if _sale_loading:
		return
	_sale_loading = true
	var res := await GuildManager.get_guild_sales()
	_sale_loading = false
	if not is_instance_valid(_no_guild_panel) or GuildManager.is_in_guild():
		return
	var mine: Dictionary = res.get("my_listing", {})
	if is_instance_valid(_sale_panel):
		_sale_panel.queue_free()
		_sale_panel = null
	if mine.is_empty():
		_create_btn.disabled = false
		_create_btn.text = "+ Create a Guild"
		return

	_create_btn.disabled = true
	_create_btn.text = "Can't create a guild while yours is for sale"

	_sale_panel = VBoxContainer.new()
	_sale_panel.add_theme_constant_override("separation", 6)
	var hdr := Label.new()
	hdr.text = "💰 Your guild \"%s\" is for sale" % str(mine.get("name", "?"))
	hdr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hdr.add_theme_font_size_override("font_size", 13)
	hdr.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	_sale_panel.add_child(hdr)
	var info := Label.new()
	var fee := int(mine.get("reclaim_fee", 10000))
	info.text = "Asking %s tokens. When it sells, the tokens are paid to you. To take it back now, reclaim it for %s tokens (you must not be in another guild)." % [
		PlayerData.format_number(int(mine.get("price", 0))), PlayerData.format_number(fee)]
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_font_size_override("font_size", 11)
	_sale_panel.add_child(info)
	var btn := Button.new()
	btn.text = "Reclaim guild (%s tokens)" % PlayerData.format_number(fee)
	btn.custom_minimum_size = Vector2(0, 40)
	btn.add_theme_font_size_override("font_size", 12)
	btn.pressed.connect(_on_reclaim_pressed.bind(fee, btn))
	_sale_panel.add_child(btn)
	_sale_panel.add_child(HSeparator.new())
	_no_guild_panel.add_child(_sale_panel)
	_no_guild_panel.move_child(_sale_panel, 0)


func _on_reclaim_pressed(fee: int, btn: Button) -> void:
	if get_node_or_null("/root/MarketplaceAccount") != null and MarketplaceAccount.token_balance < fee:
		_show_status("You need %s tokens to reclaim your guild." % PlayerData.format_number(fee), false)
		return
	btn.disabled = true
	var res := await GuildManager.reclaim_guild()
	if res.get("ok", false):
		GameNotification.show_message("Guild Reclaimed",
			"You're back in charge of \"%s\"." % str(res.get("guild_name", "your guild")))
		_get_navigator().navigate_to("guild_detail")
	else:
		btn.disabled = false
		_show_status(str(res.get("error", "Couldn't reclaim the guild.")), false)


func _show_loading(on: bool) -> void:
	_loading_label.visible = on
	_in_guild_panel.visible = false
	_no_guild_panel.visible = false


func _show_status(msg: String, ok: bool = true) -> void:
	_status_label.visible = true
	_status_label.text = msg
	_status_label.add_theme_color_override("font_color",
		Color(0.3, 1.0, 0.3) if ok else Color(1.0, 0.35, 0.35))


# ── Handlers ────────────────────────────────────────────────────

func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


func _on_open_guild_pressed() -> void:
	_get_navigator().navigate_to("guild_detail")


## NOTE: Leave/Disband moved to the guild_detail Roster panel; the old handlers
## here were removed with the bypassed InGuildPanel button.


func _on_search_pressed() -> void:
	var query := _search_field.text.strip_edges()
	var spec := ""
	match _spec_filter_btn.get_item_text(_spec_filter_btn.selected):
		"Gardening": spec = "gardening"
		"Mining":    spec = "mining"
		"Horse":     spec = "horse"

	# An empty search just shows the recommended (most active) guilds.
	if query == "":
		_show_recommended_guilds()
		return

	_clear_results()
	var label := Label.new()
	label.text = "Searching…"
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color.WHITE)
	_results_list.add_child(label)

	var res := await GuildManager.search_guilds(query, spec)
	_clear_results()

	if not res.get("ok", false):
		var err_lbl := Label.new()
		err_lbl.text = "Search failed: %s" % res.get("error", "")
		err_lbl.add_theme_font_size_override("font_size", 12)
		err_lbl.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
		_results_list.add_child(err_lbl)
		return

	var guilds: Array = res.get("guilds", [])
	if guilds.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No guilds found."
		empty_lbl.add_theme_font_size_override("font_size", 12)
		empty_lbl.add_theme_color_override("font_color", Color.WHITE)
		_results_list.add_child(empty_lbl)
		return

	for g in guilds:
		if not g is Dictionary:
			continue
		_results_list.add_child(_make_guild_row(g))


## Guards against overlapping recommendation loads (re-entrant _refresh_ui).
var _loading_recommendations := false

## Loads and displays the top-10 most active guilds as join suggestions. Shown
## by default (no search typed) when the player isn't in a guild.
func _show_recommended_guilds() -> void:
	if _loading_recommendations:
		return
	_loading_recommendations = true

	# Honor the spec filter dropdown so recommendations match the chosen spec.
	var spec := ""
	match _spec_filter_btn.get_item_text(_spec_filter_btn.selected):
		"Gardening": spec = "gardening"
		"Mining":    spec = "mining"
		"Horse":     spec = "horse"

	_clear_results()
	var loading_lbl := Label.new()
	loading_lbl.text = "Finding active guilds…"
	loading_lbl.add_theme_font_size_override("font_size", 12)
	loading_lbl.add_theme_color_override("font_color", Color.WHITE)
	_results_list.add_child(loading_lbl)

	var res := await GuildManager.get_top_active_guilds(spec, 10)
	_loading_recommendations = false

	# The player may have joined/searched or left the screen during the await.
	if not is_instance_valid(_results_list) or GuildManager.is_in_guild():
		return
	if _search_field.text.strip_edges() != "":
		return  # a search took over; don't overwrite it
	_clear_results()

	if not res.get("ok", false):
		# Non-fatal: recommendations are a convenience. Let search still work.
		var err_lbl := Label.new()
		err_lbl.text = "Couldn't load suggestions. Try searching above."
		err_lbl.add_theme_font_size_override("font_size", 12)
		err_lbl.add_theme_color_override("font_color", Color(1.0, 0.6, 0.4))
		_results_list.add_child(err_lbl)
		return

	var guilds: Array = res.get("guilds", [])
	if guilds.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No guilds to recommend yet.\nSearch above, or create your own!"
		empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_font_size_override("font_size", 12)
		empty_lbl.add_theme_color_override("font_color", Color.WHITE)
		_results_list.add_child(empty_lbl)
		return

	var header := Label.new()
	header.text = "⭐ Recommended — most active guilds"
	header.add_theme_font_size_override("font_size", 12)
	header.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_results_list.add_child(header)

	for g in guilds:
		if g is Dictionary:
			_results_list.add_child(_make_guild_row(g))


func _clear_results() -> void:
	for c in _results_list.get_children():
		c.queue_free()


func _make_guild_row(g: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_lbl := Label.new()
	name_lbl.text = str(g.get("name", "Unknown"))
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	info.add_child(name_lbl)

	var detail_lbl := Label.new()
	var spec := str(g.get("specialization", "")).capitalize()
	var members := int(g.get("member_count", 0))
	var cap := int(g.get("capacity", 5))
	detail_lbl.text = "%s · %d/%d members" % [spec, members, cap]
	detail_lbl.add_theme_font_size_override("font_size", 10)
	detail_lbl.add_theme_color_override("font_color", Color.WHITE)
	info.add_child(detail_lbl)

	row.add_child(info)

	var full := members >= cap
	var join_btn := Button.new()
	join_btn.text = "Full" if full else "Join"
	join_btn.disabled = full
	join_btn.custom_minimum_size = Vector2(60, 32)
	join_btn.add_theme_font_size_override("font_size", 12)
	var gid := str(g.get("id", ""))
	join_btn.pressed.connect(_on_join_pressed.bind(gid, str(g.get("name", "")), join_btn))
	row.add_child(join_btn)

	var sep := HSeparator.new()
	var wrapper := VBoxContainer.new()
	wrapper.add_child(row)
	wrapper.add_child(sep)
	return wrapper


func _on_join_pressed(gid: String, gname: String, btn: Button) -> void:
	btn.disabled = true
	var confirm := ConfirmationDialog.new()
	confirm.title = "Join Guild?"
	confirm.dialog_text = "Join \"%s\"?" % gname
	confirm.ok_button_text = "Join"
	add_child(confirm)
	confirm.confirmed.connect(_do_join.bind(gid, gname, btn, confirm))
	confirm.canceled.connect(func():
		btn.disabled = false
		confirm.queue_free())
	confirm.popup_centered()


func _do_join(gid: String, _gname: String, btn: Button, confirm: ConfirmationDialog) -> void:
	confirm.queue_free()
	_show_loading(true)
	var res := await GuildManager.join_guild(gid)
	_show_loading(false)
	if not res.get("ok", false):
		btn.disabled = false
		_show_status("Could not join: %s" % res.get("error", "Unknown error."), false)
	else:
		_refresh_ui()
		# Immediately open the detail screen on successful join
		_get_navigator().navigate_to("guild_detail")


func _on_create_pressed() -> void:
	# Defensive: the button is hidden while in a guild, but never open the
	# create flow if membership state says we're already in one.
	if GuildManager.is_in_guild():
		_show_status("You're already in a guild.", false)
		_refresh_ui()
		return
	_show_create_popup()


func _show_create_popup() -> void:
	var popup := Window.new()
	popup.title = "Create a Guild"
	popup.size = Vector2i(340, 260)
	popup.unresizable = true
	popup.always_on_top = true

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	var title_lbl := Label.new()
	title_lbl.text = "Create a Guild"
	title_lbl.add_theme_font_size_override("font_size", 15)
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_color_override("font_color", Color.WHITE)
	vb.add_child(title_lbl)

	# Cost label — shows "Fetching cost…" until the RPC returns.
	var cost_lbl := Label.new()
	cost_lbl.text = "Cost: fetching…"
	cost_lbl.add_theme_font_size_override("font_size", 12)
	cost_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(cost_lbl)

	var name_field := LineEdit.new()
	name_field.placeholder_text = "Guild name (3–32 characters)"
	name_field.max_length = 32
	name_field.add_theme_font_size_override("font_size", 13)
	name_field.custom_minimum_size.y = 38
	vb.add_child(name_field)

	var spec_lbl := Label.new()
	spec_lbl.text = "Specialization:"
	spec_lbl.add_theme_font_size_override("font_size", 12)
	spec_lbl.add_theme_color_override("font_color", Color.WHITE)
	vb.add_child(spec_lbl)

	# Specialization picker as a two-button segmented toggle instead of an
	# OptionButton. The OptionButton's dropdown popup was being clipped/hidden
	# inside this small always-on-top Window, so "Mining" (the 2nd item) never
	# appeared when tapped. Two always-visible toggle buttons avoid the popup
	# entirely and read better on touch.
	var spec_group := ButtonGroup.new()
	var spec_row := HBoxContainer.new()
	spec_row.add_theme_constant_override("separation", 8)
	vb.add_child(spec_row)

	var garden_btn := Button.new()
	garden_btn.text = "🌿 Gardening"
	garden_btn.toggle_mode = true
	garden_btn.button_group = spec_group
	garden_btn.button_pressed = true  # default selection
	garden_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	garden_btn.custom_minimum_size.y = 40
	garden_btn.add_theme_font_size_override("font_size", 13)
	spec_row.add_child(garden_btn)

	var mining_btn := Button.new()
	mining_btn.text = "⛏ Mining"
	mining_btn.toggle_mode = true
	mining_btn.button_group = spec_group
	mining_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mining_btn.custom_minimum_size.y = 40
	mining_btn.add_theme_font_size_override("font_size", 13)
	spec_row.add_child(mining_btn)

	var horse_btn := Button.new()
	horse_btn.text = "🐎 Horse"
	horse_btn.toggle_mode = true
	horse_btn.button_group = spec_group
	horse_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	horse_btn.custom_minimum_size.y = 40
	horse_btn.add_theme_font_size_override("font_size", 13)
	spec_row.add_child(horse_btn)

	# Capacity info — fixed default, upgradeable later in the guild
	var cap_info := Label.new()
	cap_info.text = "Starts at 5 members — upgradeable up to 20"
	cap_info.add_theme_font_size_override("font_size", 11)
	cap_info.add_theme_color_override("font_color", Color.WHITE)
	cap_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(cap_info)

	var error_lbl := Label.new()
	error_lbl.add_theme_font_size_override("font_size", 11)
	error_lbl.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	error_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(error_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vb.add_child(btn_row)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.custom_minimum_size.y = 36
	cancel_btn.pressed.connect(popup.queue_free)
	btn_row.add_child(cancel_btn)

	var confirm_btn := Button.new()
	confirm_btn.text = "Create"
	confirm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm_btn.custom_minimum_size.y = 36
	confirm_btn.disabled = true  # disabled until cost is fetched
	btn_row.add_child(confirm_btn)

	# Fetch the creation cost and update the label / button state.
	_fetch_and_show_creation_cost(cost_lbl, confirm_btn)

	confirm_btn.pressed.connect(func():
		var gname := name_field.text.strip_edges()
		var spec_str := "gardening"
		if mining_btn.button_pressed:
			spec_str = "mining"
		elif horse_btn.button_pressed:
			spec_str = "horse"
		confirm_btn.disabled = true
		var res := await GuildManager.create_guild(gname, spec_str)
		confirm_btn.disabled = false
		if not res.get("ok", false):
			error_lbl.text = res.get("error", "Failed.")
		else:
			popup.queue_free()
			_get_navigator().navigate_to("guild_detail")
	)

	popup.close_requested.connect(popup.queue_free)
	add_child(popup)
	popup.popup_centered()


## Fetches the guild creation cost and updates the popup label + confirm button.
func _fetch_and_show_creation_cost(cost_lbl: Label, confirm_btn: Button) -> void:
	var res := await GuildManager.get_guild_creation_cost()
	if not is_instance_valid(cost_lbl):
		return
	if not res.get("ok", false):
		cost_lbl.text = "Cost: unavailable"
		cost_lbl.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
		if is_instance_valid(confirm_btn):
			confirm_btn.disabled = false  # let them try anyway; server will reject if needed
		return
	var cost: int = res.get("cost", 0)
	var can_afford := PlayerData.coins >= cost
	cost_lbl.text = "Cost: %s coins  (you have: %s)" % [
		PlayerData.format_number(cost),
		PlayerData.format_number(PlayerData.coins),
	]
	cost_lbl.add_theme_color_override("font_color",
		Color(0.4, 1.0, 0.5) if can_afford else Color(1.0, 0.35, 0.35))
	if is_instance_valid(confirm_btn):
		confirm_btn.disabled = false
