extends BaseScreen
## Marketplace screen — browse and buy/sell tiles, seeds, and tools.
## Reads from PlayerData shop pool & Garden seed shop; writes immediately on purchase.
##
## Requirements: 1.2, 1.3, 1.5, 1.6, 9.1, 9.4

signal purchase_completed

## Sentinel quantity id meaning "buy as many as possible" (clamped by coins,
## stock, and storage). Uses a large positive value because OptionButton.add_item
## treats a negative id as "unset" and auto-assigns one instead — which broke the
## Max option. This value is far above any real quantity so checks stay unambiguous.
const QTY_MAX := 1_000_000


## ── Dynamic UI references (built in enter()) ─────────────────────
var _coins_label: Label = null
var _tokens_label: Label = null  ## Online marketplace token balance (server-authoritative)
var _market_grid: VBoxContainer = null
var _tab_bar: HBoxContainer = null
var _seeds_content: VBoxContainer = null
var _tools_content: VBoxContainer = null
var _items_content: VBoxContainer = null
var _food_content: VBoxContainer = null
var _gems_content: VBoxContainer = null
var _tiles_scroll: ScrollContainer = null
var _qty_dropdown: OptionButton = null
var _sort_dropdown: OptionButton = null
var _seed_qty_dropdown: OptionButton = null
var _items_qty_dropdown: OptionButton = null  ## Shared sell-quantity for the Items tab
var _gems_qty_dropdown: OptionButton = null  ## Shared sell-quantity for the Gems tab

## ── Sort modes ──────────────────────────────────────────────────
## Shared sort option ids. Shop tabs (tiles/tools/seeds) use Name/Cost/Stock/
## Owned; sell-only tabs (items/gems) use Name/Value/Owned (Value reuses COST).
enum SortMode { NAME = 0, COST = 1, STOCK = 2, OWNED = 3 }

## Remembered sort selection per tab so it persists across rebuilds. Defaults
## to COST (matching the original tiles default of "Cost").
var _sort_mode_seeds: int = SortMode.COST
var _sort_mode_items: int = SortMode.COST
var _sort_mode_gems: int = SortMode.COST

## Live references to each tab's sort dropdown (rebuilt each time) so the change
## handlers can read the selected SortMode id directly.
var _seeds_sort_dropdown: OptionButton = null
var _items_sort_dropdown: OptionButton = null
var _gems_sort_dropdown: OptionButton = null
var _current_tab: String = "tiles"
var _refresh_timer: Timer = null


func enter(params: Dictionary = {}) -> void:
	## Restore persisted per-tab sort selections (qty dropdowns restore at build).
	_sort_mode_seeds = PlayerData.get_market_pref("sort_seeds", SortMode.COST)
	_sort_mode_items = PlayerData.get_market_pref("sort_items", SortMode.COST)
	_sort_mode_gems = PlayerData.get_market_pref("sort_gems", SortMode.COST)

	# Refresh shop pools before display
	PlayerData._check_shop_pool_refresh()
	PlayerData._check_tool_shop_refresh()
	Garden._check_seed_shop_refresh()
	if get_node_or_null("/root/Orchard") != null:
		Orchard._check_sapling_shop_refresh()

	# Connect to PlayerData for live coin/inventory updates (Req 9.1)
	PlayerData.data_changed.connect(_on_data_changed)
	# Live-refresh the seed shop when a restock happens (e.g. Workshop hourglass
	# wraps the timer and regenerates the pool while this screen is open).
	if not Garden.garden_updated.is_connected(_on_garden_updated):
		Garden.garden_updated.connect(_on_garden_updated)
	if get_node_or_null("/root/Orchard") != null \
			and Orchard.has_signal("orchard_updated") \
			and not Orchard.orchard_updated.is_connected(_on_garden_updated):
		Orchard.orchard_updated.connect(_on_garden_updated)

	# Build the full marketplace UI
	_build_ui()
	_show_tab("tiles")

	# Tick once per second so the top-right restock countdown updates live.
	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = 1.0
	_refresh_timer.one_shot = false
	_refresh_timer.timeout.connect(_on_refresh_tick)
	add_child(_refresh_timer)
	_refresh_timer.start()


func exit() -> void:
	if _refresh_timer != null:
		_refresh_timer.stop()
		_refresh_timer = null
	# Disconnect signals (Req 1.6)
	if PlayerData.data_changed.is_connected(_on_data_changed):
		PlayerData.data_changed.disconnect(_on_data_changed)
	if Garden.garden_updated.is_connected(_on_garden_updated):
		Garden.garden_updated.disconnect(_on_garden_updated)
	if get_node_or_null("/root/Orchard") != null \
			and Orchard.has_signal("orchard_updated") \
			and Orchard.orchard_updated.is_connected(_on_garden_updated):
		Orchard.orchard_updated.disconnect(_on_garden_updated)
	if get_node_or_null("/root/MarketplaceAccount") != null \
			and MarketplaceAccount.token_balance_changed.is_connected(_on_token_balance_changed):
		MarketplaceAccount.token_balance_changed.disconnect(_on_token_balance_changed)
	# Clear dynamically built children
	for child in get_children():
		child.queue_free()


func get_screen_name() -> String:
	return "marketplace"


## ── Private: Build UI ────────────────────────────────────────────


func _build_ui() -> void:
	# Dark semi-transparent panel for readability
	var panel := PanelContainer.new()
	panel.name = "BgPanel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.08, 0.08, 0.12, 0.88)
	panel_style.corner_radius_top_left = 6
	panel_style.corner_radius_top_right = 6
	panel_style.corner_radius_bottom_left = 6
	panel_style.corner_radius_bottom_right = 6
	panel_style.content_margin_left = 8
	panel_style.content_margin_right = 8
	panel_style.content_margin_top = 6
	panel_style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", panel_style)
	add_child(panel)

	# Create a light-text theme so all labels inside are readable on dark bg
	var light_theme := Theme.new()
	light_theme.set_color("font_color", "Label", Color(0.9, 0.9, 0.85))
	light_theme.set_color("font_color", "Button", Color(0.1, 0.2, 0.1))

	var content := VBoxContainer.new()
	content.name = "Content"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 6)
	content.theme = light_theme
	panel.add_child(content)

	# Top bar row: title + coins
	var top_bar := HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 12)

	var title := Label.new()
	title.text = "Marketplace"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	top_bar.add_child(title)

	_coins_label = Label.new()
	_coins_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_coins_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_coins_label.add_theme_font_size_override("font_size", 12)
	_coins_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.8))
	top_bar.add_child(_coins_label)
	content.add_child(top_bar)

	## Online marketplace token balance (server-authoritative). Shown on its own
	## row so it never collides with the coins/status label.
	_tokens_label = Label.new()
	_tokens_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tokens_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_tokens_label.add_theme_font_size_override("font_size", 12)
	_tokens_label.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
	content.add_child(_tokens_label)

	_refresh_coins_label()
	_refresh_tokens_label()
	## Pull the authoritative balance from the server if we have an account.
	if get_node_or_null("/root/MarketplaceAccount") != null and MarketplaceAccount.has_account():
		if not MarketplaceAccount.token_balance_changed.is_connected(_on_token_balance_changed):
			MarketplaceAccount.token_balance_changed.connect(_on_token_balance_changed)
		_reconcile_tokens()

	## Online Market button — lives in the top-level content (not per-tab), so it
	## stays visible from every tab. Opens the dedicated online marketplace screen.
	var online_btn := Button.new()
	online_btn.name = "OnlineMarketBtn"
	online_btn.text = "🌐 Online Player Market"
	online_btn.add_theme_font_size_override("font_size", 13)
	online_btn.custom_minimum_size = Vector2(0, 44)
	online_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	online_btn.modulate = Color(0.6, 0.85, 1.0)
	online_btn.pressed.connect(_on_open_online_market)
	content.add_child(online_btn)

	# Storage upgrade button
	var storage_btn := Button.new()
	storage_btn.name = "StorageBtn"
	storage_btn.add_theme_font_size_override("font_size", 11)
	storage_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	storage_btn.custom_minimum_size.y = 48
	storage_btn.pressed.connect(_on_buy_storage)
	_update_storage_btn(storage_btn)
	content.add_child(storage_btn)

	# Refresh shop button (pay 500 coins for immediate restock)
	var refresh_btn := Button.new()
	refresh_btn.name = "RefreshBtn"
	refresh_btn.add_theme_font_size_override("font_size", 11)
	refresh_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	refresh_btn.custom_minimum_size.y = 36
	refresh_btn.pressed.connect(_on_buy_refresh)
	content.add_child(refresh_btn)
	_update_refresh_btn()

	# Tab bar — fill the full width and let the 5 tabs share it equally so the
	# rightmost ("Gems") never clips off-screen on narrow devices.
	_tab_bar = HBoxContainer.new()
	_tab_bar.add_theme_constant_override("separation", 4)
	_tab_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var tab_tiles := Button.new()
	tab_tiles.name = "TabTiles"
	tab_tiles.text = "Pho Tiles"
	tab_tiles.add_theme_font_size_override("font_size", 12)
	tab_tiles.clip_text = true
	tab_tiles.custom_minimum_size = Vector2(0, 48)
	tab_tiles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_tiles.pressed.connect(_on_tab.bind("tiles"))
	_tab_bar.add_child(tab_tiles)

	var tab_seeds := Button.new()
	tab_seeds.name = "TabSeeds"
	tab_seeds.text = "Seeds"
	tab_seeds.add_theme_font_size_override("font_size", 12)
	tab_seeds.clip_text = true
	tab_seeds.custom_minimum_size = Vector2(0, 48)
	tab_seeds.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_seeds.pressed.connect(_on_tab.bind("seeds"))
	_tab_bar.add_child(tab_seeds)

	var tab_tools := Button.new()
	tab_tools.name = "TabTools"
	tab_tools.text = "Tools"
	tab_tools.add_theme_font_size_override("font_size", 12)
	tab_tools.clip_text = true
	tab_tools.custom_minimum_size = Vector2(0, 48)
	tab_tools.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_tools.pressed.connect(_on_tab.bind("tools"))
	_tab_bar.add_child(tab_tools)

	var tab_items := Button.new()
	tab_items.name = "TabItems"
	tab_items.text = "Items"
	tab_items.add_theme_font_size_override("font_size", 12)
	tab_items.clip_text = true
	tab_items.custom_minimum_size = Vector2(0, 48)
	tab_items.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_items.pressed.connect(_on_tab.bind("items"))
	_tab_bar.add_child(tab_items)

	var tab_food := Button.new()
	tab_food.name = "TabFood"
	tab_food.text = "Food"
	tab_food.add_theme_font_size_override("font_size", 12)
	tab_food.clip_text = true
	tab_food.custom_minimum_size = Vector2(0, 48)
	tab_food.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_food.pressed.connect(_on_tab.bind("food"))
	_tab_bar.add_child(tab_food)

	var tab_gems := Button.new()
	tab_gems.name = "TabGems"
	tab_gems.text = "Gems"
	tab_gems.add_theme_font_size_override("font_size", 12)
	tab_gems.clip_text = true
	tab_gems.custom_minimum_size = Vector2(0, 48)
	tab_gems.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_gems.pressed.connect(_on_tab.bind("gems"))
	_tab_bar.add_child(tab_gems)

	content.add_child(_tab_bar)

	# Qty/Sort row for tiles
	var qty_row := HBoxContainer.new()
	qty_row.name = "QtyRow"
	qty_row.add_theme_constant_override("separation", 8)
	var qty_label := Label.new()
	qty_label.text = "   Qty:"
	qty_label.add_theme_font_size_override("font_size", 12)
	qty_row.add_child(qty_label)
	_qty_dropdown = OptionButton.new()
	_qty_dropdown.add_item("1", 1)
	_qty_dropdown.add_item("5", 5)
	_qty_dropdown.add_item("10", 10)
	_qty_dropdown.add_item("25", 25)
	_qty_dropdown.add_item("Max", QTY_MAX)  ## sentinel: buy as many as possible
	_qty_dropdown.add_theme_font_size_override("font_size", 12)
	## Restore + persist the tiles/tools buy-qty selection.
	_select_by_id(_qty_dropdown, PlayerData.get_market_pref("qty_tiles", 1))
	_qty_dropdown.item_selected.connect(func(_i):
		PlayerData.set_market_pref("qty_tiles", _qty_dropdown.get_selected_id())
		## Rebuild the active tab so each Sell button's payout reflects the new
		## quantity (tiles and tools share this Qty dropdown).
		if _current_tab == "tiles":
			_rebuild_tiles_grid()
		elif _current_tab == "tools":
			_rebuild_tool_shop())
	qty_row.add_child(_qty_dropdown)
	var sort_label := Label.new()
	sort_label.text = "  Sort:"
	sort_label.add_theme_font_size_override("font_size", 12)
	qty_row.add_child(sort_label)
	## Shared Qty/Sort row for the tiles and tools tabs (both buy/sell by qty).
	_sort_dropdown = OptionButton.new()
	_sort_dropdown.add_item("Name", SortMode.NAME)
	_sort_dropdown.add_item("Cost", SortMode.COST)
	_sort_dropdown.add_item("Stock", SortMode.STOCK)
	_sort_dropdown.add_item("Owned", SortMode.OWNED)
	_sort_dropdown.add_theme_font_size_override("font_size", 12)
	## Restore + persist the tiles/tools sort selection.
	_select_by_id(_sort_dropdown, PlayerData.get_market_pref("sort_tiles", SortMode.COST))
	_sort_dropdown.item_selected.connect(_on_sort_changed)
	qty_row.add_child(_sort_dropdown)
	content.add_child(qty_row)

	# Tiles scroll + grid
	_tiles_scroll = ScrollContainer.new()
	_tiles_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tiles_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_market_grid = VBoxContainer.new()
	_market_grid.name = "MarketGrid"
	_market_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tiles_scroll.add_child(_market_grid)
	content.add_child(_tiles_scroll)

	# Seeds content area
	_seeds_content = VBoxContainer.new()
	_seeds_content.name = "SeedsContent"
	_seeds_content.visible = false
	_seeds_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_seeds_content.add_theme_constant_override("separation", 6)

	var seed_info := Label.new()
	seed_info.name = "SeedInfoLabel"
	seed_info.add_theme_font_size_override("font_size", 11)
	seed_info.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	seed_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_seeds_content.add_child(seed_info)

	# Seed storage upgrade button — only when seeds/saplings are capped.
	# Seeds/saplings are uncapped now, so this is retired (no button shown).
	if Garden.has_seed_cap():
		var seed_storage_btn := Button.new()
		seed_storage_btn.name = "SeedStorageBtn"
		seed_storage_btn.add_theme_font_size_override("font_size", 11)
		seed_storage_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		seed_storage_btn.custom_minimum_size.y = 36
		seed_storage_btn.pressed.connect(_on_buy_seed_storage)
		_update_seed_storage_btn(seed_storage_btn)
		_seeds_content.add_child(seed_storage_btn)

	# Seed qty dropdown
	var seed_qty_row := HBoxContainer.new()
	seed_qty_row.name = "SeedQtyRow"
	seed_qty_row.add_theme_constant_override("separation", 8)
	seed_qty_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var sq_label := Label.new()
	sq_label.text = "Qty:"
	sq_label.add_theme_font_size_override("font_size", 12)
	seed_qty_row.add_child(sq_label)
	_seed_qty_dropdown = OptionButton.new()
	_seed_qty_dropdown.add_item("1", 1)
	_seed_qty_dropdown.add_item("5", 5)
	_seed_qty_dropdown.add_item("10", 10)
	_seed_qty_dropdown.add_item("25", 25)
	_seed_qty_dropdown.add_item("Max", QTY_MAX)  ## sentinel: buy as many as possible
	_seed_qty_dropdown.add_theme_font_size_override("font_size", 12)
	## Restore + persist the seed/sapling qty selection.
	_select_by_id(_seed_qty_dropdown, PlayerData.get_market_pref("qty_seeds", 1))
	_seed_qty_dropdown.item_selected.connect(func(_i):
		PlayerData.set_market_pref("qty_seeds", _seed_qty_dropdown.get_selected_id())
		## Rebuild so each Sell button's payout reflects the new quantity.
		_rebuild_seed_shop())
	seed_qty_row.add_child(_seed_qty_dropdown)
	_seeds_content.add_child(seed_qty_row)

	var seed_scroll := ScrollContainer.new()
	seed_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	seed_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var seed_grid := VBoxContainer.new()
	seed_grid.name = "SeedShopGrid"
	seed_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_scroll.add_child(seed_grid)
	_seeds_content.add_child(seed_scroll)
	content.add_child(_seeds_content)

	# Tools content area
	_tools_content = VBoxContainer.new()
	_tools_content.name = "ToolsContent"
	_tools_content.visible = false
	_tools_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tools_content.add_theme_constant_override("separation", 6)

	var tool_info := Label.new()
	tool_info.name = "ToolInfoLabel"
	tool_info.add_theme_font_size_override("font_size", 11)
	tool_info.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	tool_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tools_content.add_child(tool_info)

	var tool_scroll := ScrollContainer.new()
	tool_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tool_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var tool_grid := VBoxContainer.new()
	tool_grid.name = "ToolShopGrid"
	tool_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tool_scroll.add_child(tool_grid)
	_tools_content.add_child(tool_scroll)
	content.add_child(_tools_content)

	# Items content area
	_items_content = VBoxContainer.new()
	_items_content.name = "ItemsContent"
	_items_content.visible = false
	_items_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_items_content.add_theme_constant_override("separation", 6)

	var items_scroll := ScrollContainer.new()
	items_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	items_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var items_grid := VBoxContainer.new()
	items_grid.name = "ItemsGrid"
	items_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	items_scroll.add_child(items_grid)
	_items_content.add_child(items_scroll)
	content.add_child(_items_content)

	# Food content area (recipes — Use to activate a boost, or sell)
	_food_content = VBoxContainer.new()
	_food_content.name = "FoodContent"
	_food_content.visible = false
	_food_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_food_content.add_theme_constant_override("separation", 6)

	var food_scroll := ScrollContainer.new()
	food_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	food_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var food_grid := VBoxContainer.new()
	food_grid.name = "FoodGrid"
	food_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	food_scroll.add_child(food_grid)
	_food_content.add_child(food_scroll)
	content.add_child(_food_content)

	# Gems content area (sell gemstones from gold panning)
	_gems_content = VBoxContainer.new()
	_gems_content.name = "GemsContent"
	_gems_content.visible = false
	_gems_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_gems_content.add_theme_constant_override("separation", 6)

	var gems_scroll := ScrollContainer.new()
	gems_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	gems_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var gems_grid := VBoxContainer.new()
	gems_grid.name = "GemsGrid"
	gems_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gems_scroll.add_child(gems_grid)
	_gems_content.add_child(gems_scroll)
	content.add_child(_gems_content)

	# Back button at bottom
	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.add_theme_font_size_override("font_size", 14)
	back_btn.custom_minimum_size = Vector2(0, 48)
	back_btn.pressed.connect(_on_back_pressed)
	content.add_child(back_btn)


