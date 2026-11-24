extends BaseScreen

## Online Player Marketplace screen. Opened from the "Online Player Market"
## button in the regular marketplace (visible on every tab there).
##
## Tabs:
##   Browse      — all active listings from all players, with Buy + price chart
##   My Listings — the player's own active listings, with Cancel
##   Sell        — pick an owned item, set price/qty/daily-limit, list it
##
## Requires an active connection + a registered marketplace account. Shows a
## clear message otherwise.

var _content: VBoxContainer = null
var _tab_bar: HBoxContainer = null
var _tab_body: VBoxContainer = null       ## Where the active tab renders
var _tokens_label: Label = null
var _status_label: Label = null
var _current_tab: String = "browse"

## ── Sell tab widgets ────────────────────────────────────────────
var _sell_item_dropdown: OptionButton = null
var _sell_qty_spin: SpinBox = null
var _sell_price_spin: SpinBox = null
var _sell_limit_spin: SpinBox = null
## Parallel to the dropdown items: the canonical item-key for each option index.
var _sell_owned_keys: Array[String] = []
## The price/limit of the player's EXISTING active listing for the selected item
## (-1 = none). Used to detect a price/limit change and offer merge vs separate.
var _existing_price: int = -1
var _existing_limit: int = -1
## True for the player's FIRST-EVER Sell-tab visit after the new suggested
## prices shipped. While true, every item shows its suggested price even if the
## player already lists it (a one-time nudge). Captured when the Sell tab opens;
## the persisted PlayerData flag is set when they leave the Sell tab.
var _pricing_nudge_active: bool = false

## ── Browse tab search/filter ────────────────────────────────────
var _browse_listings: Array = []          ## Last-fetched listings (unfiltered)
var _browse_search: LineEdit = null        ## Search box
var _browse_rows_container: VBoxContainer = null  ## Holds the filtered rows
var _browse_query: String = ""             ## Current filter text

## ── Suggested default listing price (tokens), per canonical item key ─────────
## Shown pre-filled in the Sell tab's price box so each item defaults to a
## sensible token price instead of a flat 100. The player can still type any
## price (which is what gets listed), and re-listing an item they already sell
## auto-fills THAT listing's price instead (see _on_sell_item_selected).
## Fallback for anything not listed here is DEFAULT_LIST_PRICE.
const DEFAULT_LIST_PRICE := 100
const SUGGESTED_LIST_PRICE := {
	# Uncut gems
	"gem:gold":          6,
	"gem:blue_stone":    8,
	"gem:pink_stone":    8,
	"gem:violet_stone":  11,
	"gem:black_pearl":   16,
	"gem:emerald":       21,
	"gem:ruby":          31,
	"gem:diamond":       51,
	# Polished gems
	"polished:blue_stone":    76,
	"polished:pink_stone":    76,
	"polished:violet_stone":  101,
	"polished:black_pearl":   151,
	"polished:emerald":       201,
	"polished:ruby":          301,
	"polished:diamond":       501,
	# Garden crops
	"crop:beans":        2,
	"crop:cucumbers":    5,
	"crop:peppers":      7,
	"crop:squash":       12,
	"crop:grapes":       16,
	"crop:sunflower":    20,
	"crop:cauliflower":  24,
	"crop:pineapple":    27,
	"crop:watermelon":   31,
	# Orchard fruit
	"fruit:plum":        51,
	"fruit:lemon":       101,
	"fruit:apple":       151,
	"fruit:banana":      201,
	"fruit:coconut":     251,
	# Resources — ores/bars & misc
	"resource:wood":          51,
	"resource:stick":         26,
	"resource:iron_ore":      76,
	"resource:iron_bar":      751,
	"resource:copper_ore":    101,
	"resource:copper_ingot":  1001,
	"resource:gold_ingot":    2501,
	# Other
	"item:diamond_ring":  50001,
	# Presents (all 8 variants share the same suggested price)
	"present:0": 50001, "present:1": 50001, "present:2": 50001, "present:3": 50001,
	"present:4": 50001, "present:5": 50001, "present:6": 50001, "present:7": 50001,
}


## Suggested default list price for an item key (falls back to DEFAULT_LIST_PRICE).
func _suggested_list_price(key: String) -> int:
	## Food recipes: suggest the guild storefront floor, ceil(token_value × 0.5)
	## (same 50% floor as _store_min_price / migration 098).
	if key.begins_with("item:"):
		var rdef := PlayerData.get_recipe_def(key.substr(5))
		if not rdef.is_empty() and int(rdef.get("token_value", 0)) > 0:
			return maxi(1, int(ceil(int(rdef["token_value"]) * 0.5)))
	return int(SUGGESTED_LIST_PRICE.get(key, DEFAULT_LIST_PRICE))


func get_screen_name() -> String:
	return "online_marketplace"


func show_top_bar() -> bool:
	return true


func enter(_params: Dictionary = {}) -> void:
	_build_ui()
	if get_node_or_null("/root/MarketplaceAccount") != null:
		if not MarketplaceAccount.token_balance_changed.is_connected(_on_token_balance_changed):
			MarketplaceAccount.token_balance_changed.connect(_on_token_balance_changed)
	_show_tab("browse")
	_reconcile_tokens()


func exit() -> void:
	## Leaving the screen while on the Sell tab also commits the pricing nudge.
	_commit_pricing_nudge()
	if get_node_or_null("/root/MarketplaceAccount") != null \
			and MarketplaceAccount.token_balance_changed.is_connected(_on_token_balance_changed):
		MarketplaceAccount.token_balance_changed.disconnect(_on_token_balance_changed)
	for child in get_children():
		child.queue_free()


## ── Build UI ────────────────────────────────────────────────────

func _build_ui() -> void:
	## Dark backdrop, matching the other marketplace screens.
	var bg := PanelContainer.new()
	bg.name = "BgPanel"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0.08, 0.08, 0.12, 0.9)
	bg_style.set_corner_radius_all(6)
	bg_style.content_margin_left = 8; bg_style.content_margin_right = 8
	bg_style.content_margin_top = 6; bg_style.content_margin_bottom = 6
	bg.add_theme_stylebox_override("panel", bg_style)
	## Clip so no descendant that over-reports its width can paint past the
	## screen edge (defensive against a wide row forcing horizontal overflow).
	bg.clip_contents = true
	add_child(bg)

	_content = VBoxContainer.new()
	_content.set_anchors_preset(Control.PRESET_FULL_RECT)
	_content.add_theme_constant_override("separation", 8)
	_content.clip_contents = true
	bg.add_child(_content)

	## Top row: back + title
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(120, 44)
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(_on_back_pressed)
	top.add_child(back_btn)
	var title := Label.new()
	title.text = "Online Player Market"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	top.add_child(title)
	_content.add_child(top)

	## Token balance line + change-name button.
	var acct_row := HBoxContainer.new()
	acct_row.add_theme_constant_override("separation", 8)
	var name_btn := Button.new()
	name_btn.text = "✏ Change Name"
	name_btn.add_theme_font_size_override("font_size", 11)
	name_btn.custom_minimum_size = Vector2(0, 36)
	name_btn.pressed.connect(_on_change_name_pressed)
	acct_row.add_child(name_btn)
	_tokens_label = Label.new()
	_tokens_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_tokens_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tokens_label.add_theme_font_size_override("font_size", 12)
	_tokens_label.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
	acct_row.add_child(_tokens_label)
	_content.add_child(acct_row)
	_refresh_tokens_label()

	## Tab bar.
	_tab_bar = HBoxContainer.new()
	_tab_bar.add_theme_constant_override("separation", 4)
	_tab_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for entry in [["browse", "Browse"], ["fronts", "Guild Fronts"], ["mine", "My Listings"], ["sell", "Sell"]]:
		var btn := Button.new()
		btn.name = "Tab_" + entry[0]
		btn.text = entry[1]
		btn.add_theme_font_size_override("font_size", 13)
		btn.custom_minimum_size = Vector2(0, 44)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_tab.bind(entry[0]))
		_tab_bar.add_child(btn)
	_content.add_child(_tab_bar)

	## Status/feedback line.
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.8))
	_content.add_child(_status_label)

	## Scrollable body for the active tab.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	## A drag deadzone lets touch swipes that start on a listing row (or its Buy
	## button) pan the list instead of being eaten as a tap. Without it
	## (deadzone 0) the only way to scroll is dragging the thin scrollbar.
	## Mirrors the garden/deep-mine grids.
	scroll.scroll_deadzone = 16
	_content.add_child(scroll)
	_tab_body = VBoxContainer.new()
	_tab_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_body.add_theme_constant_override("separation", 8)
	## PASS so touch drags on the body/rows reach the ScrollContainer for
	## swipe-to-scroll anywhere, not just on the scrollbar.
	_tab_body.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.add_child(_tab_body)


