extends BaseScreen
## Guild Detail screen — shown when the player is already in a guild.
## Navigation is handled by beige buttons below the guild info summary.
## Sections (one visible at a time):
##   Missions  — list active guild missions, progress, accept/claim
##   Upgrades  — spend upgrade_points on guild perks (leader only)
##   Community — gardening guild: community garden stub
##               mining guild: community expedition stub
##   Linking   — view / request / accept guild links
##   Roster    — member list + kick (leader only)
##
## Requirements: Guilds §7 (suggested screens), §3 missions, §4 distribution,
##               §5 linking, §6 community garden, §2.6 expedition.

# ── Info section ────────────────────────────────────────────────
@onready var _loading_overlay: Label    = $LoadingOverlay
@onready var _home_guild_name: Label    = $MarginContainer/OuterVBox/InfoSection/GuildName
@onready var _home_spec: Label          = $MarginContainer/OuterVBox/InfoSection/SpecLabel
@onready var _home_members: Label       = $MarginContainer/OuterVBox/InfoSection/MembersLabel
@onready var _home_role: Label          = $MarginContainer/OuterVBox/InfoSection/RoleLabel
@onready var _home_upgrade_pts: Label   = $MarginContainer/OuterVBox/InfoSection/UpgradePointsLabel
@onready var _home_perks_status: Label  = $MarginContainer/OuterVBox/InfoSection/PerksStatusLabel
@onready var _home_mission_summary: Label = $MarginContainer/OuterVBox/InfoSection/MissionSummaryLabel
@onready var _home_refresh_btn: Button  = $MarginContainer/OuterVBox/InfoSection/RefreshBtn

# ── Nav buttons ─────────────────────────────────────────────────
@onready var _nav_missions: Button   = $MarginContainer/OuterVBox/NavRow/MissionsNavBtn
@onready var _nav_upgrades: Button   = $MarginContainer/OuterVBox/NavRow/UpgradesNavBtn
@onready var _nav_community: Button  = $MarginContainer/OuterVBox/NavRow/CommunityNavBtn
@onready var _nav_linking: Button    = $MarginContainer/OuterVBox/NavRow/LinkingNavBtn
@onready var _nav_roster: Button     = $MarginContainer/OuterVBox/NavRow/RosterNavBtn

# ── Section panels ───────────────────────────────────────────────
@onready var _missions_panel: VBoxContainer   = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/MissionsPanel
@onready var _upgrades_panel: VBoxContainer   = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/UpgradesPanel
@onready var _community_panel: VBoxContainer  = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/CommunityPanel
@onready var _linking_panel: VBoxContainer    = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/LinkingPanel
@onready var _roster_panel: VBoxContainer     = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/RosterPanel

# ── Missions panel nodes ─────────────────────────────────────────
@onready var _missions_list: VBoxContainer    = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/MissionsPanel/MissionsList
@onready var _missions_empty: Label           = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/MissionsPanel/EmptyLabel

# ── Upgrades panel nodes ─────────────────────────────────────────
@onready var _upgrades_list: VBoxContainer    = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/UpgradesPanel/UpgradesList
@onready var _upgrades_pts_label: Label       = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/UpgradesPanel/PointsLabel

# ── Community panel nodes ────────────────────────────────────────
@onready var _community_label: Label          = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/CommunityPanel/InfoLabel

## Holds the active GuildGardenUI instance (gardening guilds only).
## Torn down whenever the community panel is hidden or rebuilt.
var _guild_garden_ui: GuildGardenUI = null

## Holds the active GuildMineUI instance (mining guilds only).
## Torn down whenever the community panel is hidden or rebuilt.

var _guild_mine_ui: GuildMineUI = null

# ── Linking panel nodes ──────────────────────────────────────────
@onready var _linking_list: VBoxContainer     = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/LinkingPanel/LinksList
@onready var _link_search_field: LineEdit     = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/LinkingPanel/SearchHBox/SearchField
@onready var _link_search_btn: Button         = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/LinkingPanel/SearchHBox/SearchBtn
@onready var _link_results: VBoxContainer     = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/LinkingPanel/LinkResults

# ── Roster panel nodes ───────────────────────────────────────────
@onready var _roster_list: VBoxContainer      = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/RosterPanel/RosterList

# ── Stockpile panel nodes ────────────────────────────────────────
@onready var _nav_stockpile: Button           = $MarginContainer/OuterVBox/NavRow/StockpileNavBtn
@onready var _stockpile_panel: VBoxContainer   = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StockpilePanel
@onready var _stockpile_status: Label          = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StockpilePanel/StockpileStatus
@onready var _stockpile_empty: Label           = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StockpilePanel/StockpileEmpty
@onready var _stockpile_list: VBoxContainer     = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StockpilePanel/StockpileList
@onready var _stockpile_deposit_area: VBoxContainer = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StockpilePanel/DepositArea

## Stockpile-eligible categories (must match server _guild_stockpile_key_ok).
const _STOCKPILE_CATEGORIES: Array[String] = ["resource", "gem", "polished", "crop", "fruit"]

# ── Leaderboard panel nodes ──────────────────────────────────────
@onready var _nav_leaderboard: Button          = $MarginContainer/OuterVBox/NavRow/LeaderboardNavBtn
@onready var _leaderboard_panel: VBoxContainer  = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/LeaderboardPanel
@onready var _lb_players_tab: Button            = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/LeaderboardPanel/TabRow/PlayersTabBtn
@onready var _lb_guilds_tab: Button             = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/LeaderboardPanel/TabRow/GuildsTabBtn
@onready var _lb_empty: Label                   = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/LeaderboardPanel/LeaderboardEmpty
@onready var _lb_list: VBoxContainer            = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/LeaderboardPanel/LeaderboardList

## Which leaderboard tab is showing: "players" | "guilds".
var _lb_active_tab: String = "players"

# ── Production panel nodes ───────────────────────────────────────
@onready var _nav_production: Button          = $MarginContainer/OuterVBox/NavRow/ProductionNavBtn
@onready var _production_panel: VBoxContainer  = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/ProductionPanel
@onready var _prod_status: Label               = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/ProductionPanel/ProductionStatus
@onready var _prod_recipe_opt: OptionButton    = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/ProductionPanel/EnqueueRow/RecipeOption
@onready var _prod_enqueue_btn: Button         = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/ProductionPanel/EnqueueRow/EnqueueBtn
@onready var _prod_collect_btn: Button         = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/ProductionPanel/CollectBtn
@onready var _prod_empty: Label                = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/ProductionPanel/ProductionEmpty
@onready var _prod_list: VBoxContainer         = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/ProductionPanel/ProductionList

## Ticks the production countdowns while the Production panel is open.
var _prod_tick_timer: Timer = null
## Quantity SpinBox — added dynamically in _rebuild_production (not in the .tscn).
var _prod_qty_spin: SpinBox = null

# ── Store panel nodes ────────────────────────────────────────────
@onready var _nav_store: Button             = $MarginContainer/OuterVBox/NavRow/StoreNavBtn
@onready var _store_panel: VBoxContainer     = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel
@onready var _store_status: Label            = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/StoreStatus
@onready var _store_distribute_btn: Button   = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/DistributeBtn
@onready var _store_jewelry_opt: OptionButton = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/ListRow/JewelryOption
@onready var _store_qty_edit: LineEdit       = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/ListRow/QtyEdit
@onready var _store_price_edit: LineEdit     = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/ListRow/PriceEdit
@onready var _store_list_btn: Button         = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/ListRow/ListBtn
@onready var _store_empty: Label             = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/StoreEmpty
@onready var _store_list: VBoxContainer       = $MarginContainer/OuterVBox/ContentScroll/ContentVBox/StorePanel/StoreList

## Discount dropdown (100%..50% in 10% steps) built dynamically next to the
## PriceEdit so guilds can run sales. Selecting a step rewrites PriceEdit.
var _store_discount_opt: OptionButton = null

## The native JewelryOption popup doesn't scroll reliably on touch when the item
## list is long, so we hide it (it stays as the state holder — items/metadata/
## selected) and drive picking through a custom scrollable dialog opened by this
## button. The button's caption mirrors the current selection.
var _store_item_picker_btn: Button = null

# ── Back button ──────────────────────────────────────────────────
@onready var _back_btn: Button = $MarginContainer/OuterVBox/BackBtn

# Tracks which panel is currently visible (starts with none shown).
var _active_panel: VBoxContainer = null

## Live-update polling for the Missions panel. While that panel is open we poll
## the server on an interval so deposits (yours and teammates') and progress
## appear without hitting Refresh. We only rebuild the list when the mission
## data actually changed, so polling doesn't flicker the UI or steal focus from
## a quantity field mid-type.
const MISSIONS_POLL_INTERVAL_SEC := 5.0
var _missions_poll_timer: Timer = null
var _missions_signature: String = ""
## True while a poll's async refresh is in flight, to avoid overlapping polls.
var _missions_polling := false
## Set while the poll calls refresh_missions() so the guild_data_changed signal
## it emits doesn't trigger a full _rebuild_all (which would flicker the whole
## screen and steal focus every tick). The poll does its own change-gated
## rebuild of just the missions list instead.
var _suppress_data_changed_rebuild := false

## Cached guild reroll status (migration 066) for pricing the reroll buttons:
## { rerolls_used, next_cost, free_remaining, upgrade_points, is_leader }.
var _reroll_status: Dictionary = {}


func get_screen_name() -> String:
	return "guild_detail"


func enter(_params: Dictionary = {}) -> void:
	if not GuildManager.guild_data_changed.is_connected(_on_guild_data_changed):
		GuildManager.guild_data_changed.connect(_on_guild_data_changed)

	## Clip the content root so a wide dynamic row (e.g. a long store listing)
	## can never paint past the screen edge and drag the whole screen off to the
	## right. Defensive — rows also clip their own labels.
	var outer := $MarginContainer/OuterVBox as Control
	if outer != null:
		outer.clip_contents = true

	_back_btn.pressed.connect(_on_back_pressed)
	_home_refresh_btn.pressed.connect(_on_refresh_pressed)
	_link_search_btn.pressed.connect(_on_link_search_pressed)

	_nav_missions.pressed.connect(_show_section.bind(_missions_panel))
	_nav_upgrades.pressed.connect(_show_section.bind(_upgrades_panel))
	_nav_community.pressed.connect(_on_community_nav_pressed)
	_nav_linking.pressed.connect(_show_section.bind(_linking_panel))
	_nav_roster.pressed.connect(_show_section.bind(_roster_panel))
	_nav_stockpile.pressed.connect(_on_stockpile_nav_pressed)
	_nav_leaderboard.pressed.connect(_on_leaderboard_nav_pressed)
	_lb_players_tab.pressed.connect(_on_lb_tab_pressed.bind("players"))
	_lb_guilds_tab.pressed.connect(_on_lb_tab_pressed.bind("guilds"))
	_nav_production.pressed.connect(_on_production_nav_pressed)
	_prod_enqueue_btn.pressed.connect(_on_production_enqueue_pressed)
	_prod_collect_btn.pressed.connect(_on_production_collect_pressed)
	_nav_store.pressed.connect(_on_store_nav_pressed)
	_store_list_btn.pressed.connect(_on_store_list_pressed)
	_store_jewelry_opt.item_selected.connect(_store_jewelry_opt_changed)
	_store_distribute_btn.pressed.connect(_on_store_distribute_pressed)

	## Live countdown tick for the Production panel (1s).
	if _prod_tick_timer == null:
		_prod_tick_timer = Timer.new()
		_prod_tick_timer.wait_time = 1.0
		_prod_tick_timer.one_shot = false
		_prod_tick_timer.timeout.connect(_on_production_tick)
		add_child(_prod_tick_timer)

	if not GuildStockpile.stockpile_changed.is_connected(_on_stockpile_changed):
		GuildStockpile.stockpile_changed.connect(_on_stockpile_changed)
	if not GuildLeaderboard.leaderboard_changed.is_connected(_on_leaderboard_changed):
		GuildLeaderboard.leaderboard_changed.connect(_on_leaderboard_changed)
	if not GuildProduction.production_changed.is_connected(_on_production_changed):
		GuildProduction.production_changed.connect(_on_production_changed)
	if not GuildStore.store_changed.is_connected(_on_store_changed):
		GuildStore.store_changed.connect(_on_store_changed)
	## Benjamin balance drives the Rush buttons' enabled state. Refresh it live
	## when it changes so the buttons enable the moment the balance arrives
	## (fixes Rush being grayed out until the Money Gun screen is visited).
	if get_node_or_null("/root/MoneyGun") != null \
			and MoneyGun.has_signal("money_gun_changed") \
			and not MoneyGun.money_gun_changed.is_connected(_on_money_gun_changed):
		MoneyGun.money_gun_changed.connect(_on_money_gun_changed)
	## Local inventory changes (claiming/crafting jewelry, depositing) must
	## refresh the Store "List Jewelry" dropdown + the Stockpile deposit UI,
	## which are both built from the player's current local inventory.
	if not PlayerData.data_changed.is_connected(_on_local_inventory_changed):
		PlayerData.data_changed.connect(_on_local_inventory_changed)

	# Live-update timer for the Missions panel (started by _show_section).
	if _missions_poll_timer == null:
		_missions_poll_timer = Timer.new()
		_missions_poll_timer.wait_time = MISSIONS_POLL_INTERVAL_SEC
		_missions_poll_timer.one_shot = false
		_missions_poll_timer.timeout.connect(_on_missions_poll_tick)
		add_child(_missions_poll_timer)

	_show_loading(true)
	await GuildManager.refresh_all()
	await GuildManager.refresh_missions()
	await _refresh_reroll_status()
	_show_loading(false)

	if not GuildManager.is_in_guild():
		_get_navigator().navigate_to("guilds")
		return

	_rebuild_all()  ## _rebuild_missions() inside also seeds _missions_signature
	# Default to Missions section open
	_show_section(_missions_panel)

	## Pull the current Benjamin balance so Rush buttons reflect it on first
	## load (without needing to visit the Money Gun screen first). Fire-and-
	## forget; _on_money_gun_changed re-applies the Rush buttons when it lands.
	if get_node_or_null("/root/MoneyGun") != null and MoneyGun.has_method("refresh"):
		MoneyGun.refresh()


func exit() -> void:
	if GuildManager.guild_data_changed.is_connected(_on_guild_data_changed):
		GuildManager.guild_data_changed.disconnect(_on_guild_data_changed)
	if GuildStockpile.stockpile_changed.is_connected(_on_stockpile_changed):
		GuildStockpile.stockpile_changed.disconnect(_on_stockpile_changed)
	if GuildLeaderboard.leaderboard_changed.is_connected(_on_leaderboard_changed):
		GuildLeaderboard.leaderboard_changed.disconnect(_on_leaderboard_changed)
	if GuildProduction.production_changed.is_connected(_on_production_changed):
		GuildProduction.production_changed.disconnect(_on_production_changed)
	if GuildStore.store_changed.is_connected(_on_store_changed):
		GuildStore.store_changed.disconnect(_on_store_changed)
	if get_node_or_null("/root/MoneyGun") != null \
			and MoneyGun.has_signal("money_gun_changed") \
			and MoneyGun.money_gun_changed.is_connected(_on_money_gun_changed):
		MoneyGun.money_gun_changed.disconnect(_on_money_gun_changed)
	if PlayerData.data_changed.is_connected(_on_local_inventory_changed):
		PlayerData.data_changed.disconnect(_on_local_inventory_changed)
	if is_instance_valid(_prod_tick_timer):
		_prod_tick_timer.stop()
	if is_instance_valid(_missions_poll_timer):
		_missions_poll_timer.stop()
	if is_instance_valid(_guild_garden_ui):
		_guild_garden_ui.teardown()
		_guild_garden_ui.queue_free()
		_guild_garden_ui = null
	if is_instance_valid(_guild_mine_ui):
		_guild_mine_ui.teardown()
		_guild_mine_ui.queue_free()
		_guild_mine_ui = null


# ── Section visibility ────────────────────────────────────────────

func _show_section(panel: VBoxContainer) -> void:
	if is_instance_valid(_active_panel):
		_active_panel.visible = false
	## Tear down the community garden/mine UI when leaving that panel.
	if is_instance_valid(_guild_garden_ui) and _active_panel != panel:
		_guild_garden_ui.teardown()
		_guild_garden_ui.queue_free()
		_guild_garden_ui = null
	if is_instance_valid(_guild_mine_ui) and _active_panel != panel:
		_guild_mine_ui.teardown()
		_guild_mine_ui.queue_free()
		_guild_mine_ui = null
	_active_panel = panel
	panel.visible = true
	# Scroll back to top of content area when switching sections
	var scroll: ScrollContainer = $MarginContainer/OuterVBox/ContentScroll
	scroll.scroll_vertical = 0

	# Only poll for live mission updates while the Missions panel is open.
	if is_instance_valid(_missions_poll_timer):
		if panel == _missions_panel:
			_missions_poll_timer.start()
			## Refresh right away instead of waiting for the first 5 s tick, so
			## progress made elsewhere (e.g. paddock training) shows on arrival.
			_on_missions_poll_tick()
		else:
			_missions_poll_timer.stop()

	# Only tick production countdowns while the Production panel is open.
	if is_instance_valid(_prod_tick_timer):
		if panel == _production_panel:
			_prod_tick_timer.start()
		else:
			_prod_tick_timer.stop()


# ── Loading overlay ───────────────────────────────────────────────

func _show_loading(on: bool) -> void:
	_loading_overlay.visible = on
	$MarginContainer.visible = not on


# ── Signal handlers ───────────────────────────────────────────────

func _on_guild_data_changed() -> void:
	## The missions poll handles its own change-gated rebuild; ignore the signal
	## it emits so we don't full-rebuild (and flicker/steal focus) every tick.
	if _suppress_data_changed_rebuild:
		return
	if not GuildManager.is_loading:
		_rebuild_all()  ## _rebuild_missions() inside keeps _missions_signature current


## Periodic live refresh of guild missions while the Missions panel is open.
## Fetches the latest from the server and rebuilds the list only if the mission
## state actually changed — so a teammate's deposit shows up on its own, while a
## quiet interval leaves the UI (and any half-typed quantity) untouched.
func _on_missions_poll_tick() -> void:
	# Guard: skip if not viewing missions, mid-load, offline, or already polling.
	if _missions_polling or GuildManager.is_loading:
		return
	if _active_panel != _missions_panel or not _missions_panel.visible:
		return
	if not GuildManager.is_in_guild():
		return
	_missions_polling = true
	_suppress_data_changed_rebuild = true
	await GuildManager.refresh_missions()
	_suppress_data_changed_rebuild = false
	_missions_polling = false

	# Still on the missions panel after the await?
	if not is_instance_valid(_missions_panel) or _active_panel != _missions_panel:
		return

	var sig := _compute_missions_signature()
	if sig != _missions_signature:
		# _rebuild_missions() updates _missions_signature itself.
		_rebuild_missions()