## ── Private: Tab switching ───────────────────────────────────────


func _on_tab(tab_name: String) -> void:
	_show_tab(tab_name)


func _show_tab(tab_name: String) -> void:
	_current_tab = tab_name
	# Toggle visibility
	var qty_row = _tiles_scroll.get_parent().get_node_or_null("QtyRow")
	if qty_row:
		qty_row.visible = (tab_name == "tiles" or tab_name == "tools")
	var storage_btn = _tiles_scroll.get_parent().get_node_or_null("StorageBtn")
	if storage_btn:
		storage_btn.visible = (tab_name == "tiles")
	var refresh_btn = _tiles_scroll.get_parent().get_node_or_null("RefreshBtn")
	if refresh_btn:
		refresh_btn.visible = (tab_name != "items" and tab_name != "food")
	_tiles_scroll.visible = (tab_name == "tiles")
	_seeds_content.visible = (tab_name == "seeds")
	_tools_content.visible = (tab_name == "tools")
	_items_content.visible = (tab_name == "items")
	_food_content.visible = (tab_name == "food")
	_gems_content.visible = (tab_name == "gems")

	# Highlight active tab
	if _tab_bar:
		_tab_bar.get_node("TabTiles").modulate = Color(1.0, 0.85, 0.2) if tab_name == "tiles" else Color.WHITE
		_tab_bar.get_node("TabSeeds").modulate = Color(1.0, 0.85, 0.2) if tab_name == "seeds" else Color.WHITE
		_tab_bar.get_node("TabTools").modulate = Color(1.0, 0.85, 0.2) if tab_name == "tools" else Color.WHITE
		_tab_bar.get_node("TabItems").modulate = Color(1.0, 0.85, 0.2) if tab_name == "items" else Color.WHITE
		_tab_bar.get_node("TabFood").modulate = Color(1.0, 0.85, 0.2) if tab_name == "food" else Color.WHITE
		_tab_bar.get_node("TabGems").modulate = Color(1.0, 0.85, 0.2) if tab_name == "gems" else Color.WHITE

	# Rebuild active tab content
	match tab_name:
		"tiles":
			_rebuild_tiles_grid()
		"seeds":
			_rebuild_seed_shop()
		"tools":
			_rebuild_tool_shop()
		"items":
			_rebuild_items_tab()
		"food":
			_rebuild_food_tab()
		"gems":
			_rebuild_gems_tab()


## ── Private: Tiles Grid ──────────────────────────────────────────


func _rebuild_tiles_grid() -> void:
	for child in _market_grid.get_children():
		child.queue_free()

	_refresh_coins_label()

	# Get piece definitions — skip enemy-only types
	var all_defs := PieceRegistry.get_all()
	var defs: Array = []
	for d in all_defs:
		if d != null and d.display_name != null and d.display_name != "":
			if d.piece_type == Piece.Type.CLAW or d.piece_type == Piece.Type.BITE:
				continue
			defs.append(d)

	# Sort based on dropdown (shared with the tools tab).
	var sort_mode: int = SortMode.COST
	if _sort_dropdown != null and is_instance_valid(_sort_dropdown):
		sort_mode = _sort_dropdown.get_selected_id()
	_apply_sort(defs, sort_mode,
		func(d): return d.display_name,
		func(d): return PlayerData.get_piece_price(d.piece_type),
		func(d): return PlayerData.get_shop_stock(d.piece_type),
		func(d): return PlayerData.count_in_inventory(d.piece_type))

	for def in defs:
		var price := PlayerData.get_piece_price(def.piece_type)
		var owned := PlayerData.count_in_inventory(def.piece_type)
		var stock: int = PlayerData.get_shop_stock(def.piece_type) if def.piece_type != Piece.Type.PAWN else 99

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)

		# Icon
		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(48, 48)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.tooltip_text = "%s\n%s" % [def.display_name, def.description]
		var icon := PieceSprites.get_icon(def.sprite_index)
		if icon:
			icon_btn.icon = icon
			icon_btn.expand_icon = true
		var icon_style := StyleBoxFlat.new()
		icon_style.bg_color = Color(0.18, 0.18, 0.28)
		icon_style.border_width_left = 1; icon_style.border_width_right = 1
		icon_style.border_width_top = 1; icon_style.border_width_bottom = 1
		icon_style.border_color = Color(0.35, 0.35, 0.5)
		icon_btn.add_theme_stylebox_override("normal", icon_style)
		row.add_child(icon_btn)

		# Info column
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = "%s  (%d pt)" % [def.display_name, def.base_points]
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
		info.add_child(name_lbl)
		var price_text := "FREE" if price == 0 else "%s coins" % PlayerData.format_number(price)
		var price_lbl := Label.new()
		price_lbl.text = "Buy: %s : Sell: %s\nIn Stock: %d : In Inventory: %d" % [
			price_text, PlayerData.format_number(price / 2), stock, owned]
		price_lbl.add_theme_font_size_override("font_size", 11)
		price_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.8))
		info.add_child(price_lbl)
		row.add_child(info)

		# Buy button
		var buy_btn := Button.new()
		buy_btn.text = "Buy"
		buy_btn.add_theme_font_size_override("font_size", 12)
		buy_btn.custom_minimum_size = Vector2(44, 48)
		buy_btn.disabled = (stock <= 0 and def.piece_type != Piece.Type.PAWN)
		buy_btn.pressed.connect(_on_buy_piece.bind(def.piece_type))
		row.add_child(buy_btn)

		# Sell button — shows the coin payout for the current quantity selection.
		var sell_btn := Button.new()
		sell_btn.text = _sell_btn_text(_resolve_sell_qty(_qty_dropdown, owned), price / 2)
		sell_btn.add_theme_font_size_override("font_size", 12)
		sell_btn.custom_minimum_size = Vector2(56, 48)
		sell_btn.disabled = (owned <= 0)
		sell_btn.pressed.connect(_on_sell_piece.bind(def.piece_type))
		row.add_child(sell_btn)

		_market_grid.add_child(row)
		_market_grid.add_child(HSeparator.new())


## ── Private: Buy/Sell tiles (Req 9.4 — immediate write) ──────────