## ── Tabs ────────────────────────────────────────────────────────

func _on_tab(tab_name: String) -> void:
	_show_tab(tab_name)


## Persists the one-time pricing-nudge flag once the player has actually seen the
## Sell tab, so the whole first visit shows suggested prices and subsequent
## visits (and future sessions) auto-fill existing listings normally.
func _commit_pricing_nudge() -> void:
	if _pricing_nudge_active:
		_pricing_nudge_active = false
		if not PlayerData.market_suggested_pricing_seen:
			PlayerData.market_suggested_pricing_seen = true
			PlayerData.save_data()


func _show_tab(tab_name: String) -> void:
	## Leaving the Sell tab commits the one-time pricing nudge.
	if _current_tab == "sell" and tab_name != "sell":
		_commit_pricing_nudge()
	_current_tab = tab_name
	## Highlight the active tab.
	if _tab_bar:
		for child in _tab_bar.get_children():
			if child is Button:
				var active := child.name == ("Tab_" + tab_name)
				child.modulate = Color(1.0, 0.85, 0.2) if active else Color.WHITE
	_clear_body()
	_status_label.text = ""
	## Stale row-container/search refs were just freed by _clear_body; drop them
	## so _add_browse_row falls back correctly until _render_browse rebuilds.
	_browse_rows_container = null
	_browse_search = null
	match tab_name:
		"browse": _render_browse()
		"fronts": _render_fronts()
		"mine":   _render_my_listings()
		"sell":   _render_sell()


func _clear_body() -> void:
	for child in _tab_body.get_children():
		child.queue_free()


func _render_notice(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.75))
	_tab_body.add_child(lbl)


## Prepends an item icon (from ItemKeyRegistry.get_texture) to a listing row.
## Uses a fixed-size framed slot so rows stay aligned even when art is missing.
func _add_item_icon(row: HBoxContainer, item_key: String) -> void:
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(40, 40)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.09, 0.8)
	style.set_corner_radius_all(4)
	frame.add_theme_stylebox_override("panel", style)
	var tex := ItemKeyRegistry.get_texture(item_key)
	if tex != null:
		var icon := TextureRect.new()
		icon.texture = tex
		icon.custom_minimum_size = Vector2(36, 36)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(icon)
	## Long-press the icon to see what the item does (recipes show their boost).
	## The frame catches input; a one-shot timer distinguishes a hold from a tap.
	## PASS (not STOP) so a drag that starts on the icon still scrolls the list.
	frame.mouse_filter = Control.MOUSE_FILTER_PASS
	var hold := Timer.new()
	hold.one_shot = true
	hold.wait_time = 0.5
	frame.add_child(hold)
	hold.timeout.connect(func(): _show_item_info_popup(item_key))
	frame.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventScreenTouch or ev is InputEventMouseButton:
			if ev.pressed:
				hold.start()  ## begin counting toward a long-press
			else:
				hold.stop()    ## released before the hold fired = just a tap
		elif ev is InputEventScreenDrag:
			hold.stop())       ## dragging = a scroll gesture, not a long-press
	row.add_child(frame)


## Builds the info text for an item key. Recipes show their name + boost effect;
## everything else shows its display name (and a short category note).
func _item_info_text(item_key: String) -> String:
	## Recipes use item:<id> keys. Prefer the recipe def (name + description),
	## which already spells out the boost in plain language.
	if item_key.begins_with("item:"):
		var rid := item_key.substr("item:".length())
		var rdef := PlayerData.get_recipe_def(rid)
		if not rdef.is_empty():
			return "%s\n\n%s" % [str(rdef.get("name", rid)), str(rdef.get("description", ""))]
		var jdef := PlayerData.get_jewelry_def(rid)
		if not jdef.is_empty():
			var bonus := str(jdef.get("bonus", ""))
			var txt := str(jdef.get("name", rid))
			if jdef.has("description"):
				txt += "\n\n" + str(jdef.get("description", ""))
			elif bonus != "":
				txt += "\n\nEquip bonus: %s" % bonus.capitalize()
			return txt
	return ItemKeyRegistry.display_name(item_key)


## Shows a small dismissable popup describing the item (its function/benefit).
func _show_item_info_popup(item_key: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = ItemKeyRegistry.display_name(item_key)
	dialog.get_ok_button().text = "Close"
	var body := Label.new()
	body.text = _item_info_text(item_key)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 13)
	var vp := get_viewport().get_visible_rect().size
	body.custom_minimum_size = Vector2(mini(340, int(vp.x * 0.85)), 0)
	dialog.add_child(body)
	add_child(dialog)
	dialog.popup_centered()
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	dialog.close_requested.connect(dialog.queue_free)


## ── Browse tab ──────────────────────────────────────────────────

func _render_browse() -> void:
	if get_node_or_null("/root/MarketplaceAccount") == null \
			or get_node_or_null("/root/SupabaseClient") == null \
			or not SupabaseClient.is_configured():
		_render_notice("The online market needs an internet connection.")
		return

	_render_notice("Loading listings…")
	var res: Dictionary = await MarketplaceAccount.get_listings()
	## Guard against the tab having changed / screen closed during the await.
	if not is_instance_valid(_tab_body) or _current_tab != "browse":
		return
	_clear_body()

	if not res.get("ok", false):
		_render_notice("Couldn't reach the market.\n%s" % str(res.get("error", "")))
		return
	_browse_listings = res.get("listings", [])
	if _browse_listings.is_empty():
		_render_notice("No listings right now.\nBe the first — list something in the Sell tab!")
		return

	## Search bar (filter by name or category keyword, e.g. "seeds", "polished").
	var search_row := HBoxContainer.new()
	search_row.add_theme_constant_override("separation", 6)
	_browse_search = LineEdit.new()
	_browse_search.placeholder_text = "Search  (e.g. seeds, polished, tools, diamond)"
	_browse_search.text = _browse_query
	_browse_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_browse_search.custom_minimum_size = Vector2(0, 40)
	_browse_search.add_theme_font_size_override("font_size", 13)
	_browse_search.clear_button_enabled = true
	_browse_search.text_changed.connect(_on_browse_search_changed)
	search_row.add_child(_browse_search)
	_tab_body.add_child(search_row)

	## Container the filtered rows render into (so typing rebuilds only rows).
	_browse_rows_container = VBoxContainer.new()
	_browse_rows_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_browse_rows_container.add_theme_constant_override("separation", 8)
	_browse_rows_container.mouse_filter = Control.MOUSE_FILTER_PASS
	_tab_body.add_child(_browse_rows_container)

	_render_browse_rows()


## Renders the cached listings into _browse_rows_container, filtered by the
## current search query. Called on load and on every keystroke (no refetch).
func _render_browse_rows() -> void:
	if _browse_rows_container == null or not is_instance_valid(_browse_rows_container):
		return
	for child in _browse_rows_container.get_children():
		child.queue_free()

	var shown := 0
	for l in _browse_listings:
		if not (l is Dictionary):
			continue
		var item_key := str(l.get("item_key", ""))
		if ItemKeyRegistry.matches_search(item_key, _browse_query):
			_add_browse_row(l)
			shown += 1

	if shown == 0:
		var lbl := Label.new()
		lbl.text = "No listings match \"%s\"." % _browse_query
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.75))
		_browse_rows_container.add_child(lbl)