## A compact fingerprint of the mission list used to detect real changes between
## polls (progress, status, target, reward, and the player's own contribution).
## Rebuilding only when this differs avoids flicker and preserves focus/typing.
func _compute_missions_signature() -> String:
	var parts: Array[String] = []
	for m in GuildManager.guild_missions:
		if m is Dictionary:
			parts.append("%s:%d/%d:%s:%d" % [
				str(m.get("id", "")),
				int(m.get("progress", 0)),
				int(m.get("target", 0)),
				str(m.get("status", "")),
				int(m.get("my_contribution", 0)),
			])
	parts.sort()
	return "|".join(parts)


func _on_refresh_pressed() -> void:
	_show_loading(true)
	await GuildManager.refresh_all()
	_show_loading(false)


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


func _on_community_nav_pressed() -> void:
	## Show the panel first so it has layout dimensions, then (re)build the
	## garden UI if it isn't already live.
	_show_section(_community_panel)
	_rebuild_community()


func _on_guild_reroll_pressed(mission_id: String, btn: Button) -> void:
	if PlayerData.guild_role != "leader":
		return
	btn.disabled = true
	var res := await GuildManager.reroll_guild_mission(mission_id)
	if res.get("ok", false):
		## Refresh the reroll cost status (counter/points moved) + the mission list.
		await _refresh_reroll_status()
		await GuildManager.refresh_missions()
		_rebuild_missions()
	else:
		if res.has("error"):
			GameNotification.show_message("Reroll Failed", str(res.get("error", "Couldn't reroll.")))
		btn.disabled = false


## Fetches the guild's current reroll cost/free-remaining into the cache so the
## reroll buttons render the right price. Safe no-op off-line.
func _refresh_reroll_status() -> void:
	var st := await GuildManager.guild_reroll_status()
	if st.get("ok", false):
		_reroll_status = st


# ── Full rebuild ──────────────────────────────────────────────────

func _rebuild_all() -> void:
	_rebuild_home()
	_rebuild_missions()
	_rebuild_upgrades()
	_rebuild_community()
	_rebuild_linking()
	_rebuild_roster()


# ── Home / Info section ───────────────────────────────────────────

func _rebuild_home() -> void:
	_home_guild_name.text = GuildManager.guild_name()
	_home_guild_name.add_theme_color_override("font_color", Color.WHITE)
	_home_spec.text = "Specialization: %s" % GuildManager.guild_specialization().capitalize()
	_home_spec.add_theme_color_override("font_color", Color.WHITE)
	_home_members.text = "%d / %d members" % [GuildManager.guild_member_count(), GuildManager.guild_capacity()]
	_home_members.add_theme_color_override("font_color", Color.WHITE)
	_home_role.text = "Your role: %s" % PlayerData.guild_role.capitalize()
	_home_role.add_theme_color_override("font_color", Color.WHITE)

	var pts: int = int(GuildManager.current_guild.get("upgrade_points", 0))
	_home_upgrade_pts.text = "Upgrade Points: %d" % pts
	_home_upgrade_pts.add_theme_color_override("font_color", Color.WHITE)

	if GuildManager.perks_active():
		_home_perks_status.text = "✅ Perks active"
		_home_perks_status.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
	else:
		var pat := float(GuildManager._local_member_info.get("perks_active_at", 0.0))
		var remaining := pat - TrustedClock.now()
		var hrs := int(remaining / 3600.0)
		var mins := int(fmod(remaining, 3600.0) / 60.0)
		_home_perks_status.text = "⏳ Cooldown: %dh %dm" % [hrs, mins]
		_home_perks_status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))

	var active_count := 0
	for m in GuildManager.guild_missions:
		if m is Dictionary and str(m.get("status", "")) == "active":
			active_count += 1
	_home_mission_summary.text = "%d active guild mission(s)" % active_count
	_home_mission_summary.add_theme_color_override("font_color", Color.WHITE)


# ── Missions section ──────────────────────────────────────────────

func _rebuild_missions() -> void:
	# Keep the poll fingerprint in step with what we're about to render, so the
	# next poll only rebuilds on a genuine change (not one we just applied).
	_missions_signature = _compute_missions_signature()

	for c in _missions_list.get_children():
		c.queue_free()

	# Always hide the static empty label — we render per-slot below.
	_missions_empty.visible = false

	var is_leader := PlayerData.guild_role == "leader"

	# Build a lookup: difficulty → mission dict (only active ones).
	var by_diff: Dictionary = {}
	for m in GuildManager.guild_missions:
		if m is Dictionary:
			by_diff[str(m.get("difficulty", ""))] = m

	# Render slots in fixed order so the layout is always easy / medium / hard.
	for diff in ["easy", "medium", "hard"]:
		if by_diff.has(diff):
			_missions_list.add_child(_make_mission_card(by_diff[diff]))
		else:
			_missions_list.add_child(_make_spawn_slot(diff, is_leader))


func _make_spawn_slot(diff: String, is_leader: bool) -> Control:
	var wrapper := VBoxContainer.new()

	var card := PanelContainer.new()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	card.add_child(vb)

	var slot_lbl := Label.new()
	slot_lbl.text = diff.capitalize() + " Mission"
	slot_lbl.add_theme_font_size_override("font_size", 13)
	slot_lbl.add_theme_color_override("font_color", Color.WHITE)
	vb.add_child(slot_lbl)

	if is_leader:
		var spawn_btn := Button.new()
		spawn_btn.text = "➕ Spawn %s Mission" % diff.capitalize()
		spawn_btn.add_theme_font_size_override("font_size", 11)
		spawn_btn.custom_minimum_size = Vector2(0, 36)
		spawn_btn.pressed.connect(_on_spawn_mission_pressed.bind(diff, spawn_btn))
		vb.add_child(spawn_btn)
	else:
		var empty_lbl := Label.new()
		empty_lbl.text = "No active mission — waiting for the leader to spawn one."
		empty_lbl.add_theme_font_size_override("font_size", 10)
		empty_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		vb.add_child(empty_lbl)

	wrapper.add_child(card)
	wrapper.add_child(HSeparator.new())
	return wrapper


func _on_spawn_mission_pressed(diff: String, btn: Button) -> void:
	btn.disabled = true
	btn.text = "Spawning…"
	var res := await GuildManager.spawn_guild_mission(diff)
	if res.get("ok", false):
		await GuildManager.refresh_missions()
		_rebuild_missions()
	else:
		var err := str(res.get("error", "Could not spawn mission."))
		GameNotification.show_message("Spawn Failed", err)
		btn.text = "➕ Spawn %s Mission" % diff.capitalize()
		btn.disabled = false


## Default deposit quantity for a mission: the smaller of what the player owns
## and what the mission still needs (target - progress), so the box pre-fills a
## sensible amount. Returns "" meaning "0" when the player has none. The player
## can still type any amount afterward.
func _default_deposit_qty_text(owned: int, remaining: int) -> String:
	var want := mini(maxi(owned, 0), maxi(remaining, 0))
	return str(want) if want > 0 else "0"


func _make_mission_card(m: Dictionary) -> Control:
	var card := PanelContainer.new()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	card.add_child(vb)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	vb.add_child(header)

	var title := Label.new()
	var bkey := str(m.get("base_mission_key", "Mission"))
	var tgt: int = int(m.get("target", 0))
	if bkey == "deposit_fruit" and tgt > 0:
		title.text = "Deposit %d Fruit" % tgt
	elif bkey == "deposit_produce" and tgt > 0:
		title.text = "Deposit %d Produce" % tgt
	# ── Mining deposit titles (check before the generic crop branch) ──
	elif bkey == "deposit_gems" and tgt > 0:
		title.text = "Deposit %d Gems" % tgt
	elif bkey == "deposit_polished" and tgt > 0:
		title.text = "Deposit %d Polished Gems" % tgt
	elif bkey == "deposit_ores" and tgt > 0:
		title.text = "Deposit %d Ores" % tgt
	elif bkey.begins_with("deposit_polished_") and tgt > 0:
		var pid := bkey.trim_prefix("deposit_polished_")
		title.text = "Deposit %d Polished %s" % [tgt, _mining_item_name(pid)]
	elif bkey.begins_with("deposit_gem_") and tgt > 0:
		var gid := bkey.trim_prefix("deposit_gem_")
		title.text = "Deposit %d %s" % [tgt, _mining_item_name(gid)]
	elif bkey.begins_with("deposit_ore_") and tgt > 0:
		var oid := bkey.trim_prefix("deposit_ore_")
		title.text = "Deposit %d %s" % [tgt, _mining_item_name(oid)]
	elif bkey.begins_with("deposit_") and tgt > 0:
		var crop_id   := bkey.trim_prefix("deposit_")
		var crop_def  := PlayerData.get_crop_or_fruit_def(crop_id)
		var crop_name := str(crop_def.get("name", crop_id.capitalize())) if not crop_def.is_empty() else crop_id.capitalize()
		title.text = "Deposit %d %s" % [tgt, crop_name]
	else:
		title.text = bkey.replace("_", " ").capitalize()
	title.add_theme_font_size_override("font_size", 13)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", Color(0.1, 0.1, 0.1))
	header.add_child(title)

	var diff := str(m.get("difficulty", ""))
	var diff_lbl := Label.new()
	diff_lbl.text = diff.capitalize()
	diff_lbl.add_theme_font_size_override("font_size", 11)
	diff_lbl.add_theme_color_override("font_color", _diff_color(diff))
	header.add_child(diff_lbl)

	var progress: int = int(m.get("progress", 0))
	var target: int   = int(m.get("target", 1))
	var bar := ProgressBar.new()
	bar.max_value = max(target, 1)
	bar.value     = progress
	bar.show_percentage = false
	bar.custom_minimum_size.y = 14
	vb.add_child(bar)

	var prog_lbl := Label.new()
	var pct := int(100.0 * progress / max(target, 1))
	prog_lbl.text = "%d / %d  (%d%%)" % [progress, target, pct]
	prog_lbl.add_theme_font_size_override("font_size", 10)
	prog_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prog_lbl.add_theme_color_override("font_color", Color(0.1, 0.1, 0.1))
	vb.add_child(prog_lbl)

	var my_contrib: int = int(m.get("my_contribution", 0))
	if my_contrib > 0:
		var contrib_lbl := Label.new()
		contrib_lbl.text = "Your contribution: %d" % my_contrib
		contrib_lbl.add_theme_font_size_override("font_size", 10)
		contrib_lbl.add_theme_color_override("font_color", Color(0.0, 0.35, 0.6))
		vb.add_child(contrib_lbl)

	var tokens: int  = int(m.get("reward_tokens", 0))
	var pts: int     = int(m.get("reward_upgrade_points", 0))
	if tokens > 0 or pts > 0:
		var reward_lbl := Label.new()
		reward_lbl.text = "Reward: %d tokens  +%d upgrade pts" % [tokens, pts]
		reward_lbl.add_theme_font_size_override("font_size", 10)
		reward_lbl.add_theme_color_override("font_color", Color(0.55, 0.35, 0.0))
		vb.add_child(reward_lbl)

	var expires_at := float(m.get("expires_at", 0.0))
	var now_ts     := TrustedClock.now()
	var remaining  := expires_at - now_ts
	if remaining > 0:
		var hrs  := int(remaining / 3600.0)
		var mins := int(fmod(remaining, 3600.0) / 60.0)
		var timer_lbl := Label.new()
		timer_lbl.text = "⌛ Expires in: %dh %dm" % [hrs, mins]
		timer_lbl.add_theme_font_size_override("font_size", 10)
		timer_lbl.add_theme_color_override("font_color",
			Color(0.7, 0.1, 0.0) if remaining < 3600.0 else Color(0.15, 0.15, 0.15))
		vb.add_child(timer_lbl)

	var status := str(m.get("status", "active"))
	if status == "completed":
		var done_lbl := Label.new()
		done_lbl.text = "✅ Completed — rewards distributed"
		done_lbl.add_theme_font_size_override("font_size", 11)
		done_lbl.add_theme_color_override("font_color", Color(0.0, 0.45, 0.15))
		vb.add_child(done_lbl)
	elif status == "expired":
		var exp_lbl := Label.new()
		exp_lbl.text = "⌛ Expired"
		exp_lbl.add_theme_font_size_override("font_size", 11)
		exp_lbl.add_theme_color_override("font_color", Color(0.3, 0.3, 0.3))
		vb.add_child(exp_lbl)
	else:
		var base_key := str(m.get("base_mission_key", ""))
		## Amount the mission still needs — the deposit box pre-fills to the
		## smaller of this and what the player owns.
		var remaining_needed := maxi(int(m.get("target", 0)) - int(m.get("progress", 0)), 0)
		if base_key == "deposit_fruit":
			## ── Generic Fruit deposit UI (Deposit X Fruit) ───────────
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			vb.add_child(row)

			var fruit_opt := OptionButton.new()
			fruit_opt.add_theme_font_size_override("font_size", 10)
			fruit_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL

			var first_owned_id := ""
			var first_owned_count := 0
			var opt_idx := 0
			for fid in PlayerData.ORCHARD_FRUIT_IDS:
				var fdef := PlayerData.get_fruit_def(fid)
				var fname := str(fdef.get("name", fid.capitalize()))
				var fcount := PlayerData.get_fruit_count(fid)
				fruit_opt.add_item("🍎 %s: %d" % [fname, fcount], opt_idx)
				fruit_opt.set_item_metadata(opt_idx, fid)
				if first_owned_id == "" and fcount > 0:
					first_owned_id = fid
					first_owned_count = fcount
					fruit_opt.selected = opt_idx
				opt_idx += 1

			if first_owned_id == "" and PlayerData.ORCHARD_FRUIT_IDS.size() > 0:
				first_owned_id = PlayerData.ORCHARD_FRUIT_IDS[0]
				first_owned_count = PlayerData.get_fruit_count(first_owned_id)

			row.add_child(fruit_opt)

			var qty_edit := LineEdit.new()
			qty_edit.text = _default_deposit_qty_text(first_owned_count, remaining_needed)
			qty_edit.placeholder_text = "qty"
			qty_edit.add_theme_font_size_override("font_size", 10)
			qty_edit.custom_minimum_size = Vector2(52, 0)
			qty_edit.expand_to_text_length = false
			qty_edit.editable = first_owned_count > 0
			row.add_child(qty_edit)

			var deposit_btn := Button.new()
			deposit_btn.text = "Deposit"
			deposit_btn.add_theme_font_size_override("font_size", 10)
			deposit_btn.custom_minimum_size = Vector2(70, 0)
			deposit_btn.disabled = first_owned_count <= 0
			row.add_child(deposit_btn)

			fruit_opt.item_selected.connect(func(sel_idx: int):
				var fid: String = str(fruit_opt.get_item_metadata(sel_idx))
				var count := PlayerData.get_fruit_count(fid)
				qty_edit.text = _default_deposit_qty_text(count, remaining_needed)
				qty_edit.editable = count > 0
				deposit_btn.disabled = count <= 0
			)

			deposit_btn.pressed.connect(func():
				var sel := fruit_opt.selected
				var fid: String = str(fruit_opt.get_item_metadata(sel)) if sel >= 0 else ""
				_on_deposit_fruit_pressed(base_key, fid, qty_edit, deposit_btn)
			)

		elif base_key == "deposit_produce":
			## ── Generic Produce deposit UI (Deposit X Produce) ──────
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			vb.add_child(row)

			var produce_opt := OptionButton.new()
			produce_opt.add_theme_font_size_override("font_size", 10)
			produce_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL

			var first_owned_id := ""
			var first_owned_count := 0
			var opt_idx := 0
			for pid in PlayerData.PRODUCE_IDS:
				var pdef := PlayerData.get_crop_or_fruit_def(pid)
				var pname := str(pdef.get("name", pid.capitalize()))
				var pcount := PlayerData.get_crop_or_fruit_count(pid)
				var icon_str := "🍎" if PlayerData.is_orchard_fruit(pid) else "🌿"
				produce_opt.add_item("%s %s: %d" % [icon_str, pname, pcount], opt_idx)
				produce_opt.set_item_metadata(opt_idx, pid)
				if first_owned_id == "" and pcount > 0:
					first_owned_id = pid
					first_owned_count = pcount
					produce_opt.selected = opt_idx
				opt_idx += 1

			if first_owned_id == "" and PlayerData.PRODUCE_IDS.size() > 0:
				first_owned_id = PlayerData.PRODUCE_IDS[0]
				first_owned_count = PlayerData.get_crop_or_fruit_count(first_owned_id)

			row.add_child(produce_opt)

			var qty_edit := LineEdit.new()
			qty_edit.text = _default_deposit_qty_text(first_owned_count, remaining_needed)
			qty_edit.placeholder_text = "qty"
			qty_edit.add_theme_font_size_override("font_size", 10)
			qty_edit.custom_minimum_size = Vector2(52, 0)
			qty_edit.expand_to_text_length = false
			qty_edit.editable = first_owned_count > 0
			row.add_child(qty_edit)

			var deposit_btn := Button.new()
			deposit_btn.text = "Deposit"
			deposit_btn.add_theme_font_size_override("font_size", 10)
			deposit_btn.custom_minimum_size = Vector2(70, 0)
			deposit_btn.disabled = first_owned_count <= 0
			row.add_child(deposit_btn)

			produce_opt.item_selected.connect(func(sel_idx: int):
				var pid: String = str(produce_opt.get_item_metadata(sel_idx))
				var count := PlayerData.get_crop_or_fruit_count(pid)
				qty_edit.text = _default_deposit_qty_text(count, remaining_needed)
				qty_edit.editable = count > 0
				deposit_btn.disabled = count <= 0
			)

			deposit_btn.pressed.connect(func():
				var sel := produce_opt.selected
				var pid: String = str(produce_opt.get_item_metadata(sel)) if sel >= 0 else ""
				_on_deposit_produce_pressed(base_key, pid, qty_edit, deposit_btn)
			)

		elif _is_mining_deposit_key(base_key):
			## ── Mining deposit UI (gems / polished gems / ores) ──────
			## Generic buckets let the player pick any item of the category;
			## specific keys pin one item. Delegated to a shared builder.
			_build_mining_deposit_row(vb, base_key, remaining_needed)

		elif base_key.begins_with("deposit_"):
			## ── Specific crop or fruit deposit UI ────────────────────
			## The mission key encodes the crop/fruit: "deposit_beans" → "beans", "deposit_apple" → "apple".
			var crop_id   := base_key.trim_prefix("deposit_")
			var crop_def  := PlayerData.get_crop_or_fruit_def(crop_id)
			var crop_name := str(crop_def.get("name", crop_id.capitalize())) if not crop_def.is_empty() else crop_id.capitalize()
			var owned     := PlayerData.get_crop_or_fruit_count(crop_id)

			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			vb.add_child(row)

			## Crop/Fruit label — shows name and how many the player owns.
			var icon_str := "🍎" if PlayerData.is_orchard_fruit(crop_id) else "🌿"
			var crop_lbl := Label.new()
			crop_lbl.text = "%s %s  (you have: %d)" % [icon_str, crop_name, owned]
			crop_lbl.add_theme_font_size_override("font_size", 10)
			crop_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			crop_lbl.add_theme_color_override("font_color",
				Color(0.1, 0.1, 0.1) if owned > 0 else Color(0.5, 0.5, 0.5))
			row.add_child(crop_lbl)

			## Quantity text field.
			var qty_edit := LineEdit.new()
			qty_edit.text = _default_deposit_qty_text(owned, remaining_needed)
			qty_edit.placeholder_text = "qty"
			qty_edit.add_theme_font_size_override("font_size", 10)
			qty_edit.custom_minimum_size = Vector2(52, 0)
			qty_edit.expand_to_text_length = false
			qty_edit.editable = owned > 0
			row.add_child(qty_edit)

			## Deposit button.
			var deposit_btn := Button.new()
			deposit_btn.text = "Deposit"
			deposit_btn.add_theme_font_size_override("font_size", 10)
			deposit_btn.custom_minimum_size = Vector2(70, 0)
			deposit_btn.disabled = owned <= 0
			row.add_child(deposit_btn)

			deposit_btn.pressed.connect(
				_on_deposit_crops_pressed.bind(base_key, qty_edit, deposit_btn))

		else:
			var hint_lbl := Label.new()
			hint_lbl.text = "✦ Contribute by doing related activities"
			hint_lbl.add_theme_font_size_override("font_size", 10)
			hint_lbl.add_theme_color_override("font_color", Color(0.3, 0.3, 0.3))
			vb.add_child(hint_lbl)

		## Reroll button — LEADER-ONLY, priced in the guild's shared UPGRADE
		## POINTS on a tiered curve (first 3/day free, then +1 pt per block of 3;
		## resets daily). Cost + free-remaining come from the cached server status.
		var mission_id: String = str(m.get("id", ""))
		var is_leader := PlayerData.guild_role == "leader"
		var next_cost := int(_reroll_status.get("next_cost", 0))
		var free_left := int(_reroll_status.get("free_remaining", 0))
		var guild_pts := int(_reroll_status.get("upgrade_points", int(GuildManager.current_guild.get("upgrade_points", 0))))
		var reroll_btn := Button.new()
		if next_cost <= 0:
			reroll_btn.text = "🔄 Reroll (free — %d left)" % free_left
		else:
			reroll_btn.text = "🔄 Reroll (%d pt%s)" % [next_cost, "" if next_cost == 1 else "s"]
		reroll_btn.add_theme_font_size_override("font_size", 10)
		reroll_btn.custom_minimum_size = Vector2(0, 32)
		## Only the leader may reroll; and they must afford the next cost.
		reroll_btn.disabled = (not is_leader) or mission_id.is_empty() or (next_cost > guild_pts)
		if not is_leader:
			reroll_btn.text = "🔄 Reroll (leader only)"
		reroll_btn.pressed.connect(_on_guild_reroll_pressed.bind(mission_id, reroll_btn))
		vb.add_child(reroll_btn)

	var sep := HSeparator.new()
	var wrapper := VBoxContainer.new()
	wrapper.add_child(card)
	wrapper.add_child(sep)
	return wrapper


