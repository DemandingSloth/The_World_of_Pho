extends BaseScreen
## Prestige screen — spend XP to permanently upgrade game mechanics.
## Upgrades are selected like a cart then checked out all at once.

## Upgrade definitions: id, title, description template, max_level, per_level effect label
const UPGRADE_DEFS: Array[Dictionary] = [
	{
		"id": "crop_time",
		"title": "Rapid Growth",
		"desc": "Reduce crop grow time by 5% per level",
		"effect_fmt": "-%d%% grow time",
		"icon": "🌱",
	},
	{
		"id": "safe_tiles",
		"title": "Head Start",
		"desc": "Start expeditions with safe pre-revealed tiles (+1 per level, max 10 on small / 25 on large)",
		"effect_fmt": "+%d safe tile(s) at start",
		"icon": "⛏️",
	},
	{
		"id": "prospector_time",
		"title": "Swift Prospectors",
		"desc": "Reduce prospector production interval by 5% per level",
		"effect_fmt": "-%d%% prospector interval",
		"icon": "⏱️",
	},
	{
		"id": "prospector_cost",
		"title": "Bargain Hire",
		"desc": "Reduce prospector purchase cost by 5% per level",
		"effect_fmt": "-%d%% prospector cost",
		"icon": "💰",
	},
	{
		"id": "gem_profit",
		"title": "Gemologist",
		"desc": "Increase gem sell value (+25% at level 1, up to +1000% at level 10)",
		"effect_fmt": "+%d%% gem value",
		"icon": "💎",
	},
	{
		"id": "garden_profit",
		"title": "Master Farmer",
		"desc": "Increase crop sell value at the Marketplace (+25% at level 1, up to +1000% at level 10)",
		"effect_fmt": "+%d%% crop sell value",
		"icon": "🌾",
	},
	{
		"id": "fruit_profit",
		"title": "Orchard Baron",
		"desc": "Increase orchard fruit sell value (+25% at level 1, up to +1000% at level 10)",
		"effect_fmt": "+%d%% fruit value",
		"icon": "🍎",
	},
	{
		"id": "auto_plant",
		"title": "Green Thumb",
		"desc": "Auto-Plant button fills that many rows at once in garden & orchard with your selected seed/sapling (+1 row per level)",
		"effect_fmt": "Auto-plants %d row(s) at once",
		"icon": "🤖",
	},
	{
		"id": "xp_boost",
		"title": "Scholar",
		"desc": "Increase all XP gains (+25% at level 1, up to +1000% at level 10)",
		"effect_fmt": "+%d%% XP gain",
		"icon": "📚",
	},
	{
		"id": "market_refresh",
		"title": "Merchant's Ledger",
		"desc": "Increase daily Marketplace refreshes (base 3/day). +1 at level 1, scaling up to +25 at level 10",
		"effect_fmt": "+%d marketplace refresh(es)/day",
		"icon": "🔄",
	},
	{
		"id": "mission_refresh",
		"title": "Quartermaster",
		"desc": "Increase daily Mission rerolls (base 3/day). +1 at level 1, scaling up to +25 at level 10",
		"effect_fmt": "+%d mission reroll(s)/day",
		"icon": "📋",
	},
	{
		"id": "mine_layers",
		"title": "Deep Digger",
		"desc": "Add a layer to the Deep Mine (base 1). +1 layer per level, up to 11 total. Deeper layers yield rarer gems.",
		"effect_fmt": "%d Deep Mine layer(s)",
		"icon": "⛏️",
	},
	{
		"id": "mine_multi_layer",
		"title": "Core Driller",
		"desc": "Each Deep Mine dig (shovel or excavator) drills through more layers at once. +1 layer per level.",
		"effect_fmt": "Digs %d layer(s) per action",
		"icon": "🛢️",
	},
	{
		"id": "excavator_rows",
		"title": "Heavy Machinery",
		"desc": "The Deep Mine Excavator clears more rows per use (base 1). +1 row per level.",
		"effect_fmt": "Excavator clears %d row(s)",
		"icon": "🚜",
	},
	{
		"id": "mine_auto_collect",
		"title": "Auto-Collector",
		"desc": "Unlocks a Collect All button in the Deep Mine that harvests every unearthed treasure at once.",
		"effect_fmt": "Auto-collect %sunlocked",
		"icon": "🧲",
	},
	{
		"id": "saw_capacity",
		"title": "Bigger Saw",
		"desc": "Increase how many gems the Workshop saw holds at once (base 10, up to 10000 at level 10).",
		"effect_fmt": "Saw holds %d gems",
		"icon": "🪚",
	},
	{
		"id": "saw_speed",
		"title": "Sharper Blade",
		"desc": "Reduce the Workshop saw's gem cutting time by 5% per level (up to 50%).",
		"effect_fmt": "-%d%% cut time",
		"icon": "⚙️",
	},
	{
		"id": "saw_parallel",
		"title": "Multi-Blade",
		"desc": "The Workshop saw cuts more gems at once (base 1). Each level adds more than the last: +1, then +2, then +3, and so on.",
		"effect_fmt": "Cuts %d gems at once",
		"icon": "🪚",
	},
	{
		"id": "hourglass",
		"title": "Time Lord",
		"desc": "Increase daily Hourglass uses (base 3/day). +1 use per level.",
		"effect_fmt": "+%d hourglass use(s)/day",
		"icon": "⏳",
	},
	{
		"id": "foundry_capacity",
		"title": "Bigger Foundry",
		"desc": "Increase how many ores the Workshop foundry holds at once (base 10, up to 10000 at level 10).",
		"effect_fmt": "Foundry holds %d ores",
		"icon": "🏭",
	},
	{
		"id": "foundry_speed",
		"title": "Hotter Forge",
		"desc": "Reduce the Workshop foundry's smelting time by 5% per level (up to 50%).",
		"effect_fmt": "-%d%% smelt time",
		"icon": "🔥",
	},
	{
		"id": "foundry_parallel",
		"title": "Multi-Crucible",
		"desc": "The Workshop foundry smelts more ores at once (base 1). Each level adds more than the last: +1, then +2, then +3, and so on.",
		"effect_fmt": "Smelts %d ores at once",
		"icon": "🏭",
	},
	{
		"id": "misc_value",
		"title": "Lumber Baron",
		"desc": "Increase sell value of wood, sticks and other misc goods (+25% at level 1, up to +1000% at level 10).",
		"effect_fmt": "+%d%% misc goods value",
		"icon": "🪵",
	},
	{
		"id": "passive_xp",
		"title": "Steady Learner",
		"desc": "Earn XP every hour, even while the game is closed (10 XP/hr at level 1, up to 10,000 XP/hr at level 10).",
		"effect_fmt": "+%s XP per hour",
		"icon": "🕯️",
	},
	{
		"id": "horse_training_cap",
		"title": "Master Trainer",
		"desc": "Raise the most stat points one training minigame can earn (base 10). 11 at level 1, up to 50 at level 10. Stacks with the horse guild's Training Cap upgrade.",
		"effect_fmt": "Training sessions earn up to %d points",
		"icon": "🏇",
	},
	{
		"id": "horse_stable_size",
		"title": "Bigger Barn",
		"desc": "Add horse slots to your stable (+1 per level, +10 at level 10). Stacks with the horse guild's Stable Size upgrade.",
		"effect_fmt": "+%d stable slot(s)",
		"icon": "🐴",
	},
	{
		## Money Gun print-rate upgrade. SERVER-AUTHORITATIVE: the level lives on
		## the account (migration 053); checkout routes this through
		## MoneyGun.upgrade() instead of a local write. Only shown when the player
		## owns the gun (gated in the build loop). Rate = 1 * 2^level Benjamins/hr.
		"id": "money_gun",
		"title": "Overclocked Printer",
		"desc": "The Money Gun prints Benjamins faster. Rate doubles each level (1/hr at Lv.0, up to 1024/hr at Lv.10).",
		"effect_fmt": "Prints %d Benjamin(s)/hour",
		"icon": "🔫",
	},
]

