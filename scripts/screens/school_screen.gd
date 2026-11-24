extends BaseScreen
## School screen — displays a tutorial button and a coming-soon message.
## Navigates to the tutorial screen or back to the previous screen.
##
## Requirements: 1.2, 1.3, 1.5, 1.6


@onready var back_btn: Button = $VBox/TopBar/BackBtn
@onready var tutorial_btn: Button = $VBox/TutorialBtn
@onready var replay_tutorial_btn: Button = $VBox/ReplayTutorialBtn
@onready var mining_btn: Button = $VBox/MiningBtn
@onready var garden_btn: Button = $VBox/GardenBtn
@onready var coming_soon: Label = $VBox/ComingSoon

## Built dynamically in _ready() (keeps the scene untouched).
var recipes_btn: Button = null
var wonder_btn: Button = null


func _ready() -> void:
	tutorial_btn.pressed.connect(_on_tutorial_pressed)
	replay_tutorial_btn.pressed.connect(_on_replay_tutorial_pressed)
	mining_btn.pressed.connect(_on_mining_guide_pressed)
	garden_btn.pressed.connect(_on_garden_guide_pressed)
	back_btn.pressed.connect(_on_back_pressed)
	_build_extra_guide_buttons()


## Adds the "Recipes" and "WonderStones & WonderVessels" guide buttons, styled
## like the existing guide buttons and placed just after the Garden button.
func _build_extra_guide_buttons() -> void:
	var vbox: VBoxContainer = $VBox

	recipes_btn = Button.new()
	recipes_btn.name = "RecipesBtn"
	recipes_btn.text = "🍜 Recipes"
	recipes_btn.add_theme_font_size_override("font_size", 14)
	recipes_btn.custom_minimum_size.y = 44
	recipes_btn.pressed.connect(_on_recipes_guide_pressed)
	vbox.add_child(recipes_btn)
	vbox.move_child(recipes_btn, garden_btn.get_index() + 1)

	wonder_btn = Button.new()
	wonder_btn.name = "WonderBtn"
	wonder_btn.text = "💎 WonderStones & WonderVessels"
	wonder_btn.add_theme_font_size_override("font_size", 14)
	wonder_btn.custom_minimum_size.y = 44
	wonder_btn.pressed.connect(_on_wonder_guide_pressed)
	vbox.add_child(wonder_btn)
	vbox.move_child(wonder_btn, recipes_btn.get_index() + 1)


func get_screen_name() -> String:
	return "school"


func _on_tutorial_pressed() -> void:
	Achievements.record_tutorial_read()
	_get_navigator().navigate_to("tutorial")
	
func _on_replay_tutorial_pressed() -> void:
	Achievements.record_tutorial_read()
	var ts := get_node_or_null("/root/TutorialSystem")
	if ts != null and ts.has_method("replay_tutorial"):
		ts.call_deferred("replay_tutorial")
	else:
		_get_navigator().navigate_to("tutorial")


func _on_mining_guide_pressed() -> void:
	Achievements.record_tutorial_read()
	_show_mining_guide()


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


