extends BaseScreen
## Active Bonuses screen — a read-only overview of every bonus the player has
## active right now, grouped by source (Prestige, Business District, Guild,
## Diamond Ring), with a combined per-effect total at the bottom.
##
## Everything is read live from the autoload getters so the numbers always match
## what the game actually applies. Multipliers combine MULTIPLICATIVELY at the
## real application sites (prestige × business × guild × ring), which is how the
## "Combined Totals" section computes each effect.

const TITLE_COLOR := Color(1.0, 0.9, 0.5)
const SOURCE_COLOR := Color(0.6, 0.85, 1.0)
const ROW_COLOR := Color(0.92, 0.92, 0.88)
const DIM_COLOR := Color(0.6, 0.6, 0.6)
const TOTAL_COLOR := Color(0.5, 1.0, 0.6)

var _content: VBoxContainer = null


func get_screen_name() -> String:
	return "active_bonuses"


func enter(_params: Dictionary = {}) -> void:
	_build_ui()


func exit() -> void:
	for child in get_children():
		child.queue_free()


# ── UI scaffold ──────────────────────────────────────────────────

func _build_ui() -> void:
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0.08, 0.08, 0.12, 0.92)
	bg_style.content_margin_left = 10; bg_style.content_margin_right = 10
	bg_style.content_margin_top = 8;  bg_style.content_margin_bottom = 8
	bg.add_theme_stylebox_override("panel", bg_style)
	add_child(bg)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	bg.add_child(outer)

	## Top row: back + title.
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(110, 42)
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(_on_back_pressed)
	top.add_child(back_btn)
	var title := Label.new()
	title.text = "Active Bonuses"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	top.add_child(title)
	## Spacer to keep the title centered opposite the back button.
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(110, 0)
	top.add_child(spacer)
	outer.add_child(top)

	## Scrollable body (swipe-to-scroll on touch via deadzone).
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.scroll_deadzone = 16
	outer.add_child(scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 6)
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.add_child(_content)

	_populate()


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


# ── Content ──────────────────────────────────────────────────────

func _populate() -> void:
	_add_recipe_boost_section()
	_add_prestige_section()
	_add_business_section()
	_add_guild_section()
	_add_other_section()
	_add_totals_section()


## A section header (source name).
func _add_source_header(text: String) -> void:
	var sep := HSeparator.new()
	_content.add_child(sep)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", SOURCE_COLOR)
	_content.add_child(lbl)


## A single bonus row: "Label …… value". `active` dims the row when neutral.
func _add_row(label: String, value: String, active: bool = true) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_PASS

	var name_lbl := Label.new()
	name_lbl.text = "  " + label
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", ROW_COLOR if active else DIM_COLOR)
	row.add_child(name_lbl)

	var val_lbl := Label.new()
	val_lbl.text = value
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.add_theme_font_size_override("font_size", 12)
	val_lbl.add_theme_color_override("font_color", (TOTAL_COLOR if active else DIM_COLOR))
	row.add_child(val_lbl)

	_content.add_child(row)


## A small italic note line.
func _add_note(text: String) -> void:
	var lbl := Label.new()
	lbl.text = "  " + text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", DIM_COLOR)
	_content.add_child(lbl)


## Formats a multiplier as a signed percentage, e.g. 1.25 -> "+25%", 0.75 -> "-25%".
func _pct(mult: float) -> String:
	var delta := int(round((mult - 1.0) * 100.0))
	if delta == 0:
		return "—"
	return "+%d%%" % delta if delta > 0 else "%d%%" % delta


# ── Prestige ─────────────────────────────────────────────────────