## cart: { upgrade_id -> qty_to_buy }
var _cart: Dictionary = {}
var _vbox: VBoxContainer = null
var _cart_label: Label = null
var _checkout_btn: Button = null
var _xp_label: Label = null


func get_screen_name() -> String:
	return "prestige"


func show_top_bar() -> bool:
	return true


func enter(params: Dictionary = {}) -> void:
	_cart = {}
	_build_ui()
	PlayerData.data_changed.connect(_on_data_changed)


func exit() -> void:
	if PlayerData.data_changed.is_connected(_on_data_changed):
		PlayerData.data_changed.disconnect(_on_data_changed)
	for child in get_children():
		child.queue_free()
	_vbox = null
	_cart_label = null
	_checkout_btn = null
	_xp_label = null


## ── Build UI ───────────────────────────────────────────────────


func _build_ui() -> void:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_vbox = VBoxContainer.new()
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	_vbox.add_theme_constant_override("separation", 12)
	scroll.add_child(_vbox)

	## Back button
	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(200, 48)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(_on_back_pressed)
	_vbox.add_child(back_btn)

	## Title
	var title := Label.new()
	title.text = "✨ Prestige Upgrades"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.178, 0.14, 0.0, 1.0))
	_vbox.add_child(title)

	## XP display
	_xp_label = Label.new()
	_xp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_xp_label.add_theme_font_size_override("font_size", 13)
	_vbox.add_child(_xp_label)
	_refresh_xp_label()

	var sub := Label.new()
	sub.text = "Spend XP to permanently enhance your game.\nAdd upgrades to your cart, then checkout."
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.add_theme_font_size_override("font_size", 11)
	_vbox.add_child(sub)

	## Keep the local prestige mirror of the server-authoritative Money Gun level
	## in step, so the shared cost-curve / level / +/- logic reads the right value.
	PlayerData.prestige_levels["money_gun"] = PlayerData.money_gun_level

	## Upgrade rows. The Money Gun row only appears once the player owns the gun.
	for def in UPGRADE_DEFS:
		if def["id"] == "money_gun" and not PlayerData.money_gun_owned:
			continue
		_vbox.add_child(_build_upgrade_row(def))

	## Cart summary + checkout
	var sep := HSeparator.new()
	_vbox.add_child(sep)

	_cart_label = Label.new()
	_cart_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cart_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cart_label.add_theme_font_size_override("font_size", 12)
	_vbox.add_child(_cart_label)

	_checkout_btn = Button.new()
	_checkout_btn.text = "Checkout"
	_checkout_btn.custom_minimum_size = Vector2(220, 52)
	_checkout_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_checkout_btn.add_theme_font_size_override("font_size", 15)
	_checkout_btn.disabled = true
	_checkout_btn.pressed.connect(_on_checkout_pressed)
	_vbox.add_child(_checkout_btn)

	_refresh_cart_ui()