func _on_buy_piece(piece_type: Piece.Type) -> void:
	var qty := _get_qty()
	if PlayerData.get_inventory_size() >= PlayerData.MAX_INVENTORY:
		_coins_label.text = "Inventory FULL (%d / %d)" % [
			PlayerData.get_inventory_size(), PlayerData.MAX_INVENTORY]
		return
	## "Max" — buy as many as coins, stock, and inventory space allow.
	if qty == QTY_MAX:
		var price: int = maxi(PlayerData.get_piece_price(piece_type), 1)
		var affordable: int = int(PlayerData.coins / price)
		var space: int = PlayerData.MAX_INVENTORY - PlayerData.get_inventory_size()
		qty = mini(affordable, space)
		if piece_type != Piece.Type.PAWN:
			qty = mini(qty, PlayerData.get_shop_stock(piece_type))
		if qty <= 0:
			_coins_label.text = "Can't buy any (coins/stock/space)."
			return
		## purchase_tiles clamps each call to MAX_PURCHASE_QTY, so buy in batches
		## until the whole "Max" amount is purchased.
		var bought := 0
		while bought < qty and PlayerData.purchase_tiles(piece_type, qty - bought):
			var step: int = mini(qty - bought, PlayerData.MAX_PURCHASE_QTY)
			bought += step
		if bought > 0:
			_rebuild_tiles_grid()
			purchase_completed.emit()
		return
	var success := PlayerData.purchase_tiles(piece_type, qty)
	if success:
		_rebuild_tiles_grid()
		purchase_completed.emit()
	else:
		_coins_label.text = "Not enough coins! (%s)" % PlayerData.format_number(PlayerData.coins)


func _on_sell_piece(piece_type: Piece.Type) -> void:
	var qty := _get_qty()
	var owned := PlayerData.count_in_inventory(piece_type)
	if owned <= 0:
		_coins_label.text = "None to sell!"
		return
	## "Max" sells everything owned of this piece. sell_tiles already handles the
	## full quantity in ONE pass (single inventory scan + single save), so call
	## it once rather than looping per-tile — looping is O(n²) on the inventory
	## array plus one save per tile, which froze the app on large stacks.
	var to_sell := owned if qty == QTY_MAX else mini(qty, owned)
	if to_sell > 0:
		PlayerData.sell_tiles(piece_type, to_sell)
	_rebuild_tiles_grid()


func _get_qty() -> int:
	if _qty_dropdown == null or not is_instance_valid(_qty_dropdown):
		return 1
	return _qty_dropdown.get_selected_id()


## ── Private: Seed Shop ───────────────────────────────────────────


func _rebuild_seed_shop() -> void:
	Garden._check_seed_shop_refresh()
	if get_node_or_null("/root/Orchard") != null:
		Orchard._check_sapling_shop_refresh()

	var shop_grid = _seeds_content.find_child("SeedShopGrid", true, false)
	if shop_grid == null:
		return

	# Update info label
	_refresh_seed_info_label()

	for child in shop_grid.get_children():
		child.queue_free()

	## Sort row (Name / Cost / Stock / Owned), remembered across rebuilds.
	var seed_sort_parts := _make_sort_row(true, "Cost", _sort_mode_seeds, _on_seeds_sort_changed)
	_seeds_sort_dropdown = seed_sort_parts[1]
	shop_grid.add_child(seed_sort_parts[0])

	## Build a sorted list of seed indices per the selected sort mode.
	var seed_indices: Array = []
	for si in range(GardenData.PLANT_DEFS.size()):
		seed_indices.append(si)
	_apply_sort(seed_indices, _sort_mode_seeds,
		func(idx): return str(GardenData.PLANT_DEFS[idx].get("name", "")),
		func(idx): return int(GardenData.PLANT_DEFS[idx].get("seed_cost", 0)),
		func(idx): return Garden.get_seed_shop_stock(idx),
		func(idx): return Garden.get_seed_count(idx))

	for i in seed_indices:
		var def: Dictionary = GardenData.PLANT_DEFS[i]
		var stock: int = Garden.get_seed_shop_stock(i)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		# Seed icon (first frame of spritesheet)
		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(36, 36)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tex: Texture2D = load(def["sprite"])
		if tex:
			var frame_w: float = tex.get_width() / 4.0
			var atlas := AtlasTexture.new()
			atlas.atlas = tex
			atlas.region = Rect2(0, 0, frame_w, tex.get_height())
			icon_btn.icon = atlas
			icon_btn.expand_icon = true
		var icon_style := StyleBoxFlat.new()
		icon_style.bg_color = Color(0.18, 0.28, 0.18)
		icon_style.border_width_left = 1; icon_style.border_width_right = 1
		icon_style.border_width_top = 1; icon_style.border_width_bottom = 1
		icon_style.border_color = Color(0.35, 0.5, 0.35)
		icon_btn.add_theme_stylebox_override("normal", icon_style)
		row.add_child(icon_btn)

		# Name + cost + harvest info
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = "%s — %s" % [def["name"], PlayerData.format_number(def["seed_cost"])]
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 0.9))
		info.add_child(name_lbl)
		var detail_lbl := Label.new()
		var effective_secs: float = Garden.get_effective_harvest_time(i)
		var time_text := FormatUtils.format_duration(effective_secs)
		## Crops are sold (not auto-harvested) — show the per-crop MARKETPLACE sell
		## value including the garden-profit prestige, so players see what one
		## harvested crop will fetch.
		var crop_id: String = PlayerData.get_crop_id_for_plant_type(i)
		var sell_value: int = PlayerData.get_crop_sell_value(crop_id) if crop_id != "" \
				else int(def["reward"] * PlayerData.get_garden_profit_multiplier())
		## "Crop:" = what one harvested crop sells for (prestige-scaled).
		## "Sellback:" = what this seed sells back for (half its buy price).
		detail_lbl.text = "%s | Crop:%s | Sellback:%s | Stk:%d | Own:%d" % [
			time_text, PlayerData.format_coins(sell_value),
			PlayerData.format_coins(PlayerData.get_seed_sell_value(i)),
			stock, Garden.get_seed_count(i)]
		detail_lbl.add_theme_font_size_override("font_size", 9)
		detail_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
		detail_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		info.add_child(detail_lbl)
		row.add_child(info)

		# Buy button
		var buy_btn := Button.new()
		buy_btn.text = "Buy"
		buy_btn.add_theme_font_size_override("font_size", 11)
		buy_btn.custom_minimum_size = Vector2(44, 48)
		var can_afford: bool = PlayerData.coins >= int(def["seed_cost"])
		var has_space: bool = Garden.get_total_seeds_and_saplings() < Garden.MAX_SEED_STORAGE
		buy_btn.disabled = (stock <= 0) or (not can_afford) or (not has_space)
		buy_btn.pressed.connect(_on_buy_seed.bind(i))
		row.add_child(buy_btn)

		# Sell button — sells owned seeds at half their buy price (uses the seed
		# qty dropdown). Disabled when none are owned.
		var seed_owned := Garden.get_seed_count(i)
		var sell_btn := Button.new()
		sell_btn.text = _sell_btn_text(_seed_sell_qty(seed_owned), PlayerData.get_seed_sell_value(i))
		sell_btn.add_theme_font_size_override("font_size", 11)
		sell_btn.custom_minimum_size = Vector2(56, 48)
		sell_btn.disabled = seed_owned <= 0
		sell_btn.pressed.connect(_on_sell_seed.bind(i))
		row.add_child(sell_btn)

		shop_grid.add_child(row)

	# Tree Saplings section in Seed Shop
	if get_node_or_null("/root/Orchard") != null:
		var sep := HSeparator.new()
		shop_grid.add_child(sep)

		var sapling_header := Label.new()
		sapling_header.text = "── Tree Saplings ──"
		sapling_header.add_theme_font_size_override("font_size", 13)
		sapling_header.add_theme_color_override("font_color", Color(0.5, 0.9, 0.5))
		sapling_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		shop_grid.add_child(sapling_header)

		## Sort saplings by the same mode as seeds (within their own section).
		var sapling_indices: Array = []
		for ti in range(Orchard.TREE_DEFS.size()):
			sapling_indices.append(ti)
		_apply_sort(sapling_indices, _sort_mode_seeds,
			func(idx): return str(Orchard.TREE_DEFS[idx].get("fruit_name", "")),
			func(idx): return int(Orchard.TREE_DEFS[idx].get("sapling_cost", 0)),
			func(idx): return Orchard.get_sapling_shop_stock(idx),
			func(idx): return Orchard.get_sapling_count(idx))

		for t in sapling_indices:
			var t_def: Dictionary = Orchard.TREE_DEFS[t]
			var stock: int = Orchard.get_sapling_shop_stock(t)
			var t_row := HBoxContainer.new()
			t_row.add_theme_constant_override("separation", 8)

			var t_icon := Button.new()
			t_icon.custom_minimum_size = Vector2(36, 36)
			t_icon.focus_mode = Control.FOCUS_NONE
			t_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			## Fruit trees show their fruit icon; the Christmas Conifer produces
			## presents, so it shows THIS SAVE's assigned present sprite.
			var atlas = null
			if bool(Orchard.TREE_DEFS[t].get("is_conifer", false)):
				atlas = PlayerData.get_present_texture(PlayerData.ensure_present_variant())
			else:
				atlas = Orchard.get_fruit_texture(t)
			if atlas:
				t_icon.icon = atlas
				t_icon.expand_icon = true
			var icon_style := StyleBoxFlat.new()
			icon_style.bg_color = Color(0.2, 0.3, 0.2)
			icon_style.border_width_left = 1; icon_style.border_width_right = 1
			icon_style.border_width_top = 1; icon_style.border_width_bottom = 1
			icon_style.border_color = Color(0.4, 0.7, 0.4)
			t_icon.add_theme_stylebox_override("normal", icon_style)
			t_row.add_child(t_icon)

			var t_info := VBoxContainer.new()
			t_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var t_name := Label.new()
			t_name.text = "%s Sapling — %s" % [t_def["fruit_name"], PlayerData.format_number(t_def["sapling_cost"])]
			t_name.add_theme_font_size_override("font_size", 12)
			t_name.add_theme_color_override("font_color", Color(1.0, 1.0, 0.9))
			t_info.add_child(t_name)

			var t_detail := Label.new()
			## Show the sapling's sellback value (half its buy price) so the Sell
			## button's payout is clear, plus the fruit's daily sell price.
			t_detail.text = "Stk:%d | Own:%d | Sellback:%s | %s fruit:%s" % [
				stock, Orchard.get_sapling_count(t),
				PlayerData.format_coins(Orchard.get_sapling_sell_value(t)),
				t_def["fruit_name"], PlayerData.format_coins(t_def["fruit_sell_price"])]
			t_detail.add_theme_font_size_override("font_size", 9)
			t_detail.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
			t_info.add_child(t_detail)
			t_row.add_child(t_info)

			var t_buy_btn := Button.new()
			t_buy_btn.text = "Buy"
			t_buy_btn.add_theme_font_size_override("font_size", 11)
			t_buy_btn.custom_minimum_size = Vector2(44, 48)
			var cost: int = int(t_def["sapling_cost"])
			var can_afford: bool = PlayerData.coins >= cost
			## Saplings share the seed storage pool.
			var has_space: bool = Garden.get_total_seeds_and_saplings() < Garden.MAX_SEED_STORAGE
			t_buy_btn.disabled = (stock <= 0) or (not can_afford) or (not has_space)
			t_buy_btn.pressed.connect(_on_buy_sapling.bind(t))
			t_row.add_child(t_buy_btn)

			# Sell button — sells owned saplings at half buy price (seed qty
			# dropdown). Disabled when none are owned.
			var sap_owned := Orchard.get_sapling_count(t)
			var t_sell_btn := Button.new()
			t_sell_btn.text = _sell_btn_text(_seed_sell_qty(sap_owned), Orchard.get_sapling_sell_value(t))
			t_sell_btn.add_theme_font_size_override("font_size", 11)
			t_sell_btn.custom_minimum_size = Vector2(56, 48)
			t_sell_btn.disabled = sap_owned <= 0
			t_sell_btn.pressed.connect(_on_sell_sapling.bind(t))
			t_row.add_child(t_sell_btn)

			shop_grid.add_child(t_row)