func _add_prestige_section() -> void:
	_add_source_header("✨ Prestige")
	var any := false

	## Each entry: [label, prestige level, value-string, is-active].
	var rows := [
		["💎 Gem Sell Value",    PlayerData.get_prestige_level("gem_profit"),    _pct(PlayerData.get_gem_profit_multiplier())],
		["🌾 Crop Sell Value",   PlayerData.get_prestige_level("garden_profit"), _pct(PlayerData.get_garden_profit_multiplier())],
		["🍎 Fruit Sell Value",  PlayerData.get_prestige_level("fruit_profit"),  _pct(PlayerData.get_fruit_profit_multiplier())],
		["🪵 Misc Goods Value",  PlayerData.get_prestige_level("misc_value"),    _pct(PlayerData.get_misc_profit_multiplier())],
		["📚 XP Gain",           PlayerData.get_prestige_level("xp_boost"),      _pct(PlayerData.get_xp_multiplier())],
		["🌱 Crop Grow Time",    PlayerData.get_prestige_level("crop_time"),     _pct(PlayerData.get_crop_time_multiplier())],
		["⏱️ Prospector Interval", PlayerData.get_prestige_level("prospector_time"), _pct(PlayerData.get_prospector_time_multiplier())],
		["💰 Prospector Cost",   PlayerData.get_prestige_level("prospector_cost"), _pct(PlayerData.get_prospector_cost_multiplier())],
	]
	for r in rows:
		var lvl: int = int(r[1])
		var active := lvl > 0
		if active:
			any = true
		_add_row("%s  (Lv.%d)" % [r[0], lvl], str(r[2]), active)

	## Flat (non-multiplier) prestige perks.
	var safe := PlayerData.get_safe_expedition_tiles()
	if safe > 0:
		any = true
		_add_row("⛏️ Expedition Safe Tiles  (Lv.%d)" % PlayerData.get_prestige_level("safe_tiles"), "+%d" % safe)
	var auto_rows := PlayerData.get_auto_plant_rows()
	if auto_rows > 0:
		any = true
		_add_row("🤖 Auto-Plant Rows  (Lv.%d)" % PlayerData.get_prestige_level("auto_plant"), "%d" % auto_rows)
	var xp_hr := PlayerData.get_passive_xp_per_hour()
	if PlayerData.get_passive_xp_percent() > 0:
		any = true
		_add_row("🕯️ Passive XP  (Lv.%d)" % PlayerData.get_prestige_level("passive_xp"),
			"%.1f%% (+%s/hr)" % [PlayerData.get_passive_xp_percent(), PlayerData.format_number(xp_hr)])
	if PlayerData.get_prestige_level("horse_training_cap") > 0:
		any = true
		_add_row("🏇 Training Cap  (Lv.%d)" % PlayerData.get_prestige_level("horse_training_cap"),
			"%d pts/session" % PlayerData.get_prestige_training_cap())
	if PlayerData.get_prestige_stable_bonus() > 0:
		any = true
		_add_row("🐴 Stable Slots  (Lv.%d)" % PlayerData.get_prestige_level("horse_stable_size"),
			"+%d" % PlayerData.get_prestige_stable_bonus())

	if not any:
		_add_note("No prestige upgrades yet. Spend XP in the Prestige screen.")


# ── Business District ────────────────────────────────────────────

func _add_business_section() -> void:
	_add_source_header("🏪 Business District")
	if get_node_or_null("/root/BusinessDistrict") == null:
		_add_note("Business District unavailable.")
		return

	var any := false

	## Sell / reward multipliers — show when the backing shop is active.
	## [shop_id, label, value-string]
	var mult_rows := [
		["flower",    "🌻 Flower Shop — Sunflower sell",   _pct(BusinessDistrict.crop_sell_multiplier("sunflower"))],
		["farmer",    "🥦 Farmer's Stand — Veg sell",      _pct(BusinessDistrict.crop_sell_multiplier("beans"))],
		["smoothie",  "🍹 Smoothie Shop — Fruit sell",     _pct(BusinessDistrict.fruit_sell_multiplier("apple"))],
		["lemonaid",  "🍋 Lemonaid Stand — Lemon sell",    _pct(BusinessDistrict.fruit_sell_multiplier("lemon"))],
		["bank",      "🏦 Bank of Pho — Coin rewards",     _pct(BusinessDistrict.coin_reward_multiplier())],
		["blackpearl","⚫ Black Pearl — Mine find rate",   _pct(BusinessDistrict.mine_find_multiplier())],
		["carl",      "🏗️ Carl's — Market restock",        _pct(BusinessDistrict.market_stock_multiplier())],
		["jewelers",  "💍 Jewelers — Saw speed",           _pct(BusinessDistrict.saw_speed_multiplier())],
		["carpenter", "🪚 Carpenter's — Orchard grow time", _pct(BusinessDistrict.orchard_growth_multiplier())],
		["miners",    "⛏️ Miners Source — Tool price",      _pct(BusinessDistrict.tool_price_multiplier(0))],
	]
	for r in mult_rows:
		var shop_id: String = str(r[0])
		var active := BusinessDistrict.is_bonus_active(shop_id)
		var lvl := BusinessDistrict.get_level(shop_id) if active else 0
		if active:
			any = true
		_add_row("%s  (Lv.%d)" % [r[1], lvl], str(r[2]), active)

	## Seed Shop — extra harvest units (additive integer, not a multiplier).
	if BusinessDistrict.is_bonus_active("seed"):
		var extra := BusinessDistrict.harvest_yield_bonus()
		if extra > 0:
			any = true
			_add_row("🌰 Seed Shop — Extra harvest  (Lv.%d)" % BusinessDistrict.get_level("seed"), "+%d/harvest" % extra)

	## Luck (Lucky's Lucky Loot) — informational, not a yield multiplier.
	if BusinessDistrict.is_bonus_active("lucky"):
		any = true
		_add_row("🍀 Lucky's Lucky Loot — Luck  (Lv.%d)" % BusinessDistrict.get_level("lucky"), "%d" % BusinessDistrict.current_luck())

	if not any:
		_add_note("No active shop bonuses. Assign shops to slots in the Business District.")