# ── Mining deposit helpers ───────────────────────────────────────

## Mining gem order and ore ids, for display + candidate lists.
const _MINING_GEM_ORDER: Array[String] = [
	"gold", "blue_stone", "pink_stone", "violet_stone",
	"black_pearl", "emerald", "ruby", "diamond",
]
const _MINING_ORE_ORDER: Array[String] = [
	"iron_ore", "iron_bar", "copper_ore", "copper_ingot", "gold_ingot",
]

## True for any mining deposit mission key (generic bucket or specific item).
func _is_mining_deposit_key(key: String) -> bool:
	return key in ["deposit_gems", "deposit_polished", "deposit_ores"] \
		or key.begins_with("deposit_gem_") \
		or key.begins_with("deposit_polished_") \
		or key.begins_with("deposit_ore_")


## Pretty name for a mining item id. Ores use their RESOURCE_DEFS name; gems are
## title-cased from the id (e.g. "blue_stone" -> "Blue Stone").
func _mining_item_name(item_id: String) -> String:
	var rdef := PlayerData.get_resource_def(item_id)
	if not rdef.is_empty():
		return str(rdef.get("name", item_id.capitalize()))
	return item_id.replace("_", " ").capitalize()


## How many of a mining item the player holds, by category.
##   kind: "gem" | "polished" | "ore"
func _mining_item_count(kind: String, item_id: String) -> int:
	match kind:
		"gem":      return PlayerData.get_gem_count(item_id)
		"polished": return PlayerData.get_polished_gem_count(item_id)
		"ore":      return PlayerData.get_item_count(item_id)
	return 0


## Returns [kind, candidate_item_ids] for a mining deposit mission key.
##   generic buckets -> all item ids of that category
##   specific key    -> just that one item id
func _mining_deposit_spec(base_key: String) -> Array:
	if base_key == "deposit_gems":
		return ["gem", _MINING_GEM_ORDER.duplicate()]
	if base_key == "deposit_polished":
		## Polished excludes gold.
		return ["polished", PlayerData.POLISHABLE_GEMS.duplicate()]
	if base_key == "deposit_ores":
		return ["ore", _MINING_ORE_ORDER.duplicate()]
	if base_key.begins_with("deposit_polished_"):
		return ["polished", [base_key.trim_prefix("deposit_polished_")]]
	if base_key.begins_with("deposit_gem_"):
		return ["gem", [base_key.trim_prefix("deposit_gem_")]]
	if base_key.begins_with("deposit_ore_"):
		return ["ore", [base_key.trim_prefix("deposit_ore_")]]
	return ["", []]


## Builds the gem/polished/ore deposit row (OptionButton of owned candidates +
## quantity + Deposit button) and wires it to the mining deposit handler.
func _build_mining_deposit_row(vb: VBoxContainer, base_key: String, remaining: int = 0) -> void:
	var spec := _mining_deposit_spec(base_key)
	var kind: String = spec[0]
	var candidates: Array = spec[1]
	var icon := "💎" if kind != "ore" else "⛏"

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	vb.add_child(row)

	var opt := OptionButton.new()
	opt.add_theme_font_size_override("font_size", 10)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var first_owned_count := 0
	var opt_idx := 0
	for item_id in candidates:
		var cnt := _mining_item_count(kind, item_id)
		var label_name := _mining_item_name(item_id)
		if kind == "polished":
			label_name = "Polished %s" % label_name
		opt.add_item("%s %s: %d" % [icon, label_name, cnt], opt_idx)
		opt.set_item_metadata(opt_idx, item_id)
		if first_owned_count <= 0 and cnt > 0:
			first_owned_count = cnt
			opt.selected = opt_idx
		opt_idx += 1
	row.add_child(opt)

	var qty_edit := LineEdit.new()
	qty_edit.text = _default_deposit_qty_text(first_owned_count, remaining)
	qty_edit.placeholder_text = "qty"
	qty_edit.add_theme_font_size_override("font_size", 10)
	qty_edit.custom_minimum_size = Vector2(52, 0)
	qty_edit.expand_to_text_length = false
	qty_edit.editable = first_owned_count > 0
	row.add_child(qty_edit)

	var deposit_btn := Button.new()
	deposit_btn.text = "Deposit"
	deposit_btn.add_theme_font_size_override("font_size", 10)
	deposit_btn.custom_minimum_size = Vector2(70, 0)
	deposit_btn.disabled = first_owned_count <= 0
	row.add_child(deposit_btn)

	## DIAGNOSTIC (temporary): some players report a mission showing 0 of an item
	## they own. If the whole row reads 0, dump what each lookup path returns so
	## the next report comes with the actual data. Also add a tiny "?" button to
	## show it on-screen. Remove once the root cause is identified.
	if first_owned_count <= 0:
		_log_mining_deposit_diag(base_key, kind, candidates)
		var diag_btn := Button.new()
		diag_btn.text = "?"
		diag_btn.tooltip_text = "Why 0? (diagnostic)"
		diag_btn.add_theme_font_size_override("font_size", 10)
		diag_btn.custom_minimum_size = Vector2(28, 0)
		diag_btn.pressed.connect(func(): _show_mining_deposit_diag(base_key, kind, candidates))
		row.add_child(diag_btn)

	opt.item_selected.connect(func(sel_idx: int):
		var iid: String = str(opt.get_item_metadata(sel_idx))
		var cnt := _mining_item_count(kind, iid)
		qty_edit.text = _default_deposit_qty_text(cnt, remaining)
		qty_edit.editable = cnt > 0
		deposit_btn.disabled = cnt <= 0
	)

	deposit_btn.pressed.connect(func():
		var sel := opt.selected
		var iid: String = str(opt.get_item_metadata(sel)) if sel >= 0 else ""
		_on_deposit_mining_pressed(base_key, kind, iid, qty_edit, deposit_btn)
	)


# ── Mining deposit DIAGNOSTIC (temporary) ────────────────────────
## Builds a report comparing, for each candidate item of a mining deposit
## mission, the count the DEPOSIT path reads (_mining_item_count ->
## get_*_count) against the count the MARKETPLACE path reads
## (market_count_owned), plus a dump of the raw store keys. If a player sees 0
## while owning the item, this shows exactly which path/key disagrees so the bug
## can be pinpointed from a single screenshot/log. Remove once resolved.
func _mining_deposit_diag_text(base_key: String, kind: String, candidates: Array) -> String:
	var lines: Array[String] = []
	lines.append("DIAG mission=%s kind=%s" % [base_key, kind])
	for item_id in candidates:
		var iid := str(item_id)
		var via_deposit := _mining_item_count(kind, iid)
		var market_key := ""
		match kind:
			"gem":      market_key = "gem:%s" % iid
			"polished": market_key = "polished:%s" % iid
			"ore":      market_key = "resource:%s" % iid
		var via_market := PlayerData.market_count_owned(market_key)
		lines.append("  %s  deposit=%d  market(%s)=%d" % [iid, via_deposit, market_key, via_market])
	## Raw store key dumps so we can see the ACTUAL stored keys/values.
	lines.append("gemstones keys: %s" % str(PlayerData.gemstones.keys()))
	lines.append("polished keys:  %s" % str(PlayerData.polished_gems.keys()))
	## Ores/bars live in the generic `fruits` item store.
	var ore_keys: Array = []
	for k in PlayerData.fruits.keys():
		if not PlayerData.get_resource_def(str(k)).is_empty():
			ore_keys.append(k)
	lines.append("resource(fruits) ore keys: %s" % str(ore_keys))
	lines.append("in_guild=%s perks_active=%s" % [
		str(GuildManager.is_in_guild()), str(GuildManager.perks_active())])
	return "\n".join(lines)


## Logs the diagnostic to the Godot/Android log (push_warning shows in adb logcat
## and the editor output) so a bug report screenshot or log capture reveals it.
func _log_mining_deposit_diag(base_key: String, kind: String, candidates: Array) -> void:
	push_warning("[GuildDepositDiag]\n" + _mining_deposit_diag_text(base_key, kind, candidates))


## Shows the diagnostic on screen in a dismissable dialog (tapped via the "?").
func _show_mining_deposit_diag(base_key: String, kind: String, candidates: Array) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Deposit Diagnostic"
	dlg.dialog_text = _mining_deposit_diag_text(base_key, kind, candidates)
	dlg.ok_button_text = "Close"
	dlg.close_requested.connect(dlg.queue_free)
	dlg.confirmed.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


## Validates and submits a mining deposit, then refreshes / reports errors —
## mirrors _on_deposit_crops_pressed but for gems / polished gems / ores.
func _on_deposit_mining_pressed(
		mission_key: String,
		kind: String,
		item_id: String,
		qty_edit: LineEdit,
		deposit_btn: Button) -> void:

	var qty: int = int(qty_edit.text.strip_edges())
	if qty <= 0:
		GameNotification.show_message("Deposit Failed", "Enter a quantity greater than zero.")
		return
	if item_id == "":
		GameNotification.show_message("Deposit Failed", "Pick an item to deposit.")
		return

	var item_name := _mining_item_name(item_id)
	if kind == "polished":
		item_name = "Polished %s" % item_name
	var owned := _mining_item_count(kind, item_id)
	if qty > owned:
		## DIAGNOSTIC (temporary): capture the mismatch when a player can't
		## deposit an item they believe they own.
		_log_mining_deposit_diag(mission_key, kind, [item_id])
		GameNotification.show_message("Deposit Failed", "You only have %d %s." % [owned, item_name])
		return

	deposit_btn.disabled = true
	qty_edit.editable    = false
	deposit_btn.text     = "Depositing…"

	var res := await GuildManager.deposit_mining_for_mission(mission_key, qty, item_id)

	if res.get("ok", false):
		await GuildManager.refresh_missions()
		_rebuild_missions()
	else:
		var err := str(res.get("error", "deposit_failed"))
		var msg: String
		match err:
			"perks_inactive":     msg = "Your guild perks are on cooldown."
			"insufficient_items": msg = "Not enough %s." % item_name
			"invalid_item":       msg = "That item can't go in this mission."
			"online_required":    msg = "Online account required."
			"not_in_guild":       msg = "You are not in a guild."
			_:                    msg = "Deposit failed (%s)." % err
		## DIAGNOSTIC (temporary): log server-side rejections too.
		_log_mining_deposit_diag(mission_key, kind, [item_id])
		GameNotification.show_message("Deposit Failed", msg)
		deposit_btn.disabled = false
		qty_edit.editable    = true
		deposit_btn.text     = "Deposit"


func _on_deposit_crops_pressed(
		mission_key: String,    ## e.g. "deposit_beans"
		qty_edit: LineEdit,
		deposit_btn: Button) -> void:

	var qty: int = int(qty_edit.text.strip_edges())
	if qty <= 0:
		GameNotification.show_message("Deposit Failed", "Enter a quantity greater than zero.")
		return

	var crop_id   := mission_key.trim_prefix("deposit_")
	var crop_def  := PlayerData.get_crop_or_fruit_def(crop_id)
	var crop_name := str(crop_def.get("name", crop_id.capitalize())) if not crop_def.is_empty() else crop_id.capitalize()
	var owned: int = PlayerData.get_crop_or_fruit_count(crop_id)
	if qty > owned:
		GameNotification.show_message("Deposit Failed",
			"You only have %d %s." % [owned, crop_name])
		return

	deposit_btn.disabled = true
	qty_edit.editable    = false
	deposit_btn.text     = "Depositing…"

	var res := await GuildManager.deposit_crops_for_mission(mission_key, qty, crop_id)

	if res.get("ok", false):
		await GuildManager.refresh_missions()
		_rebuild_missions()
	else:
		var err := str(res.get("error", "deposit_failed"))
		var msg: String
		match err:
			"perks_inactive":      msg = "Your guild perks are on cooldown."
			"insufficient_crops":  msg = "Not enough %s." % crop_name
			"invalid_crop":        msg = "Invalid crop or fruit."
			"invalid_fruit":       msg = "Presents cannot be deposited."
			"online_required":     msg = "Online account required."
			"not_in_guild":        msg = "You are not in a guild."
			_:                     msg = "Deposit failed (%s)." % err
		GameNotification.show_message("Deposit Failed", msg)
		deposit_btn.disabled = false
		qty_edit.editable    = true
		deposit_btn.text     = "Deposit"


func _on_deposit_fruit_pressed(
		mission_key: String,
		fruit_id: String,
		qty_edit: LineEdit,
		deposit_btn: Button) -> void:

	var qty: int = int(qty_edit.text.strip_edges())
	if qty <= 0:
		GameNotification.show_message("Deposit Failed", "Enter a quantity greater than zero.")
		return

	if not PlayerData.is_orchard_fruit(fruit_id):
		GameNotification.show_message("Deposit Failed", "Presents cannot be deposited. Please select a valid fruit.")
		return

	var fdef := PlayerData.get_fruit_def(fruit_id)
	var fname := str(fdef.get("name", fruit_id.capitalize())) if not fdef.is_empty() else fruit_id.capitalize()
	var owned: int = PlayerData.get_fruit_count(fruit_id)
	if qty > owned:
		GameNotification.show_message("Deposit Failed",
			"You only have %d %s." % [owned, fname])
		return

	deposit_btn.disabled = true
	qty_edit.editable    = false
	deposit_btn.text     = "Depositing…"

	var res := await GuildManager.deposit_crops_for_mission(mission_key, qty, fruit_id)

	if res.get("ok", false):
		await GuildManager.refresh_missions()
		_rebuild_missions()
	else:
		var err := str(res.get("error", "deposit_failed"))
		var msg: String
		match err:
			"perks_inactive":      msg = "Your guild perks are on cooldown."
			"insufficient_crops":  msg = "Not enough %s." % fname
			"invalid_fruit":       msg = "Presents cannot be deposited."
			"online_required":     msg = "Online account required."
			"not_in_guild":        msg = "You are not in a guild."
			_:                     msg = "Deposit failed (%s)." % err
		GameNotification.show_message("Deposit Failed", msg)
		deposit_btn.disabled = false
		qty_edit.editable    = true
		deposit_btn.text     = "Deposit"