func _build_upgrade_row(def: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "Row_%s" % def["id"]
	## MOUSE_FILTER_PASS lets scroll drags reach the ScrollContainer behind the panel.
	## Interactive children (buttons) keep MOUSE_FILTER_STOP so clicks still work.
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.14, 0.88)
	style.corner_radius_top_left = 6; style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6; style.corner_radius_bottom_right = 6
	style.content_margin_left = 10; style.content_margin_right = 10
	style.content_margin_top = 8; style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	hbox.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_child(hbox)

	## Icon label
	var icon_lbl := Label.new()
	icon_lbl.text = def["icon"]
	icon_lbl.add_theme_font_size_override("font_size", 24)
	icon_lbl.custom_minimum_size = Vector2(36, 36)
	icon_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	hbox.add_child(icon_lbl)

	## Info column
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 3)
	info.mouse_filter = Control.MOUSE_FILTER_PASS
	hbox.add_child(info)

	var id: String = def["id"]
	var current_lvl: int = PlayerData.get_prestige_level(id)
	var next_cost: int = PlayerData.get_prestige_upgrade_cost(id)

	var name_lbl := Label.new()
	## Binary (one-time) unlocks show Owned/Locked instead of a "Lv.X / 10" count.
	if _is_one_time(id):
		name_lbl.text = "%s  (%s)" % [def["title"], "Owned" if current_lvl >= 1 else "Locked"]
	else:
		name_lbl.text = "%s  (Lv.%d / 10)" % [def["title"], current_lvl]
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	info.add_child(name_lbl)

	var desc_lbl := Label.new()
	desc_lbl.text = def["desc"]
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.add_theme_font_size_override("font_size", 10)
	desc_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.75))
	desc_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	info.add_child(desc_lbl)

	var effect_lbl := Label.new()
	effect_lbl.name = "EffectLabel"
	effect_lbl.add_theme_font_size_override("font_size", 11)
	effect_lbl.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
	effect_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	info.add_child(effect_lbl)
	_update_effect_label(effect_lbl, def, current_lvl)

	var cost_lbl := Label.new()
	cost_lbl.name = "CostLabel"
	cost_lbl.add_theme_font_size_override("font_size", 10)
	cost_lbl.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	cost_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	info.add_child(cost_lbl)
	## A one-time upgrade is "maxed" once owned (level >= 1), so it can't be
	## bought again even though its cost curve technically has more entries.
	var one_time_owned := _is_one_time(id) and current_lvl >= 1
	if next_cost < 0 or one_time_owned:
		cost_lbl.text = "OWNED" if _is_one_time(id) else "MAX LEVEL"
	else:
		cost_lbl.text = "Cost: %s XP" % PlayerData.format_number(next_cost) if _is_one_time(id) else "Next level: %s XP" % PlayerData.format_number(next_cost)

	## +/- buttons column
	var btn_col := VBoxContainer.new()
	btn_col.add_theme_constant_override("separation", 4)
	btn_col.mouse_filter = Control.MOUSE_FILTER_PASS
	hbox.add_child(btn_col)

	if next_cost >= 0 and not one_time_owned:
		var add_btn := Button.new()
		add_btn.text = "+"
		add_btn.name = "AddBtn"
		add_btn.custom_minimum_size = Vector2(40, 36)
		add_btn.pressed.connect(_on_add_to_cart.bind(id))
		btn_col.add_child(add_btn)

		var qty_lbl := Label.new()
		qty_lbl.name = "QtyLabel"
		qty_lbl.text = "0"
		qty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		qty_lbl.add_theme_font_size_override("font_size", 12)
		qty_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		btn_col.add_child(qty_lbl)

		var rem_btn := Button.new()
		rem_btn.text = "−"
		rem_btn.name = "RemBtn"
		rem_btn.custom_minimum_size = Vector2(40, 36)
		rem_btn.pressed.connect(_on_remove_from_cart.bind(id))
		btn_col.add_child(rem_btn)
	else:
		var maxed := Label.new()
		maxed.text = "✅"
		maxed.add_theme_font_size_override("font_size", 20)
		maxed.mouse_filter = Control.MOUSE_FILTER_PASS
		maxed.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn_col.add_child(maxed)

	return panel