func _on_browse_search_changed(new_text: String) -> void:
	_browse_query = new_text
	_render_browse_rows()


## One browse row: item, price/unit, qty, seller, daily limit, plus Buy and a
## price-history button. Rows go into _browse_rows_container (below the search).
func _add_browse_row(l: Dictionary) -> void:
	var parent: Node = _browse_rows_container if _browse_rows_container != null and is_instance_valid(_browse_rows_container) else _tab_body
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS  ## let drags pass to the scroll
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.14, 0.20, 0.9)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10; style.content_margin_right = 10
	style.content_margin_top = 8; style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_child(row)

	var item_key := str(l.get("item_key", ""))
	_add_item_icon(row, item_key)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = ItemKeyRegistry.display_name(item_key)
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	info.add_child(name_lbl)

	var detail := Label.new()
	var limit_txt := "no limit" if int(l.get("per_buyer_daily_limit", 0)) <= 0 \
			else "%d/day" % int(l.get("per_buyer_daily_limit", 0))
	detail.text = "%s tokens each  |  %d available  |  limit: %s" % [
		PlayerData.format_number(int(l.get("unit_price", 0))),
		int(l.get("quantity_remaining", 0)), limit_txt]
	detail.add_theme_font_size_override("font_size", 11)
	detail.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	info.add_child(detail)

	var seller := Label.new()
	seller.text = "Seller: %s" % str(l.get("seller", "?"))
	seller.add_theme_font_size_override("font_size", 10)
	seller.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
	info.add_child(seller)

	## Action buttons, stacked so they fit on narrow phone screens.
	var actions := VBoxContainer.new()
	actions.add_theme_constant_override("separation", 4)
	row.add_child(actions)

	## Buy button — opens a quantity prompt, then purchases via the server.
	var buy_btn := Button.new()
	buy_btn.text = "Buy"
	buy_btn.add_theme_font_size_override("font_size", 12)
	buy_btn.custom_minimum_size = Vector2(64, 40)
	buy_btn.pressed.connect(_on_buy_pressed.bind(l))
	actions.add_child(buy_btn)

	## Price-history button — opens the chart for this item.
	var hist_btn := Button.new()
	hist_btn.text = "📈"
	hist_btn.tooltip_text = "Price history"
	hist_btn.add_theme_font_size_override("font_size", 12)
	hist_btn.custom_minimum_size = Vector2(64, 32)
	hist_btn.pressed.connect(_on_price_history_pressed.bind(item_key))
	actions.add_child(hist_btn)


## ── Guild Fronts tab (public guild storefronts, migration 059) ──────────────

## Public browse of jewelry listed by guilds. Any player can buy; the proceeds
## go to the selling guild's bank and disperse evenly to its members.
func _render_fronts() -> void:
	if get_node_or_null("/root/MarketplaceAccount") == null \
			or get_node_or_null("/root/SupabaseClient") == null \
			or not SupabaseClient.is_configured():
		_render_notice("The online market needs an internet connection.")
		return
	if get_node_or_null("/root/GuildStore") == null:
		_render_notice("Guild Fronts are unavailable.")
		return

	_render_notice("Loading guild storefronts…")
	var res: Dictionary = await GuildStore.refresh_fronts()
	## Guard against the tab having changed / screen closed during the await.
	if not is_instance_valid(_tab_body) or _current_tab != "fronts":
		return
	_clear_body()

	if not res.get("ok", false):
		_render_notice("Couldn't reach the guild market.\n%s" % str(res.get("message", res.get("error", ""))))
		return

	## Whole guilds for sale come first (migration 103).
	await _render_guild_sales()
	if not is_instance_valid(_tab_body) or _current_tab != "fronts":
		return

	var intro := Label.new()
	intro.text = "Jewelry crafted by guilds. Buying sends your tokens to that guild's bank, split evenly among its members."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_font_size_override("font_size", 11)
	intro.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	_tab_body.add_child(intro)

	var rows: Array = GuildStore.fronts
	if rows.is_empty():
		_render_notice("No guilds are selling items right now.")
		return

	for l in rows:
		if l is Dictionary:
			_add_front_row(l)


## "🏰 Guilds for Sale" — whole guilds listed by their leaders. Buying makes you
## the guild's leader; the tokens go to the seller.
func _render_guild_sales() -> void:
	if get_node_or_null("/root/GuildManager") == null:
		return
	var res: Dictionary = await GuildManager.get_guild_sales()
	if not is_instance_valid(_tab_body) or _current_tab != "fronts":
		return
	var items: Array = res.get("items", [])
	var hdr := Label.new()
	hdr.text = "🏰 Guilds for Sale"
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	_tab_body.add_child(hdr)
	if items.is_empty():
		var none := Label.new()
		none.text = "No guilds are for sale right now."
		none.add_theme_font_size_override("font_size", 11)
		none.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
		_tab_body.add_child(none)
	else:
		var blurb := Label.new()
		blurb.text = "Buy a whole guild and become its leader. Everything comes with it; its missions are rerolled for you. You can't be in a guild when you buy."
		blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		blurb.add_theme_font_size_override("font_size", 10)
		blurb.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
		_tab_body.add_child(blurb)
		for g in items:
			if g is Dictionary:
				_add_guild_sale_row(g)
	_tab_body.add_child(HSeparator.new())


func _add_guild_sale_row(g: Dictionary) -> void:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.18, 0.14, 0.9)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10; style.content_margin_right = 10
	style.content_margin_top = 8; style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	_tab_body.add_child(panel)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = "🏰 %s" % str(g.get("name", "?"))
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	name_lbl.clip_text = true
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(name_lbl)

	var detail := Label.new()
	detail.text = "%s  |  Upgrades %s  |  Points %s  |  Score %s" % [
		str(g.get("specialization", "")).capitalize(),
		PlayerData.format_number(int(g.get("levels", 0))),
		PlayerData.format_number(int(g.get("points", 0))),
		PlayerData.format_number(int(g.get("score", 0)))]
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_theme_font_size_override("font_size", 11)
	info.add_child(detail)

	var seller := Label.new()
	seller.text = "Sold by: %s" % str(g.get("seller_name", "?"))
	seller.add_theme_font_size_override("font_size", 10)
	seller.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
	seller.clip_text = true
	seller.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(seller)

	var action := HBoxContainer.new()
	action.add_theme_constant_override("separation", 8)
	info.add_child(action)
	var price := int(g.get("price", 0))
	var price_lbl := Label.new()
	price_lbl.text = "🎟 %s tokens" % PlayerData.format_number(price)
	price_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	price_lbl.add_theme_font_size_override("font_size", 12)
	action.add_child(price_lbl)

	var btn := Button.new()
	btn.add_theme_font_size_override("font_size", 12)
	btn.custom_minimum_size = Vector2(90, 40)
	if bool(g.get("mine", false)):
		btn.text = "Yours"
		btn.disabled = true
	elif GuildManager.is_in_guild():
		btn.text = "Leave guild first"
		btn.disabled = true
	else:
		btn.text = "Buy Guild"
		btn.disabled = MarketplaceAccount.token_balance < price
		btn.pressed.connect(_on_buy_guild_pressed.bind(g))
	action.add_child(btn)


func _on_buy_guild_pressed(g: Dictionary) -> void:
	var price := int(g.get("price", 0))
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.6)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.12, 0.15, 0.98)
	style.set_corner_radius_all(8)
	style.content_margin_left = 18; style.content_margin_right = 18
	style.content_margin_top = 14; style.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(280, 0)
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var msg := Label.new()
	msg.text = "Buy the guild \"%s\" for 🎟 %s tokens?\n\nYou'll become its leader with perks active immediately, and its guild missions will be rerolled." % [
		str(g.get("name", "?")), PlayerData.format_number(price)]
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.add_theme_font_size_override("font_size", 12)
	vbox.add_child(msg)

	var yes := Button.new()
	yes.text = "Buy Guild"
	yes.custom_minimum_size = Vector2(0, 40)
	yes.add_theme_font_size_override("font_size", 13)
	vbox.add_child(yes)
	var no := Button.new()
	no.text = "Cancel"
	no.custom_minimum_size = Vector2(0, 36)
	no.add_theme_font_size_override("font_size", 12)
	no.pressed.connect(overlay.queue_free)
	vbox.add_child(no)

	yes.pressed.connect(func():
		yes.disabled = true
		var res: Dictionary = await GuildManager.buy_guild(str(g.get("listing_id", "")))
		overlay.queue_free()
		if res.get("ok", false):
			_refresh_tokens_label()
			if get_node_or_null("/root/GameNotification") != null:
				GameNotification.show_message("Guild Purchased",
					"You now lead \"%s\"!" % str(res.get("guild_name", g.get("name", ""))))
			_get_navigator().navigate_to("guild_detail")
		else:
			_status_label.text = str(res.get("error", "Couldn't buy the guild.")))