func _on_deposit_produce_pressed(
		mission_key: String,
		item_id: String,
		qty_edit: LineEdit,
		deposit_btn: Button) -> void:

	var qty: int = int(qty_edit.text.strip_edges())
	if qty <= 0:
		GameNotification.show_message("Deposit Failed", "Enter a quantity greater than zero.")
		return

	if not PlayerData.is_produce(item_id):
		GameNotification.show_message("Deposit Failed", "Presents cannot be deposited. Please select a valid crop or fruit.")
		return

	var pdef := PlayerData.get_crop_or_fruit_def(item_id)
	var pname := str(pdef.get("name", item_id.capitalize())) if not pdef.is_empty() else item_id.capitalize()
	var owned: int = PlayerData.get_crop_or_fruit_count(item_id)
	if qty > owned:
		GameNotification.show_message("Deposit Failed",
			"You only have %d %s." % [owned, pname])
		return

	deposit_btn.disabled = true
	qty_edit.editable    = false
	deposit_btn.text     = "Depositing…"

	var res := await GuildManager.deposit_crops_for_mission(mission_key, qty, item_id)

	if res.get("ok", false):
		await GuildManager.refresh_missions()
		_rebuild_missions()
	else:
		var err := str(res.get("error", "deposit_failed"))
		var msg: String
		match err:
			"perks_inactive":      msg = "Your guild perks are on cooldown."
			"insufficient_crops":  msg = "Not enough %s." % pname
			"invalid_crop":        msg = "Invalid crop or fruit."
			"invalid_fruit":       msg = "Presents cannot be deposited."
			"invalid_produce":     msg = "Presents cannot be deposited."
			"online_required":     msg = "Online account required."
			"not_in_guild":        msg = "You are not in a guild."
			_:                     msg = "Deposit failed (%s)." % err
		GameNotification.show_message("Deposit Failed", msg)
		deposit_btn.disabled = false
		qty_edit.editable    = true
		deposit_btn.text     = "Deposit"


func _diff_color(diff: String) -> Color:
	match diff:
		"easy":   return Color(0.0, 0.45, 0.15)   ## dark green
		"medium": return Color(0.55, 0.35, 0.0)   ## dark amber
		"hard":   return Color(0.65, 0.05, 0.05)  ## dark red
	return Color(0.1, 0.1, 0.1)


# ── Upgrades section ──────────────────────────────────────────────

const UPGRADE_DISPLAY: Dictionary = {
	"crop_sell_value":      {"label": "Crop Sell Value",    "icon": "🌿", "spec": "gardening"},
	"growth_time":          {"label": "Crop Growth Speed",  "icon": "⏱",  "spec": "gardening"},
	"community_garden_size":{"label": "Community Garden",   "icon": "🌱", "spec": "gardening"},
	"guild_silo_capacity":  {"label": "Guild Silo",         "icon": "🏚", "spec": "gardening"},
	"gem_sell_value":       {"label": "Gem Sell Value",     "icon": "💎", "spec": "mining"},
	"prospector_cost":      {"label": "Prospector Cost",    "icon": "⛏",  "spec": "mining"},
	"foundry_time":         {"label": "Foundry Speed",      "icon": "🔥", "spec": "mining"},
	"mine_depth":           {"label": "Mine Depth",         "icon": "⛏",  "spec": "mining"},
	"warehouse_capacity":   {"label": "Guild Warehouse",    "icon": "🏦", "spec": "mining"},
	"horse_stable_size":    {"label": "Stable Size",        "icon": "🐎", "spec": "horse"},
	"horse_training_cap":   {"label": "Training Cap",       "icon": "🏋", "spec": "horse"},
	"production_batch_size":{"label": "Batch Production",   "icon": "📦", "spec": ""},
	"mission_reward_boost": {"label": "Mission Rewards",    "icon": "⭐", "spec": ""},
	"capacity":             {"label": "Guild Capacity",     "icon": "👥", "spec": ""},
	"link_discount":        {"label": "Cross-Guild Bonus",  "icon": "🔗", "spec": ""},
}

const UPGRADE_DESCRIPTIONS: Dictionary = {
	"crop_sell_value":       "Crops sell for more at the marketplace. Each level: +5% sell value.",
	"growth_time":           "Crops grow faster in your garden. Each level: -5% growth time.",
	"community_garden_size": "Expands the shared community garden grid. Each level unlocks a larger plot.",
	"guild_silo_capacity":   "Increases how many of each crop the guild silo can hold. Base: 100. Each level: +50 per crop type.",
	"gem_sell_value":        "Polished gems sell for more. Each level: +5% gem sell value.",
	"prospector_cost":       "Prospectors cost fewer coins to hire. Each level: -5% hire cost.",
	"foundry_time":          "Bars smelt faster in the foundry. Each level: -5% smelt time.",
	"mine_depth":            "Lets your guild dig deeper in the Community Deep Mine. Base: 1 layer. Each level: +1 reachable layer (max 11). Deeper layers yield rarer gems and ores.",
	"warehouse_capacity":    "Increases how much of each gem and ore the guild warehouse can hold. Base: 500. Each level: +250 per item type.",
	"horse_stable_size":     "Expands every member's stable. Base: 5 active horses. Each level: +1 slot (max 15).",
	"horse_training_cap":    "Raises the max stat a single training session can add. Base: 10.00. Each level: +1.00 (max 20.00).",
	"production_batch_size": "Produce multiple items per slot in the same time. Base: 1. Levels: 1→10→50→100→250→500→1k→2.5k→5k→7.5k→10k.",
	"mission_reward_boost":  "Guild missions award more tokens and upgrade points. Each level: +10% rewards.",
	"capacity":              "Increases maximum guild member slots.",
	"link_discount":         "Boosts benefits received from a linked guild. Each level: +5% perk strength.",
}

## Cost in upgrade_points to reach the next level (matches server _guild_upgrade_cost).
const UPGRADE_COSTS: Array[int] = [50, 250, 1250, 5000, 15000, 50000, 150000, 300000, 600000, 1000000]

## Member cap at each capacity level (index = level 0–10).
const CAPACITY_PER_LEVEL: Array[int] = [5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 20]


func _rebuild_upgrades() -> void:
	for c in _upgrades_list.get_children():
		c.queue_free()

	var pts: int = int(GuildManager.current_guild.get("upgrade_points", 0))
	_upgrades_pts_label.text = "Available Upgrade Points: %d" % pts
	_upgrades_pts_label.add_theme_color_override("font_color", Color.WHITE)

	var is_leader := PlayerData.guild_role == "leader"
	var spec := GuildManager.guild_specialization()

	for key in UPGRADE_DISPLAY:
		var info: Dictionary = UPGRADE_DISPLAY[key]
		var entry_spec: String = str(info.get("spec", ""))
		if entry_spec != "" and entry_spec != spec:
			continue
		var level: int = int(GuildManager.guild_upgrades.get(key, 0))
		_upgrades_list.add_child(_make_upgrade_row(key, info, level, pts, is_leader))


func _make_upgrade_row(key: String, info: Dictionary, level: int, pts: int, is_leader: bool) -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 3)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 8)
	outer.add_child(top_row)

	var name_lbl := Label.new()
	name_lbl.text = "%s %s   Lv.%d / 10" % [str(info.get("icon", "")), str(info.get("label", key)), level]
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(name_lbl)

	if level >= 10:
		var max_lbl := Label.new()
		max_lbl.text = "MAX"
		max_lbl.add_theme_font_size_override("font_size", 11)
		max_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
		top_row.add_child(max_lbl)
	elif is_leader:
		var cost: int = UPGRADE_COSTS[clampi(level, 0, 9)]
		var can_afford := pts >= cost
		var upgrade_btn := Button.new()
		upgrade_btn.text = "Upgrade (%d pts)" % cost
		upgrade_btn.add_theme_font_size_override("font_size", 11)
		upgrade_btn.custom_minimum_size = Vector2(130, 28)
		upgrade_btn.disabled = not can_afford
		upgrade_btn.pressed.connect(_on_purchase_upgrade.bind(key, upgrade_btn))
		top_row.add_child(upgrade_btn)
	else:
		var cost: int = UPGRADE_COSTS[clampi(level, 0, 9)]
		var cost_lbl := Label.new()
		cost_lbl.text = "Next: %d pts" % cost
		cost_lbl.add_theme_font_size_override("font_size", 10)
		cost_lbl.add_theme_color_override("font_color",
			Color(0.5, 0.9, 0.5) if pts >= cost else Color.WHITE)
		top_row.add_child(cost_lbl)

	var desc := str(UPGRADE_DESCRIPTIONS.get(key, ""))
	var detail := _upgrade_next_level_detail(key, level)
	var full_desc := "    " + desc
	if detail != "":
		full_desc += "\n    " + detail

	var sub_lbl := Label.new()
	sub_lbl.text = full_desc
	sub_lbl.add_theme_font_size_override("font_size", 10)
	sub_lbl.add_theme_color_override("font_color", Color.WHITE)
	sub_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(sub_lbl)

	var sep := HSeparator.new()
	var wrapper := VBoxContainer.new()
	wrapper.add_child(outer)
	wrapper.add_child(sep)
	return wrapper


func _upgrade_next_level_detail(key: String, level: int) -> String:
	if level >= 10:
		return ""
	match key:
		"community_garden_size":
			var grid_info_cur := GuildManager.GARDEN_GRID_LEVELS[clampi(level, 0, 10)]
			var grid_info_nxt := GuildManager.GARDEN_GRID_LEVELS[clampi(level + 1, 0, 10)]
			return "Current: %d×%d  →  Next level: %d×%d" % [
				grid_info_cur.width, grid_info_cur.height,
				grid_info_nxt.width, grid_info_nxt.height]
		"guild_silo_capacity":
			var cur_cap := 100 + level * 50
			var nxt_cap := 100 + (level + 1) * 50
			return "Current capacity: %d per crop  →  Next level: %d per crop" % [cur_cap, nxt_cap]
		"capacity":
			var cur := CAPACITY_PER_LEVEL[clampi(level, 0, 10)]
			var nxt := CAPACITY_PER_LEVEL[clampi(level + 1, 0, 10)]
			return "Current: %d members  →  Next level: %d members" % [cur, nxt]
		"crop_sell_value":
			return "Currently +%d%% sell value  →  Next level: +%d%%" % [level * 5, (level + 1) * 5]
		"growth_time":
			return "Currently -%d%% growth time  →  Next level: -%d%%" % [level * 5, (level + 1) * 5]
		"gem_sell_value":
			return "Currently +%d%% gem value  →  Next level: +%d%%" % [level * 5, (level + 1) * 5]
		"prospector_cost":
			return "Currently -%d%% hire cost  →  Next level: -%d%%" % [level * 5, (level + 1) * 5]
		"foundry_time":
			return "Currently -%d%% smelt time  →  Next level: -%d%%" % [level * 5, (level + 1) * 5]
		"mine_depth":
			var cur_layers := mini(1 + level, 11)
			var nxt_layers := mini(1 + level + 1, 11)
			return "Currently %d reachable layer(s)  →  Next level: %d" % [cur_layers, nxt_layers]
		"warehouse_capacity":
			var cur_cap := 500 + level * 250
			var nxt_cap := 500 + (level + 1) * 250
			return "Current capacity: %d per item  →  Next level: %d per item" % [cur_cap, nxt_cap]
		"horse_stable_size":
			return "Current stable: %d horses  →  Next level: %d" % [5 + level, 5 + level + 1]
		"horse_training_cap":
			return "Current cap: +%.2f/session  →  Next level: +%.2f" % [10.0 + level, 10.0 + level + 1]
		"production_batch_size":
			var _batch_sizes := [1, 10, 50, 100, 250, 500, 1000, 2500, 5000, 7500, 10000]
			var cur: int = _batch_sizes[clampi(level, 0, 10)]
			var nxt: int = _batch_sizes[clampi(level + 1, 0, 10)]
			return "Current batch: ×%s  →  Next level: ×%s" % [
				PlayerData.format_number(cur), PlayerData.format_number(nxt)]
		"mission_reward_boost":
			return "Currently +%d%% rewards  →  Next level: +%d%%" % [level * 10, (level + 1) * 10]
		"link_discount":
			return "Currently +%d%% perk strength  →  Next level: +%d%%" % [level * 5, (level + 1) * 5]
	return ""


func _on_purchase_upgrade(upgrade_key: String, btn: Button) -> void:
	btn.disabled = true
	var res := await GuildManager.purchase_upgrade(upgrade_key)
	## On success, purchase_upgrade calls refresh_all() which rebuilds the
	## upgrades panel and queue_frees this button — guard before touching it.
	if not res.get("ok", false):
		if is_instance_valid(btn):
			btn.disabled = false
		GameNotification.show_message("Upgrade Failed", res.get("error", "Could not upgrade."))


# ── Community section ─────────────────────────────────────────────

func _rebuild_community() -> void:
	var spec := GuildManager.guild_specialization()

	if spec == "gardening":
		## Hide the static label — the interactive UI replaces it.
		_community_label.visible = false

		## Only (re)build if the widget doesn't already exist.
		if is_instance_valid(_guild_garden_ui):
			## Already live — just make sure the silo/seed bar is fresh.
			_guild_garden_ui._rebuild_seed_bar()
			_guild_garden_ui._rebuild_silo()
			return

		## Determine grid dimensions from the community_garden_size upgrade level.
		var garden_level: int = int(GuildManager.guild_upgrades.get("community_garden_size", 0))
		var grid_info: Dictionary = GuildManager.GARDEN_GRID_LEVELS[clampi(garden_level, 0, 10)]
		var cols: int = int(grid_info.get("width",  5))
		var rows: int = int(grid_info.get("height", 5))

		## Build and attach the interactive widget.
		_guild_garden_ui = GuildGardenUI.new()
		_community_panel.add_child(_guild_garden_ui)
		_guild_garden_ui.setup(GuildManager.guild_id(), cols, rows)

		## Fetch fresh garden data in the background; UI shows immediately with
		## whatever is already cached, then refreshes once the RPC returns.
		GuildGarden.refresh(GuildManager.guild_id())

	elif spec == "mining":
		## Hide the static label — the interactive mine UI replaces it.
		_community_label.visible = false

		## Already live — nothing to rebuild; a background refresh keeps it fresh.
		if is_instance_valid(_guild_mine_ui):
			return

		## Build and attach the interactive Deep Mine widget.
		_guild_mine_ui = GuildMineUI.new()
		_community_panel.add_child(_guild_mine_ui)
		_guild_mine_ui.setup(GuildManager.guild_id())

		## Fetch fresh mine data in the background; UI shows immediately with
		## whatever is cached, then refreshes once the RPC returns.
		GuildMine.refresh(GuildManager.guild_id())

	elif spec == "horse":
		## The horse guild's community feature is the shared PADDOCK: members
		## deposit horses so guildmates can train them (gains go to the owner).
		_community_label.visible = false
		_build_guild_paddock()
	else:
		_community_label.visible = true
		_community_label.add_theme_color_override("font_color", Color.WHITE)
		_community_label.text = "Community activity will appear here once your guild's specialization is set."


# ── Horse guild community: the shared PADDOCK ─────────────────────
## Deposit one of your horses so guildmates can train it (gains land on YOU);
## train any paddocked horse once per kind per day. Horse guild only.

func _build_guild_paddock() -> void:
	## Rebuild the paddock UI into the community panel each time (cheap).
	for c in _community_panel.get_children():
		if c != _community_label:
			c.queue_free()

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_community_panel.add_child(box)

	var hdr := Label.new()
	hdr.text = "🐎 Guild Paddock"
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	box.add_child(hdr)

	var blurb := Label.new()
	blurb.text = "Deposit a horse so guildmates can train it — gains go to you. Train any paddocked horse once per kind each day."
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_font_size_override("font_size", 10)
	blurb.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	box.add_child(blurb)

	var open_btn := Button.new()
	open_btn.text = "Open Paddock"
	open_btn.add_theme_font_size_override("font_size", 12)
	open_btn.custom_minimum_size = Vector2(0, 36)
	open_btn.pressed.connect(_on_open_paddock_pressed)
	box.add_child(open_btn)


func _on_open_paddock_pressed() -> void:
	var res := await HorseRacing.refresh_paddock()
	if not res.get("ok", false):
		if get_node_or_null("/root/GameNotification") != null:
			GameNotification.show_message("Guild Paddock",
				str(res.get("message", "Paddock unavailable.")))
		return
	_show_paddock_dialog()


func _show_paddock_dialog() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "🐎 Guild Paddock"
	dialog.ok_button_text = "Close"

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(320, 360)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)

	## Deposit control: your active, un-paddocked, not-in-race horses.
	var dep_hdr := Label.new()
	dep_hdr.text = "Deposit one of your horses:"
	dep_hdr.add_theme_font_size_override("font_size", 11)
	dep_hdr.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6))
	box.add_child(dep_hdr)

	var paddocked_ids := {}
	for p in HorseRacing.paddock:
		paddocked_ids[str(p.get("horse_id", ""))] = true

	var any_depositable := false
	for h in HorseRacing.active_horses():
		var hid := str(h.get("id", ""))
		if paddocked_ids.has(hid) or HorseRacing.horse_in_any_race(hid):
			continue
		any_depositable = true
		var dbtn := Button.new()
		dbtn.text = "Deposit %s  (Σ%.2f)" % [
			str(h.get("name", "?")), HorseRacing.horse_stat_total(hid)]
		dbtn.add_theme_font_size_override("font_size", 11)
		dbtn.custom_minimum_size = Vector2(0, 32)
		dbtn.pressed.connect(func():
			dialog.queue_free()
			await _do_paddock_deposit(hid, str(h.get("name", ""))))
		box.add_child(dbtn)
	if not any_depositable:
		box.add_child(_paddock_muted("No eligible horses to deposit right now."))

	box.add_child(HSeparator.new())

	var pad_hdr := Label.new()
	pad_hdr.text = "In the paddock:"
	pad_hdr.add_theme_font_size_override("font_size", 11)
	pad_hdr.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	box.add_child(pad_hdr)

	if HorseRacing.paddock.is_empty():
		box.add_child(_paddock_muted("The paddock is empty."))
	else:
		for p in HorseRacing.paddock:
			box.add_child(_make_paddock_row(dialog, p))

	dialog.add_child(scroll)
	add_child(dialog)
	dialog.popup_centered(Vector2i(360, 420))
	dialog.close_requested.connect(dialog.queue_free)
	dialog.confirmed.connect(dialog.queue_free)


func _paddock_muted(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	return l


func _make_paddock_row(dialog: AcceptDialog, p: Dictionary) -> Control:
	var hid := str(p.get("horse_id", ""))
	var mine := bool(p.get("mine", false))

	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 2)

	var name_lbl := Label.new()
	name_lbl.text = "%s%s  (⚡%.2f 🏃%.2f ❤%.2f/%.2f)" % [
		str(p.get("name", "?")), "  (yours)" if mine else "",
		float(p.get("speed", 0)), float(p.get("endurance", 0)),
		float(p.get("life", 0)), float(p.get("life_cap", 0))]
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_lbl.add_theme_color_override("font_color",
		Color(0.6, 1.0, 0.7) if mine else Color(0.9, 0.9, 0.8))
	card.add_child(name_lbl)

	## Train buttons (per kind), disabled if the CALLER already trained it today.
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	for kind in HorseRacing.TRAINING_ORDER:
		var d := HorseRacing.training_def(kind)
		var avail := bool(p.get("can_%s" % kind, true))
		var tb := Button.new()
		tb.text = str(d.get("icon", kind))
		tb.tooltip_text = str(d.get("name", kind))
		tb.add_theme_font_size_override("font_size", 12)
		tb.custom_minimum_size = Vector2(44, 30)
		tb.disabled = not avail
		if avail:
			tb.pressed.connect(func():
				dialog.queue_free()
				_launch_paddock_minigame(hid, str(p.get("name", "")),
					str(p.get("breed", "thoroughbred")), kind))
		btn_row.add_child(tb)

	if mine:
		var wbtn := Button.new()
		wbtn.text = "Withdraw"
		wbtn.add_theme_font_size_override("font_size", 10)
		wbtn.custom_minimum_size = Vector2(72, 30)
		wbtn.pressed.connect(func():
			dialog.queue_free()
			await _do_paddock_withdraw(hid, str(p.get("name", ""))))
		btn_row.add_child(wbtn)

	card.add_child(btn_row)
	return card