func _show_mining_guide() -> void:
	# Build a scrollable mining guide in place of the buttons
	var vbox: VBoxContainer = $VBox

	# Hide school content
	_set_school_buttons_visible(false)

	# Build guide content
	var scroll := ScrollContainer.new()
	scroll.name = "MiningGuide"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	# Dark panel background for readability
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.08, 0.08, 0.12, 0.9)
	panel_style.corner_radius_top_left = 6
	panel_style.corner_radius_top_right = 6
	panel_style.corner_radius_bottom_left = 6
	panel_style.corner_radius_bottom_right = 6
	panel_style.content_margin_left = 12
	panel_style.content_margin_right = 12
	panel_style.content_margin_top = 10
	panel_style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", panel_style)
	scroll.add_child(panel)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	panel.add_child(content)

	# Title
	var title := Label.new()
	title.text = "⛏ Mining Guide"
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.modulate = Color(1.0, 0.85, 0.3)
	content.add_child(title)

	# Rules
	var rules_title := Label.new()
	rules_title.text = "── Rules ──"
	rules_title.add_theme_font_size_override("font_size", 13)
	rules_title.modulate = Color(1.0, 0.85, 0.3)
	content.add_child(rules_title)

	var rules := Label.new()
	rules.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rules.add_theme_font_size_override("font_size", 11)
	rules.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	rules.text = """Mining works like minesweeper:
• Tap a tile to dig (reveal what's underneath)
• Numbers show how many treasures are adjacent (1-8 directions)
• Use Flag Mode to mark tiles you think are treasures
• Flag ALL treasures without digging one to win!
• Digging a treasure = you lose (fined by Town Council)

Small Mine: 8×8 grid, 10 treasures (100c entry)
Large Mine: 16×16 grid, 40 treasures (300c entry)"""
	content.add_child(rules)

	content.add_child(HSeparator.new())

	# Tips
	var tips_title := Label.new()
	tips_title.text = "── Tips ──"
	tips_title.add_theme_font_size_override("font_size", 13)
	tips_title.modulate = Color(0.7, 0.9, 0.7)
	content.add_child(tips_title)

	var tips := Label.new()
	tips.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tips.add_theme_font_size_override("font_size", 11)
	tips.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	tips.text = """• Start by tapping corners or edges — less neighbors = easier to deduce
• If a "1" has only one hidden neighbor, that neighbor is a treasure — flag it!
• If a revealed number already has enough flags around it, tap it to chord (reveal remaining safe neighbors)
• Use the Magnifying Glass tool to safely reveal a 3×3 area and auto-flag mines in it
• Large mines pay off big but are harder — practice on small mines first
• Win streaks earn bonus XP!"""
	content.add_child(tips)

	content.add_child(HSeparator.new())

	# Rewards
	var rewards_title := Label.new()
	rewards_title.text = "── Rewards ──"
	rewards_title.add_theme_font_size_override("font_size", 13)
	rewards_title.modulate = Color(0.7, 0.8, 1.0)
	content.add_child(rewards_title)

	var rewards := Label.new()
	rewards.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rewards.add_theme_font_size_override("font_size", 11)
	rewards.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	rewards.text = """Each flagged treasure gives a random reward:
• 40% chance: a random Pho tile for your inventory
• 40% chance: 50 coins
• 20% chance: 1-3 garden seeds

If your inventory is full, extra tiles are sold at full price automatically."""
	content.add_child(rewards)

	# Close button
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_font_size_override("font_size", 13)
	close_btn.custom_minimum_size.y = 36
	close_btn.pressed.connect(_close_mining_guide)
	content.add_child(close_btn)

	vbox.add_child(scroll)


func _close_mining_guide() -> void:
	var vbox: VBoxContainer = $VBox
	var guide = vbox.get_node_or_null("MiningGuide")
	if guide:
		guide.queue_free()
	_set_school_buttons_visible(true)


## Shows/hides every school menu button + the coming-soon label together, so
## opening/closing any guide toggles them all consistently.
func _set_school_buttons_visible(v: bool) -> void:
	tutorial_btn.visible = v
	replay_tutorial_btn.visible = v
	mining_btn.visible = v
	garden_btn.visible = v
	if recipes_btn != null and is_instance_valid(recipes_btn):
		recipes_btn.visible = v
	if wonder_btn != null and is_instance_valid(wonder_btn):
		wonder_btn.visible = v
	coming_soon.visible = v


func _on_garden_guide_pressed() -> void:
	_show_garden_guide()