## One Guild Fronts row: guild name, item, price, qty, seller — plus Buy (or a
## disabled "Your listing" marker when the caller is the lister).
func _add_front_row(l: Dictionary) -> void:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.14, 0.12, 0.20, 0.9)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10; style.content_margin_right = 10
	style.content_margin_top = 8; style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	_tab_body.add_child(panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_child(row)

	var item_key := str(l.get("item_key", ""))
	_add_item_icon(row, item_key)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = ItemKeyRegistry.display_name(item_key)
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	## Clip long names so they can't force the row past the screen edge.
	name_lbl.clip_text = true
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(name_lbl)

	var guild_lbl := Label.new()
	guild_lbl.text = "🏰 %s" % str(l.get("guild_name", "?"))
	guild_lbl.add_theme_font_size_override("font_size", 11)
	guild_lbl.add_theme_color_override("font_color", Color(0.75, 0.9, 1.0))
	guild_lbl.clip_text = true
	guild_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(guild_lbl)

	var detail := Label.new()
	detail.text = "%s tokens each  |  %d available" % [
		PlayerData.format_number(int(l.get("unit_price", 0))),
		int(l.get("quantity_remaining", 0))]
	detail.add_theme_font_size_override("font_size", 11)
	detail.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	info.add_child(detail)

	var seller := Label.new()
	seller.text = "Listed by: %s" % str(l.get("seller_name", "?"))
	seller.add_theme_font_size_override("font_size", 10)
	seller.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
	seller.clip_text = true
	seller.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(seller)

	## Action row (qty + Buy) lives INSIDE the info column on its own line, so the
	## fixed-width controls never push the whole row past the viewport on phones.
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	action_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(action_row)

	## Guild-owned stock: anyone (including the member who listed it) may buy.
	## Show a small "yours" tag on your own listing, but still offer Buy.
	if bool(l.get("mine", false)):
		var mine_lbl := Label.new()
		mine_lbl.text = "yours"
		mine_lbl.add_theme_font_size_override("font_size", 10)
		mine_lbl.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6))
		action_row.add_child(mine_lbl)

	## Qty SpinBox: default to max the player can afford (or stock limit).
	var unit_price := int(l.get("unit_price", 1))
	var stock := int(l.get("quantity_remaining", 0))
	var max_afford := MarketplaceAccount.token_balance / unit_price if unit_price > 0 else stock
	var default_qty := maxi(1, mini(stock, max_afford))
	var qty_box := SpinBox.new()
	qty_box.min_value = 1
	qty_box.max_value = float(maxi(1, mini(stock, max_afford)))
	qty_box.value = float(default_qty)
	qty_box.step = 1
	qty_box.custom_minimum_size = Vector2(80, 0)
	qty_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	qty_box.add_theme_font_size_override("font_size", 12)
	action_row.add_child(qty_box)

	var buy_btn := Button.new()
	buy_btn.text = "Buy"
	buy_btn.add_theme_font_size_override("font_size", 12)
	buy_btn.custom_minimum_size = Vector2(64, 40)
	buy_btn.pressed.connect(_on_front_buy_pressed.bind(l, qty_box))
	action_row.add_child(buy_btn)