func _do_paddock_deposit(horse_id: String, horse_name: String) -> void:
	var res := await HorseRacing.deposit_to_paddock(horse_id)
	if get_node_or_null("/root/GameNotification") != null:
		GameNotification.show_message("Guild Paddock",
			"%s is in the paddock." % horse_name if res.get("ok", false)
			else str(res.get("message", "Couldn't deposit.")))


func _do_paddock_withdraw(horse_id: String, horse_name: String) -> void:
	var res := await HorseRacing.withdraw_from_paddock(horse_id)
	if get_node_or_null("/root/GameNotification") != null:
		GameNotification.show_message("Guild Paddock",
			"%s left the paddock." % horse_name if res.get("ok", false)
			else str(res.get("message", "Couldn't withdraw.")))


## Launches a training mini-game for a PADDOCK horse (gain lands on the owner;
## per-trainer daily cooldown). Mini-game scenes loaded by path (headless-safe).
func _launch_paddock_minigame(horse_id: String, horse_name: String, breed: String, kind: String) -> void:
	var scene_path: String = "res://scripts/horse_racing/training_minigame.gd"
	if kind == "sprint":
		scene_path = "res://scripts/horse_racing/sprint_minigame.gd"
	elif kind == "hurdle":
		scene_path = "res://scripts/horse_racing/hurdle_minigame.gd"
	var d := HorseRacing.training_def(kind)
	var game = (load(scene_path) as GDScript).new()
	match kind:
		"hurdle":
			game.setup(breed, "%s — jump the hurdles!" % horse_name)
		"sprint":
			game.setup(breed, "%s — tap on green, stop on red!" % horse_name)
		_:
			game.setup("%s %s" % [str(d.get("icon", "")), str(d.get("name", kind))],
				"%s — brush over the horse!" % horse_name, Color(0.85, 0.6, 1.0))
			game.set_breed(breed)
	add_child(game)
	game.finished.connect(func(score: int):
		if score < 0:
			return
		var res := await HorseRacing.train_paddock(horse_id, kind, score)
		## The session counts toward the guild's training mission server-side;
		## pull the new progress so the Missions tab shows it straight away.
		if res.get("ok", false) and GuildManager.is_in_guild():
			_suppress_data_changed_rebuild = true
			await GuildManager.refresh_missions()
			_suppress_data_changed_rebuild = false
			if _active_panel == _missions_panel:
				_rebuild_missions()
		if get_node_or_null("/root/GameNotification") != null:
			if not res.get("ok", false):
				GameNotification.show_message("Paddock Training",
					str(res.get("message", "Couldn't train.")))
			elif bool(res.get("retired", false)):
				GameNotification.show_message("Paddock Training",
					"%s collapsed and was retired to the pasture." % horse_name)
			else:
				GameNotification.show_message("Paddock Training",
					"Trained %s! +%.2f %s (for the owner)" % [
						horse_name, float(res.get("gain", 0)), str(d.get("name", kind))]))


# ── Linking section ───────────────────────────────────────────────

func _rebuild_linking() -> void:
	for c in _linking_list.get_children():
		c.queue_free()

	var links = GuildManager.current_guild.get("links", [])
	if not links is Array or links.is_empty():
		var empty := Label.new()
		empty.text = "No linked guilds yet."
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color.WHITE)
		_linking_list.add_child(empty)
		return

	var is_leader := PlayerData.guild_role == "leader"
	for lnk in links:
		if not lnk is Dictionary:
			continue
		_linking_list.add_child(_make_link_row(lnk, is_leader))


func _make_link_row(lnk: Dictionary, is_leader: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_lbl := Label.new()
	name_lbl.text = str(lnk.get("name", "Unknown Guild"))
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	info.add_child(name_lbl)

	var link_status := str(lnk.get("status", "active"))
	## The id of the OTHER guild — what accept/remove act on.
	var other_guild_id := str(lnk.get("guild_id", ""))

	var detail_lbl := Label.new()
	var spec := str(lnk.get("specialization", "")).capitalize()
	var status_text: String = ""
	match link_status:
		"active":           status_text = "Linked"
		"pending_incoming": status_text = "Wants to link with you"
		"pending_outgoing": status_text = "Request sent — awaiting their leader"
		_:                  status_text = link_status.capitalize()
	detail_lbl.text = "%s · %s" % [spec, status_text]
	detail_lbl.add_theme_font_size_override("font_size", 10)
	detail_lbl.add_theme_color_override("font_color", Color.WHITE)
	info.add_child(detail_lbl)

	row.add_child(info)

	if link_status == "pending_incoming" and is_leader:
		## Someone requested US — leader can accept (passes the REQUESTING guild id).
		var accept_btn := Button.new()
		accept_btn.text = "Accept"
		accept_btn.add_theme_font_size_override("font_size", 11)
		accept_btn.custom_minimum_size = Vector2(60, 28)
		accept_btn.pressed.connect(_on_accept_link.bind(other_guild_id, accept_btn))
		row.add_child(accept_btn)
	elif link_status == "pending_outgoing":
		## We requested them; nothing to do but wait. Show a disabled marker.
		var waiting := Label.new()
		waiting.text = "Pending"
		waiting.add_theme_font_size_override("font_size", 11)
		waiting.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
		row.add_child(waiting)
	elif link_status == "active" and is_leader:
		## Confirmed link — leader can remove it (passes the LINKED guild id).
		var remove_btn := Button.new()
		remove_btn.text = "Remove"
		remove_btn.add_theme_font_size_override("font_size", 11)
		remove_btn.custom_minimum_size = Vector2(64, 28)
		remove_btn.pressed.connect(_on_remove_link.bind(other_guild_id, remove_btn))
		row.add_child(remove_btn)

	var sep := HSeparator.new()
	var wrapper := VBoxContainer.new()
	wrapper.add_child(row)
	wrapper.add_child(sep)
	return wrapper


func _on_link_search_pressed() -> void:
	for c in _link_results.get_children():
		c.queue_free()
	var query := _link_search_field.text.strip_edges()
	if query.is_empty():
		return

	var searching_lbl := Label.new()
	searching_lbl.text = "Searching…"
	searching_lbl.add_theme_font_size_override("font_size", 12)
	searching_lbl.add_theme_color_override("font_color", Color.WHITE)
	_link_results.add_child(searching_lbl)

	var opp_spec := "mining" if GuildManager.guild_specialization() == "gardening" else "gardening"
	var res := await GuildManager.search_guilds(query, opp_spec)
	for c in _link_results.get_children():
		c.queue_free()

	if not res.get("ok", false):
		var err_lbl := Label.new()
		err_lbl.text = res.get("error", "Search failed.")
		err_lbl.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
		_link_results.add_child(err_lbl)
		return

	var guilds: Array = res.get("guilds", [])
	for g in guilds:
		if not g is Dictionary:
			continue
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = "%s (%s)" % [str(g.get("name", "")), str(g.get("specialization", "")).capitalize()]
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color.WHITE)
		row.add_child(lbl)

		var req_btn := Button.new()
		req_btn.text = "Request Link"
		req_btn.add_theme_font_size_override("font_size", 11)
		req_btn.custom_minimum_size = Vector2(88, 28)
		req_btn.pressed.connect(_on_request_link.bind(str(g.get("id", "")), req_btn))
		row.add_child(req_btn)
		_link_results.add_child(row)


func _on_accept_link(requesting_guild_id: String, btn: Button) -> void:
	btn.disabled = true
	## accept_link expects the REQUESTING guild's id (the one that asked us).
	var res := await GuildManager.accept_link(requesting_guild_id)
	if not res.get("ok", false):
		btn.disabled = false
		GameNotification.show_message("Error", res.get("error", "Could not accept link."))
	else:
		## accept_link refreshes guild data; make the linking list reflect it now.
		_rebuild_linking()


func _on_request_link(target_id: String, btn: Button) -> void:
	btn.disabled = true
	var res := await GuildManager.request_link(target_id)
	if not res.get("ok", false):
		btn.disabled = false
		GameNotification.show_message("Error", res.get("error", "Could not request link."))
	else:
		btn.text = "Requested"


func _on_remove_link(linked_guild_id: String, btn: Button) -> void:
	btn.disabled = true
	var res := await GuildManager.remove_link(linked_guild_id)
	if not res.get("ok", false):
		btn.disabled = false
		GameNotification.show_message("Error", res.get("error", "Could not remove link."))
	else:
		_rebuild_linking()


# ── Roster section ────────────────────────────────────────────────

func _rebuild_roster() -> void:
	for c in _roster_list.get_children():
		c.queue_free()

	var is_leader := PlayerData.guild_role == "leader"
	var member_count := 0
	for member in GuildManager.guild_roster:
		if not member is Dictionary:
			continue
		member_count += 1
		_roster_list.add_child(_make_member_row(member, is_leader))

	## Transfer Leadership button — leader-only, only when there are other members.
	if is_leader and member_count > 1:
		var transfer_btn := Button.new()
		transfer_btn.text = "👑 Transfer Leadership"
		transfer_btn.add_theme_font_size_override("font_size", 12)
		transfer_btn.custom_minimum_size = Vector2(0, 38)
		transfer_btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
		transfer_btn.pressed.connect(_on_transfer_leadership_pressed)
		_roster_list.add_child(transfer_btn)

	## Sell Guild — leader-only. (Requirements are checked in the dialog.)
	if is_leader:
		var sell_btn := Button.new()
		sell_btn.text = "💰 Sell Guild"
		sell_btn.add_theme_font_size_override("font_size", 12)
		sell_btn.custom_minimum_size = Vector2(0, 38)
		sell_btn.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
		sell_btn.pressed.connect(_on_sell_guild_pressed)
		_roster_list.add_child(sell_btn)

	## Leave / Disband lives here.
	_roster_list.add_child(HSeparator.new())
	_roster_list.add_child(_make_leave_disband_button(is_leader, member_count))


## Builds the bottom-of-roster action:
##  • Member, or sole-member leader  → "Leave Guild" (leaving the guild; a sole
##    leader's departure dissolves it server-side, same as before).
##  • Leader with other members      → "Disband Guild" (shut it down for everyone;
##    guarded behind a two-step warning). Leadership transfer is available via
##    the "Transfer Leadership" button above this one in the roster.
func _make_leave_disband_button(is_leader: bool, member_count: int) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, 40)
	btn.add_theme_font_size_override("font_size", 13)
	btn.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45))
	var leader_with_members := is_leader and member_count > 1
	if leader_with_members:
		btn.text = "🛑 Disband Guild"
		btn.tooltip_text = "Permanently shut down this guild for all members."
		btn.pressed.connect(_on_disband_pressed)
	else:
		btn.text = "⚠️ Leave Guild"
		if is_leader:
			btn.tooltip_text = "You're the only member — leaving dissolves the guild."
		btn.pressed.connect(_on_leave_pressed)
	return btn


# ── Leave / Disband ───────────────────────────────────────────────

func _on_leave_pressed() -> void:
	var is_sole_leader := PlayerData.guild_role == "leader"
	var confirm := ConfirmationDialog.new()
	confirm.title = "Leave Guild?"
	if is_sole_leader:
		confirm.dialog_text = "You're the only member of \"%s\".\nLeaving will permanently dissolve the guild.\n\nContinue?" % GuildManager.guild_name()
		confirm.ok_button_text = "Dissolve"
	else:
		confirm.dialog_text = "Leave \"%s\"?\n\nYou'll enter a 48-hour cooldown before fully joining another guild." % GuildManager.guild_name()
		confirm.ok_button_text = "Leave"
	add_child(confirm)
	confirm.confirmed.connect(func():
		confirm.queue_free()
		await _do_leave())
	confirm.canceled.connect(confirm.queue_free)
	confirm.close_requested.connect(confirm.queue_free)
	confirm.popup_centered(Vector2i(340, 0))


func _do_leave() -> void:
	var res := await GuildManager.leave_guild()
	if res.get("ok", false):
		GameNotification.show_message("Left Guild", "You have left the guild.")
		_get_navigator().navigate_to("guilds")
	else:
		GameNotification.show_message("Couldn't Leave", str(res.get("error", "Unknown error.")))


## Leader disband — TWO warnings before the irreversible delete.
func _on_disband_pressed() -> void:
	var gname := GuildManager.guild_name()
	var warn1 := ConfirmationDialog.new()
	warn1.title = "Disband Guild?"
	warn1.dialog_text = "This permanently SHUTS DOWN \"%s\" for every member.\n\nAll members are removed, every guild mission, stockpile, and store listing is lost, and all links with other guilds are severed.\n\nThis cannot be undone." % gname
	warn1.ok_button_text = "Continue"
	add_child(warn1)
	warn1.canceled.connect(warn1.queue_free)
	warn1.close_requested.connect(warn1.queue_free)
	warn1.confirmed.connect(func():
		warn1.queue_free()
		_disband_confirm_step_two(gname))
	warn1.popup_centered(Vector2i(360, 0))


func _disband_confirm_step_two(gname: String) -> void:
	var warn2 := ConfirmationDialog.new()
	warn2.title = "Are you absolutely sure?"
	warn2.dialog_text = "Last chance. \"%s\" and everything in it will be gone for good.\n\nDisband the guild now?" % gname
	warn2.ok_button_text = "Disband Permanently"
	add_child(warn2)
	warn2.canceled.connect(warn2.queue_free)
	warn2.close_requested.connect(warn2.queue_free)
	warn2.confirmed.connect(func():
		warn2.queue_free()
		await _do_disband())
	warn2.popup_centered(Vector2i(360, 0))


func _do_disband() -> void:
	var res := await GuildManager.disband_guild()
	if res.get("ok", false):
		GameNotification.show_message("Guild Disbanded", "The guild has been permanently shut down.")
		_get_navigator().navigate_to("guilds")
	else:
		GameNotification.show_message("Couldn't Disband", str(res.get("error", "Unknown error.")))


# ── Sell Guild ────────────────────────────────────────────────────

func _on_sell_guild_pressed() -> void:
	var q := await GuildManager.get_guild_sale_quote()
	if not q.get("ok", false):
		GameNotification.show_message("Sell Guild", str(q.get("error", "Couldn't load the price.")))
		return
	_show_sell_guild_dialog(q)


func _show_sell_guild_dialog(q: Dictionary) -> void:
	var overlay := _make_modal_overlay()
	var panel := _make_modal_panel()
	overlay.get_child(1).get_child(0).add_child(panel)

	## The CenterContainer shrinks the panel to its minimum size, and wrapped
	## labels have no minimum width — so give the panel a real width, and put
	## the (long) content in a scroll box that fits on screen.
	var vp := get_viewport().get_visible_rect().size
	panel.custom_minimum_size = Vector2(maxf(240.0, vp.x - 48.0), 0)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.scroll_deadzone = 16
	scroll.custom_minimum_size = Vector2(0, maxf(200.0, vp.y - 220.0))
	panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = "💰 Sell \"%s\"" % GuildManager.guild_name()
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title_lbl.add_theme_font_size_override("font_size", 15)
	title_lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	vbox.add_child(title_lbl)

	var levels := int(q.get("levels", 0))
	var points := int(q.get("points", 0))
	var score := int(q.get("score", 0))
	var floor_price := int(q.get("floor", 0))
	var stats := Label.new()
	stats.text = "Upgrades: %s  ×  Points: %s  =  Score %s\nMinimum price: %s tokens" % [
		PlayerData.format_number(levels), PlayerData.format_number(points),
		PlayerData.format_number(score), PlayerData.format_number(floor_price)]
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats.add_theme_font_size_override("font_size", 11)
	vbox.add_child(stats)

	var rules := Label.new()
	rules.text = "• Listing removes you from the guild (no perks). You can join another guild, but can't create one while it's for sale.\n• Everything goes with the guild. The buyer pays you in tokens.\n• Changed your mind? While guildless you can reclaim it for %s tokens." % \
		PlayerData.format_number(10000)
	rules.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rules.add_theme_font_size_override("font_size", 10)
	rules.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	vbox.add_child(rules)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.add_theme_font_size_override("font_size", 12)
	cancel_btn.custom_minimum_size = Vector2(0, 36)
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(overlay.queue_free)

	## Not eligible: explain why and only offer Close.
	if not bool(q.get("eligible", false)):
		var why := Label.new()
		match str(q.get("reason", "")):
			"guild_not_empty":
				why.text = "Everyone else must leave the guild first (%d other member%s)." % [
					int(q.get("others", 0)), "" if int(q.get("others", 0)) == 1 else "s"]
			"score_too_low":
				why.text = "Your score must be at least %s to sell (buy upgrades and keep points to raise it)." % \
					PlayerData.format_number(int(q.get("min_score", 50)))
			_:
				why.text = "Only the guild leader can sell the guild."
		why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		why.add_theme_font_size_override("font_size", 11)
		why.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
		vbox.add_child(why)
		cancel_btn.text = "Close"
		vbox.add_child(cancel_btn)
		add_child(overlay)
		return

	var price_lbl := Label.new()
	price_lbl.text = "Asking price (tokens, minimum %s):" % PlayerData.format_number(floor_price)
	price_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	price_lbl.add_theme_font_size_override("font_size", 11)
	vbox.add_child(price_lbl)

	var price_edit := LineEdit.new()
	price_edit.text = str(floor_price)
	price_edit.custom_minimum_size = Vector2(0, 38)
	price_edit.add_theme_font_size_override("font_size", 13)
	vbox.add_child(price_edit)

	var list_btn := Button.new()
	list_btn.text = "List Guild for Sale"
	list_btn.add_theme_font_size_override("font_size", 13)
	list_btn.custom_minimum_size = Vector2(0, 40)
	list_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_btn.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))
	list_btn.pressed.connect(func():
		var txt := price_edit.text.strip_edges().replace(",", "")
		var price := int(txt) if txt.is_valid_int() else 0
		if price < floor_price:
			price_edit.text = str(floor_price)
			GameNotification.show_message("Sell Guild",
				"The minimum price is %s tokens." % PlayerData.format_number(floor_price))
			return
		list_btn.disabled = true
		var res := await GuildManager.list_guild_for_sale(price)
		overlay.queue_free()
		if res.get("ok", false):
			GameNotification.show_message("Guild Listed",
				"Your guild is for sale at %s tokens. Find it under Guild Fronts in the Online Market." % \
				PlayerData.format_number(price))
			_get_navigator().navigate_to("guilds")
		else:
			GameNotification.show_message("Couldn't List", str(res.get("error", "Unknown error."))))
	vbox.add_child(list_btn)

	## ── Option 2: sell instantly to the game at the floor price ──────────
	var or_lbl := Label.new()
	or_lbl.text = "— or —"
	or_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	or_lbl.add_theme_font_size_override("font_size", 11)
	or_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	vbox.add_child(or_lbl)

	var relist := int(ceil(floor_price * 1.05))
	var game_info := Label.new()
	game_info.text = "Sell to the Guild Exchange for %s tokens, paid instantly. The game re-lists it for %s. It holds 3 guilds at most; the oldest unsold one is removed when a new one comes in." % [
		PlayerData.format_number(floor_price), PlayerData.format_number(relist)]
	game_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	game_info.add_theme_font_size_override("font_size", 10)
	game_info.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	vbox.add_child(game_info)

	var game_btn := Button.new()
	game_btn.text = "Sell to Game (%s tokens)" % PlayerData.format_number(floor_price)
	game_btn.add_theme_font_size_override("font_size", 13)
	game_btn.custom_minimum_size = Vector2(0, 40)
	game_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	game_btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	game_btn.pressed.connect(func():
		## Two-tap confirm: this is instant and can't be undone.
		if game_btn.text != "Tap again to confirm":
			game_btn.text = "Tap again to confirm"
			return
		game_btn.disabled = true
		list_btn.disabled = true
		var res := await GuildManager.sell_guild_to_game()
		overlay.queue_free()
		if res.get("ok", false):
			GameNotification.show_message("Guild Sold 💰",
				"The Guild Exchange paid you %s tokens." % PlayerData.format_number(int(res.get("paid", floor_price))))
			_get_navigator().navigate_to("guilds")
		else:
			GameNotification.show_message("Couldn't Sell", str(res.get("error", "Unknown error."))))
	vbox.add_child(game_btn)

	vbox.add_child(cancel_btn)
	add_child(overlay)