func _show_garden_guide() -> void:
	var vbox: VBoxContainer = $VBox

	# Hide school content
	_set_school_buttons_visible(false)

	var scroll := ScrollContainer.new()
	scroll.name = "GardenGuide"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	# Dark panel background for readability
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.08, 0.08, 0.12, 0.9)
	panel_style.corner_radius_top_left = 6
	panel_style.corner_radius_top_right = 6
	panel_style.corner_radius_bottom_left = 6
	panel_style.corner_radius_bottom_right = 6
	panel_style.content_margin_left = 12
	panel_style.content_margin_right = 12
	panel_style.content_margin_top = 10
	panel_style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", panel_style)
	scroll.add_child(panel)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	panel.add_child(content)

	# Title
	var title := Label.new()
	title.text = "🌱 Gardening Guide"
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.modulate = Color(0.5, 1.0, 0.5)
	content.add_child(title)

	# Basics
	var basics_title := Label.new()
	basics_title.text = "── Basics ──"
	basics_title.add_theme_font_size_override("font_size", 13)
	basics_title.modulate = Color(0.5, 1.0, 0.5)
	content.add_child(basics_title)

	var basics := Label.new()
	basics.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	basics.add_theme_font_size_override("font_size", 11)
	basics.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	basics.text = """• Select a seed from your seed bar at the top
• Tap an empty garden tile to plant it
• Crops grow in real time (even when the app is closed!)
• Tap a fully-grown crop to harvest it for coins
• Hold a growing crop to see time remaining

Starting garden: 1 row × 5 columns
Max garden: 16 rows × 16 columns"""
	content.add_child(basics)

	content.add_child(HSeparator.new())

	# Expanding
	var expand_title := Label.new()
	expand_title.text = "── Expanding ──"
	expand_title.add_theme_font_size_override("font_size", 13)
	expand_title.modulate = Color(1.0, 0.85, 0.3)
	content.add_child(expand_title)

	var expand := Label.new()
	expand.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	expand.add_theme_font_size_override("font_size", 11)
	expand.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	expand.text = """• Use +Row and +Column buttons at the bottom of the garden
• Each purchase costs more than the last (25% scaling)
• First row costs 150c, first column costs 100c
• More space = more crops growing simultaneously = more profit!"""
	content.add_child(expand)

	content.add_child(HSeparator.new())

	# Seeds & Crops
	var crops_title := Label.new()
	crops_title.text = "── Seeds & Crops ──"
	crops_title.add_theme_font_size_override("font_size", 13)
	crops_title.modulate = Color(0.7, 0.8, 1.0)
	content.add_child(crops_title)

	var crops := Label.new()
	crops.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	crops.add_theme_font_size_override("font_size", 11)
	crops.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	crops.text = """• Buy seeds at the Marketplace (Seeds tab)
• Cheaper seeds grow faster but yield less
• Expensive seeds take longer but pay more per harvest
• Seed storage is separate from tile inventory (50 max, upgradeable)

Crop list (cost → time → reward):
  Beans: 1c → 5min → 15c
  Cucumbers: 3c → 10min → 36c
  Peppers: 5c → 20min → 60c
  Squash: 7c → 40min → 105c
  Grapes: 9c → 80min → 150c
  Sunflower: 12c → 2hr → 195c
  Cauliflower: 15c → 3hr → 225c
  Pineapple: 18c → 4.5hr → 264c
  Watermelon: 20c → 6hr → 300c"""
	content.add_child(crops)

	content.add_child(HSeparator.new())

	# Tools
	var tools_title := Label.new()
	tools_title.text = "── Garden Tools ──"
	tools_title.add_theme_font_size_override("font_size", 13)
	tools_title.modulate = Color(0.9, 0.7, 1.0)
	content.add_child(tools_title)

	var tools := Label.new()
	tools.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tools.add_theme_font_size_override("font_size", 11)
	tools.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	tools.text = """• Scythe (1500c, 3 uses): harvest a 3×3 area at once
• Tractor (5000c, permanent): harvest an entire row at once
• Shovel (10c each, consumable): remove a planted crop
• Combine Scythe + Tractor: harvest 3 full rows at once!

Toggle tools on/off using the buttons above the garden grid."""
	content.add_child(tools)

	# Close button
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_font_size_override("font_size", 13)
	close_btn.custom_minimum_size.y = 36
	close_btn.pressed.connect(_close_garden_guide)
	content.add_child(close_btn)

	vbox.add_child(scroll)