# ── Guild ────────────────────────────────────────────────────────

## Guild upgrade keys that translate to a player-facing +/-% perk, with their
## per-level step and whether the effect increases (+) or reduces (−).
const GUILD_PERK_ROWS := [
	["crop_sell_value", "🌿 Crop Sell Value",   5,  1],
	["gem_sell_value",  "💎 Gem Sell Value",    5,  1],
	["growth_time",     "⏱ Crop Growth Time",   5, -1],
	["foundry_time",    "🔥 Foundry Speed",      5, -1],
	["prospector_cost", "⛏ Prospector Cost",    5, -1],
	["mission_reward_boost", "⭐ Mission Rewards", 10, 1],
]

func _add_guild_section() -> void:
	_add_source_header("⚔️ Guild")
	if get_node_or_null("/root/GuildManager") == null or not GuildManager.is_in_guild():
		_add_note("Not in a guild. Join or create one to earn guild perks.")
		return

	## During the join probation window, perks are earned but not yet applied.
	if not GuildManager.perks_active():
		_add_note("⏳ Guild perks are on join cooldown — shown here but not applied yet.")

	var any := false
	for r in GUILD_PERK_ROWS:
		var key: String = str(r[0])
		var lvl: int = int(GuildManager.guild_upgrades.get(key, 0))
		if lvl <= 0:
			continue
		any = true
		var step: int = int(r[2])
		var sign: int = int(r[3])
		var pct := lvl * step * sign
		_add_row("%s  (Lv.%d)" % [r[1], lvl], ("+%d%%" % pct) if pct >= 0 else ("%d%%" % pct))

	if not any:
		_add_note("Your guild has no upgrade levels yet.")


# ── Other (Diamond Ring, etc.) ───────────────────────────────────

func _add_other_section() -> void:
	_add_source_header("💍 Equipped Jewelry")
	var any := false

	## List each equipped jewelry slot's bonus + level (count-scaled).
	if get_node_or_null("/root/JewelryBonus") != null:
		var equipped: Dictionary = PlayerData.equipped_jewelry()
		for slot in ["ring", "necklace", "misc"]:
			var jid := str(equipped[slot])
			if jid == "":
				continue
			var def := PlayerData.get_jewelry_def(jid)
			var bonus := str(def.get("bonus", ""))
			var lvl := JewelryBonus.level_for_count(PlayerData.get_jewelry_count(jid))
			if lvl <= 0:
				continue
			any = true
			var pct := JewelryBonus.pct_for_level(lvl)
			_add_row("💍 %s (Lv.%d)" % [str(def.get("name", jid)), lvl],
				"%s +%d%%" % [_bonus_label(bonus), int(round(pct))])

	if not any:
		_add_note("No jewelry equipped. Equip rings/necklaces in the Equipment screen.")


## Human label for a jewelry bonus id (for the active-bonuses display).
func _bonus_label(bonus_id: String) -> String:
	match bonus_id:
		"all_sell_value": return "All sell value"
		"coin_gain":      return "Coin gains"
		"xp_gain":        return "XP gain"
		"daily_bonus":    return "Daily bonus"
		"growth_speed":   return "Crop growth speed"
		"chest_luck":     return "Chest luck"
		"rarer_gems":     return "Rarer gem odds"
		"loving_messages":return "Loving messages"
	return bonus_id.capitalize()


# ── Combined totals per effect ───────────────────────────────────
## Each effect's total is the product of every live source that contributes to
## it, matching how the game actually stacks them at the application site.