# ── Transfer Leadership ───────────────────────────────────────────

func _on_transfer_leadership_pressed() -> void:
	var members: Array = []
	for m in GuildManager.guild_roster:
		if not m is Dictionary:
			continue
		if str(m.get("role", "")) == "member":
			members.append(m)
	if members.is_empty():
		GameNotification.show_message("Transfer Leadership", "No other members to transfer to.")
		return
	## Warning 1 — hand-built modal so it stays on-screen on mobile.
	_show_transfer_warning(members)


func _show_transfer_warning(members: Array) -> void:
	var overlay := _make_modal_overlay()

	var panel := _make_modal_panel()
	overlay.get_child(1).get_child(0).add_child(panel)   ## MarginContainer → CenterContainer

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = "Transfer Leadership?"
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_font_size_override("font_size", 15)
	title_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	vbox.add_child(title_lbl)

	var body := Label.new()
	body.text = "You are about to hand over leadership of \"%s\".\n\nYou will LOSE all leader privileges (upgrades, store, stockpile, etc.).\n\nThis cannot be undone without the new leader's co-operation." % GuildManager.guild_name()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 11)
	body.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	vbox.add_child(body)

	vbox.add_child(HSeparator.new())

	var continue_btn := Button.new()
	continue_btn.text = "Choose New Leader"
	continue_btn.add_theme_font_size_override("font_size", 13)
	continue_btn.custom_minimum_size = Vector2(0, 40)
	continue_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	continue_btn.pressed.connect(func():
		overlay.queue_free()
		_show_transfer_picker(members))
	vbox.add_child(continue_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.add_theme_font_size_override("font_size", 12)
	cancel_btn.custom_minimum_size = Vector2(0, 36)
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(overlay.queue_free)
	vbox.add_child(cancel_btn)

	add_child(overlay)


func _show_transfer_picker(members: Array) -> void:
	## ── STEP 2: Pick a member ────────────────────────────────────────────────
	## Build a dimmed full-screen modal (no AcceptDialog — avoids a second
	## built-in cancel button) that fits within the screen width.
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.65)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 0)   ## never wider than the screen
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.16, 0.98)
	style.set_corner_radius_all(8)
	style.set_border_width_all(1)
	style.border_color = Color(0.5, 0.5, 0.5, 0.6)
	style.content_margin_left = 14; style.content_margin_right = 14
	style.content_margin_top = 12; style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.custom_minimum_size = Vector2(260, 0)
	panel.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = "Choose New Leader"
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_font_size_override("font_size", 14)
	title_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	vbox.add_child(title_lbl)

	var sub := Label.new()
	sub.text = "Select a member to promote:"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 11)
	sub.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(sub)

	vbox.add_child(HSeparator.new())

	for m in members:
		var uid := str(m.get("user_id", ""))
		var uname := str(m.get("username", "?"))
		var btn := Button.new()
		btn.text = uname
		btn.add_theme_font_size_override("font_size", 13)
		btn.custom_minimum_size = Vector2(0, 40)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(func():
			overlay.queue_free()
			_confirm_transfer(uid, uname))
		vbox.add_child(btn)

	vbox.add_child(HSeparator.new())

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.add_theme_font_size_override("font_size", 12)
	cancel_btn.custom_minimum_size = Vector2(0, 36)
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(overlay.queue_free)
	vbox.add_child(cancel_btn)

	add_child(overlay)


func _confirm_transfer(new_leader_id: String, new_leader_name: String) -> void:
	var overlay := _make_modal_overlay()
	var panel := _make_modal_panel()
	overlay.get_child(1).get_child(0).add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = "Confirm Transfer?"
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_font_size_override("font_size", 15)
	title_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	vbox.add_child(title_lbl)

	var body := Label.new()
	body.text = "Transfer leadership to %s?\n\nYou will immediately become a regular member and %s will have full leader control.\n\nAre you sure?" % [new_leader_name, new_leader_name]
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 11)
	body.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	vbox.add_child(body)

	vbox.add_child(HSeparator.new())

	var confirm_btn := Button.new()
	confirm_btn.text = "Yes, Transfer to %s" % new_leader_name
	confirm_btn.add_theme_font_size_override("font_size", 12)
	confirm_btn.custom_minimum_size = Vector2(0, 40)
	confirm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm_btn.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))
	confirm_btn.pressed.connect(func():
		overlay.queue_free()
		await _do_transfer_leadership(new_leader_id, new_leader_name))
	vbox.add_child(confirm_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.add_theme_font_size_override("font_size", 12)
	cancel_btn.custom_minimum_size = Vector2(0, 36)
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(overlay.queue_free)
	vbox.add_child(cancel_btn)

	add_child(overlay)


func _do_transfer_leadership(new_leader_id: String, new_leader_name: String) -> void:
	var res := await GuildManager.transfer_leadership(new_leader_id)
	if res.get("ok", false):
		GameNotification.show_message("Leadership Transferred",
			"%s is now the guild leader. You are now a regular member." % new_leader_name)
		_rebuild_roster()
	else:
		GameNotification.show_message("Transfer Failed",
			str(res.get("error", "Couldn't transfer leadership. Please try again.")))


## ── Shared modal helpers (used by the transfer leadership flow) ───────────────
## Builds a full-screen dimmed overlay. Child 0 = dim. Child 1 = MarginContainer
## with 16px side margins (guarantees the panel fits on narrow phones).
## Add the panel directly into child 1.
func _make_modal_overlay() -> Control:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.65)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)
	## A full-rect VBox that centres the panel vertically and constrains width.
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 80)
	margin.add_theme_constant_override("margin_bottom", 80)
	overlay.add_child(margin)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(center)
	return overlay


## Builds the styled panel. Call overlay.get_child(1).get_child(0).add_child(panel).
func _make_modal_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.16, 0.98)
	style.set_corner_radius_all(8)
	style.set_border_width_all(1)
	style.border_color = Color(0.5, 0.5, 0.5, 0.6)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _make_member_row(member: Dictionary, is_leader: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var name_lbl := Label.new()
	name_lbl.text = str(member.get("username", "Unknown"))
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)

	var role_lbl := Label.new()
	var role := str(member.get("role", "member"))
	role_lbl.text = role.capitalize()
	role_lbl.add_theme_font_size_override("font_size", 11)
	role_lbl.add_theme_color_override("font_color",
		Color(1.0, 0.85, 0.3) if role == "leader" else Color.WHITE)
	row.add_child(role_lbl)

	var score_lbl := Label.new()
	## Score = lifetime guild upgrade points this member has earned for the guild
	## (their proportional share of completed missions' upgrade-point rewards).
	var score := int(member.get("score", 0))
	score_lbl.text = "Score: %s" % PlayerData.format_number(score)
	score_lbl.tooltip_text = "Guild upgrade points earned for the guild"
	score_lbl.add_theme_font_size_override("font_size", 10)
	score_lbl.add_theme_color_override("font_color", Color.WHITE)
	row.add_child(score_lbl)

	var member_id := str(member.get("user_id", ""))
	var my_id := MarketplaceAccount.account_id
	if is_leader and role != "leader" and member_id != my_id:
		var kick_btn := Button.new()
		kick_btn.text = "Kick"
		kick_btn.add_theme_font_size_override("font_size", 11)
		kick_btn.custom_minimum_size = Vector2(44, 28)
		kick_btn.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
		kick_btn.pressed.connect(_on_kick.bind(member_id, str(member.get("username", "")), kick_btn))
		row.add_child(kick_btn)

	var sep := HSeparator.new()
	var wrapper := VBoxContainer.new()
	wrapper.add_child(row)
	wrapper.add_child(sep)
	return wrapper


func _on_kick(user_id: String, uname: String, btn: Button) -> void:
	btn.disabled = true
	var confirm := ConfirmationDialog.new()
	confirm.title = "Kick Member?"
	confirm.dialog_text = "Remove %s from the guild?" % uname
	confirm.ok_button_text = "Kick"
	add_child(confirm)
	confirm.confirmed.connect(func():
		confirm.queue_free()
		_do_kick(user_id, btn)
	)
	confirm.canceled.connect(func():
		btn.disabled = false
		confirm.queue_free()
	)
	confirm.popup_centered()


func _do_kick(user_id: String, btn: Button) -> void:
	var res := await GuildManager.kick_member(user_id)
	if not res.get("ok", false):
		btn.disabled = false
		GameNotification.show_message("Error", res.get("error", "Could not kick member."))


# ── Stockpile section ─────────────────────────────────────────────

## Nav button handler: show the panel and fetch the latest stockpile.
func _on_stockpile_nav_pressed() -> void:
	_show_section(_stockpile_panel)
	if GuildManager.is_in_guild():
		await GuildStockpile.refresh(GuildManager.guild_id())
		## refresh() emits stockpile_changed -> _on_stockpile_changed rebuilds.


## Rebuild only when the stockpile panel is the active one (the signal can fire
## from a background deposit while another section is open).
func _on_stockpile_changed() -> void:
	if _active_panel == _stockpile_panel:
		_rebuild_stockpile()
	## The Store dropdown includes stockpile items, so a stockpile change
	## also means the store view should refresh its available items.
	if _active_panel == _store_panel:
		_rebuild_store()


func _rebuild_stockpile() -> void:
	var is_leader := PlayerData.guild_role == "leader"

	## Status line: capacity.
	var cap_txt := PlayerData.format_number(GuildStockpile.capacity)
	_stockpile_status.text = "Capacity: %s per item" % cap_txt

	## ── Stored items list ──────────────────────────────────────────
	for c in _stockpile_list.get_children():
		c.queue_free()

	var keys := GuildStockpile.item_keys()
	keys.sort()
	_stockpile_empty.visible = keys.is_empty()
	for item_key in keys:
		_stockpile_list.add_child(_make_stockpile_row(str(item_key), is_leader))

	## ── Deposit area (any member) ──────────────────────────────────
	for c in _stockpile_deposit_area.get_children():
		c.queue_free()
	_build_stockpile_deposit_row(_stockpile_deposit_area)


## One row per stored item: name, amount (and reserved), plus leader-only
## reserve control.
func _make_stockpile_row(item_key: String, is_leader: bool) -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 2)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	outer.add_child(row)

	var name_lbl := Label.new()
	name_lbl.text = ItemKeyRegistry.display_name(item_key)
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)

	var amount := GuildStockpile.get_amount(item_key)
	var reserved := GuildStockpile.get_reserved(item_key)
	var amt_lbl := Label.new()
	if reserved > 0:
		amt_lbl.text = "%s  (%s reserved)" % [
			PlayerData.format_number(amount), PlayerData.format_number(reserved)]
	else:
		amt_lbl.text = PlayerData.format_number(amount)
	amt_lbl.add_theme_font_size_override("font_size", 11)
	amt_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.6))
	row.add_child(amt_lbl)

	## Leader-only reserve + withdraw controls on a second line.
	if is_leader:
		var ctl := HBoxContainer.new()
		ctl.add_theme_constant_override("separation", 4)
		outer.add_child(ctl)

		var res_edit := LineEdit.new()
		res_edit.placeholder_text = "reserve"
		res_edit.text = str(reserved)
		res_edit.add_theme_font_size_override("font_size", 10)
		res_edit.custom_minimum_size = Vector2(64, 0)
		ctl.add_child(res_edit)

		var res_btn := Button.new()
		res_btn.text = "Reserve"
		res_btn.add_theme_font_size_override("font_size", 10)
		res_btn.custom_minimum_size = Vector2(64, 0)
		res_btn.pressed.connect(func():
			_on_stockpile_reserve_pressed(item_key, res_edit, res_btn))
		ctl.add_child(res_btn)

	var sep := HSeparator.new()
	outer.add_child(sep)
	return outer


## Collects every stockpile-eligible item the player currently owns (across
## resource/gem/polished/crop/fruit), as [{key, name, count}], sorted by name.
func _owned_stockpile_items() -> Array:
	var out: Array = []
	for key in ItemKeyRegistry.all_keys():
		var cat := ItemKeyRegistry.category_of(key)
		if not _STOCKPILE_CATEGORIES.has(cat):
			continue
		if not ItemKeyRegistry.is_tradeable(key):
			continue
		var cnt := PlayerData.market_count_owned(key)
		if cnt > 0:
			out.append({"key": key, "name": ItemKeyRegistry.display_name(key), "count": cnt})
	out.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	return out


## Deposit row: a dropdown of everything the player owns that can be stockpiled,
## a quantity field, and a Deposit button. Available to any member.
func _build_stockpile_deposit_row(vb: VBoxContainer) -> void:
	var owned := _owned_stockpile_items()

	if owned.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "You have no raw materials to deposit."
		none_lbl.add_theme_font_size_override("font_size", 11)
		none_lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
		vb.add_child(none_lbl)
		return

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	vb.add_child(row)

	var opt := OptionButton.new()
	opt.add_theme_font_size_override("font_size", 10)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in range(owned.size()):
		var entry: Dictionary = owned[i]
		opt.add_item("%s: %s" % [entry["name"], PlayerData.format_number(int(entry["count"]))], i)
		opt.set_item_metadata(i, entry["key"])
	opt.selected = 0
	row.add_child(opt)

	var qty_edit := LineEdit.new()
	qty_edit.text = "1"
	qty_edit.placeholder_text = "qty"
	qty_edit.add_theme_font_size_override("font_size", 10)
	qty_edit.custom_minimum_size = Vector2(52, 0)
	row.add_child(qty_edit)

	var deposit_btn := Button.new()
	deposit_btn.text = "Deposit"
	deposit_btn.add_theme_font_size_override("font_size", 10)
	deposit_btn.custom_minimum_size = Vector2(70, 0)
	row.add_child(deposit_btn)

	deposit_btn.pressed.connect(func():
		var sel := opt.selected
		var key: String = str(opt.get_item_metadata(sel)) if sel >= 0 else ""
		_on_stockpile_deposit_pressed(key, qty_edit, deposit_btn))


# ── Stockpile action handlers ─────────────────────────────────────

func _on_stockpile_deposit_pressed(item_key: String, qty_edit: LineEdit, btn: Button) -> void:
	if item_key == "":
		GameNotification.show_message("Deposit Failed", "Pick an item to deposit.")
		return
	var qty := int(qty_edit.text.strip_edges())
	if qty <= 0:
		GameNotification.show_message("Deposit Failed", "Enter a quantity greater than zero.")
		return
	if PlayerData.market_count_owned(item_key) < qty:
		GameNotification.show_message("Deposit Failed", "You don't have that many.")
		return

	btn.disabled = true
	btn.text = "Depositing…"
	var res := await GuildStockpile.deposit(GuildManager.guild_id(), item_key, qty)
	if res.get("ok", false):
		var stored := int(res.get("deposited", qty))
		if stored < qty:
			GameNotification.show_message("Stockpile Full",
				"Only %d fit — the rest was returned." % stored)
		_rebuild_stockpile()
	else:
		GameNotification.show_message("Deposit Failed", str(res.get("message", "Deposit failed.")))
		btn.disabled = false
		btn.text = "Deposit"


func _on_stockpile_reserve_pressed(item_key: String, edit: LineEdit, btn: Button) -> void:
	var amount := int(edit.text.strip_edges())
	if amount < 0:
		GameNotification.show_message("Reserve Failed", "Enter a valid amount.")
		return
	btn.disabled = true
	var res := await GuildStockpile.reserve(GuildManager.guild_id(), item_key, amount)
	if res.get("ok", false):
		_rebuild_stockpile()
	else:
		GameNotification.show_message("Reserve Failed", str(res.get("message", "Could not reserve.")))
		btn.disabled = false


# ── Leaderboard section ───────────────────────────────────────────

func _on_leaderboard_nav_pressed() -> void:
	_show_section(_leaderboard_panel)
	_lb_empty.text = "Loading…"
	_lb_empty.visible = true
	for c in _lb_list.get_children():
		c.queue_free()
	var res := await GuildLeaderboard.refresh()
	if not res.get("ok", false):
		_lb_empty.text = str(res.get("message", "Could not load leaderboards."))
		_lb_empty.visible = true
		return
	## refresh() emits leaderboard_changed -> _on_leaderboard_changed rebuilds.


func _on_leaderboard_changed() -> void:
	if _active_panel == _leaderboard_panel:
		_rebuild_leaderboard()