func _update_effect_label(lbl: Label, def: Dictionary, current_lvl: int) -> void:
	if current_lvl == 0:
		lbl.text = "Not yet upgraded"
		return
	var id: String = def["id"]
	match id:
		"crop_time":
			lbl.text = def["effect_fmt"] % (current_lvl * 5)
		"safe_tiles":
			lbl.text = def["effect_fmt"] % current_lvl
		"prospector_time":
			lbl.text = def["effect_fmt"] % (current_lvl * 5)
		"prospector_cost":
			lbl.text = def["effect_fmt"] % (current_lvl * 5)
		"gem_profit", "garden_profit", "fruit_profit", "xp_boost", "misc_value":
			var slvl: int = clampi(current_lvl, 1, PlayerData.SELL_PRICE_PRESTIGE_BONUS_PCT.size())
			lbl.text = def["effect_fmt"] % PlayerData.SELL_PRICE_PRESTIGE_BONUS_PCT[slvl - 1]
		"auto_plant":
			lbl.text = def["effect_fmt"] % current_lvl
		"market_refresh":
			var lvl: int = clampi(current_lvl, 1, PlayerData.MARKET_REFRESH_PRESTIGE_BONUS.size())
			lbl.text = def["effect_fmt"] % PlayerData.MARKET_REFRESH_PRESTIGE_BONUS[lvl - 1]
		"mission_refresh":
			var mlvl: int = clampi(current_lvl, 1, PlayerData.MISSION_REFRESH_PRESTIGE_BONUS.size())
			lbl.text = def["effect_fmt"] % PlayerData.MISSION_REFRESH_PRESTIGE_BONUS[mlvl - 1]
		"mine_layers":
			## Base 1 layer + this level.
			lbl.text = def["effect_fmt"] % (1 + current_lvl)
		"mine_multi_layer":
			## Base 1 layer/action + this level.
			lbl.text = def["effect_fmt"] % (1 + current_lvl)
		"excavator_rows":
			## Base 1 row + this level.
			lbl.text = def["effect_fmt"] % (1 + current_lvl)
		"mine_auto_collect":
			## Binary unlock — level 1+ enables it.
			lbl.text = def["effect_fmt"] % ("" if current_lvl >= 1 else "not ")
		"saw_capacity":
			## Linear BASE -> MAX (10000) over 10 levels, snapped to even; level 10 = MAX.
			var s_lvl: int = clampi(current_lvl, 0, 10)
			var s_raw: int = WorkshopData.SAW_BASE_CAPACITY + int(round((WorkshopData.SAW_MAX_CAPACITY - WorkshopData.SAW_BASE_CAPACITY) * s_lvl / 10.0))
			var cap: int = clampi(int(round(s_raw / 2.0)) * 2, WorkshopData.SAW_BASE_CAPACITY, WorkshopData.SAW_MAX_CAPACITY)
			lbl.text = def["effect_fmt"] % cap
		"saw_speed":
			lbl.text = def["effect_fmt"] % (current_lvl * 5)
		"saw_parallel":
			## Base 1 + growing per-level bonus (+1,+2,+3...) = 1 + n(n+1)/2.
			lbl.text = def["effect_fmt"] % (1 + current_lvl * (current_lvl + 1) / 2)
		"hourglass":
			## +1 use per level (base 3 shown in the description).
			lbl.text = def["effect_fmt"] % current_lvl
		"foundry_capacity":
			## Linear BASE -> MAX (10000) over 10 levels, snapped to even; level 10 = MAX (mirrors the saw).
			var f_lvl: int = clampi(current_lvl, 0, 10)
			var f_raw: int = WorkshopData.FOUNDRY_BASE_CAPACITY + int(round((WorkshopData.FOUNDRY_MAX_CAPACITY - WorkshopData.FOUNDRY_BASE_CAPACITY) * f_lvl / 10.0))
			var f_cap: int = clampi(int(round(f_raw / 2.0)) * 2, WorkshopData.FOUNDRY_BASE_CAPACITY, WorkshopData.FOUNDRY_MAX_CAPACITY)
			lbl.text = def["effect_fmt"] % f_cap
		"foundry_speed":
			lbl.text = def["effect_fmt"] % (current_lvl * 5)
		"foundry_parallel":
			## Base 1 + growing per-level bonus (+1,+2,+3...) = 1 + n(n+1)/2.
			lbl.text = def["effect_fmt"] % (1 + current_lvl * (current_lvl + 1) / 2)
		"money_gun":
			## Print rate = 1 * 2^level Benjamins/hour (matches server tuning).
			lbl.text = def["effect_fmt"] % (1 << clampi(current_lvl, 0, 10))
		"passive_xp":
			var p_lvl: int = clampi(current_lvl, 1, PlayerData.PASSIVE_XP_PER_HOUR.size())
			lbl.text = def["effect_fmt"] % PlayerData.format_number(PlayerData.PASSIVE_XP_PER_HOUR[p_lvl - 1])
		"horse_training_cap":
			var t_lvl: int = clampi(current_lvl, 1, PlayerData.HORSE_TRAINING_CAP_BY_LEVEL.size())
			lbl.text = def["effect_fmt"] % PlayerData.HORSE_TRAINING_CAP_BY_LEVEL[t_lvl - 1]
		"horse_stable_size":
			lbl.text = def["effect_fmt"] % current_lvl