func _close_garden_guide() -> void:
	var vbox: VBoxContainer = $VBox
	var guide = vbox.get_node_or_null("GardenGuide")
	if guide:
		guide.queue_free()
	_set_school_buttons_visible(true)


## ── Shared guide-panel scaffolding ──────────────────────────────
## Builds the dark scroll panel used by every guide and returns its inner
## content VBox (caller adds rows + a Close button). `node_name` lets each guide
## find/free its own scroll on close.
func _make_guide_panel(node_name: String) -> VBoxContainer:
	var vbox: VBoxContainer = $VBox
	var scroll := ScrollContainer.new()
	scroll.name = node_name
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.08, 0.08, 0.12, 0.9)
	panel_style.corner_radius_top_left = 6
	panel_style.corner_radius_top_right = 6
	panel_style.corner_radius_bottom_left = 6
	panel_style.corner_radius_bottom_right = 6
	panel_style.content_margin_left = 12
	panel_style.content_margin_right = 12
	panel_style.content_margin_top = 10
	panel_style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", panel_style)
	scroll.add_child(panel)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	panel.add_child(content)

	vbox.add_child(scroll)
	return content


## Adds a centered colored title label to a guide content box.
func _guide_title(content: Control, text: String, color: Color) -> void:
	var title := Label.new()
	title.text = text
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.modulate = color
	content.add_child(title)


## Adds a "── Header ──" sub-header label.
func _guide_header(content: Control, text: String, color: Color) -> void:
	var h := Label.new()
	h.text = "── %s ──" % text
	h.add_theme_font_size_override("font_size", 13)
	h.modulate = color
	content.add_child(h)


## Adds a wrapped body paragraph label.
func _guide_body(content: Control, text: String) -> void:
	var b := Label.new()
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_theme_font_size_override("font_size", 11)
	b.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	b.text = text
	content.add_child(b)


## Adds a Close button wired to `on_close`.
func _guide_close_btn(content: Control, on_close: Callable) -> void:
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_font_size_override("font_size", 13)
	close_btn.custom_minimum_size.y = 36
	close_btn.pressed.connect(on_close)
	content.add_child(close_btn)


## ── Recipes guide ───────────────────────────────────────────────
func _on_recipes_guide_pressed() -> void:
	Achievements.record_tutorial_read()
	_set_school_buttons_visible(false)
	var content := _make_guide_panel("RecipesGuide")

	_guide_title(content, "🍜 Recipes", Color(1.0, 0.6, 0.3))
	_guide_header(content, "How Recipes Work", Color(1.0, 0.6, 0.3))
	_guide_body(content, """Recipes are special food items crafted ONLY by Gardening guilds. Each one grants a temporary BOOST when used.
• Crafting requires 10 of each listed ingredient.
• Buy finished recipes from a guild storefront, then use them from the Marketplace → Food tab (or your Inventory).
• Timed boosts last for a set duration; "next N" boosts apply to your next few races / Pho games.
• Using more than one of the same recipe stacks the duration (or adds uses).""")
	content.add_child(HSeparator.new())

	_guide_header(content, "Recipe List", Color(0.5, 1.0, 0.5))
	## Data-driven from the real recipe defs so this stays accurate.
	for rid in PlayerData.recipe_ids():
		var def := PlayerData.get_recipe_def(rid)
		if def.is_empty():
			continue
		var name_lbl := Label.new()
		name_lbl.text = "• %s" % str(def.get("name", rid))
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
		content.add_child(name_lbl)
		var desc := Label.new()
		desc.text = "   %s" % str(def.get("description", ""))
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.add_theme_font_size_override("font_size", 10)
		desc.add_theme_color_override("font_color", Color(0.85, 0.85, 0.8))
		content.add_child(desc)
		## Ingredients line.
		var recipe_in: Dictionary = def.get("recipe", {})
		var parts: Array = []
		for key in recipe_in:
			parts.append("%d× %s" % [int(recipe_in[key]), ItemKeyRegistry.display_name(key)])
		if not parts.is_empty():
			var ing := Label.new()
			ing.text = "   Ingredients: %s" % ", ".join(parts)
			ing.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			ing.add_theme_font_size_override("font_size", 10)
			ing.add_theme_color_override("font_color", Color(0.7, 0.8, 0.95))
			content.add_child(ing)

	_guide_close_btn(content, _close_recipes_guide)