func _add_totals_section() -> void:
	var sep := HSeparator.new()
	_content.add_child(sep)
	var hdr := Label.new()
	hdr.text = "📊 Combined Totals"
	hdr.add_theme_font_size_override("font_size", 16)
	hdr.add_theme_color_override("font_color", TITLE_COLOR)
	_content.add_child(hdr)
	_add_note("Each total is every active source multiplied together — what the game actually applies.")

	## Use the SAME guild perk getters the gameplay now applies, so these totals
	## match real payouts (and honor probation + linked-guild scaling).
	var has_guild := get_node_or_null("/root/GuildManager") != null
	var guild_crop := GuildManager.crop_sell_perk_mult() if has_guild else 1.0
	var guild_gem := GuildManager.gem_sell_perk_mult() if has_guild else 1.0
	var guild_growth := GuildManager.growth_time_perk_mult() if has_guild else 1.0

	var bd_crop_sun := _bd_mult_crop("sunflower")
	var bd_crop_veg := _bd_mult_crop("beans")

	## Crop sell value: prestige × business (per-crop) × guild. Business varies by
	## crop, so show the two representative buckets the shops cover.
	_add_total_row("🌾 Crop Sell (vegetables)",
		PlayerData.get_garden_profit_multiplier() * bd_crop_veg * guild_crop)
	_add_total_row("🌻 Crop Sell (sunflower)",
		PlayerData.get_garden_profit_multiplier() * bd_crop_sun * guild_crop)

	## Fruit sell value: prestige × business (smoothie/lemonaid).
	_add_total_row("🍎 Fruit Sell (apple)",
		PlayerData.get_fruit_profit_multiplier() * _bd_mult_fruit("apple"))
	_add_total_row("🍋 Fruit Sell (lemon)",
		PlayerData.get_fruit_profit_multiplier() * _bd_mult_fruit("lemon"))

	## Gem sell value: prestige × guild (polished x10 is item-state, shown as note).
	_add_total_row("💎 Gem Sell Value",
		PlayerData.get_gem_profit_multiplier() * guild_gem)

	## Misc goods (wood/sticks): prestige only.
	_add_total_row("🪵 Misc Goods Value", PlayerData.get_misc_profit_multiplier())

	## XP: prestige only.
	_add_total_row("📚 XP Gain", PlayerData.get_xp_multiplier())

	## Coin rewards: business (Bank) only.
	_add_total_row("💰 Coin Rewards", _bd_mult("coin_reward"))

	## Crop grow time: prestige × equipped-diamond growth × guild (lower=faster).
	var ring := JewelryBonus.growth_time_multiplier() if get_node_or_null("/root/JewelryBonus") else 1.0
	_add_total_row("🌱 Crop Grow Time",
		PlayerData.get_crop_time_multiplier() * ring * guild_growth, true)

	## Orchard grow time: business (Carpenter) × equipped-diamond growth.
	_add_total_row("🌳 Orchard Grow Time",
		BusinessDistrict.orchard_growth_multiplier() * ring if get_node_or_null("/root/BusinessDistrict") else ring,
		true)

	## Prospector interval: prestige.
	_add_total_row("⏱️ Prospector Interval", PlayerData.get_prospector_time_multiplier(), true)

	## Prospector hire cost: prestige × guild (lower is cheaper).
	var guild_prosp := GuildManager.prospector_cost_perk_mult() if has_guild else 1.0
	_add_total_row("💰 Prospector Cost",
		PlayerData.get_prospector_cost_multiplier() * guild_prosp, true)

	## Foundry smelt time: prestige (foundry_speed) × guild (lower is faster).
	var foundry_prestige := maxf(1.0 - PlayerData.get_prestige_level("foundry_speed") * 0.05, 0.5)
	var guild_foundry := GuildManager.foundry_time_perk_mult() if has_guild else 1.0
	_add_total_row("🔥 Foundry Smelt Time", foundry_prestige * guild_foundry, true)


## A combined-total row rendered a bit larger/brighter than a normal row.
## When `lower_is_better` the arrow/colour flips so a reduction reads as good.
func _add_total_row(label: String, mult: float, lower_is_better: bool = false) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var name_lbl := Label.new()
	name_lbl.text = "  " + label
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", ROW_COLOR)
	row.add_child(name_lbl)

	var val_lbl := Label.new()
	val_lbl.text = "%s  (×%.2f)" % [_pct(mult), mult]
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.add_theme_font_size_override("font_size", 13)
	## Neutral = dim; otherwise green when the change is beneficial.
	var delta := mult - 1.0
	var beneficial := (delta < 0.0) if lower_is_better else (delta > 0.0)
	var col := DIM_COLOR
	if absf(delta) > 0.0001:
		col = TOTAL_COLOR if beneficial else Color(1.0, 0.6, 0.4)
	val_lbl.add_theme_color_override("font_color", col)
	row.add_child(val_lbl)

	_content.add_child(row)