func _on_buy_seed(plant_type: int) -> void:
	var def: Dictionary = GardenData.PLANT_DEFS[plant_type]
	var cost: int = int(def["seed_cost"])
	var qty: int = 1
	if _seed_qty_dropdown != null and is_instance_valid(_seed_qty_dropdown):
		qty = _seed_qty_dropdown.get_item_id(_seed_qty_dropdown.selected)
	# Clamp by affordability, stock, and storage space
	var affordable_qty := int(PlayerData.coins / maxi(cost, 1))
	var stock := Garden.get_seed_shop_stock(plant_type)
	var space := Garden.MAX_SEED_STORAGE - Garden.get_total_seeds_and_saplings()
	## "Max" — the affordability/stock/space clamps below determine the amount.
	if qty == QTY_MAX:
		qty = maxi(affordable_qty, maxi(stock, space))
	qty = mini(qty, mini(affordable_qty, mini(stock, space)))
	if qty <= 0:
		return
	if not Garden.consume_seed_shop_stock(plant_type, qty):
		return
	PlayerData.coins -= cost * qty
	PlayerData.save_data()
	PlayerData.data_changed.emit()
	Garden.add_seeds(plant_type, qty)
	_rebuild_seed_shop()


func _on_buy_sapling(tree_type: int) -> void:
	if get_node_or_null("/root/Orchard") == null:
		return
	var def: Dictionary = Orchard.get_tree_def(tree_type)
	var cost: int = int(def.get("sapling_cost", 0))
	var stock: int = Orchard.get_sapling_shop_stock(tree_type)
	if stock <= 0 or PlayerData.coins < cost:
		return

	## Honor the seed-tab quantity selector (saplings live in the seeds tab).
	var qty: int = 1
	if _seed_qty_dropdown != null and is_instance_valid(_seed_qty_dropdown):
		qty = _seed_qty_dropdown.get_item_id(_seed_qty_dropdown.selected)
	var affordable: int = int(PlayerData.coins / maxi(cost, 1))
	## Saplings share the seed storage pool.
	var space: int = Garden.MAX_SEED_STORAGE - Garden.get_total_seeds_and_saplings()
	if qty == QTY_MAX:
		qty = maxi(affordable, maxi(stock, space))
	## Clamp by affordability, shop stock, and shared seed/sapling storage space.
	qty = mini(qty, mini(affordable, mini(stock, space)))
	if qty <= 0:
		if space <= 0:
			_coins_label.text = "Seed/Sapling storage full!"
		return

	if not Orchard.consume_sapling_shop_stock(tree_type, qty):
		return
	PlayerData.coins -= cost * qty
	Orchard.add_saplings(tree_type, qty)
	PlayerData.save_data()
	PlayerData.data_changed.emit()
	_rebuild_seed_shop()
	_refresh_coins_label()


## Returns the seed-tab quantity selection (from _seed_qty_dropdown), resolving
## "Max"/QTY_MAX to `owned` and clamping to it. Defaults to 1 if unavailable.
func _seed_sell_qty(owned: int) -> int:
	var sel := 1
	if _seed_qty_dropdown != null and is_instance_valid(_seed_qty_dropdown):
		sel = _seed_qty_dropdown.get_item_id(_seed_qty_dropdown.selected)
	if sel == QTY_MAX:
		return owned
	return mini(sel, owned)


func _on_sell_seed(plant_type: int) -> void:
	var qty := _seed_sell_qty(Garden.get_seed_count(plant_type))
	if qty > 0 and PlayerData.sell_seed(plant_type, qty) > 0:
		_rebuild_seed_shop()
		_refresh_coins_label()


func _on_sell_sapling(tree_type: int) -> void:
	if get_node_or_null("/root/Orchard") == null:
		return
	var qty := _seed_sell_qty(Orchard.get_sapling_count(tree_type))
	if qty > 0 and Orchard.sell_sapling(tree_type, qty) > 0:
		_rebuild_seed_shop()
		_refresh_coins_label()


## ── Private: Tool Shop ───────────────────────────────────────────


func _rebuild_tool_shop() -> void:
	PlayerData._check_tool_shop_refresh()

	var tool_grid = _tools_content.find_child("ToolShopGrid", true, false)
	if tool_grid == null:
		return

	# Update info label
	_refresh_tool_info_label()

	for child in tool_grid.get_children():
		child.queue_free()

	## Deep Mine Excavator — one-time 5,000,000c unlock (shown once Deep Mine is
	## unlocked). Always pinned at the top, above the sorted tool rows.
	_add_excavator_row(tool_grid)

	## Sort the tool list by the shared Qty/Sort dropdown (same as the tiles tab).
	var tool_defs: Array = PlayerData.TOOL_DEFS.duplicate()
	var tool_sort_mode: int = SortMode.COST
	if _sort_dropdown != null and is_instance_valid(_sort_dropdown):
		tool_sort_mode = _sort_dropdown.get_selected_id()
	_apply_sort(tool_defs, tool_sort_mode,
		func(d): return str(d.get("name", "")),
		func(d): return int(d.get("price", 0)),
		func(d): return PlayerData.get_tool_shop_stock(int(d.get("id", 0))),
		func(d): return PlayerData.get_tool_count(int(d.get("id", 0))))

	for def in tool_defs:
		var tid: int = int(def["id"])
		var stock: int = PlayerData.get_tool_shop_stock(tid)
		var owned: int = PlayerData.get_tool_count(tid)
		var price: int = PlayerData.get_tool_buy_price(tid)
		var is_permanent: bool = bool(def.get("permanent", false))

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		# Tool icon
		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(40, 40)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tool_tex: Texture2D = load(def.get("sprite", ""))
		if tool_tex:
			var sprite := TextureRect.new()
			sprite.texture = tool_tex
			sprite.custom_minimum_size = Vector2(32, 32)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_btn.add_child(sprite)
		row.add_child(icon_btn)

		# Name + description + info
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		if is_permanent and owned > 0:
			name_lbl.text = "%s — ✓ Owned" % def["name"]
			name_lbl.modulate = Color(0.4, 1.0, 0.4)
		else:
			name_lbl.text = "%s — %s" % [def["name"], PlayerData.format_number(price)]
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 0.9))
		info.add_child(name_lbl)
		var desc_lbl := Label.new()
		if is_permanent:
			desc_lbl.text = "%s" % def["description"]
		else:
			desc_lbl.text = "%s  |  Stock: %d  |  Owned: %d" % [
				def["description"], stock, owned]
		desc_lbl.add_theme_font_size_override("font_size", 9)
		desc_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		info.add_child(desc_lbl)
		row.add_child(info)

		# Buy button
		var buy_btn := Button.new()
		buy_btn.add_theme_font_size_override("font_size", 11)
		buy_btn.custom_minimum_size = Vector2(60, 48)
		if is_permanent and owned > 0:
			buy_btn.text = "Owned"
			buy_btn.disabled = true
		elif is_permanent and owned <= 0:
			# Permanent tools are always available to buy (not stock-limited)
			buy_btn.text = "Buy"
			buy_btn.disabled = (PlayerData.coins < price)
			buy_btn.pressed.connect(_on_buy_tool.bind(tid))
		else:
			buy_btn.text = "Buy"
			buy_btn.disabled = (stock <= 0) or (PlayerData.coins < price)
			buy_btn.pressed.connect(_on_buy_tool.bind(tid))
		row.add_child(buy_btn)

		# Sell button — non-permanent tools only (Tractor is permanent and never
		# sellable). Sells at half buy price using the top Qty dropdown.
		if not is_permanent:
			var sell_btn := Button.new()
			sell_btn.text = _sell_btn_text(_resolve_sell_qty(_qty_dropdown, owned), price / 2)
			sell_btn.add_theme_font_size_override("font_size", 11)
			sell_btn.custom_minimum_size = Vector2(60, 48)
			sell_btn.disabled = owned <= 0
			sell_btn.pressed.connect(_on_sell_tool.bind(tid))
			row.add_child(sell_btn)

		tool_grid.add_child(row)


func _on_buy_tool(tool_id: int) -> void:
	var def: Dictionary = PlayerData.TOOL_DEFS[tool_id]
	var price: int = PlayerData.get_tool_buy_price(tool_id)
	if PlayerData.coins < price:
		return
	var is_permanent: bool = bool(def.get("permanent", false))

	if is_permanent:
		# Permanent tools: buy once, no stock check needed
		PlayerData.coins -= price
		PlayerData.add_tool(tool_id, 1)
		PlayerData.save_data()
		PlayerData.data_changed.emit()
		_rebuild_tool_shop()
		return

	## Determine quantity: for non-permanent tools, allow buying multiple
	var qty: int = 1
	if _qty_dropdown != null and is_instance_valid(_qty_dropdown):
		qty = _qty_dropdown.get_selected_id()
	## Clamp by affordability and stock
	var affordable: int = int(PlayerData.coins / maxi(price, 1))
	var stock: int = PlayerData.get_tool_shop_stock(tool_id)
	## "Max" — buy as many as coins and stock allow.
	if qty == QTY_MAX:
		qty = maxi(affordable, stock)
	qty = mini(qty, mini(affordable, stock))
	if qty <= 0:
		return
	if not PlayerData.consume_tool_shop_stock(tool_id, qty):
		return
	PlayerData.coins -= price * qty
	PlayerData.add_tool(tool_id, qty)
	PlayerData.save_data()
	PlayerData.data_changed.emit()
	_rebuild_tool_shop()


## Sells a non-permanent tool at half its buy price, honoring the top Qty
## dropdown ("Max"/QTY_MAX sells all owned). Permanent tools (Tractor) are
## rejected by PlayerData.sell_tool, so this is a no-op for them.
func _on_sell_tool(tool_id: int) -> void:
	var owned := PlayerData.get_tool_count(tool_id)
	if owned <= 0:
		return
	var qty: int = 1
	if _qty_dropdown != null and is_instance_valid(_qty_dropdown):
		qty = _qty_dropdown.get_selected_id()
	if qty == QTY_MAX:
		qty = owned
	qty = mini(qty, owned)
	if qty > 0 and PlayerData.sell_tool(tool_id, qty) > 0:
		_rebuild_tool_shop()
		_refresh_coins_label()


## Adds the one-time Deep Mine Excavator purchase row (5,000,000c). Only appears
## once the Deep Mine is unlocked; shows "Owned" state after purchase.
func _add_excavator_row(tool_grid: Control) -> void:
	if get_node_or_null("/root/DeepMine") == null:
		return
	if not DeepMine.is_unlocked():
		return

	var owned := DeepMine.has_excavator()
	var price := DeepMineData.EXCAVATOR_COST

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	# Icon
	var icon_btn := Button.new()
	icon_btn.custom_minimum_size = Vector2(40, 40)
	icon_btn.focus_mode = Control.FOCUS_NONE
	icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tex := DeepMine.get_excavator_texture()
	if tex:
		var sprite := TextureRect.new()
		sprite.texture = tex
		sprite.custom_minimum_size = Vector2(32, 32)
		sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
		sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon_btn.add_child(sprite)
	row.add_child(icon_btn)

	# Name + description
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_lbl := Label.new()
	if owned:
		name_lbl.text = "Excavator — ✓ Owned"
		name_lbl.modulate = Color(0.4, 1.0, 0.4)
	else:
		name_lbl.text = "Excavator — %s" % PlayerData.format_number(price)
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 0.9))
	info.add_child(name_lbl)
	var desc_lbl := Label.new()
	desc_lbl.text = "Deep Mine: dig a full row without using shovels. Harvests faster than by hand, but risks damaging some of your treasures."
	desc_lbl.add_theme_font_size_override("font_size", 9)
	desc_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	info.add_child(desc_lbl)
	row.add_child(info)

	# Buy button
	var buy_btn := Button.new()
	buy_btn.add_theme_font_size_override("font_size", 11)
	buy_btn.custom_minimum_size = Vector2(60, 48)
	if owned:
		buy_btn.text = "Owned"
		buy_btn.disabled = true
	else:
		buy_btn.text = "Buy"
		buy_btn.disabled = (PlayerData.coins < price)
		buy_btn.pressed.connect(_on_buy_excavator)
	row.add_child(buy_btn)

	tool_grid.add_child(row)


func _on_buy_excavator() -> void:
	if DeepMine.buy_excavator():
		_rebuild_tool_shop()
	else:
		_coins_label.text = "Can't buy Excavator — not enough coins."


## ── Private: Items Tab ───────────────────────────────────────────