## ── Cart Logic ─────────────────────────────────────────────────


func _on_add_to_cart(upgrade_id: String) -> void:
	var current_lvl: int = PlayerData.get_prestige_level(upgrade_id)
	var in_cart: int = _cart.get(upgrade_id, 0)
	var new_total_lvl: int = current_lvl + in_cart

	## One-time unlocks cap at level 1 (owned or a single pending purchase).
	var cap: int = 1 if _is_one_time(upgrade_id) else 10
	if new_total_lvl >= cap:
		return  ## Already at max (including pending)

	## Check if we can afford this addition (per-track cost curve).
	var cost_of_next: int = PlayerData.prestige_cost_for_level(upgrade_id, new_total_lvl)
	var total_cost := _get_cart_total_cost()
	if total_cost + cost_of_next > PlayerData.xp:
		return  ## Not enough XP

	_cart[upgrade_id] = in_cart + 1
	_refresh_cart_ui()
	_refresh_row(upgrade_id)


func _on_remove_from_cart(upgrade_id: String) -> void:
	var in_cart: int = _cart.get(upgrade_id, 0)
	if in_cart <= 0:
		return
	_cart[upgrade_id] = in_cart - 1
	if _cart[upgrade_id] == 0:
		_cart.erase(upgrade_id)
	_refresh_cart_ui()
	_refresh_row(upgrade_id)