func _on_lb_tab_pressed(tab: String) -> void:
	_lb_active_tab = tab
	_lb_players_tab.button_pressed = (tab == "players")
	_lb_guilds_tab.button_pressed = (tab == "guilds")
	_rebuild_leaderboard()


func _rebuild_leaderboard() -> void:
	for c in _lb_list.get_children():
		c.queue_free()

	if _lb_active_tab == "players":
		var rows: Array = GuildLeaderboard.players
		_lb_empty.visible = rows.is_empty()
		if rows.is_empty():
			_lb_empty.text = "No ranked players yet."
		for i in range(rows.size()):
			_lb_list.add_child(_make_player_rank_row(i + 1, rows[i]))
	else:
		var grows: Array = GuildLeaderboard.guilds
		_lb_empty.visible = grows.is_empty()
		if grows.is_empty():
			_lb_empty.text = "No ranked guilds yet."
		for i in range(grows.size()):
			_lb_list.add_child(_make_guild_rank_row(i + 1, grows[i]))


## A player row: "#rank  Name  (Guild)  score". The caller's own row is tinted.
func _make_player_rank_row(rank: int, entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var rank_lbl := Label.new()
	rank_lbl.text = "#%d" % rank
	rank_lbl.add_theme_font_size_override("font_size", 11)
	rank_lbl.custom_minimum_size = Vector2(32, 0)
	rank_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	row.add_child(rank_lbl)

	var is_you := bool(entry.get("is_you", false))
	var name_lbl := Label.new()
	name_lbl.text = "%s%s" % [str(entry.get("username", "?")), ("  (you)" if is_you else "")]
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_color_override("font_color",
		Color(0.6, 1.0, 0.6) if is_you else Color.WHITE)
	row.add_child(name_lbl)

	var guild_lbl := Label.new()
	guild_lbl.text = str(entry.get("guild_name", "—"))
	guild_lbl.add_theme_font_size_override("font_size", 10)
	guild_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.9))
	## Clip a long guild name so it never pushes the score off-screen.
	guild_lbl.clip_text = true
	guild_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	guild_lbl.custom_minimum_size = Vector2(90, 0)
	guild_lbl.size_flags_horizontal = Control.SIZE_SHRINK_END
	row.add_child(guild_lbl)

	var score_lbl := Label.new()
	score_lbl.text = PlayerData.format_number(int(entry.get("score", 0)))
	score_lbl.add_theme_font_size_override("font_size", 11)
	score_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.6))
	## Fixed width + right-aligned so the score always sits at the row's edge.
	score_lbl.custom_minimum_size = Vector2(56, 0)
	score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(score_lbl)

	var wrapper := VBoxContainer.new()
	wrapper.add_child(row)
	wrapper.add_child(HSeparator.new())
	return wrapper


## A guild row: "#rank  GuildName (spec)  members  points". The caller's guild tinted.
func _make_guild_rank_row(rank: int, entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var rank_lbl := Label.new()
	rank_lbl.text = "#%d" % rank
	rank_lbl.add_theme_font_size_override("font_size", 11)
	rank_lbl.custom_minimum_size = Vector2(32, 0)
	rank_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	row.add_child(rank_lbl)

	var is_yours := bool(entry.get("is_yours", false))
	var name_lbl := Label.new()
	name_lbl.text = "%s%s" % [str(entry.get("name", "?")), ("  (yours)" if is_yours else "")]
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_color_override("font_color",
		Color(0.6, 1.0, 0.6) if is_yours else Color.WHITE)
	row.add_child(name_lbl)

	var spec_lbl := Label.new()
	spec_lbl.text = str(entry.get("specialization", "")).capitalize()
	spec_lbl.add_theme_font_size_override("font_size", 10)
	spec_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.9))
	row.add_child(spec_lbl)

	## Score = points available × upgrades purchased (migration 087).
	var pts_lbl := Label.new()
	pts_lbl.text = PlayerData.format_number(int(entry.get("score", 0)))
	pts_lbl.tooltip_text = "Score = %d points available × %d upgrades purchased" % [
		int(entry.get("upgrade_points", 0)), int(entry.get("upgrades_purchased", 0))]
	pts_lbl.add_theme_font_size_override("font_size", 11)
	pts_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.6))
	row.add_child(pts_lbl)

	var wrapper := VBoxContainer.new()
	wrapper.add_child(row)
	wrapper.add_child(HSeparator.new())
	return wrapper


# ── Production section ────────────────────────────────────────────

func _on_production_nav_pressed() -> void:
	_show_section(_production_panel)
	_prod_empty.text = "Loading…"
	_prod_empty.visible = true
	if GuildManager.is_in_guild():
		await GuildProduction.refresh(GuildManager.guild_id())
		## refresh() emits production_changed -> _on_production_changed rebuilds.


func _on_production_changed() -> void:
	if _active_panel == _production_panel:
		_rebuild_production()


## 1s tick: just refresh the countdown labels + collect-button state without a
## full rebuild (avoids flicker and keeps the dropdown selection stable).
func _on_production_tick() -> void:
	if _active_panel != _production_panel or not _production_panel.visible:
		return
	_update_production_countdowns()


func _rebuild_production() -> void:
	## Status line.
	var batch := GuildProduction.batch_size
	_prod_status.text = "Facility: %d / %d slots  •  %d lane(s)  •  batch ×%s" % [
		GuildProduction.items.size(), GuildProduction.capacity, GuildProduction.parallel,
		PlayerData.format_number(batch)]

	## Recipe dropdown — only recipes this guild's specialization can craft
	## (gardening=food recipes, mining=jewelry+horseshoes, horse=horseshoes).
	_prod_recipe_opt.clear()
	var spec := GuildManager.guild_specialization()
	var jids := PlayerData.producible_ids_for_spec(spec)
	for i in range(jids.size()):
		var jid: String = jids[i]
		var def := PlayerData.get_jewelry_def(jid)
		_prod_recipe_opt.add_item(str(def.get("name", jid)), i)
		_prod_recipe_opt.set_item_metadata(i, jid)
	if jids.size() > 0:
		_prod_recipe_opt.selected = 0

	## ── Quantity SpinBox (batch size) ────────────────────────────────────────
	## Inserted into the EnqueueRow between the recipe dropdown and craft button.
	## Only shown when the upgrade is level > 0 (batch > 1).
	if batch > 1:
		var enqueue_row := _prod_recipe_opt.get_parent()
		if _prod_qty_spin == null or not is_instance_valid(_prod_qty_spin):
			_prod_qty_spin = SpinBox.new()
			_prod_qty_spin.min_value = 1
			_prod_qty_spin.step = 1
			_prod_qty_spin.add_theme_font_size_override("font_size", 12)
			_prod_qty_spin.custom_minimum_size = Vector2(90, 0)
			## Insert before the Craft button (last child of EnqueueRow).
			enqueue_row.add_child(_prod_qty_spin)
			enqueue_row.move_child(_prod_qty_spin, enqueue_row.get_child_count() - 2)
		_prod_qty_spin.visible = true
		_prod_qty_spin.max_value = float(batch)
		## Smart default: min(batch_size, stockpile can afford for current recipe).
		var default_qty := _smart_qty_default(
			str(_prod_recipe_opt.get_item_metadata(_prod_recipe_opt.selected)), batch)
		_prod_qty_spin.value = float(default_qty)
		## Update default when recipe changes.
		if not _prod_recipe_opt.item_selected.is_connected(_on_prod_recipe_changed):
			_prod_recipe_opt.item_selected.connect(_on_prod_recipe_changed)
	elif _prod_qty_spin != null and is_instance_valid(_prod_qty_spin):
		_prod_qty_spin.visible = false

	_prod_enqueue_btn.disabled = GuildProduction.is_full()

	## Queue list.
	for c in _prod_list.get_children():
		c.queue_free()
	var rows: Array = GuildProduction.items
	_prod_empty.visible = rows.is_empty()
	if rows.is_empty():
		_prod_empty.text = "Nothing in production."
	for it in rows:
		_prod_list.add_child(_make_production_row(it))

	_update_collect_button()


## Returns the smart-default qty: min(batch_size, how many the stockpile affords).
func _smart_qty_default(recipe_id: String, batch: int) -> int:
	## Check GuildStockpile for each input; divide available stock by recipe need.
	## Falls back to batch_size if stockpile data isn't cached yet.
	if get_node_or_null("/root/GuildStockpile") == null:
		return batch
	var min_can_afford := batch
	## Query each recipe input from the local GuildStockpile cache if available.
	for item_key in _recipe_inputs_for(recipe_id).keys():
		var need: int = int(_recipe_inputs_for(recipe_id)[item_key])
		if need <= 0:
			continue
		var avail: int = GuildStockpile.get_available(item_key)
		var can_afford: int = avail / need if need > 0 else batch
		min_can_afford = mini(min_can_afford, can_afford)
	return maxi(1, min_can_afford)


## Returns a Dict {item_key -> qty_per_recipe} for a recipe from the client ITEM_DEFS.
func _recipe_inputs_for(recipe_id: String) -> Dictionary:
	var def := PlayerData.get_jewelry_def(recipe_id)
	if def.is_empty():
		return {}
	return def.get("recipe", {})


func _on_prod_recipe_changed(_idx: int) -> void:
	## Update the qty default when the recipe selection changes.
	if _prod_qty_spin == null or not is_instance_valid(_prod_qty_spin):
		return
	var batch := GuildProduction.batch_size
	if batch <= 1:
		return
	var recipe_id := str(_prod_recipe_opt.get_item_metadata(_prod_recipe_opt.selected))
	var default_qty := _smart_qty_default(recipe_id, batch)
	_prod_qty_spin.max_value = float(batch)
	_prod_qty_spin.value = float(default_qty)


## Builds a single production row with a live countdown label (named so the tick
## can update it in place).
func _make_production_row(it: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var jid := str(it.get("recipe_id", ""))
	var def := PlayerData.get_jewelry_def(jid)
	var name_lbl := Label.new()
	var qty := int(it.get("quantity", 1))
	var qty_tag := ("  ×%s" % PlayerData.format_number(qty)) if qty > 1 else ""
	name_lbl.text = str(def.get("name", jid)) + qty_tag
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	row.add_child(name_lbl)

	var time_lbl := Label.new()
	time_lbl.name = "Time_%s" % str(it.get("id", ""))
	time_lbl.add_theme_font_size_override("font_size", 11)
	_apply_countdown_text(time_lbl, float(it.get("finish_at", 0.0)))
	row.add_child(time_lbl)

	## Rush button (💵): spend Benjamins to finish this craft now. Hidden on a
	## craft that's already finished. The label shows the Benjamin cost to finish
	## and is kept in step by the countdown tick (named so it can be found).
	var finish_at := float(it.get("finish_at", 0.0))
	var queue_id := str(it.get("id", ""))
	var rush_btn := Button.new()
	rush_btn.name = "Rush_%s" % queue_id
	rush_btn.add_theme_font_size_override("font_size", 10)
	rush_btn.custom_minimum_size = Vector2(96, 0)
	_apply_rush_button(rush_btn, finish_at)
	rush_btn.pressed.connect(_on_rush_pressed.bind(queue_id, finish_at, rush_btn))
	row.add_child(rush_btn)

	var wrapper := VBoxContainer.new()
	wrapper.add_child(row)
	wrapper.add_child(HSeparator.new())
	return wrapper


## The Benjamin balance changed (first-load refresh, a claim, or a rush) — re-
## apply every Rush button's enabled state in place so they enable/disable to
## match the new balance without a full panel rebuild.
func _on_money_gun_changed() -> void:
	_update_production_countdowns()


## Sets a rush button's label/visibility/enabled state from remaining time and
## the player's current Benjamin balance. Hidden when the craft is Ready.
func _apply_rush_button(btn: Button, finish_at: float) -> void:
	var rem := GuildProduction.remaining_seconds(finish_at)
	if rem <= 0.0:
		btn.visible = false
		return
	btn.visible = true
	var cost := GuildProduction.rush_cost_for(rem)
	btn.text = "💵 Rush (%d)" % cost
	btn.tooltip_text = "Spend %d Benjamin(s) to finish now (10 min each)." % cost
	## Can't afford the full finish? Still allow a partial rush with whatever the
	## player has, as long as they have at least 1 Benjamin.
	var have := 0
	if get_node_or_null("/root/MoneyGun") != null:
		have = int(MoneyGun.balance)
	btn.disabled = have < 1


## Sets a countdown label's text + color from remaining seconds.
func _apply_countdown_text(lbl: Label, finish_at: float) -> void:
	var rem := GuildProduction.remaining_seconds(finish_at)
	if rem <= 0.0:
		lbl.text = "✅ Ready"
		lbl.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
	else:
		lbl.text = _format_duration(rem)
		lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.6))


## Updates every countdown label + the collect button, in place (no rebuild).
func _update_production_countdowns() -> void:
	for it in GuildProduction.items:
		var fin := float(it.get("finish_at", 0.0))
		var lbl := _prod_list.find_child("Time_%s" % str(it.get("id", "")), true, false)
		if lbl is Label:
			_apply_countdown_text(lbl, fin)
		var rbtn := _prod_list.find_child("Rush_%s" % str(it.get("id", "")), true, false)
		if rbtn is Button:
			_apply_rush_button(rbtn, fin)
	_update_collect_button()


func _update_collect_button() -> void:
	var ready := GuildProduction.ready_count()
	_prod_collect_btn.disabled = ready <= 0
	_prod_collect_btn.text = "Collect Finished (%d)" % ready if ready > 0 else "Collect Finished"


## "1h 23m", "5m 09s", "42s".
func _format_duration(seconds: float) -> String:
	var s := int(ceil(seconds))
	var h := s / 3600
	var m := (s % 3600) / 60
	var sec := s % 60
	if h > 0:
		return "%dh %dm" % [h, m]
	if m > 0:
		return "%dm %02ds" % [m, sec]
	return "%ds" % sec


func _on_production_enqueue_pressed() -> void:
	var sel := _prod_recipe_opt.selected
	if sel < 0:
		return
	var recipe_id := str(_prod_recipe_opt.get_item_metadata(sel))
	var qty := 1
	if _prod_qty_spin != null and is_instance_valid(_prod_qty_spin) and _prod_qty_spin.visible:
		qty = maxi(1, int(_prod_qty_spin.value))
	_prod_enqueue_btn.disabled = true
	_prod_enqueue_btn.text = "…"
	var res := await GuildProduction.enqueue(GuildManager.guild_id(), recipe_id, qty)
	_prod_enqueue_btn.text = "Craft"
	if res.get("ok", false):
		_rebuild_production()
	else:
		GameNotification.show_message("Can't Craft", str(res.get("message", "Could not start the craft.")))
		_prod_enqueue_btn.disabled = GuildProduction.is_full()


func _on_production_collect_pressed() -> void:
	_prod_collect_btn.disabled = true
	var res := await GuildProduction.collect(GuildManager.guild_id())
	if res.get("ok", false):
		var total := int(res.get("total", 0))
		if total > 0:
			GameNotification.show_message("Collected",
				"Collected %d piece(s) into the guild jewelry inventory — list them in the Store tab." % total)
		_rebuild_production()
	else:
		GameNotification.show_message("Collect Failed", str(res.get("message", "Could not collect.")))
		_update_collect_button()


## Rush a craft with Benjamins. Spends enough to finish it (clamped to what the
## player holds; the server charges only what's actually needed). The MoneyGun
## balance is refreshed first so the amount we offer is current.
func _on_rush_pressed(queue_id: String, finish_at: float, btn: Button) -> void:
	btn.disabled = true
	## Make sure we have the latest Benjamin balance before deciding the amount.
	if get_node_or_null("/root/MoneyGun") != null:
		await MoneyGun.refresh()
	var have := int(MoneyGun.balance) if get_node_or_null("/root/MoneyGun") != null else 0
	if have < 1:
		GameNotification.show_message("No Benjamins",
			"Print Benjamins with the Money Gun (Town → Money Gun) to rush crafts.")
		_apply_rush_button(btn, finish_at)
		return

	var rem := GuildProduction.remaining_seconds(finish_at)
	var needed := GuildProduction.rush_cost_for(rem)
	## Spend min(needed, have); the server clamps to needed anyway (overshoot-safe).
	var spend := mini(needed, have)
	if spend < 1:
		_apply_rush_button(btn, finish_at)
		return

	var res := await GuildProduction.rush(GuildManager.guild_id(), queue_id, spend)
	if res.get("ok", false):
		var spent := int(res.get("spent", 0))
		var ready := bool(res.get("ready", false))
		GameNotification.show_message("Rushed",
			("Craft finished! " if ready else "") + "Spent %d Benjamin(s)." % spent)
		## rush() refreshed the queue; rebuild the panel to reflect new times.
		_rebuild_production()
	else:
		GameNotification.show_message("Rush Failed", str(res.get("message", "Could not rush.")))
		_apply_rush_button(btn, finish_at)


# ── Store section ─────────────────────────────────────────────────

func _on_store_nav_pressed() -> void:
	_show_section(_store_panel)
	_store_empty.text = "Loading…"
	_store_empty.visible = true
	if GuildManager.is_in_guild():
		## Refresh both the store (jewelry pool + listings) and the stockpile
		## (raw materials available to list). Both must be loaded before the
		## dropdown can show everything the guild can sell.
		await GuildStore.refresh(GuildManager.guild_id())
		await GuildStockpile.refresh(GuildManager.guild_id())
		## refresh() emits store_changed -> _on_store_changed rebuilds.


func _on_store_changed() -> void:
	if _active_panel == _store_panel:
		_rebuild_store()


## Local inventory changed (e.g. the player deposited materials). Rebuild the
## Stockpile deposit UI, which is driven by the player's local inventory. The
## Store panel is NOT refreshed here — its "List Jewelry" dropdown now reads the
## GUILD jewelry pool (server-side), refreshed via GuildStore.store_changed.
func _on_local_inventory_changed() -> void:
	if _active_panel == _stockpile_panel:
		_rebuild_stockpile()


## Hides the native JewelryOption dropdown and drops a picker Button in its place
## (same row slot). Pressing the button opens a scrollable dialog. Idempotent.
func _ensure_item_picker() -> void:
	if _store_item_picker_btn != null and is_instance_valid(_store_item_picker_btn):
		return
	var list_row := _store_jewelry_opt.get_parent()  ## ListRow
	if list_row == null:
		return
	## Keep the OptionButton as the state holder but take it out of the layout.
	_store_jewelry_opt.visible = false
	_store_item_picker_btn = Button.new()
	_store_item_picker_btn.name = "ItemPickerBtn"
	_store_item_picker_btn.add_theme_font_size_override("font_size", 10)
	_store_item_picker_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_store_item_picker_btn.clip_text = true
	_store_item_picker_btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_store_item_picker_btn.text = "Select item…"
	_store_item_picker_btn.pressed.connect(_open_item_picker_dialog)
	list_row.add_child(_store_item_picker_btn)
	## Sit exactly where the OptionButton was (first in the ListRow).
	list_row.move_child(_store_item_picker_btn, _store_jewelry_opt.get_index())