func _rebuild_items_tab() -> void:
	var items_grid = _items_content.find_child("ItemsGrid", true, false)
	if items_grid == null:
		return

	for child in items_grid.get_children():
		child.queue_free()

	_refresh_coins_label()

	## Shared sell-quantity selector for the whole Items tab (1 / 5 / 10 / 25 /
	## Max). Rebuilt each time; preserve the prior selection across rebuilds so
	## selling doesn't reset the chosen amount.
	var prev_qty_id := PlayerData.get_market_pref("qty_items", 1)
	var qty_parts := _make_sell_qty_row(prev_qty_id)
	_items_qty_dropdown = qty_parts[1]
	_items_qty_dropdown.item_selected.connect(func(_i):
		PlayerData.set_market_pref("qty_items", _items_qty_dropdown.get_selected_id())
		## Rebuild so each Sell button's payout reflects the new quantity.
		_rebuild_items_tab())
	items_grid.add_child(qty_parts[0])

	## Sort row (Name / Value / Owned). Applies within each category below.
	var items_sort_parts := _make_sort_row(false, "Value", _sort_mode_items, _on_items_sort_changed)
	_items_sort_dropdown = items_sort_parts[1]
	items_grid.add_child(items_sort_parts[0])

	## Render categories in a fixed order, each with a header (shown only when the
	## category has owned items). Sorting applies WITHIN each category.
	var has_any := false
	if _render_crops_section(items_grid):
		has_any = true
	if _render_fruit_section(items_grid):
		has_any = true
	if _render_resources_section(items_grid):
		has_any = true
	if _render_presents_section(items_grid):
		has_any = true
	if _render_jewelry_section(items_grid):
		has_any = true
	if _render_wonder_sell_section(items_grid):
		has_any = true

	if not has_any:
		var empty_label := Label.new()
		empty_label.text = "No items available to sell.\nHarvest crops from your Garden, fruit from your Orchard, or find Diamond Rings!"
		empty_label.add_theme_font_size_override("font_size", 13)
		empty_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.65))
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		items_grid.add_child(empty_label)


## ── Items tab: category renderers ───────────────────────────────
## Each returns true if it rendered at least one row (i.e. the player owns
## something in that category). A category header is shown only when non-empty.


## Wearable jewelry the player owns (rings/necklaces/misc — includes the Diamond
## Ring). Each row has a Sell button driven by the shared qty selector. Excludes
## horseshoes (slot "horse") and food recipes. Returns true if any were shown.
func _render_jewelry_section(items_grid: Control) -> bool:
	var jewelry_defs: Array = []
	for jid in PlayerData.jewelry_ids():
		var def := PlayerData.get_jewelry_def(jid)
		var slot := str(def.get("slot", ""))
		if slot == "horse":
			continue  ## horseshoes equip to a horse, not personal jewelry
		jewelry_defs.append(def)
	_apply_sort(jewelry_defs, _sort_mode_items,
		func(d): return str(d.get("name", "")),
		func(d): return PlayerData.get_jewelry_sell_value(str(d.get("id", ""))),
		func(_d): return 0,
		func(d): return PlayerData.get_jewelry_count(str(d.get("id", ""))))

	var rendered := false
	for def in jewelry_defs:
		var jid: String = str(def["id"])
		var count: int = PlayerData.get_jewelry_count(jid)
		if count <= 0:
			continue
		if not rendered:
			_add_category_header(items_grid, "Jewelry")
			rendered = true

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(48, 48)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tex: Texture2D = load(str(def.get("sprite", "")))
		if tex:
			var sprite := TextureRect.new()
			sprite.texture = tex
			sprite.custom_minimum_size = Vector2(36, 36)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_btn.add_child(sprite)
		row.add_child(icon_btn)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = str(def.get("name", jid))
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
		info.add_child(name_lbl)
		var unit := PlayerData.get_jewelry_sell_value(jid)
		var detail_lbl := Label.new()
		detail_lbl.text = "Owned: %d  |  Sell: %s each" % [count, PlayerData.format_coins(unit)]
		detail_lbl.add_theme_font_size_override("font_size", 10)
		detail_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
		info.add_child(detail_lbl)
		row.add_child(info)

		var sell_btn := Button.new()
		sell_btn.text = _sell_btn_text(_items_sell_qty(count), unit)
		sell_btn.add_theme_font_size_override("font_size", 12)
		sell_btn.custom_minimum_size = Vector2(54, 48)
		sell_btn.pressed.connect(_on_sell_jewelry.bind(jid))
		row.add_child(sell_btn)

		items_grid.add_child(row)
	return rendered


## Sells the selected qty of a jewelry item (shared Items-tab qty selector).
func _on_sell_jewelry(jid: String) -> void:
	var owned := PlayerData.get_jewelry_count(jid)
	var qty := _items_sell_qty(owned)
	if qty > 0 and PlayerData.sell_jewelry(jid, qty):
		_rebuild_items_tab()
		_refresh_coins_label()


## Orchard fruit, sorted by the selected mode. Returns true if any were shown.
func _render_fruit_section(items_grid: Control) -> bool:
	var fruit_defs: Array = []
	for fi in range(1, PlayerData.ITEM_DEFS.size()):
		fruit_defs.append(PlayerData.ITEM_DEFS[fi])
	_apply_sort(fruit_defs, _sort_mode_items,
		func(d): return str(d.get("name", "")),
		func(d): return PlayerData.get_fruit_sell_price(str(d.get("id", ""))),
		func(_d): return 0,
		func(d): return PlayerData.get_fruit_count(str(d.get("id", ""))))
	var rendered := false
	for f_def in fruit_defs:
		var f_id: String = f_def["id"]
		var count: int = PlayerData.get_fruit_count(f_id)
		## Effective per-fruit PRICE (orchard prestige + Business District + jewelry).
		var value: int = PlayerData.get_fruit_sell_price(f_id)
		if count > 0:
			if not rendered:
				_add_category_header(items_grid, "Fruit")
				rendered = true
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)

			var icon_btn := Button.new()
			icon_btn.custom_minimum_size = Vector2(48, 48)
			icon_btn.focus_mode = Control.FOCUS_NONE
			icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var fruit_idx: int = f_def.get("fruit_index", 0)
			if get_node_or_null("/root/Orchard") != null:
				var atlas = get_node("/root/Orchard").get_fruit_texture(fruit_idx)
				if atlas:
					var sprite := TextureRect.new()
					sprite.texture = atlas
					sprite.custom_minimum_size = Vector2(36, 36)
					sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
					sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
					sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
					sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
					icon_btn.add_child(sprite)
			var icon_style := StyleBoxFlat.new()
			icon_style.bg_color = Color(0.18, 0.25, 0.18)
			icon_style.border_width_left = 1; icon_style.border_width_right = 1
			icon_style.border_width_top = 1; icon_style.border_width_bottom = 1
			icon_style.border_color = Color(0.4, 0.6, 0.3)
			icon_btn.add_theme_stylebox_override("normal", icon_style)
			row.add_child(icon_btn)

			var info := VBoxContainer.new()
			info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var name_lbl := Label.new()
			name_lbl.text = f_def["name"]
			name_lbl.add_theme_font_size_override("font_size", 12)
			name_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 0.9))
			info.add_child(name_lbl)
			var detail_lbl := Label.new()
			detail_lbl.text = "Sell: %s  |  Owned: %d" % [PlayerData.format_coins(value), count]
			detail_lbl.add_theme_font_size_override("font_size", 10)
			detail_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
			info.add_child(detail_lbl)
			row.add_child(info)

			var sell_btn := Button.new()
			sell_btn.text = _sell_btn_text(_items_sell_qty(count), value)
			sell_btn.add_theme_font_size_override("font_size", 11)
			sell_btn.custom_minimum_size = Vector2(60, 48)
			sell_btn.pressed.connect(_on_sell_fruit.bind(f_id))
			row.add_child(sell_btn)

			items_grid.add_child(row)
	return rendered


## Resource items (wood, sticks, ores, bars, ingots), sorted. Returns true if any shown.
func _render_resources_section(items_grid: Control) -> bool:
	var resource_defs: Array = PlayerData.RESOURCE_DEFS.duplicate()
	_apply_sort(resource_defs, _sort_mode_items,
		func(d): return str(d.get("name", "")),
		func(d): return PlayerData.get_resource_sell_price(str(d.get("id", ""))),
		func(_d): return 0,
		func(d): return PlayerData.get_item_count(str(d.get("id", ""))))
	var rendered := false
	for r_def in resource_defs:
		var r_id: String = r_def["id"]
		var r_count: int = PlayerData.get_item_count(r_id)
		if r_count <= 0:
			continue
		if not rendered:
			_add_category_header(items_grid, "Ores & Ingots")
			rendered = true
		var value: int = PlayerData.get_resource_sell_price(r_id)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(48, 48)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ore_tex := OreSprites.get_item_texture(str(r_def.get("ore_sprite", r_id)))
		if ore_tex:
			var sprite := TextureRect.new()
			sprite.texture = ore_tex
			sprite.custom_minimum_size = Vector2(36, 36)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_btn.add_child(sprite)
		var icon_style := StyleBoxFlat.new()
		icon_style.bg_color = Color(0.22, 0.20, 0.16)
		icon_style.border_width_left = 1; icon_style.border_width_right = 1
		icon_style.border_width_top = 1; icon_style.border_width_bottom = 1
		icon_style.border_color = Color(0.55, 0.45, 0.3)
		icon_btn.add_theme_stylebox_override("normal", icon_style)
		row.add_child(icon_btn)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = r_def["name"]
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 0.9))
		info.add_child(name_lbl)
		var detail_lbl := Label.new()
		detail_lbl.text = "Sell: %s  |  Owned: %d" % [PlayerData.format_coins(value), r_count]
		detail_lbl.add_theme_font_size_override("font_size", 10)
		detail_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
		info.add_child(detail_lbl)
		row.add_child(info)

		var sell_btn := Button.new()
		sell_btn.text = _sell_btn_text(_items_sell_qty(r_count), value)
		sell_btn.add_theme_font_size_override("font_size", 11)
		sell_btn.custom_minimum_size = Vector2(60, 48)
		sell_btn.pressed.connect(_on_sell_item.bind(r_id))
		row.add_child(sell_btn)

		items_grid.add_child(row)
		## Wood also gets its own craft-to-sticks row with a craft qty picker.
		if r_id == "wood":
			items_grid.add_child(_make_stick_craft_row())
	return rendered


## Harvested crops (garden output — prestige applies on sale), sorted. Returns true if any shown.
func _render_crops_section(items_grid: Control) -> bool:
	var crop_defs: Array = PlayerData.CROP_DEFS.duplicate()
	_apply_sort(crop_defs, _sort_mode_items,
		func(d): return str(d.get("name", "")),
		func(d): return PlayerData.get_crop_sell_price(str(d.get("id", ""))),
		func(_d): return 0,
		func(d): return PlayerData.get_crop_count(str(d.get("id", ""))))
	var rendered := false
	for c_def in crop_defs:
		var c_id: String = c_def["id"]
		var c_count: int = PlayerData.get_crop_count(c_id)
		if c_count <= 0:
			continue
		if not rendered:
			_add_category_header(items_grid, "Crops")
			rendered = true
		var value: int = PlayerData.get_crop_sell_price(c_id)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(48, 48)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var crop_tex: Texture2D = load(c_def["sprite"])
		if crop_tex:
			var sprite := TextureRect.new()
			sprite.texture = crop_tex
			sprite.custom_minimum_size = Vector2(36, 36)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_btn.add_child(sprite)
		var icon_style := StyleBoxFlat.new()
		icon_style.bg_color = Color(0.18, 0.25, 0.18)
		icon_style.border_width_left = 1; icon_style.border_width_right = 1
		icon_style.border_width_top = 1; icon_style.border_width_bottom = 1
		icon_style.border_color = Color(0.4, 0.6, 0.3)
		icon_btn.add_theme_stylebox_override("normal", icon_style)
		row.add_child(icon_btn)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = c_def["name"]
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 0.9))
		info.add_child(name_lbl)
		var detail_lbl := Label.new()
		detail_lbl.text = "Sell: %s  |  Owned: %d" % [PlayerData.format_coins(value), c_count]
		detail_lbl.add_theme_font_size_override("font_size", 10)
		detail_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
		info.add_child(detail_lbl)
		row.add_child(info)

		var sell_btn := Button.new()
		sell_btn.text = _sell_btn_text(_items_sell_qty(c_count), value)
		sell_btn.add_theme_font_size_override("font_size", 11)
		sell_btn.custom_minimum_size = Vector2(60, 48)
		sell_btn.pressed.connect(_on_sell_crop.bind(c_id))
		row.add_child(sell_btn)

		items_grid.add_child(row)
	return rendered


func _on_sell_fruit(fruit_id: String) -> void:
	var qty := _items_sell_qty(PlayerData.get_fruit_count(fruit_id))
	if qty > 0 and PlayerData.sell_fruit(fruit_id, qty):
		_rebuild_items_tab()
		_refresh_coins_label()