func _get_cart_total_cost() -> int:
	var total := 0
	for id in _cart:
		var base_lvl: int = PlayerData.get_prestige_level(id)
		var qty: int = _cart[id]
		for i in range(qty):
			total += PlayerData.prestige_cost_for_level(id, base_lvl + i)
	return total


func _refresh_cart_ui() -> void:
	var total := _get_cart_total_cost()
	if _cart.is_empty() or total == 0:
		_cart_label.text = "Cart is empty"
		_checkout_btn.disabled = true
	else:
		var lines: Array = []
		for id in _cart:
			var qty: int = _cart[id]
			var def := _get_def(id)
			lines.append("%s ×%d" % [def["title"], qty])
		_cart_label.text = "Cart: %s\nTotal: %s XP" % [", ".join(lines), PlayerData.format_number(total)]
		_checkout_btn.disabled = total > PlayerData.xp
	_refresh_xp_label()


func _refresh_xp_label() -> void:
	if _xp_label == null:
		return
	var cart_cost := _get_cart_total_cost()
	var remaining := PlayerData.xp - cart_cost
	_xp_label.text = "Available XP: %s  (after cart: %s)" % [
		PlayerData.format_number(PlayerData.xp),
		PlayerData.format_number(maxi(0, remaining))
	]


func _refresh_row(upgrade_id: String) -> void:
	if _vbox == null:
		return
	var panel: PanelContainer = _vbox.get_node_or_null("Row_%s" % upgrade_id)
	if panel == null:
		return
	var qty_lbl: Label = panel.get_node_or_null("HBoxContainer/VBoxContainer2/QtyLabel") 
	## Walk to find by name since the path varies
	for child in panel.get_children():
		if child is HBoxContainer:
			for sub in child.get_children():
				if sub is VBoxContainer:
					var ql: Label = sub.get_node_or_null("QtyLabel")
					if ql:
						ql.text = str(_cart.get(upgrade_id, 0))
						return