func _close_recipes_guide() -> void:
	var guide = ($VBox as VBoxContainer).get_node_or_null("RecipesGuide")
	if guide:
		guide.queue_free()
	_set_school_buttons_visible(true)


## ── WonderStones & WonderVessels guide ──────────────────────────
func _on_wonder_guide_pressed() -> void:
	Achievements.record_tutorial_read()
	_set_school_buttons_visible(false)
	var content := _make_guide_panel("WonderGuide")

	_guide_title(content, "💎 WonderStones & WonderVessels", Color(0.7, 0.95, 1.0))

	_guide_header(content, "WonderStone", Color(0.7, 0.95, 1.0))
	_guide_body(content, """A rare material used to craft WonderVessels. Valued at %s coins (or %s tokens).
Where to find them:
• Level 10 chests: 50%% chance to hold 1–20.
• Harvesting watermelon: ~1 in 250 per crop (harvest boosts give more rolls, so you can pull several at once).
• Deep Mine level 10: ~1 in 250 per dig. Level 11: ~1 in 100 per dig.""" % [
		PlayerData.format_number(PlayerData.WONDERSTONE_COIN_VALUE),
		PlayerData.format_number(PlayerData.WONDERSTONE_TOKEN_VALUE)])
	content.add_child(HSeparator.new())

	_guide_header(content, "WonderVessels", Color(1.0, 0.85, 0.3))
	_guide_body(content, """Single-use duplicators crafted locally in your Inventory (near the WonderStone row). Crafting one costs coins + WonderStones + a quantity of EVERY raw resource (gems, crops, fruit, wood, ore, etc.) plus one of each refined bar/ingot — the amount scales with the tier.
To use one: pick items to load (any item except the Tractor, Excavator, and Benjamin Gun). You keep your originals and receive the extra copies.
Higher tiers let you duplicate more item TYPES at once, allow larger input stacks, and multiply harder (add → double → triple → quintuple).""")
	content.add_child(HSeparator.new())

	_guide_header(content, "Tier Table", Color(0.5, 1.0, 0.5))
	for tier in range(1, PlayerData.WONDERVESSEL_DEFS.size() + 1):
		var def := PlayerData.get_vessel_def(tier)
		if def.is_empty():
			continue
		var types := int(def["types"])
		var cap := int(def["cap"])
		var mode := str(def["mode"])
		var n := int(def["n"])
		var effect_txt: String
		if mode == "mult":
			effect_txt = "output ×%d" % (n + 1)
		else:
			effect_txt = "+%d per item" % n
		var row := Label.new()
		row.text = "• Tier %d: up to %d type%s, %s each, %s" % [
			tier, types, "s" if types > 1 else "",
			PlayerData.format_number(cap), effect_txt]
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_theme_font_size_override("font_size", 11)
		row.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
		content.add_child(row)

	_guide_close_btn(content, _close_wonder_guide)


func _close_wonder_guide() -> void:
	var guide = ($VBox as VBoxContainer).get_node_or_null("WonderGuide")
	if guide:
		guide.queue_free()
	_set_school_buttons_visible(true)