# ── Live-value helpers ───────────────────────────────────────────

func _bd_mult(effect: String) -> float:
	if get_node_or_null("/root/BusinessDistrict") == null:
		return 1.0
	match effect:
		"coin_reward": return BusinessDistrict.coin_reward_multiplier()
	return 1.0

func _bd_mult_crop(crop_id: String) -> float:
	if get_node_or_null("/root/BusinessDistrict") == null:
		return 1.0
	return BusinessDistrict.crop_sell_multiplier(crop_id)

func _bd_mult_fruit(fruit_id: String) -> float:
	if get_node_or_null("/root/BusinessDistrict") == null:
		return 1.0
	return BusinessDistrict.fruit_sell_multiplier(fruit_id)




# ── Recipe Boosts (temporary, from food recipes) ─────────────────
## Lists every currently-active recipe boost with its magnitude and remaining
## time (or uses for counted boosts). Reads PlayerData.active_boosts live.

## effect id -> short human label shown in the Active Bonuses list.
const RECIPE_BOOST_LABELS := {
	"double_crop_chance": "🌿 Green Thumb — double-harvest chance",
	"fast_sprout":        "🌱 Fast Sprout — faster new-crop growth",
	"bountiful_yield":    "🧺 Bountiful Yield — +1 crop per tile",
	"miner_stamina":      "⛏️ Miner's Stamina — prevents mining fails",
	"deep_prospector":    "💎 Deep Prospector — better rare finds",
	"precision_cutting":  "🪚 Precision Cutting — faster gem saw",
	"furnace_fuel":       "🔥 Furnace Fuel — faster foundry smelting",
	"equestrian_spark":   "🐎 Equestrian Spark — bonus training gains",
	"grooming_bliss":     "🧖 Grooming Bliss — extra grooming recovery",
	"jockeys_luck":       "🍀 Jockey's Luck — race prize / speed edge",
	"eagle_eye":          "🦅 Eagle Eye — better panning gem drops",
	"traders_tongue":     "🗣️ Trader's Tongue — double mission rewards",
	"pho_focus":          "🀄 Pho Focus — +1 to non-pawn tiles placed",
}


func _add_recipe_boost_section() -> void:
	_add_source_header("🍜 Recipe Boosts")

	## Walk the recipe defs so order is stable and labels/values stay accurate.
	var any := false
	for rid in PlayerData.recipe_ids():
		var def := PlayerData.get_recipe_def(rid)
		var boost: Dictionary = def.get("boost", {})
		var effect := str(boost.get("effect", ""))
		if effect == "" or not PlayerData.boost_active(effect):
			continue
		any = true
		var label := str(RECIPE_BOOST_LABELS.get(effect, effect.capitalize()))
		_add_row(label, _recipe_boost_value_text(boost))

	if not any:
		_add_note("No recipe boosts active. Use a food recipe from the Marketplace Food tab or your Inventory.")


## Builds the right-hand value text for an active recipe boost: the magnitude
## plus remaining time (timed) or uses (counted).
func _recipe_boost_value_text(boost: Dictionary) -> String:
	var effect := str(boost.get("effect", ""))
	var value := float(boost.get("value", 0.0))

	## Magnitude: percent for fractional boosts, flat "+N" for integer ones.
	var mag: String
	if value > 0.0 and value < 1.0:
		mag = "+%d%%" % int(round(value * 100.0))
	elif effect == "bountiful_yield" or effect == "pho_focus":
		mag = "+%d" % int(round(value))
	elif value >= 1.0:
		mag = "+%d%%" % int(round(value * 100.0))
	else:
		mag = ""

	## Remaining time or uses.
	var rem: String
	if boost.has("uses"):
		var left := 0
		if PlayerData.active_boosts.has(effect):
			left = int(PlayerData.active_boosts[effect].get("remaining", 0))
		rem = "%d use%s" % [left, "s" if left != 1 else ""]
	else:
		var secs := PlayerData.boost_seconds_remaining(effect)
		rem = "%d:%02d" % [secs / 60, secs % 60]

	if mag == "":
		return rem
	return "%s  (%s)" % [mag, rem]