## Presents (Christmas Conifer output) — sellable at a flat 500k each. Only owned
## variants shown. Returns true if any rendered.
func _render_presents_section(items_grid: Control) -> bool:
	var rendered := false
	for v in range(PlayerData.PRESENT_COUNT):
		var count: int = PlayerData.get_present_count(v)
		if count <= 0:
			continue
		if not rendered:
			_add_category_header(items_grid, "Presents")
			rendered = true
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		var icon_btn := Button.new()
		icon_btn.custom_minimum_size = Vector2(48, 48)
		icon_btn.focus_mode = Control.FOCUS_NONE
		icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tex := PlayerData.get_present_texture(v)
		if tex:
			var sprite := TextureRect.new()
			sprite.texture = tex
			sprite.custom_minimum_size = Vector2(40, 40)
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_btn.add_child(sprite)
		row.add_child(icon_btn)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = "Present"
		name_lbl.add_theme_font_size_override("font_size", 14)
		info.add_child(name_lbl)
		var unit := PlayerData.get_present_sell_value()
		var count_lbl := Label.new()
		count_lbl.text = "Owned: %d  |  Total Value: %s" % [count, PlayerData.format_coins(count * unit)]
		count_lbl.add_theme_font_size_override("font_size", 11)
		count_lbl.modulate = Color(1.0, 0.9, 0.5)
		info.add_child(count_lbl)
		row.add_child(info)

		var sell_btn := Button.new()
		sell_btn.text = _sell_btn_text(_items_sell_qty(count), unit)
		sell_btn.add_theme_font_size_override("font_size", 12)
		sell_btn.custom_minimum_size = Vector2(64, 48)
		sell_btn.pressed.connect(_on_sell_present.bind(v))
		row.add_child(sell_btn)

		items_grid.add_child(row)
	return rendered


func _on_sell_present(variant: int) -> void:
	var owned := PlayerData.get_present_count(variant)
	var qty := _items_sell_qty(owned)
	if qty <= 0:
		return
	var sold := 0
	if qty >= owned:
		sold = PlayerData.sell_all_present(variant)
	else:
		if PlayerData.sell_present(variant, qty):
			sold = qty
	if sold > 0:
		_rebuild_items_tab()
		_refresh_coins_label()


## WonderStone + WonderVessels sell section (Items tab). Both are view-rich rows
## with a Sell button driven by the shared Items-tab qty selector. Returns true
## if any row rendered.
func _render_wonder_sell_section(items_grid: Control) -> bool:
	var rendered := false

	## WonderStone row.
	var ws_count := PlayerData.get_wonderstone_count()
	if ws_count > 0:
		if not rendered:
			_add_category_header(items_grid, "WonderStones & WonderVessels")
			rendered = true
		var unit := PlayerData.WONDERSTONE_COIN_VALUE
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.add_child(_make_icon_btn(ItemKeyRegistry.get_texture(
			ItemKeyRegistry.material_key("wonderstone"))))
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = "WonderStone"
		name_lbl.add_theme_font_size_override("font_size", 14)
		info.add_child(name_lbl)
		var cl := Label.new()
		cl.text = "Owned: %d  |  Total Value: %s" % [ws_count, PlayerData.format_coins(ws_count * unit)]
		cl.add_theme_font_size_override("font_size", 11)
		cl.modulate = Color(1.0, 0.9, 0.5)
		info.add_child(cl)
		row.add_child(info)
		var sell_btn := Button.new()
		sell_btn.text = _sell_btn_text(_items_sell_qty(ws_count), unit)
		sell_btn.add_theme_font_size_override("font_size", 12)
		sell_btn.custom_minimum_size = Vector2(64, 48)
		sell_btn.pressed.connect(_on_sell_wonderstone)
		row.add_child(sell_btn)
		items_grid.add_child(row)

	## One row per owned vessel tier.
	for tier in range(1, PlayerData.WONDERVESSEL_DEFS.size() + 1):
		var vc := PlayerData.get_vessel_count(tier)
		if vc <= 0:
			continue
		if not rendered:
			_add_category_header(items_grid, "WonderStones & WonderVessels")
			rendered = true
		var unit := PlayerData.get_vessel_sell_value(tier)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.add_child(_make_icon_btn(ItemKeyRegistry.get_texture(
			ItemKeyRegistry.vessel_key(tier))))
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = "WonderVessel (Tier %d)" % tier
		name_lbl.add_theme_font_size_override("font_size", 14)
		info.add_child(name_lbl)
		var cl := Label.new()
		cl.text = "Owned: %d  |  Total Value: %s" % [vc, PlayerData.format_coins(vc * unit)]
		cl.add_theme_font_size_override("font_size", 11)
		cl.modulate = Color(1.0, 0.9, 0.5)
		info.add_child(cl)
		row.add_child(info)
		var sell_btn := Button.new()
		sell_btn.text = _sell_btn_text(_items_sell_qty(vc), unit)
		sell_btn.add_theme_font_size_override("font_size", 12)
		sell_btn.custom_minimum_size = Vector2(64, 48)
		sell_btn.pressed.connect(_on_sell_vessel.bind(tier))
		row.add_child(sell_btn)
		items_grid.add_child(row)

	return rendered


## Builds a 48×48 icon button holding `tex` (centered, non-interactive). Shared
## helper for the wonder rows.
func _make_icon_btn(tex: Texture2D) -> Button:
	var icon_btn := Button.new()
	icon_btn.custom_minimum_size = Vector2(48, 48)
	icon_btn.focus_mode = Control.FOCUS_NONE
	icon_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if tex:
		var sprite := TextureRect.new()
		sprite.texture = tex
		sprite.custom_minimum_size = Vector2(40, 40)
		sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
		sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon_btn.add_child(sprite)
	return icon_btn


func _on_sell_wonderstone() -> void:
	var owned := PlayerData.get_wonderstone_count()
	var qty := _items_sell_qty(owned)
	if qty > 0 and PlayerData.sell_wonderstone(qty):
		_rebuild_items_tab()
		_refresh_coins_label()


func _on_sell_vessel(tier: int) -> void:
	var owned := PlayerData.get_vessel_count(tier)
	var qty := _items_sell_qty(owned)
	if qty > 0 and PlayerData.sell_vessel(tier, qty):
		_rebuild_items_tab()
		_refresh_coins_label()


## ── Food tab (recipes) ──────────────────────────────────────────
## Each owned recipe shows its boost + duration, a "Use" button that activates
## the boost (via PlayerData.use_recipe), and a Sell button. A banner at the top
## lists any boosts currently active with their remaining time / uses.
func _rebuild_food_tab() -> void:
	var food_grid = _food_content.find_child("FoodGrid", true, false)
	if food_grid == null:
		return
	for child in food_grid.get_children():
		child.queue_free()

	_refresh_coins_label()

	## Shared sell-qty selector (reuses the Items-tab preference key so the choice
	## is consistent across the two sell tabs).
	var prev_qty_id := PlayerData.get_market_pref("qty_items", 1)
	var qty_parts := _make_sell_qty_row(prev_qty_id)
	_items_qty_dropdown = qty_parts[1]
	_items_qty_dropdown.item_selected.connect(func(_i):
		PlayerData.set_market_pref("qty_items", _items_qty_dropdown.get_selected_id())
		_rebuild_food_tab())
	food_grid.add_child(qty_parts[0])

	## Active-boosts banner.
	var active_lines := _active_boost_lines()
	if not active_lines.is_empty():
		var banner := Label.new()
		banner.text = "⚡ Active: " + "   ".join(active_lines)
		banner.add_theme_font_size_override("font_size", 11)
		banner.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))
		banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		food_grid.add_child(banner)

	var has_any := false
	for rid in PlayerData.recipe_ids():
		var count := PlayerData.get_recipe_count(rid)
		if count <= 0:
			continue
		has_any = true
		food_grid.add_child(_make_recipe_row(rid, count))

	if not has_any:
		var empty := Label.new()
		empty.text = "No food recipes yet.\nGardening guilds craft these — buy them at a guild storefront."
		empty.add_theme_font_size_override("font_size", 13)
		empty.add_theme_color_override("font_color", Color(0.7, 0.7, 0.65))
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		food_grid.add_child(empty)


## Builds one recipe row (icon, name/desc, owned+value, Use + Sell buttons).
func _make_recipe_row(rid: String, count: int) -> Control:
	var def := PlayerData.get_recipe_def(rid)
	var unit := PlayerData.get_recipe_sell_value(rid)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var tex: Texture2D = load(str(def.get("sprite", "")))
	row.add_child(_make_icon_btn(tex))

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_lbl := Label.new()
	name_lbl.text = str(def.get("name", rid))
	name_lbl.add_theme_font_size_override("font_size", 14)
	info.add_child(name_lbl)
	var desc_lbl := Label.new()
	desc_lbl.text = str(def.get("description", ""))
	desc_lbl.add_theme_font_size_override("font_size", 11)
	desc_lbl.modulate = Color(0.8, 0.8, 0.8)
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_child(desc_lbl)
	var count_lbl := Label.new()
	count_lbl.text = "Owned: %d  |  Total Value: %s" % [count, PlayerData.format_coins(count * unit)]
	count_lbl.add_theme_font_size_override("font_size", 11)
	count_lbl.modulate = Color(1.0, 0.9, 0.5)
	info.add_child(count_lbl)
	## Show remaining time/uses if this recipe's boost is active.
	var effect := str((def.get("boost", {}) as Dictionary).get("effect", ""))
	if effect != "" and PlayerData.boost_active(effect):
		var active_lbl := Label.new()
		active_lbl.text = "⚡ Active — %s" % _boost_status_text(def.get("boost", {}))
		active_lbl.add_theme_font_size_override("font_size", 11)
		active_lbl.modulate = Color(0.4, 1.0, 0.5)
		info.add_child(active_lbl)
	row.add_child(info)

	var btns := VBoxContainer.new()
	btns.add_theme_constant_override("separation", 4)
	var use_btn := Button.new()
	use_btn.text = "Use"
	use_btn.add_theme_font_size_override("font_size", 11)
	use_btn.custom_minimum_size = Vector2(64, 0)
	use_btn.pressed.connect(_on_use_recipe.bind(rid))
	btns.add_child(use_btn)
	var sell_btn := Button.new()
	sell_btn.text = _sell_btn_text(_items_sell_qty(count), unit)
	sell_btn.add_theme_font_size_override("font_size", 11)
	sell_btn.custom_minimum_size = Vector2(64, 0)
	sell_btn.pressed.connect(_on_sell_recipe.bind(rid))
	btns.add_child(sell_btn)
	row.add_child(btns)
	return row


## Uses ONE recipe (activates/refreshes its boost), toasts the result, refreshes.
func _on_use_recipe(rid: String) -> void:
	## Checked: Trader's Tongue activates on the server first (needs internet).
	var res: Dictionary = await PlayerData.use_recipe_checked(rid, 1)
	if int(res.get("used", 0)) <= 0:
		if res.has("error") and get_node_or_null("/root/GameNotification") != null:
			GameNotification.show_message("Recipe not used", str(res["error"]))
		return
	if get_node_or_null("/root/GameNotification") != null:
		GameNotification.show_message("Boost activated", str(res.get("name", "Recipe")))
	if is_instance_valid(_food_content):
		_rebuild_food_tab()


## Sells the selected qty of a recipe for coins, then refreshes.
func _on_sell_recipe(rid: String) -> void:
	var owned := PlayerData.get_recipe_count(rid)
	var qty := _items_sell_qty(owned)
	if qty > 0 and PlayerData.sell_recipe(rid, qty):
		_rebuild_food_tab()
		_refresh_coins_label()


## Builds "Active: <name> (mm:ss)" lines for every currently active recipe boost.
func _active_boost_lines() -> Array:
	var lines: Array = []
	for rid in PlayerData.recipe_ids():
		var def := PlayerData.get_recipe_def(rid)
		var boost: Dictionary = def.get("boost", {})
		var effect := str(boost.get("effect", ""))
		if effect == "" or not PlayerData.boost_active(effect):
			continue
		lines.append("%s (%s)" % [str(def.get("name", rid)), _boost_status_text(boost)])
	return lines


## Returns "mm:ss" for timed boosts or "N uses" for counted ones.
func _boost_status_text(boost: Dictionary) -> String:
	var effect := str(boost.get("effect", ""))
	if boost.has("uses"):
		var rem := 0
		if PlayerData.active_boosts.has(effect):
			rem = int(PlayerData.active_boosts[effect].get("remaining", 0))
		return "%d use%s left" % [rem, "s" if rem != 1 else ""]
	var secs := PlayerData.boost_seconds_remaining(effect)
	return "%d:%02d left" % [secs / 60, secs % 60]


## Returns the sell quantity selected in the Items-tab dropdown, clamped to the
## amount owned. "Max" (QTY_MAX) and any option larger than owned sell all.
func _items_sell_qty(owned: int) -> int:
	return _resolve_sell_qty(_items_qty_dropdown, owned)