## Confirms a multi-unit purchase from a guild front using a custom modal
## (ConfirmationDialog clips on mobile). qty comes from the SpinBox in the row.
func _on_front_buy_pressed(l: Dictionary, qty_box: SpinBox) -> void:
	var listing_id := str(l.get("id", ""))
	var unit_price := int(l.get("unit_price", 0))
	var stock := int(l.get("quantity_remaining", 0))
	var qty := maxi(1, int(qty_box.value)) if is_instance_valid(qty_box) else 1
	if listing_id == "" or unit_price <= 0 or stock <= 0:
		_status_label.text = "That listing is unavailable."
		return
	var total_cost := unit_price * qty
	if MarketplaceAccount.token_balance < total_cost:
		_status_label.text = "You can't afford %d × %s (%s tokens)." % [
			qty, ItemKeyRegistry.display_name(str(l.get("item_key", ""))),
			PlayerData.format_number(total_cost)]
		return

	## Custom confirm modal — no ConfirmationDialog (clips on small screens).
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.6)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.12, 0.15, 0.98)
	style.set_corner_radius_all(8)
	style.content_margin_left = 18; style.content_margin_right = 18
	style.content_margin_top = 14; style.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", style)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(280, 0)
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var msg := Label.new()
	msg.text = "Buy %d × %s\nfrom %s\nfor 🎟 %s tokens?" % [
		qty, ItemKeyRegistry.display_name(str(l.get("item_key", ""))),
		str(l.get("guild_name", "the guild")),
		PlayerData.format_number(total_cost)]
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.add_theme_font_size_override("font_size", 12)
	msg.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	vbox.add_child(msg)

	var confirm_btn := Button.new()
	confirm_btn.text = "Confirm Buy"
	confirm_btn.add_theme_font_size_override("font_size", 13)
	confirm_btn.custom_minimum_size = Vector2(0, 40)
	confirm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm_btn.pressed.connect(func():
		overlay.queue_free()
		_do_front_buy(listing_id, qty))
	vbox.add_child(confirm_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.add_theme_font_size_override("font_size", 11)
	cancel_btn.custom_minimum_size = Vector2(0, 34)
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(overlay.queue_free)
	vbox.add_child(cancel_btn)


func _do_front_buy(listing_id: String, qty: int = 1) -> void:
	_status_label.text = "Buying…"
	var res: Dictionary = await GuildStore.buy_front(listing_id, maxi(1, qty))
	if not is_instance_valid(_tab_body) or _current_tab != "fronts":
		return
	if res.get("ok", false):
		_status_label.text = "Purchased! Added to your inventory."
		_refresh_tokens_label()
		_clear_body()
		_render_fronts()
	else:
		_status_label.text = str(res.get("message", "Couldn't complete the purchase."))


## Remaining LOCAL storage space for an item key, or -1 if the category is
## uncapped (-1). Only Pho tiles are capped (MAX_INVENTORY); seeds/saplings are
## now uncapped like gems/resources/crops. Buy clamp + escrow gating read this so
## a capped store (tiles) can't be overfilled while uncapped ones flow freely.
func _storage_space_for(item_key: String) -> int:
	## Single source of truth lives in PlayerData so the buy clamp here and the
	## escrow-claim gating (MarketplaceAccount) can't drift apart.
	return PlayerData.market_storage_space_for(item_key)


## Opens a quantity prompt for a listing, then purchases. Quantity is clamped to
## stock, the per-buyer daily limit (best-effort client hint; the server is
## authoritative), what the player can afford, and — for tiles/seeds/saplings —
## remaining local storage space.
func _on_buy_pressed(l: Dictionary) -> void:
	var listing_id := str(l.get("id", ""))
	var unit_price := int(l.get("unit_price", 0))
	var stock := int(l.get("quantity_remaining", 0))
	var limit := int(l.get("per_buyer_daily_limit", 0))
	var item_key := str(l.get("item_key", ""))
	if listing_id == "" or unit_price <= 0 or stock <= 0:
		_status_label.text = "That listing is unavailable."
		return

	## Client-side max hint: min of stock, affordability, and daily limit (if any).
	var affordable := int(MarketplaceAccount.token_balance / unit_price) if unit_price > 0 else 0
	var max_qty := mini(stock, affordable)
	if limit > 0:
		max_qty = mini(max_qty, limit)

	## Capped stores (tiles only now) can't overflow. _storage_space_for returns
	## -1 for uncapped items (seeds/saplings/gems/etc.), which skips both guards
	## below. Clamp to free space and bail when a CAPPED store has no room.
	var space := _storage_space_for(item_key)
	if space == 0:
		_status_label.text = "Your storage for this item is full. Make room first."
		return
	if space > 0:
		max_qty = mini(max_qty, space)

	if max_qty < 1:
		_status_label.text = "You can't afford any of this item."
		return

	var dialog := ConfirmationDialog.new()
	dialog.title = "Buy %s" % ItemKeyRegistry.display_name(str(l.get("item_key", "")))
	dialog.ok_button_text = "Buy"
	## Constrain to the viewport so the OK/Cancel row can never fall off the
	## bottom of a short screen (Android gesture bar / small devices).
	var _vp := get_viewport().get_visible_rect().size
	dialog.min_size = Vector2(mini(320, int(_vp.x - 20.0)), mini(180, int(_vp.y - 60.0)))
	dialog.max_size = Vector2i(int(_vp.x - 20.0), int(_vp.y - 40.0))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	## Don't let the content expand to fill a tall screen — that would push the
	## dialog's OK/Cancel button row off the bottom (see the reprice dialog fix).
	box.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var info := Label.new()
	info.text = "%s tokens each  •  %d available%s%s" % [
		PlayerData.format_number(unit_price), stock,
		("  •  limit %d/day" % limit) if limit > 0 else "",
		("  •  room for %d" % space) if space >= 0 else ""]
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_font_size_override("font_size", 12)
	box.add_child(info)

	var qty_row := HBoxContainer.new()
	qty_row.add_theme_constant_override("separation", 8)
	var qty_lbl := Label.new()
	qty_lbl.text = "Quantity:"
	qty_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	qty_row.add_child(qty_lbl)
	var qty_spin := SpinBox.new()
	qty_spin.min_value = 1
	qty_spin.max_value = max_qty
	qty_spin.step = 1
	qty_spin.value = 1
	qty_spin.custom_minimum_size = Vector2(110, 40)
	qty_row.add_child(qty_spin)
	box.add_child(qty_row)

	var total_lbl := Label.new()
	total_lbl.text = "Total: %s tokens" % PlayerData.format_number(unit_price)
	total_lbl.add_theme_font_size_override("font_size", 12)
	total_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	box.add_child(total_lbl)
	## Live-update the total as quantity changes.
	qty_spin.value_changed.connect(func(v):
		total_lbl.text = "Total: %s tokens" % PlayerData.format_number(unit_price * int(v)))

	dialog.add_child(box)
	dialog.confirmed.connect(func():
		var q := int(qty_spin.value)
		dialog.queue_free()
		_do_buy(listing_id, q, item_key))
	dialog.canceled.connect(dialog.queue_free)
	dialog.close_requested.connect(dialog.queue_free)
	add_child(dialog)
	## Center within the VISIBLE viewport at a compact size so the Buy/Cancel
	## row always sits on-screen. Width capped; height auto-fits (0) then clamped
	## by max_size above. Without an explicit size, popup_centered() could place
	## the dialog so its bottom button row ran under the Android nav bar.
	var pop_w := mini(360, int(_vp.x - 20.0))
	dialog.popup_centered(Vector2i(pop_w, 0))
	## After layout, if the dialog is taller than the visible area, nudge it up
	## so the bottom (button row) stays fully on-screen.
	await get_tree().process_frame
	if is_instance_valid(dialog):
		var dh := dialog.size.y
		var max_y := int(_vp.y) - dh - 10
		if dialog.position.y > max_y:
			dialog.position.y = maxi(max_y, 10)


func _do_buy(listing_id: String, quantity: int, item_key: String = "") -> void:
	## Final storage-cap guard, re-checked at confirm time. Storage could have
	## filled since the dialog opened, and we must refuse BEFORE the server
	## charges tokens — claiming overflow into a capped store would lose items.
	if item_key != "":
		var space := _storage_space_for(item_key)
		if space == 0:
			_status_label.text = "Your storage for this item is full. Make room first."
			return
		if space > 0 and quantity > space:
			quantity = space
			_status_label.text = "Only room for %d — buying that many." % space
	if quantity < 1:
		return
	_status_label.text = "Buying…"
	var res: Dictionary = await MarketplaceAccount.buy(listing_id, quantity)
	if not res.get("ok", false):
		_status_label.text = "Purchase failed: %s" % str(res.get("error", ""))
		return
	_refresh_tokens_label()

	## How much of this purchase actually landed in local storage. If storage
	## filled during the buy (race), the rest sits in escrow — tell the player
	## plainly and point them to the Held items block (My Listings). Nothing is
	## lost or hidden: it auto-claims when space frees, or via its Claim button.
	var claimed_qty := 0
	if item_key != "":
		for it in res.get("claimed", []):
			if it is Dictionary and str(it.get("item_key", "")) == item_key:
				claimed_qty += int(it.get("quantity", 0))
	var spent_txt := PlayerData.format_number(int(res.get("spent", 0)))
	if item_key != "" and claimed_qty < quantity:
		var held_qty := quantity - claimed_qty
		_status_label.text = "Purchased! Spent %s tokens. %d added; %d are held (storage full) — see Held items under My Listings." % [
			spent_txt, claimed_qty, held_qty]
	else:
		_status_label.text = "Purchased! Spent %s tokens. Items added to your inventory." % spent_txt
	## Refresh Browse so stock/availability reflect the purchase.
	if _current_tab == "browse":
		_render_browse()


## ── Price history ───────────────────────────────────────────────

const PriceChart := preload("res://scripts/marketplace/price_chart.gd")

## Opens a dialog with the item's 30-day price chart plus a quick stat line.
func _on_price_history_pressed(item_key: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "%s — Price History" % ItemKeyRegistry.display_name(item_key)
	dialog.ok_button_text = "Close"
	## Cap the dialog to the viewport so the Close button can't fall off a short
	## screen; the chart min_size below could otherwise force it taller than the
	## display. Shrink the baseline min height to fit small devices.
	var _vp := get_viewport().get_visible_rect().size
	dialog.min_size = Vector2(mini(360, int(_vp.x - 20.0)), mini(320, int(_vp.y - 60.0)))
	dialog.max_size = Vector2i(int(_vp.x - 20.0), int(_vp.y - 40.0))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.custom_minimum_size = Vector2(340, 240)

	var status := Label.new()
	status.text = "Loading price history…"
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_font_size_override("font_size", 12)
	status.add_theme_color_override("font_color", Color(0.85, 0.88, 0.95))
	box.add_child(status)

	var chart := PriceChart.new()
	chart.custom_minimum_size = Vector2(320, 180)
	chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(chart)

	var stats := Label.new()
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats.add_theme_font_size_override("font_size", 11)
	stats.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	box.add_child(stats)

	dialog.add_child(box)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	dialog.close_requested.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()

	## Fetch after showing the dialog so the UI feels responsive.
	var res: Dictionary = await MarketplaceAccount.get_price_history(item_key, 30)
	if not is_instance_valid(dialog):
		return
	if not res.get("ok", false):
		status.text = "Couldn't load price history.\n%s" % str(res.get("error", ""))
		return
	var points: Array = res.get("points", [])
	chart.set_points(points)
	if points.is_empty():
		status.text = "No sales recorded yet for this item."
		stats.text = ""
		return
	status.text = "Last 30 days of sales (marketplace tokens)"
	stats.text = _price_stats_line(points)


## Builds a one-line summary: latest price, range, and total volume.
func _price_stats_line(points: Array) -> String:
	var last: Dictionary = points[points.size() - 1]
	var lo := INF
	var hi := -INF
	var vol := 0
	for p in points:
		lo = minf(lo, float(p.get("min_price", p.get("avg_price", 0))))
		hi = maxf(hi, float(p.get("max_price", p.get("avg_price", 0))))
		vol += int(p.get("volume", 0))
	if lo == INF:
		lo = 0.0
	if hi == -INF:
		hi = 0.0
	return "Latest avg: %s  •  Range: %s–%s  •  Sold: %s" % [
		PlayerData.format_number(int(last.get("avg_price", 0))),
		PlayerData.format_number(int(lo)),
		PlayerData.format_number(int(hi)),
		PlayerData.format_number(vol)]


## ── My Listings tab ─────────────────────────────────────────────

func _render_my_listings() -> void:
	if get_node_or_null("/root/MarketplaceAccount") == null or not MarketplaceAccount.has_account():
		_render_notice("Your online account isn't set up yet. Check your internet connection and reopen the game.")
		return

	_render_notice("Loading your listings…")
	## First, pull in anything held in escrow that now fits (buy races, prior
	## partial cancels). Capacity-gated, so it only takes what fits.
	await MarketplaceAccount.claim_escrow()
	if not is_instance_valid(_tab_body) or _current_tab != "mine":
		return
	var res: Dictionary = await MarketplaceAccount.get_my_listings()
	if not is_instance_valid(_tab_body) or _current_tab != "mine":
		return
	## Read whatever is STILL held after the auto-claim, to surface it.
	var escrow_res: Dictionary = await MarketplaceAccount.get_escrow()
	if not is_instance_valid(_tab_body) or _current_tab != "mine":
		return
	_clear_body()

	if not res.get("ok", false):
		_render_notice("Couldn't reach the market.\n%s" % str(res.get("error", "")))
		return

	## "Held items" — escrow the player couldn't fully claim (storage full) or
	## that this build can't accept yet. Shown so nothing is ever invisible.
	var held: Array = escrow_res.get("items", []) if escrow_res.get("ok", false) else []
	if not held.is_empty():
		_add_held_items_section(held)

	var listings: Array = res.get("listings", [])
	if listings.is_empty():
		if held.is_empty():
			_render_notice("You have no active listings.\nUse the Sell tab to list an item.")
		return

	for l in listings:
		if l is Dictionary:
			_add_my_listing_row(l)


## Renders the "Held items" block: everything currently sitting in server escrow
## that hasn't been claimed into local storage yet (storage full, or an item key
## this build doesn't recognize). A Claim button retries the capacity-gated claim
## so the player can pull items in after freeing space.
func _add_held_items_section(held: Array) -> void:
	var header := Label.new()
	header.text = "Held items (storage full — claim when you have space)"
	header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	header.add_theme_font_size_override("font_size", 12)
	header.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
	_tab_body.add_child(header)

	for it in held:
		if not (it is Dictionary):
			continue
		var item_key := str(it.get("item_key", ""))
		var qty := int(it.get("quantity", 0))
		if qty <= 0:
			continue

		var panel := PanelContainer.new()
		panel.mouse_filter = Control.MOUSE_FILTER_PASS
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.20, 0.17, 0.10, 0.9)
		style.set_corner_radius_all(6)
		style.content_margin_left = 10; style.content_margin_right = 10
		style.content_margin_top = 8; style.content_margin_bottom = 8
		panel.add_theme_stylebox_override("panel", style)
		_tab_body.add_child(panel)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		panel.add_child(row)

		## Icon only if this build knows the item; otherwise a generic frame.
		if ItemKeyRegistry.is_valid(item_key):
			_add_item_icon(row, item_key)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(info)

		var name_lbl := Label.new()
		## Unknown-to-this-build keys can't be named — show the raw key so the
		## player still SEES it exists (and knows to update the app).
		name_lbl.text = ItemKeyRegistry.display_name(item_key) if ItemKeyRegistry.is_valid(item_key) \
				else "%s (update app to receive)" % item_key
		name_lbl.add_theme_font_size_override("font_size", 14)
		name_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
		info.add_child(name_lbl)

		var detail := Label.new()
		detail.text = "%s held" % PlayerData.format_number(qty)
		detail.add_theme_font_size_override("font_size", 11)
		detail.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
		info.add_child(detail)

		## Claim button — only meaningful for items this build understands.
		if ItemKeyRegistry.is_valid(item_key):
			var claim_btn := Button.new()
			claim_btn.text = "Claim"
			claim_btn.add_theme_font_size_override("font_size", 12)
			claim_btn.custom_minimum_size = Vector2(72, 40)
			claim_btn.pressed.connect(_on_claim_held.bind(item_key))
			row.add_child(claim_btn)


## Retries the capacity-gated claim for a specific held item and reports how much
## came home vs. is still waiting on free space.
func _on_claim_held(item_key: String) -> void:
	var space := _storage_space_for(item_key)
	if space == 0:
		_status_label.text = "Still no room for %s — free some storage first." % \
			ItemKeyRegistry.display_name(item_key)
		return
	_status_label.text = "Claiming…"
	await MarketplaceAccount.claim_escrow()
	if _current_tab == "mine":
		_render_my_listings()


func _add_my_listing_row(l: Dictionary) -> void:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS  ## let drags pass to the scroll
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.14, 0.16, 0.14, 0.9)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10; style.content_margin_right = 10
	style.content_margin_top = 8; style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	_tab_body.add_child(panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_child(row)

	var item_key := str(l.get("item_key", ""))
	var listing_id := str(l.get("id", ""))

	_add_item_icon(row, item_key)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = ItemKeyRegistry.display_name(item_key)
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", Color(0.7, 1.0, 0.7))
	info.add_child(name_lbl)

	var detail := Label.new()
	var limit_txt := "no limit" if int(l.get("per_buyer_daily_limit", 0)) <= 0 \
			else "%d/day" % int(l.get("per_buyer_daily_limit", 0))
	detail.text = "%s tokens each  |  %d remaining  |  limit: %s" % [
		PlayerData.format_number(int(l.get("unit_price", 0))),
		int(l.get("quantity_remaining", 0)), limit_txt]
	detail.add_theme_font_size_override("font_size", 11)
	detail.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	info.add_child(detail)

	var actions := VBoxContainer.new()
	actions.add_theme_constant_override("separation", 4)
	row.add_child(actions)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.add_theme_font_size_override("font_size", 12)
	cancel_btn.custom_minimum_size = Vector2(72, 40)
	cancel_btn.pressed.connect(_on_cancel_listing.bind(listing_id, item_key))
	actions.add_child(cancel_btn)

	var hist_btn := Button.new()
	hist_btn.text = "📈"
	hist_btn.tooltip_text = "Price history"
	hist_btn.add_theme_font_size_override("font_size", 12)
	hist_btn.custom_minimum_size = Vector2(72, 32)
	hist_btn.pressed.connect(_on_price_history_pressed.bind(item_key))
	actions.add_child(hist_btn)


## Cancels a listing, returning only as much as the player can hold right now
## and KEEPING the rest as an active listing (so nothing is hidden — the leftover
## stays visible/sellable in My Listings). We tell the server our free local
## space; it moves that much to escrow and reduces the listing's quantity. We
## then claim that escrow immediately (sized to fit, so it all comes home).
func _on_cancel_listing(listing_id: String, item_key: String) -> void:
	_status_label.text = "Cancelling…"
	## Free local space for this item (-1 = uncapped -> return everything).
	var space := _storage_space_for(item_key)
	var res: Dictionary = await MarketplaceAccount.cancel_listing_partial(listing_id, space)
	if not res.get("ok", false):
		_status_label.text = "Cancel failed: %s" % str(res.get("error", ""))
		return
	var returned := int(res.get("returned_qty", 0))
	var remaining := int(res.get("remaining_qty", 0))

	## Claim the just-escrowed portion into inventory (fits by construction).
	if returned > 0:
		await MarketplaceAccount.claim_escrow()

	var item_name := ItemKeyRegistry.display_name(item_key)
	if remaining <= 0:
		_status_label.text = "Listing cancelled. Returned %d %s to your inventory." % [returned, item_name]
	elif returned > 0:
		_status_label.text = "Returned %d %s. Your storage is full, so %d stay listed for sale." % [
			returned, item_name, remaining]
	else:
		_status_label.text = "Your storage for %s is full — nothing returned. %d stay listed for sale. Free space, then cancel again." % [
			item_name, remaining]

	## Refresh the list so the (possibly still-active) listing reflects the new qty.
	if _current_tab == "mine":
		_render_my_listings()


## ── Sell tab ────────────────────────────────────────────────────

func _render_sell() -> void:
	if get_node_or_null("/root/MarketplaceAccount") == null or not MarketplaceAccount.has_account():
		_render_notice("Your online account isn't set up yet. Check your internet connection and reopen the game.")
		return

	## Capture the one-time pricing nudge for this whole Sell-tab visit, so every
	## item consistently shows the suggested price on the first visit. The
	## persisted flag is flipped when the player leaves the Sell tab.
	_pricing_nudge_active = not PlayerData.market_suggested_pricing_seen

	## Collect the item-keys the player currently owns AND is allowed to trade.
	## (Unique permanent tools like the Tractor are excluded — see is_tradeable.)
	_sell_owned_keys.clear()
	for key in ItemKeyRegistry.all_keys():
		if ItemKeyRegistry.is_tradeable(key) and PlayerData.market_count_owned(key) > 0:
			_sell_owned_keys.append(key)

	if _sell_owned_keys.is_empty():
		_render_notice("You have nothing to sell.\nHarvest, mine, or craft some items first!")
		return

	## Item picker.
	var item_row := HBoxContainer.new()
	item_row.add_theme_constant_override("separation", 8)
	var item_lbl := Label.new()
	item_lbl.text = "Item:"
	item_lbl.add_theme_font_size_override("font_size", 13)
	item_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	item_row.add_child(item_lbl)
	_sell_item_dropdown = OptionButton.new()
	## Clip + a modest fixed width so a long item name can't push the row (and
	## thus the whole content root) wider than the screen. We intentionally do
	## NOT set per-item icons here: the source sprites are full-resolution and an
	## OptionButton sizes itself to the native icon, which blew the entire tab
	## (title included) off-screen. Text-only keeps the picker bounded.
	_sell_item_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sell_item_dropdown.add_theme_font_size_override("font_size", 13)
	_sell_item_dropdown.clip_text = true
	_sell_item_dropdown.custom_minimum_size = Vector2(0, 40)
	for i in range(_sell_owned_keys.size()):
		var k: String = _sell_owned_keys[i]
		_sell_item_dropdown.add_item("%s  (own %d)" % [
			ItemKeyRegistry.display_name(k), PlayerData.market_count_owned(k)], i)
	_sell_item_dropdown.item_selected.connect(_on_sell_item_selected)
	## The native OptionButton popup (a PopupMenu) can't be swipe-scrolled on
	## touch, and this list is long. Intercept the popup and show our own
	## finger-scrollable picker instead; it drives the same select() path.
	_sell_item_dropdown.get_popup().about_to_popup.connect(_on_sell_popup_about_to_show)
	item_row.add_child(_sell_item_dropdown)
	_tab_body.add_child(item_row)

	## Quantity / Price / Daily-limit spinboxes.
	_sell_qty_spin = _add_sell_number_row("Quantity:", 1, 1, 999999)
	_sell_price_spin = _add_sell_number_row("Price each (tokens):", 100, 1, 99999999)
	_sell_limit_spin = _add_sell_number_row("Per-buyer daily limit (0 = none):", 0, 0, 999999)

	## List button.
	var list_btn := Button.new()
	list_btn.text = "List on Market"
	list_btn.add_theme_font_size_override("font_size", 14)
	list_btn.custom_minimum_size = Vector2(0, 48)
	list_btn.pressed.connect(_on_list_pressed)
	_tab_body.add_child(list_btn)

	## Initialize the first item: default quantity to max on hand + auto-fill
	## price/limit from any existing listing. (The one-time "suggested pricing"
	## nudge + its persistence are handled inside _on_sell_item_selected so the
	## flag flips only after the first selection's async listing lookup resolves.)
	_on_sell_item_selected(0)


## Builds a labeled SpinBox row and returns the SpinBox.
func _add_sell_number_row(label_text: String, value: float, min_v: float, max_v: float) -> SpinBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	row.add_child(lbl)
	var spin := SpinBox.new()
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = 1
	spin.value = value
	spin.custom_minimum_size = Vector2(120, 40)
	row.add_child(spin)
	_tab_body.add_child(row)
	return spin


## Clamp the quantity spinbox to what's owned, and — if the player already has
## an active listing for this item — auto-fill its price + daily limit so adding
## more merges by default. Remembers that existing offer for the List handler.
func _on_sell_item_selected(index: int) -> void:
	if index < 0 or index >= _sell_owned_keys.size():
		return
	var key: String = _sell_owned_keys[index]
	var owned := PlayerData.market_count_owned(key)
	if _sell_qty_spin != null:
		_sell_qty_spin.max_value = maxi(owned, 1)
		## Default the quantity to everything on hand (player can dial it down).
		_sell_qty_spin.value = maxi(owned, 1)

	## Default the price to this item's suggested token price. If the player
	## already lists this item, the existing-listing lookup below overrides it
	## with their own price. Either way the player can still type any value.
	if _sell_price_spin != null:
		_sell_price_spin.value = _suggested_list_price(key)

	## Reset the remembered existing offer, then look one up.
	_existing_price = -1
	_existing_limit = -1
	if get_node_or_null("/root/MarketplaceAccount") != null and MarketplaceAccount.has_account():
		var res: Dictionary = await MarketplaceAccount.get_my_listing_for(key)
		## The selection may have changed during the await.
		if _sell_item_dropdown == null or not is_instance_valid(_sell_item_dropdown):
			return
		if _sell_item_dropdown.get_selected_id() != index:
			return
		var listing: Dictionary = res.get("listing", {})
		if not listing.is_empty():
			_existing_price = int(listing.get("unit_price", 0))
			_existing_limit = int(listing.get("per_buyer_daily_limit", 0))
			## Pre-fill the fields from the existing listing — EXCEPT during the
			## one-time pricing nudge (the player's first-ever Sell-tab visit
			## after the new suggested prices shipped), when we keep the
			## suggestion for every item to steer them toward it. (The limit
			## still fills, and _existing_price is still remembered so the
			## reprice/merge prompt on List works correctly either way.)
			if _sell_price_spin != null and not _pricing_nudge_active:
				_sell_price_spin.value = _existing_price
			if _sell_limit_spin != null:
				_sell_limit_spin.value = _existing_limit


## Intercept the native (non-touch-scrollable) OptionButton popup and show our
## own finger-scrollable picker instead.
func _on_sell_popup_about_to_show() -> void:
	if _sell_item_dropdown == null or not is_instance_valid(_sell_item_dropdown):
		return
	## Hide the native popup immediately (it was about to show) and open ours.
	_sell_item_dropdown.get_popup().call_deferred("hide")
	call_deferred("_show_sell_item_picker")


## A swipe-scrollable item picker: a dim backdrop + a scrollable column of
## buttons, one per owned item. Choosing drives the same select() + handler path
## the native dropdown would have.
func _show_sell_item_picker() -> void:
	if _sell_item_dropdown == null or not is_instance_valid(_sell_item_dropdown):
		return

	var overlay := Control.new()
	overlay.name = "SellItemPicker"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	## Tap-outside-to-dismiss backdrop.
	var dim := Button.new()
	dim.flat = true
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim_style := StyleBoxFlat.new()
	dim_style.bg_color = Color(0, 0, 0, 0.55)
	dim.add_theme_stylebox_override("normal", dim_style)
	dim.add_theme_stylebox_override("hover", dim_style)
	dim.add_theme_stylebox_override("pressed", dim_style)
	dim.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	dim.pressed.connect(overlay.queue_free)
	overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(300, 420)
	var pstyle := StyleBoxFlat.new()
	pstyle.bg_color = Color(0.12, 0.12, 0.16, 1.0)
	pstyle.set_corner_radius_all(8)
	pstyle.set_border_width_all(2)
	pstyle.border_color = Color(0.4, 0.6, 0.9)
	pstyle.content_margin_left = 6; pstyle.content_margin_right = 6
	pstyle.content_margin_top = 6; pstyle.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", pstyle)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Choose an item to sell"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	vbox.add_child(title)

	## Finger-scrollable list.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.scroll_deadzone = 12   ## tolerate a little finger wobble before it counts as a tap
	vbox.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	scroll.add_child(list)

	var selected := _sell_item_dropdown.get_selected_id()
	for i in range(_sell_item_dropdown.item_count):
		var idx := i  ## capture per-iteration for the lambda
		var btn := Button.new()
		btn.text = _sell_item_dropdown.get_item_text(i)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.clip_text = true
		btn.custom_minimum_size = Vector2(0, 38)
		btn.add_theme_font_size_override("font_size", 13)
		if i == selected:
			btn.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
		btn.pressed.connect(func():
			overlay.queue_free()
			if _sell_item_dropdown != null and is_instance_valid(_sell_item_dropdown):
				_sell_item_dropdown.select(idx)
				_on_sell_item_selected(idx))
		list.add_child(btn)

	add_child(overlay)


func _on_list_pressed() -> void:
	if _sell_item_dropdown == null:
		return
	var idx := _sell_item_dropdown.get_selected_id()
	if idx < 0 or idx >= _sell_owned_keys.size():
		_status_label.text = "Pick an item to list."
		return
	var key: String = _sell_owned_keys[idx]
	var qty := int(_sell_qty_spin.value)
	var price := int(_sell_price_spin.value)
	var limit := int(_sell_limit_spin.value)

	if qty < 1:
		_status_label.text = "Quantity must be at least 1."
		return
	if PlayerData.market_count_owned(key) < qty:
		_status_label.text = "You don't own that many."
		return

	## If the player already has a listing for this item at DIFFERENT terms,
	## ask whether to re-price everything to the new terms (one merged listing)
	## or list this batch separately at the new price.
	var has_existing := _existing_price >= 0
	var terms_differ := has_existing and (price != _existing_price or limit != _existing_limit)
	if terms_differ:
		_prompt_reprice_or_separate(key, qty, price, limit)
		return

	## No existing listing, or same terms -> list normally (server auto-merges
	## when item_key + price + limit match an existing active listing).
	await _do_list(key, qty, price, limit)


## Lists `qty` of `key` at the given price/limit (deducting locally on success),
## then refreshes the Sell tab. Shared by the plain and reprice paths.
func _do_list(key: String, qty: int, price: int, limit: int) -> void:
	_status_label.text = "Listing…"
	var res: Dictionary = await MarketplaceAccount.list_and_deduct(key, qty, price, limit)
	if not res.get("ok", false):
		_status_label.text = "Listing failed: %s" % str(res.get("error", ""))
		return
	_status_label.text = "Listed %d %s at %s tokens each!" % [
		qty, ItemKeyRegistry.display_name(key), PlayerData.format_number(price)]
	if _current_tab == "sell":
		_clear_body()
		_render_sell()


## Asks the player how to handle a price/limit change vs their existing listing:
##   • "All at new price" -> reprice existing listings to the new terms, then
##      list this batch so everything merges into one.
##   • "This batch only"  -> list the new batch separately at the new price.
func _prompt_reprice_or_separate(key: String, qty: int, price: int, limit: int) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Different Price"
	## OK = "All at new price"; the extra custom button = "This batch only".
	dialog.ok_button_text = "All at new price"
	dialog.add_button("This batch only", true, "separate")
	dialog.get_cancel_button().text = "Cancel"

	## Use the dialog's built-in message label rather than a stretching child
	## VBox. Adding an expanding child control here consumed the whole client
	## area and pushed the OK/Cancel button row off the bottom of tall (mobile)
	## screens, leaving the dialog with no visible buttons.
	dialog.dialog_autowrap = true
	dialog.dialog_text = "You already list %s at %s tokens (limit %s).\n\nRe-price ALL of them to %s tokens (limit %s) and combine, or list just this batch separately at the new price?" % [
		ItemKeyRegistry.display_name(key),
		PlayerData.format_number(_existing_price),
		("none" if _existing_limit <= 0 else str(_existing_limit)),
		PlayerData.format_number(price),
		("none" if limit <= 0 else str(limit))]

	dialog.confirmed.connect(func():
		dialog.queue_free()
		_do_reprice_and_list(key, qty, price, limit))
	## Custom "separate" button.
	dialog.custom_action.connect(func(action):
		if action == "separate":
			dialog.queue_free()
			_do_list(key, qty, price, limit))
	dialog.canceled.connect(dialog.queue_free)
	dialog.close_requested.connect(dialog.queue_free)
	add_child(dialog)
	## Cap the width so it doesn't stretch full-screen; height auto-fits the
	## wrapped text plus the button row.
	dialog.popup_centered(Vector2i(360, 0))


## Re-prices the seller's existing listings for `key` to the new terms, then
## lists the new batch (which merges in since terms now match).
func _do_reprice_and_list(key: String, qty: int, price: int, limit: int) -> void:
	_status_label.text = "Re-pricing…"
	var rep: Dictionary = await MarketplaceAccount.reprice(key, price, limit)
	if not rep.get("ok", false):
		_status_label.text = "Re-price failed: %s" % str(rep.get("error", ""))
		return
	await _do_list(key, qty, price, limit)


## ── Tokens ──────────────────────────────────────────────────────

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


func _reconcile_tokens() -> void:
	if get_node_or_null("/root/MarketplaceAccount") == null or not MarketplaceAccount.has_account():
		return
	await MarketplaceAccount.reconcile()
	## Pull in any escrow that was held back on a previous full-storage buy or
	## cancel. Capacity-gated, so it only takes what now fits; the rest waits.
	await MarketplaceAccount.claim_escrow()
	_refresh_tokens_label()


## ── Change online name ──────────────────────────────────────────

## One shared name (in-game + online market) — same price as Settings.
var NAME_CHANGE_COST: int:
	get:
		return PlayerData.get_name_change_cost()

func _on_change_name_pressed() -> void:
	if get_node_or_null("/root/MarketplaceAccount") == null:
		_status_label.text = "The online market is unavailable."
		return

	var free := bool(MarketplaceAccount.free_name_change)
	if not free and PlayerData.coins < NAME_CHANGE_COST:
		_status_label.text = "Changing your name costs %s coins." % PlayerData.format_number(NAME_CHANGE_COST)
		return

	var dialog := ConfirmationDialog.new()
	dialog.title = "Change Online Name"
	dialog.ok_button_text = "Change" if free else "Change (%s)" % PlayerData.format_number(NAME_CHANGE_COST)
	dialog.min_size = Vector2(340, 180)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	## Prevent the content from expanding and pushing the button row off-screen.
	box.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var info := Label.new()
	info.text = "New name (2-16 letters/numbers/spaces)." if free \
		else "New name (2-16 chars). Costs %s coins." % PlayerData.format_number(NAME_CHANGE_COST)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_font_size_override("font_size", 11)
	box.add_child(info)
	var edit := LineEdit.new()
	edit.text = PlayerData.player_name
	edit.max_length = 16
	edit.custom_minimum_size = Vector2(0, 40)
	box.add_child(edit)
	dialog.add_child(box)

	dialog.confirmed.connect(func():
		var new_name := edit.text
		dialog.queue_free()
		_do_rename(new_name, free))
	dialog.canceled.connect(dialog.queue_free)
	dialog.close_requested.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


func _do_rename(new_name: String, _free: bool) -> void:
	_status_label.text = "Checking name…"
	## Shared rename: validates, asks the server (uniqueness), then charges coins
	## (or consumes the free override) and updates the in-game name too.
	var err: String = await PlayerData.change_name(new_name)
	if not is_instance_valid(_status_label):
		return
	if err != "":
		_status_label.text = "Couldn't change name: %s" % err
		return
	_refresh_tokens_label()
	_status_label.text = "Your name is now %s." % PlayerData.player_name


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()