## Syncs the picker button caption to the OptionButton's current selection.
func _sync_item_picker_caption() -> void:
	if _store_item_picker_btn == null or not is_instance_valid(_store_item_picker_btn):
		return
	var sel := _store_jewelry_opt.selected
	if sel >= 0 and sel < _store_jewelry_opt.item_count:
		_store_item_picker_btn.text = _store_jewelry_opt.get_item_text(sel)
	else:
		_store_item_picker_btn.text = "Select item…"


## Opens a scrollable dialog listing every item currently in the OptionButton
## (jewelry + stockpile). Tapping a row selects it (sets OptionButton.selected,
## fires the change handler to refill qty/price) and closes the dialog. This is
## the touch-friendly replacement for the native popup, which didn't scroll.
func _open_item_picker_dialog() -> void:
	if _store_jewelry_opt.item_count <= 0:
		return
	var dialog := AcceptDialog.new()
	dialog.title = "Select an item to list"
	dialog.get_ok_button().text = "Close"

	var scroll := ScrollContainer.new()
	var vp := get_viewport().get_visible_rect().size
	scroll.custom_minimum_size = Vector2(mini(360, int(vp.x * 0.85)), int(vp.y * 0.6))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	scroll.add_child(list)

	for i in range(_store_jewelry_opt.item_count):
		var meta := str(_store_jewelry_opt.get_item_metadata(i))
		if meta.is_empty():
			continue  ## skip the "nothing to list" placeholder
		var b := Button.new()
		b.text = _store_jewelry_opt.get_item_text(i)
		b.add_theme_font_size_override("font_size", 12)
		b.custom_minimum_size = Vector2(0, 40)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func():
			_store_jewelry_opt.selected = i
			_sync_item_picker_caption()
			_store_jewelry_opt_changed(i)
			dialog.hide())
		list.add_child(b)

	dialog.add_child(scroll)
	add_child(dialog)
	dialog.popup_centered()
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	dialog.close_requested.connect(dialog.queue_free)


## Builds the Sale % dropdown and inserts it into the ListRow just before the
## PriceEdit. Idempotent — only builds once. Changing it rewrites PriceEdit to
## the discounted price for the currently selected item.
func _ensure_discount_dropdown() -> void:
	_ensure_item_picker()
	if _store_discount_opt != null and is_instance_valid(_store_discount_opt):
		return
	var list_row := _store_price_edit.get_parent()  ## ListRow
	if list_row == null:
		return
	var panel := list_row.get_parent()  ## StorePanel
	if panel == null:
		return
	## Own row above ListRow so the narrow List row doesn't overflow on phones.
	var discount_row := HBoxContainer.new()
	discount_row.name = "DiscountRow"
	discount_row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = "Sale price:"
	lbl.add_theme_font_size_override("font_size", 11)
	discount_row.add_child(lbl)
	_store_discount_opt = OptionButton.new()
	_store_discount_opt.name = "DiscountOption"
	_store_discount_opt.add_theme_font_size_override("font_size", 11)
	_store_discount_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for pct in _STORE_DISCOUNT_STEPS:
		var label := "Full price (recommended)" if pct == 100 else ("Sale −%d%%" % (100 - pct))
		_store_discount_opt.add_item(label, pct)
	_store_discount_opt.selected = 0  ## 100% (full price) by default
	_store_discount_opt.item_selected.connect(_on_store_discount_changed)
	discount_row.add_child(_store_discount_opt)
	panel.add_child(discount_row)
	panel.move_child(discount_row, list_row.get_index())


## Discount changed — recompute PriceEdit from the selected item's recommended
## price × the chosen percent.
func _on_store_discount_changed(_idx: int) -> void:
	var sel := _store_jewelry_opt.selected
	if sel < 0:
		return
	var item_key := str(_store_jewelry_opt.get_item_metadata(sel))
	if item_key.is_empty():
		return
	var pct := _store_discount_opt.get_selected_id() if _store_discount_opt != null else 100
	_store_price_edit.text = str(_store_price_at_discount(item_key, pct))


func _rebuild_store() -> void:
	_ensure_discount_dropdown()

	## Bank + member status line.
	_store_status.text = "Guild Bank: %s tokens  •  %d member(s)" % [
		PlayerData.format_number(GuildStore.bank_balance), GuildStore.member_count]

	## Leader-only manual distribute (only meaningful when the bank holds enough
	## to pay at least 1 token to every member).
	var is_leader := PlayerData.guild_role == "leader"
	_store_distribute_btn.visible = is_leader
	_store_distribute_btn.disabled = not (
		is_leader and GuildStore.member_count > 0 and GuildStore.bank_balance >= GuildStore.member_count)

	## Dropdown — lists BOTH guild jewelry (from the jewelry pool) AND excess
	## stockpile items (available = amount − reserved). The metadata stores the
	## full canonical key (e.g. "item:diamond_ring", "gem:gold") so the server
	## knows which pool to draw from.
	_store_jewelry_opt.clear()
	var any_owned := false
	var opt_idx := 0

	## TEMP DEBUG: dump the guild jewelry pool keys so we can see whether the
	## collected recipes actually arrived client-side. Remove once confirmed.
	print("[Store] guild_jewelry pool: ", GuildStore.guild_jewelry)

	## Jewelry from the guild pool.
	for jid in PlayerData.jewelry_ids():
		var owned := GuildStore.guild_jewelry_count("item:%s" % jid)
		if owned <= 0:
			continue
		var def := PlayerData.get_jewelry_def(jid)
		_store_jewelry_opt.add_item("%s (%d)" % [str(def.get("name", jid)), owned], opt_idx)
		_store_jewelry_opt.set_item_metadata(opt_idx, "item:%s" % jid)
		any_owned = true
		opt_idx += 1

	## Food recipes from the guild pool. Recipes are produced like jewelry and
	## land in guild_jewelry_inventory as item:<id>, but they're excluded from
	## jewelry_ids() (so they don't show in the equip UI), so list them here too.
	for rid in PlayerData.recipe_ids():
		var r_owned := GuildStore.guild_jewelry_count("item:%s" % rid)
		if r_owned <= 0:
			continue
		var r_def := PlayerData.get_recipe_def(rid)
		_store_jewelry_opt.add_item("%s (%d)" % [str(r_def.get("name", rid)), r_owned], opt_idx)
		_store_jewelry_opt.set_item_metadata(opt_idx, "item:%s" % rid)
		any_owned = true
		opt_idx += 1

	## Excess stockpile items (available > 0 only; reserved stock is not listable).
	for item_key in GuildStockpile.item_keys():
		if GuildStockpile.get_available(item_key) <= 0:
			continue
		var avail := GuildStockpile.get_available(item_key)
		var display := ItemKeyRegistry.display_name(item_key)
		_store_jewelry_opt.add_item("%s (%d)" % [display, avail], opt_idx)
		_store_jewelry_opt.set_item_metadata(opt_idx, item_key)
		any_owned = true
		opt_idx += 1

	if not any_owned:
		_store_jewelry_opt.add_item("Nothing to list — craft or deposit first", 0)
		_store_jewelry_opt.set_item_metadata(0, "")
	_store_jewelry_opt.selected = 0
	## The native dropdown is hidden; the picker button (scrollable dialog) drives
	## selection. Mirror the current selection onto the button caption.
	_sync_item_picker_caption()
	if _store_item_picker_btn != null and is_instance_valid(_store_item_picker_btn):
		_store_item_picker_btn.disabled = not any_owned
	_store_list_btn.disabled = not any_owned
	_store_qty_edit.editable = any_owned
	_store_price_edit.editable = any_owned
	## Auto-fill qty + price for the initially selected item.
	if any_owned:
		_store_jewelry_opt_changed(0)

	## Listings.
	for c in _store_list.get_children():
		c.queue_free()
	var rows: Array = GuildStore.listings
	_store_empty.visible = rows.is_empty()
	if rows.is_empty():
		_store_empty.text = "Nothing listed yet."
	for l in rows:
		_store_list.add_child(_make_store_row(l))


## One listing row: name, qty @ price, and a Buy button (or Cancel if it's mine).
func _make_store_row(l: Dictionary) -> Control:
	var wrapper := VBoxContainer.new()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	wrapper.add_child(row)

	var item_key := str(l.get("item_key", ""))
	## Display name: jewelry uses ITEM_DEFS name; stockpile items use
	## ItemKeyRegistry.display_name.
	var display_name := item_key
	if item_key.begins_with("item:"):
		var jid := item_key.trim_prefix("item:")
		var def := PlayerData.get_jewelry_def(jid)
		if def.is_empty():
			## Recipes also use item:<id> but aren't in the jewelry defs.
			def = PlayerData.get_recipe_def(jid)
		display_name = str(def.get("name", jid)) if not def.is_empty() else ItemKeyRegistry.display_name(item_key)
	else:
		display_name = ItemKeyRegistry.display_name(item_key)

	var name_lbl := Label.new()
	name_lbl.text = display_name
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	## Clip a long name so it can't force the row (and thus the whole screen)
	## wider than the viewport.
	name_lbl.clip_text = true
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.custom_minimum_size = Vector2(40, 0)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	row.add_child(name_lbl)

	var qty := int(l.get("quantity_remaining", 0))
	var price := int(l.get("unit_price", 0))
	var info_lbl := Label.new()
	info_lbl.text = "x%d  @ %s" % [qty, PlayerData.format_number(price)]
	info_lbl.add_theme_font_size_override("font_size", 11)
	info_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.6))
	row.add_child(info_lbl)

	var listing_id := str(l.get("id", ""))
	## This panel is VIEW/MANAGE only — buying happens in the public storefront,
	## not here. Others' listings just show the seller name; the lister gets a
	## Cancel button to pull their listing back into the guild pool.
	if not bool(l.get("mine", false)):
		var seller_lbl := Label.new()
		seller_lbl.text = str(l.get("seller_name", ""))
		seller_lbl.add_theme_font_size_override("font_size", 10)
		seller_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		row.add_child(seller_lbl)

	if bool(l.get("mine", false)):
		var cancel_btn := Button.new()
		cancel_btn.text = "Cancel"
		cancel_btn.add_theme_font_size_override("font_size", 10)
		cancel_btn.custom_minimum_size = Vector2(60, 0)
		cancel_btn.pressed.connect(_on_store_cancel_pressed.bind(listing_id, cancel_btn))
		row.add_child(cancel_btn)

	wrapper.add_child(HSeparator.new())
	return wrapper


## Recommended (100%) listing price per canonical item key. MUST match
## _item_recommended_price in migration 098. Jewelry: sell_price. Recipes:
## token_value. Stockpile items: suggested_price. The server lets guilds list
## anywhere from 100% down to a 50% floor (a sale), so the client offers 10%
## steps and enforces the same 50% floor locally before the RPC.
const _STORE_RECOMMENDED_PRICE: Dictionary = {
	"item:diamond_ring": 500000, "item:gold_ring": 250000,
	"item:blue_stone_necklace": 400000, "item:pink_stone_necklace": 400000,
	"item:violet_stone_ring": 600000, "item:black_pearl_necklace": 900000,
	"item:emerald_necklace": 1400000, "item:ruby_ring": 2500000,
	"item:copper_horseshoe": 300000, "item:iron_horseshoe": 300000,
	## Food recipes (Σ ingredient token × 10).
	"item:sparkling_grape_juice": 1150, "item:sun_dried_trail_mix": 2190,
	"item:summer_melon_salad": 1340, "item:stuffed_roasted_peppers": 180,
	"item:spicy_plum_jam": 560, "item:roasted_cauliflower_and_squash_soup": 340,
	"item:smoked_apple_glaze": 2500, "item:tropical_oat_and_fruit_mash": 4760,
	"item:coconut_water_hydration": 2500, "item:sweet_banana_crisp": 2190,
	"item:citrus_melon_lemonade": 1300, "item:curried_veggie_bowl": 410,
	"item:spiced_pho_noodle_bowl": 1300,
	"gem:gold": 6, "gem:blue_stone": 8, "gem:pink_stone": 8,
	"gem:violet_stone": 11, "gem:black_pearl": 16, "gem:emerald": 21,
	"gem:ruby": 31, "gem:diamond": 51,
	"polished:blue_stone": 76, "polished:pink_stone": 76,
	"polished:violet_stone": 101, "polished:black_pearl": 151,
	"polished:emerald": 201, "polished:ruby": 301, "polished:diamond": 501,
	"crop:beans": 2, "crop:cucumbers": 5, "crop:peppers": 7,
	"crop:squash": 12, "crop:grapes": 16, "crop:sunflower": 20,
	"crop:cauliflower": 24, "crop:pineapple": 27, "crop:watermelon": 31,
	"fruit:plum": 51, "fruit:lemon": 101, "fruit:apple": 151,
	"fruit:banana": 201, "fruit:coconut": 251,
	"resource:wood": 51, "resource:stick": 26,
	"resource:iron_ore": 76, "resource:iron_bar": 751,
	"resource:copper_ore": 101, "resource:copper_ingot": 1001,
	"resource:gold_ingot": 2501,
}

## Discount steps a guild may apply when listing (100% = recommended, 50% = floor).
const _STORE_DISCOUNT_STEPS := [100, 90, 80, 70, 60, 50]

## Recommended (100%) listing price for a canonical item key.
func _store_recommended_price(item_key: String) -> int:
	return int(_STORE_RECOMMENDED_PRICE.get(item_key, 1))

## Lowest price a guild may list at = ceil(recommended × 0.5). Matches the
## server's _item_min_price in migration 098.
func _store_min_price(item_key: String) -> int:
	return maxi(1, int(ceil(_store_recommended_price(item_key) * 0.5)))

## Price for a given discount percent (100 → recommended, 50 → floor), never
## below the 50% floor.
func _store_price_at_discount(item_key: String, percent: int) -> int:
	var rec := _store_recommended_price(item_key)
	return maxi(_store_min_price(item_key), int(ceil(rec * (percent / 100.0))))


## Called when the jewelry dropdown selection changes. Auto-fills:
##   qty   → all available guild pool stock for that item
##   price → recommended floor (sell_price − 1)
## The player may raise the price but not lower it below the floor.
func _store_jewelry_opt_changed(_idx: int) -> void:
	var sel := _store_jewelry_opt.selected
	if sel < 0:
		return
	var item_key := str(_store_jewelry_opt.get_item_metadata(sel))
	if item_key.is_empty():
		return
	## Available qty depends on which pool the item lives in.
	var avail := 0
	if item_key.begins_with("item:"):
		avail = GuildStore.guild_jewelry_count(item_key)
	else:
		avail = GuildStockpile.get_available(item_key)
	_store_qty_edit.text = str(maxi(avail, 1))
	## Reset to full price when the item changes, then fill PriceEdit from the
	## recommended value × the (now 100%) discount.
	if _store_discount_opt != null and is_instance_valid(_store_discount_opt):
		_store_discount_opt.selected = 0  ## 100%
	var pct := _store_discount_opt.get_selected_id() if _store_discount_opt != null else 100
	_store_price_edit.text = str(_store_price_at_discount(item_key, pct))


func _on_store_list_pressed() -> void:
	var sel := _store_jewelry_opt.selected
	if sel < 0:
		return
	var item_key := str(_store_jewelry_opt.get_item_metadata(sel))
	if item_key.is_empty():
		return
	var qty := int(_store_qty_edit.text) if _store_qty_edit.text.is_valid_int() else 0
	var price := int(_store_price_edit.text) if _store_price_edit.text.is_valid_int() else 0
	if qty <= 0:
		GameNotification.show_message("List Failed", "Enter a valid quantity.")
		return
	## Enforce the 50% sale floor client-side before hitting the server.
	var floor_price := _store_min_price(item_key)
	if price < floor_price:
		GameNotification.show_message("Price Too Low",
			"Lowest allowed is %s (50%% of recommended)." % PlayerData.format_number(floor_price))
		_store_price_edit.text = str(floor_price)
		return

	_store_list_btn.disabled = true
	var res := await GuildStore.list_item(GuildManager.guild_id(), item_key, qty, price)
	_store_list_btn.disabled = false
	if res.get("ok", false):
		## rebuild fires from store_changed inside list_item, which re-fills
		## qty/price for whatever item is next in the dropdown.
		pass
	else:
		## Server may echo the floor in price_below_minimum for extra safety.
		var err := str(res.get("error", ""))
		if err == "price_below_minimum":
			var srv_floor := int(res.get("min_price", floor_price))
			GameNotification.show_message("Price Too Low",
				"Minimum price is %s." % PlayerData.format_number(srv_floor))
			_store_price_edit.text = str(srv_floor)
		else:
			GameNotification.show_message("List Failed", str(res.get("message", "Could not list that item.")))


func _on_store_buy_pressed(listing_id: String, btn: Button) -> void:
	btn.disabled = true
	var res := await GuildStore.buy(GuildManager.guild_id(), listing_id, 1)
	if res.get("ok", false):
		GameNotification.show_message("Purchased",
			"Bought 1 item — added to your inventory.")
		## refresh inside buy() emits store_changed -> rebuild.
	else:
		GameNotification.show_message("Buy Failed", str(res.get("message", "Could not buy that item.")))
		btn.disabled = false


func _on_store_cancel_pressed(listing_id: String, btn: Button) -> void:
	btn.disabled = true
	var res := await GuildStore.cancel(GuildManager.guild_id(), listing_id)
	if res.get("ok", false):
		var qty := int(res.get("returned_qty", 0))
		if qty > 0:
			GameNotification.show_message("Listing Cancelled",
				"Returned %d piece(s) to the guild jewelry inventory." % qty)
		## refresh inside cancel() emits store_changed -> rebuild.
	else:
		GameNotification.show_message("Cancel Failed", str(res.get("message", "Could not cancel.")))
		btn.disabled = false


func _on_store_distribute_pressed() -> void:
	_store_distribute_btn.disabled = true
	var res := await GuildStore.distribute_bank(GuildManager.guild_id())
	if res.get("ok", false):
		var dist := int(res.get("distributed", 0))
		GameNotification.show_message("Bank Distributed",
			"Shared %s tokens evenly among members." % PlayerData.format_number(dist))
		await GuildStore.refresh(GuildManager.guild_id())
	else:
		GameNotification.show_message("Distribute Failed", str(res.get("message", "Could not distribute.")))
		_rebuild_store()