## Builds the Sell button caption showing the coin payout for the CURRENT
## quantity selection: e.g. selling 25 @ 1,000 -> "Sell\n25.0k". Falls back to
## just "Sell" when nothing is owned. `unit_value` is the per-item sell price
## (already prestige/bonus-adjusted by the caller).
func _sell_btn_text(qty: int, unit_value: int) -> String:
	if qty <= 0 or unit_value <= 0:
		return "Sell"
	return "Sell\n%s" % PlayerData.format_coins(qty * unit_value)


## Resolves a sell-quantity dropdown selection against `owned`: "Max"/QTY_MAX and
## any value above owned sell everything; otherwise sells the picked amount.
func _resolve_sell_qty(dropdown: OptionButton, owned: int) -> int:
	var sel := 1
	if dropdown != null and is_instance_valid(dropdown):
		sel = dropdown.get_selected_id()
	if sel == QTY_MAX:
		return owned
	return mini(sel, owned)


## Builds a "Sell qty:" row with a 1/5/10/25/Max OptionButton, restoring the
## previously selected id (via prev_id) so rebuilds don't reset the choice.
## Returns [row: HBoxContainer, dropdown: OptionButton].
## Selects the option in `dd` whose stored item-id equals `id` (no-op if absent).
func _select_by_id(dd: OptionButton, id: int) -> void:
	if dd == null or not is_instance_valid(dd):
		return
	for i in range(dd.item_count):
		if dd.get_item_id(i) == id:
			dd.selected = i
			return


func _make_sell_qty_row(prev_id: int) -> Array:
	var qty_row := HBoxContainer.new()
	qty_row.add_theme_constant_override("separation", 8)
	qty_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var qty_lbl := Label.new()
	qty_lbl.text = "Sell qty:"
	qty_lbl.add_theme_font_size_override("font_size", 12)
	qty_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	qty_row.add_child(qty_lbl)
	var dd := OptionButton.new()
	_fill_qty_options(dd, SELL_QTY_OPTIONS)
	dd.add_theme_font_size_override("font_size", 12)
	for opt_idx in range(dd.item_count):
		if dd.get_item_id(opt_idx) == prev_id:
			dd.selected = opt_idx
			break
	qty_row.add_child(dd)
	return [qty_row, dd]


## Quantity steps. Sell/use: 1 / 100 / 1000 / 10k / Max. Craft: 1 / 10 / 100 /
## 1000 / 10k / Max. Max is the QTY_MAX sentinel (OptionButton ids can't be <0).
const SELL_QTY_OPTIONS: Array[int] = [1, 100, 1000, 10000]
const CRAFT_QTY_OPTIONS: Array[int] = [1, 10, 100, 1000, 10000]


## Adds the given steps plus "Max" to a dropdown ("10k" for 10,000).
func _fill_qty_options(dd: OptionButton, steps: Array[int]) -> void:
	for q in steps:
		dd.add_item("10k" if q == 10000 else str(q), q)
	dd.add_item("Max", QTY_MAX)


## Wood -> sticks craft row with its OWN quantity picker (1 wood = 1 craft =
## 2 sticks). Previously the Craft button silently used the tab's "Sell qty"
## selector, so it looked like it only ever made 2 sticks.
func _make_stick_craft_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = "🪵 → Sticks (1 wood = 2):"
	lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(lbl)
	var dd := OptionButton.new()
	dd.add_theme_font_size_override("font_size", 11)
	_fill_qty_options(dd, CRAFT_QTY_OPTIONS)
	var prev := PlayerData.get_market_pref("qty_craft_sticks", 1)
	for i in range(dd.item_count):
		if dd.get_item_id(i) == prev:
			dd.selected = i
			break
	row.add_child(dd)
	var btn := Button.new()
	btn.add_theme_font_size_override("font_size", 11)
	btn.custom_minimum_size = Vector2(0, 40)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(btn)
	var update := func():
		var n := _resolve_sell_qty(dd, PlayerData.get_item_count("wood"))
		btn.text = "Craft %s → %s sticks" % [
			PlayerData.format_number(n), PlayerData.format_number(n * 2)]
		btn.disabled = n <= 0
	update.call()
	dd.item_selected.connect(func(_i):
		PlayerData.set_market_pref("qty_craft_sticks", dd.get_selected_id())
		update.call())
	btn.pressed.connect(func():
		var n := _resolve_sell_qty(dd, PlayerData.get_item_count("wood"))
		if n > 0 and PlayerData.craft_sticks(n) > 0:
			_rebuild_items_tab()
			_refresh_coins_label())
	return row


## Builds a "Sort:" row with an OptionButton. `include_stock` adds the Stock
## option (shop tabs); sell-only tabs omit it and label COST as "Value".
## `prev_id` restores the current selection; `on_changed` is connected to
## item_selected. Returns [row: HBoxContainer, dropdown: OptionButton].
func _make_sort_row(include_stock: bool, cost_label: String, prev_id: int, on_changed: Callable) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var lbl := Label.new()
	lbl.text = "Sort:"
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	row.add_child(lbl)
	var dd := OptionButton.new()
	dd.add_item("Name", SortMode.NAME)
	dd.add_item(cost_label, SortMode.COST)
	if include_stock:
		dd.add_item("Stock", SortMode.STOCK)
	dd.add_item("Owned", SortMode.OWNED)
	dd.add_theme_font_size_override("font_size", 12)
	for opt_idx in range(dd.item_count):
		if dd.get_item_id(opt_idx) == prev_id:
			dd.selected = opt_idx
			break
	dd.item_selected.connect(on_changed)
	row.add_child(dd)
	return [row, dd]


## Generic sort applier. Sorts `list` in place by the given SortMode using the
## provided extractor callables: name_fn(item)->String, cost_fn(item)->int,
## stock_fn(item)->int, owned_fn(item)->int. Name/Cost/Owned use the natural
## ascending/descending order that reads best (Name A→Z, Cost low→high, Stock
## and Owned high→low). Any extractor may be a no-op for tabs lacking that axis.
func _apply_sort(list: Array, mode: int, name_fn: Callable, cost_fn: Callable, stock_fn: Callable, owned_fn: Callable) -> void:
	match mode:
		SortMode.NAME:
			list.sort_custom(func(a, b): return str(name_fn.call(a)) < str(name_fn.call(b)))
		SortMode.COST:
			list.sort_custom(func(a, b): return int(cost_fn.call(a)) < int(cost_fn.call(b)))
		SortMode.STOCK:
			list.sort_custom(func(a, b): return int(stock_fn.call(a)) > int(stock_fn.call(b)))
		SortMode.OWNED:
			list.sort_custom(func(a, b): return int(owned_fn.call(a)) > int(owned_fn.call(b)))


func _on_sell_crop(crop_id: String) -> void:
	var qty := _items_sell_qty(PlayerData.get_crop_count(crop_id))
	if qty > 0 and PlayerData.sell_crop(crop_id, qty):
		_rebuild_items_tab()
		_refresh_coins_label()


func _on_sell_item(item_id: String) -> void:
	var qty := _items_sell_qty(PlayerData.get_item_count(item_id))
	if qty > 0 and PlayerData.sell_item(item_id, qty):
		_rebuild_items_tab()
		_refresh_coins_label()


func _on_craft_sticks() -> void:
	## Craft sticks from wood based on the selected quantity (1 wood -> 2 sticks
	## each; "Max" uses all wood), matching the sell-quantity behavior.
	var wood := PlayerData.get_item_count("wood")
	if wood <= 0:
		return
	var qty := _items_sell_qty(wood)
	if qty > 0 and PlayerData.craft_sticks(qty) > 0:
		_rebuild_items_tab()
		_refresh_coins_label()


func _on_sell_diamond_ring() -> void:
	# Show confirmation dialog before selling (Req 3.1, 3.3)
	var dialog := ConfirmationDialog.new()
	dialog.title = "Sell Item"
	dialog.dialog_text = "Sell Diamond Ring for 500,000 coins?"
	dialog.ok_button_text = "Sell"
	dialog.cancel_button_text = "Cancel"
	dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN

	# Style the dialog for readability on dark background
	dialog.min_size = Vector2(300, 120)

	dialog.confirmed.connect(_on_sell_diamond_ring_confirmed.bind(dialog))
	dialog.canceled.connect(_on_sell_diamond_ring_canceled.bind(dialog))
	# Also handle close button (X) as cancel
	dialog.close_requested.connect(_on_sell_diamond_ring_canceled.bind(dialog))

	add_child(dialog)
	dialog.popup_centered()


func _on_sell_diamond_ring_confirmed(dialog: ConfirmationDialog) -> void:
	# Execute the sale (Req 3.2)
	var success := PlayerData.sell_diamond_ring()
	if success:
		_rebuild_items_tab()
		_refresh_coins_label()
	# Clean up dialog
	dialog.queue_free()


func _on_sell_diamond_ring_canceled(dialog: ConfirmationDialog) -> void:
	# Dismiss dialog, no state change (Req 3.3)
	dialog.queue_free()


## ── Private: Gems Tab (Sell Gemstones) ────────────────────────────


func _rebuild_gems_tab() -> void:
	var gems_grid = _gems_content.find_child("GemsGrid", true, false)
	if gems_grid == null:
		return

	for child in gems_grid.get_children():
		child.queue_free()

	_refresh_coins_label()

	## Shared sell-quantity selector (1 / 5 / 10 / 25 / Max), matching the other
	## tabs. Preserve the prior selection across rebuilds.
	var prev_qty_id := PlayerData.get_market_pref("qty_gems", 1)
	var qty_parts := _make_sell_qty_row(prev_qty_id)
	_gems_qty_dropdown = qty_parts[1]
	_gems_qty_dropdown.item_selected.connect(func(_i):
		PlayerData.set_market_pref("qty_gems", _gems_qty_dropdown.get_selected_id())
		## Rebuild so each Sell button's payout reflects the new quantity.
		_rebuild_gems_tab())
	gems_grid.add_child(qty_parts[0])

	## Sort row (Name / Value / Owned). Applies within each gem section below.
	var gems_sort_parts := _make_sort_row(false, "Value", _sort_mode_gems, _on_gems_sort_changed)
	_gems_sort_dropdown = gems_sort_parts[1]
	gems_grid.add_child(gems_sort_parts[0])

	# Count gemstones by type
	var gem_counts: Dictionary = {}  # gem_type -> { "count": int, "value": int }
	for gem_def in PlayerData.PROSPECTOR_GEM_ORDER:
		var gt: String = gem_def["gem_type"]
		var count: int = PlayerData.get_gem_count(gt)
		if count > 0:
			## Use the effective sell PRICE (prestige + guild + jewelry) so the
			## display matches the payout.
			gem_counts[gt] = {"count": count, "value": PlayerData.get_gem_sell_price(gt)}

	# Count polished gems too (Workshop output — sells for 10x, prestige-scaled).
	var polished_counts: Dictionary = {}
	for gem_type in PlayerData.POLISHABLE_GEMS:
		var pc: int = PlayerData.get_polished_gem_count(gem_type)
		if pc > 0:
			polished_counts[gem_type] = pc

	if gem_counts.is_empty() and polished_counts.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No gemstones to sell.\nFind them through Gold Panning!"
		empty_lbl.add_theme_font_size_override("font_size", 12)
		empty_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.65))
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		gems_grid.add_child(empty_lbl)
		return

	## Uncut gems, sorted by the selected mode.
	var uncut_types: Array = gem_counts.keys()
	_apply_sort(uncut_types, _sort_mode_gems,
		func(gt): return str(gt).replace("_", " ").capitalize(),
		func(gt): return int(gem_counts[gt]["value"]),
		func(_gt): return 0,
		func(gt): return int(gem_counts[gt]["count"]))
	for gem_type in uncut_types:
		var data: Dictionary = gem_counts[gem_type]
		_add_gem_sell_row(gems_grid, gem_type, data["count"], data["value"], false)

	## Polished gems section (sorted the same way).
	if not polished_counts.is_empty():
		var sep := HSeparator.new()
		gems_grid.add_child(sep)
		var polished_header := Label.new()
		polished_header.text = "✨ Polished Gems (10× value)"
		polished_header.add_theme_font_size_override("font_size", 12)
		polished_header.add_theme_color_override("font_color", Color(0.8, 0.95, 1.0))
		polished_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		gems_grid.add_child(polished_header)
		var polished_types: Array = polished_counts.keys()
		_apply_sort(polished_types, _sort_mode_gems,
			func(gt): return str(gt).replace("_", " ").capitalize(),
			func(gt): return PlayerData.get_polished_gem_sell_price(gt),
			func(_gt): return 0,
			func(gt): return int(polished_counts[gt]))
		for gem_type in polished_types:
			_add_gem_sell_row(gems_grid, gem_type, polished_counts[gem_type],
				PlayerData.get_polished_gem_sell_price(gem_type), true)