## ── Checkout ───────────────────────────────────────────────────


func _on_checkout_pressed() -> void:
	## Show warning popup before completing purchase
	var dialog := ConfirmationDialog.new()
	dialog.title = "⚠️ Prestige Warning"
	dialog.dialog_text = "Prestiging resets your level in exchange for powerful permanent boosts.\n\nAre you sure you want to continue?"
	dialog.ok_button_text = "Confirm Purchase"
	dialog.cancel_button_text = "Cancel"
	dialog.min_size = Vector2(300, 0)
	add_child(dialog)
	dialog.confirmed.connect(_on_checkout_confirmed)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()


func _on_checkout_confirmed() -> void:
	var total_cost := _get_cart_total_cost()
	## Hard guard — never allow spending more than available
	if total_cost > PlayerData.xp or total_cost <= 0:
		return

	## The Money Gun level is SERVER-AUTHORITATIVE: apply those level-ups via RPC
	## FIRST (before charging XP), so a network failure can't take XP without
	## granting the level. If any gun upgrade fails, abort the whole checkout.
	var gun_qty: int = int(_cart.get("money_gun", 0))
	if gun_qty > 0:
		for i in range(gun_qty):
			var res: Dictionary = await MoneyGun.upgrade()
			if not res.get("ok", false):
				GameNotification.show_message("Upgrade Failed",
					str(res.get("message", "Could not upgrade the Money Gun.")))
				## Nothing charged yet — rebuild to reflect however many succeeded.
				_cart = {}
				for child in get_children():
					child.queue_free()
				_vbox = null
				_cart_label = null
				_checkout_btn = null
				_xp_label = null
				_build_ui()
				return
		## Mirror the authoritative server level locally for display/cost logic.
		PlayerData.prestige_levels["money_gun"] = PlayerData.money_gun_level

	## Bank passive XP earned at the OLD rate before levels change.
	PlayerData.accrue_passive_xp()

	## Deduct from xp (lifetime_xp is NOT touched!)
	PlayerData.xp = maxi(0, PlayerData.xp - total_cost)

	## Apply the remaining (local) prestige level-ups. The Money Gun was already
	## applied server-side above; skip it here.
	for id in _cart:
		if id == "money_gun":
			continue
		var qty: int = _cart[id]
		var base_lvl: int = PlayerData.get_prestige_level(id)
		for i in range(qty):
			PlayerData.prestige_levels[id] = base_lvl + i + 1

	## Recalculate level based on new xp value (levels player down based on remaining xp)
	PlayerData.recalculate_level()
	PlayerData.save_data()
	PlayerData.data_changed.emit()

	## Horse training cap + stable size are enforced by the server — push them.
	if _cart.has("horse_training_cap") or _cart.has("horse_stable_size"):
		PlayerData.sync_horse_prestige()

	_cart = {}

	## Rebuild UI to show new levels
	for child in get_children():
		child.queue_free()
	_vbox = null
	_cart_label = null
	_checkout_btn = null
	_xp_label = null
	_build_ui()


## ── Signal Handlers ────────────────────────────────────────────


func _on_data_changed() -> void:
	_refresh_cart_ui()


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


## ── Helpers ────────────────────────────────────────────────────


func _get_def(upgrade_id: String) -> Dictionary:
	for def in UPGRADE_DEFS:
		if def["id"] == upgrade_id:
			return def
	return {}


## Binary one-time unlocks (bought once, no levels). These show Owned/Locked
## instead of a "Lv.X / 10" counter.
const ONE_TIME_UPGRADES := ["mine_auto_collect"]

func _is_one_time(upgrade_id: String) -> bool:
	return upgrade_id in ONE_TIME_UPGRADES