## Adds a centered category header label (e.g. "── Crops ──") to a grid.
func _add_category_header(grid: Control, text: String) -> void:
	var header := Label.new()
	header.text = "── %s ──" % text
	header.add_theme_font_size_override("font_size", 13)
	header.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	grid.add_child(header)


## Builds one sell row for a gem (uncut or polished). `polished` picks the
## polished sprite/name and routes selling to the polished handlers.
func _add_gem_sell_row(gems_grid: Control, gem_type: String, count: int, value: int, polished: bool) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var icon_rect := TextureRect.new()
	var sprite_name := "%s_polished" % gem_type if polished else gem_type
	icon_rect.texture = load("res://Assets/GoldPanning/Gemstones/%s.png" % sprite_name)
	icon_rect.custom_minimum_size = Vector2(48, 48)
	icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(icon_rect)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_lbl := Label.new()
	var pretty := gem_type.replace("_", " ").capitalize()
	name_lbl.text = ("Polished %s" % pretty) if polished else pretty
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", Color(0.7, 0.95, 1.0) if polished else Color(1.0, 0.9, 0.5))
	info.add_child(name_lbl)
	var detail_lbl := Label.new()
	detail_lbl.text = "Owned: %d  |  Sell: %s each" % [count, PlayerData.format_number(value)]
	detail_lbl.add_theme_font_size_override("font_size", 10)
	detail_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	info.add_child(detail_lbl)
	row.add_child(info)

	var sell_btn := Button.new()
	sell_btn.text = _sell_btn_text(_resolve_sell_qty(_gems_qty_dropdown, count), value)
	sell_btn.add_theme_font_size_override("font_size", 11)
	sell_btn.custom_minimum_size = Vector2(60, 48)
	if polished:
		sell_btn.pressed.connect(_on_sell_polished_gem.bind(gem_type))
	else:
		sell_btn.pressed.connect(_on_sell_gem.bind(gem_type))
	row.add_child(sell_btn)

	gems_grid.add_child(row)


## Sells the dropdown-selected quantity of an uncut gem (looping the per-gem
## sell so coins/XP/mission tracking stay correct). "Max" sells all owned.
func _on_sell_gem(gem_type: String) -> void:
	var owned := PlayerData.get_gem_count(gem_type)
	var qty := _resolve_sell_qty(_gems_qty_dropdown, owned)
	if qty <= 0:
		return
	var sold := 0
	if qty >= owned:
		## Selling everything — do it in ONE bulk operation (single save + XP
		## grant) instead of looping per-gem, which otherwise fires hundreds of
		## save_data() calls and can freeze the app on large counts.
		sold = PlayerData.sell_all_gems(gem_type)
	else:
		## Partial, bounded amount — loop is small and safe.
		while sold < qty and PlayerData.sell_gem(gem_type):
			sold += 1
	if sold > 0:
		_rebuild_gems_tab()


## Sells the dropdown-selected quantity of a polished gem. "Max" sells all owned.
func _on_sell_polished_gem(gem_type: String) -> void:
	var owned := PlayerData.get_polished_gem_count(gem_type)
	var qty := _resolve_sell_qty(_gems_qty_dropdown, owned)
	if qty <= 0:
		return
	var sold := 0
	if qty >= owned:
		## Bulk sell-all: one save + XP grant instead of a per-gem loop.
		sold = PlayerData.sell_all_polished_gems(gem_type)
	else:
		while sold < qty and PlayerData.sell_polished_gem(gem_type):
			sold += 1
	if sold > 0:
		_rebuild_gems_tab()


## ── Private: Storage Upgrade ─────────────────────────────────────


func _on_buy_storage() -> void:
	var success := PlayerData.buy_storage_upgrade()
	if success:
		_show_tab(_current_tab)
	else:
		_coins_label.text = "Can't buy storage — not enough coins or maxed out!"


func _on_buy_refresh() -> void:
	if PlayerData.coins < PlayerData.MARKET_REFRESH_COST:
		_coins_label.text = "Not enough coins! Need %s to refresh." % PlayerData.format_coins(PlayerData.MARKET_REFRESH_COST)
		return
	if PlayerData.get_market_refreshes_remaining() <= 0:
		_coins_label.text = "Out of refreshes today (%d/%d used). Come back tomorrow." % [
			PlayerData.get_market_refresh_limit(), PlayerData.get_market_refresh_limit()]
		_update_refresh_btn()
		return
	## Consume a daily refresh allowance, then charge coins.
	if not PlayerData.use_market_refresh():
		_coins_label.text = "Out of refreshes today. Come back tomorrow."
		_update_refresh_btn()
		return
	PlayerData.coins -= PlayerData.MARKET_REFRESH_COST
	PlayerData._generate_shop_pool()
	PlayerData._generate_tool_shop_pool()
	Garden._generate_seed_shop_pool()
	if get_node_or_null("/root/Orchard") != null:
		Orchard._generate_sapling_shop_pool()
	PlayerData.save_data()
	PlayerData.data_changed.emit()
	_show_tab(_current_tab)
	_update_refresh_btn()


## Updates the refresh button's label (with remaining count) and disabled state.
func _update_refresh_btn() -> void:
	var refresh_btn = get_node_or_null("BgPanel/Content/RefreshBtn") as Button
	if refresh_btn == null:
		return
	var remaining := PlayerData.get_market_refreshes_remaining()
	var limit := PlayerData.get_market_refresh_limit()
	refresh_btn.text = "🔄 Refresh Stock (%s) — %d/%d left" % [
		PlayerData.format_coins(PlayerData.MARKET_REFRESH_COST), remaining, limit]
	refresh_btn.disabled = not PlayerData.can_refresh_market()


func _update_storage_btn(btn: Button) -> void:
	btn.disabled = not PlayerData.can_buy_storage()
	if PlayerData.storage_upgrades >= PlayerData.MAX_STORAGE_UPGRADES:
		btn.text = "Storage Maxed (%d/%d)" % [
			PlayerData.MAX_INVENTORY, PlayerData.MAX_INVENTORY]
	else:
		var cost := PlayerData.get_storage_upgrade_cost()
		btn.text = "+10 Storage (%s) — %d/%d slots" % [
			PlayerData.format_number(cost), PlayerData.MAX_INVENTORY,
			PlayerData.BASE_INVENTORY + PlayerData.MAX_STORAGE_UPGRADES * PlayerData.STORAGE_UPGRADE_SLOTS]


func _on_buy_seed_storage() -> void:
	var success := Garden.buy_seed_storage()
	if success:
		_rebuild_seed_shop()
		_refresh_coins_label()
		var btn = _seeds_content.get_node_or_null("SeedStorageBtn")
		if btn:
			_update_seed_storage_btn(btn)
	else:
		_coins_label.text = "Can't buy seeds/saplings storage — not enough coins or maxed out!"


func _update_seed_storage_btn(btn: Button) -> void:
	btn.disabled = not Garden.can_buy_seed_storage()
	if Garden.seed_storage_upgrades >= GardenData.MAX_SEED_STORAGE_UPGRADES:
		btn.text = "Seeds/Saplings Storage Maxed (%d/%d)" % [
			Garden.MAX_SEED_STORAGE, Garden.MAX_SEED_STORAGE]
	else:
		var cost := Garden.get_seed_storage_cost()
		btn.text = "+10 Seeds/Saplings Storage (%s) — %d/%d slots" % [
			PlayerData.format_number(cost), Garden.MAX_SEED_STORAGE,
			GardenData.BASE_SEED_STORAGE + GardenData.MAX_SEED_STORAGE_UPGRADES * GardenData.SEED_STORAGE_UPGRADE_SLOTS]


## ── Private: Helpers ─────────────────────────────────────────────


## Updates the online token-balance line. Shows the cached balance, or an
## "offline / not registered" hint when unavailable.
func _refresh_tokens_label() -> void:
	if _tokens_label == null:
		return
	if get_node_or_null("/root/MarketplaceAccount") == null or not MarketplaceAccount.has_account():
		_tokens_label.text = "Market Tokens: — (not registered)"
		return
	_tokens_label.text = "Market Tokens: %s  (%s)" % [
		PlayerData.format_number(MarketplaceAccount.token_balance), MarketplaceAccount.username]


func _on_token_balance_changed(_balance: int) -> void:
	_refresh_tokens_label()


## Async: fetch the authoritative balance from the server, then refresh the label.
func _reconcile_tokens() -> void:
	var res: Dictionary = await MarketplaceAccount.reconcile()
	## Whether it succeeded or not, reflect the current cached value.
	_refresh_tokens_label()
	if not res.get("ok", false):
		## Non-fatal: keep the cached balance. Show the reason so config/migration
		## problems are visible rather than silently "offline".
		if _tokens_label != null:
			_tokens_label.text = "Market Tokens: %s  (%s)" % [
				PlayerData.format_number(MarketplaceAccount.token_balance),
				str(res.get("error", "offline"))]


func _on_refresh_tick() -> void:
	_refresh_coins_label()


func _refresh_seed_info_label() -> void:
	if _seeds_content == null:
		return
	var info_label := _seeds_content.get_node_or_null("SeedInfoLabel") as Label
	if info_label == null:
		return
	if Garden.has_seed_cap():
		info_label.text = "Seeds/Saplings: %d/%d" % [
			Garden.get_total_seeds_and_saplings(), Garden.MAX_SEED_STORAGE]
	else:
		info_label.text = "Seeds/Saplings: %d" % Garden.get_total_seeds_and_saplings()


func _refresh_tool_info_label() -> void:
	if _tools_content == null:
		return
	var info_label := _tools_content.get_node_or_null("ToolInfoLabel") as Label
	if info_label == null:
		return
	info_label.text = "Tools"


func _refresh_coins_label() -> void:
	if _coins_label == null:
		return
	var refresh_secs := PlayerData.get_shop_refresh_remaining()
	_coins_label.text = "Coins: %s | Inv: %d/%d\nRestock: %s" % [
		PlayerData.format_number(PlayerData.coins), PlayerData.get_inventory_size(), PlayerData.MAX_INVENTORY,
		FormatUtils.format_duration(refresh_secs)]


func _on_data_changed() -> void:
	_refresh_coins_label()
	# Update storage button state
	var storage_btn = get_node_or_null("BgPanel/Content/StorageBtn")
	if storage_btn:
		_update_storage_btn(storage_btn)
	# Keep the refresh button's remaining-count and enabled state in sync
	_update_refresh_btn()
	# Rebuild the active tab so shop-pool restocks (tile/tool, possibly triggered
	# by the Workshop hourglass) show fresh stock without leaving the screen.
	match _current_tab:
		"items":
			_rebuild_items_tab()
		"food":
			_rebuild_food_tab()
		"tiles":
			_rebuild_tiles_grid()
		"tools":
			_rebuild_tool_shop()


## Fired when Garden (or Orchard) state changes — e.g. a seed/sapling shop
## restock from the Workshop hourglass. Rebuild the seeds tab live if it's the
## one currently shown so the new stock appears immediately.
func _on_garden_updated() -> void:
	if _current_tab == "seeds":
		_rebuild_seed_shop()


func _on_sort_changed(_index: int) -> void:
	## The shared Qty/Sort row is used by both the tiles and tools tabs; rebuild
	## whichever is active so the new sort applies.
	if _sort_dropdown != null and is_instance_valid(_sort_dropdown):
		PlayerData.set_market_pref("sort_tiles", _sort_dropdown.get_selected_id())
	if _current_tab == "tools":
		_rebuild_tool_shop()
	else:
		_rebuild_tiles_grid()


## Sort-change handlers read the selected SortMode id from the tab's dropdown
## (item_selected passes an index, but get_selected_id returns our stored id).
func _on_seeds_sort_changed(_index: int) -> void:
	if _seeds_sort_dropdown != null and is_instance_valid(_seeds_sort_dropdown):
		_sort_mode_seeds = _seeds_sort_dropdown.get_selected_id()
		PlayerData.set_market_pref("sort_seeds", _sort_mode_seeds)
	_rebuild_seed_shop()


func _on_items_sort_changed(_index: int) -> void:
	if _items_sort_dropdown != null and is_instance_valid(_items_sort_dropdown):
		_sort_mode_items = _items_sort_dropdown.get_selected_id()
		PlayerData.set_market_pref("sort_items", _sort_mode_items)
	_rebuild_items_tab()


func _on_gems_sort_changed(_index: int) -> void:
	if _gems_sort_dropdown != null and is_instance_valid(_gems_sort_dropdown):
		_sort_mode_gems = _gems_sort_dropdown.get_selected_id()
		PlayerData.set_market_pref("sort_gems", _sort_mode_gems)
	_rebuild_gems_tab()


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


## Opens the dedicated online player-market screen.
func _on_open_online_market() -> void:
	_get_navigator().navigate_to("online_marketplace")
