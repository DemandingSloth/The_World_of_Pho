extends BaseScreen
## Mining screen — minesweeper-style expeditions where players spend coins to find
## treasures (pieces, coins, seeds). Instantiates MiningGame for active gameplay.
##
## Requirements: 1.2, 1.3, 1.5, 1.6, 9.1, 9.4


@onready var scroll_container: ScrollContainer = $ScrollContainer
@onready var content_vbox: VBoxContainer = $ScrollContainer/ContentVBox
@onready var status_label: Label = $ScrollContainer/ContentVBox/StatusLabel
@onready var small_mine_btn: Button = $ScrollContainer/ContentVBox/SmallMineBtn
@onready var large_mine_btn: Button = $ScrollContainer/ContentVBox/LargeMineBtn
@onready var gold_panning_btn: Button = $ScrollContainer/ContentVBox/GoldPanningBtn
@onready var prospectors_btn: Button = $ScrollContainer/ContentVBox/ProspectorsBtn
@onready var game_container: VBoxContainer = $ScrollContainer/ContentVBox/GameContainer
@onready var results_label: Label = $ScrollContainer/ContentVBox/ResultsLabel
@onready var rewards_container: HBoxContainer = $ScrollContainer/ContentVBox/RewardsContainer
@onready var back_btn: Button = $ScrollContainer/ContentVBox/BackBtn

var _mining_game: MiningGame = null
var _magnify_btn: Button = null
var _magnify_count_label: Label = null
var _flag_btn: Button = null
var _flag_mode: bool = false


func enter(params: Dictionary = {}) -> void:
	# Connect buttons
	small_mine_btn.pressed.connect(_on_small_mine_pressed)
	large_mine_btn.pressed.connect(_on_large_mine_pressed)
	gold_panning_btn.pressed.connect(_on_gold_panning_pressed)
	prospectors_btn.pressed.connect(_on_prospectors_pressed)
	back_btn.pressed.connect(_on_back_pressed)

	# Reset UI state
	_refresh_status()
	var lvl: int = PlayerData.level
	small_mine_btn.visible = true
	large_mine_btn.visible = true
	gold_panning_btn.visible = true
	prospectors_btn.visible = true

	# Level locks
	small_mine_btn.disabled = PlayerData.coins < 100 or lvl < 2
	small_mine_btn.text = "Small Expedition (100c)" if lvl >= 2 else "🔒 Small Expedition — Lv.2"
	large_mine_btn.disabled = PlayerData.coins < 300 or lvl < 5
	large_mine_btn.text = "Large Expedition (300c)" if lvl >= 5 else "🔒 Large Expedition — Lv.5"
	gold_panning_btn.disabled = lvl < 3
	gold_panning_btn.text = "Gold Panning" if lvl >= 3 else "🔒 Gold Panning — Lv.3"
	prospectors_btn.disabled = lvl < 10
	prospectors_btn.text = "Prospectors" if lvl >= 10 else "🔒 Prospectors — Lv.10"
	_set_deep_mine_btn_visible(true)

	# Deep Mine entry — built dynamically to avoid editing the scene. Lv.20 gate.
	_build_deep_mine_button(lvl)

	results_label.visible = false
	rewards_container.visible = false


func exit() -> void:
	# Clean up MiningGame instance and all dynamic tool nodes (Req 1.6)
	_cleanup_game()


func get_screen_name() -> String:
	return "mining"


## ── Private: Button handlers ─────────────────────────────────────


func _on_small_mine_pressed() -> void:
	if PlayerData.coins < 100:
		status_label.text = "Not enough coins! Need 100c."
		return
	PlayerData.coins -= 100
	PlayerData.save_data()
	_start_mining_expedition(8, 8, 10)


func _on_large_mine_pressed() -> void:
	if PlayerData.coins < 300:
		status_label.text = "Not enough coins! Need 300c."
		return
	PlayerData.coins -= 300
	PlayerData.save_data()
	_start_mining_expedition(16, 16, 40)


func _on_gold_panning_pressed() -> void:
	_get_navigator().navigate_to("gold_panning")


func _on_prospectors_pressed() -> void:
	_get_navigator().navigate_to("prospectors")


## Builds the Deep Mine entry button below Prospectors, gated at Lv.20.
func _build_deep_mine_button(lvl: int) -> void:
	## Remove any prior instance (defensive — enter() normally runs on a fresh scene).
	var old := content_vbox.get_node_or_null("DeepMineBtn")
	if old != null:
		old.queue_free()

	var btn := Button.new()
	btn.name = "DeepMineBtn"
	## Match the sizing of the existing scene buttons (Gold Panning, etc.).
	btn.size_flags_horizontal = prospectors_btn.size_flags_horizontal
	btn.size_flags_vertical = prospectors_btn.size_flags_vertical
	btn.custom_minimum_size = prospectors_btn.custom_minimum_size
	if prospectors_btn.theme_type_variation != &"":
		btn.theme_type_variation = prospectors_btn.theme_type_variation
	var fs := prospectors_btn.get_theme_font_size("font_size")
	if fs > 0:
		btn.add_theme_font_size_override("font_size", fs)
	btn.disabled = lvl < DeepMineData.UNLOCK_LEVEL
	btn.text = "⛏ Deep Mine" if lvl >= DeepMineData.UNLOCK_LEVEL else "🔒 Deep Mine — Lv.%d" % DeepMineData.UNLOCK_LEVEL
	btn.pressed.connect(_on_deep_mine_pressed)
	content_vbox.add_child(btn)
	## Place it right after the Prospectors button.
	content_vbox.move_child(btn, prospectors_btn.get_index() + 1)


func _on_deep_mine_pressed() -> void:
	_get_navigator().navigate_to("deep_mine")


func _set_deep_mine_btn_visible(v: bool) -> void:
	var btn := content_vbox.get_node_or_null("DeepMineBtn")
	if btn != null:
		btn.visible = v


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


## ── Private: Mining expedition logic ─────────────────────────────


func _start_mining_expedition(w: int, h: int, mines: int) -> void:
	# Remove existing game if any
	_cleanup_game()

	# Hide expedition buttons during game
	small_mine_btn.visible = false
	large_mine_btn.visible = false
	gold_panning_btn.visible = false
	prospectors_btn.visible = false
	_set_deep_mine_btn_visible(false)
	results_label.visible = false
	rewards_container.visible = false
	status_label.text = "Tap: dig. Flag mode: mark treasure."

	# Show flag mode toggle button for mobile
	_build_flag_button()

	# Show magnify button if player owns any
	var magnify_count := PlayerData.get_tool_count(PlayerData.ToolType.MAGNIFYING_GLASS)
	_build_magnify_button(magnify_count)

	# Create and start the game
	_mining_game = MiningGame.new()
	game_container.add_child(_mining_game)
	_mining_game.game_won.connect(_on_mining_won)
	_mining_game.game_lost.connect(_on_mining_lost)
	_mining_game.magnify_mode_changed.connect(_on_magnify_mode_changed)
	_mining_game.start_game(w, h, mines)


func _build_flag_button() -> void:
	# Remove old flag button if exists
	if _flag_btn != null and is_instance_valid(_flag_btn):
		_flag_btn.queue_free()
		_flag_btn = null

	_flag_mode = false
	_flag_btn = Button.new()
	_flag_btn.text = "⚑ Flag Mode: OFF"
	_flag_btn.add_theme_font_size_override("font_size", 12)
	_flag_btn.custom_minimum_size = Vector2(180, 36)
	_flag_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_flag_btn.pressed.connect(_on_flag_mode_toggled)

	# Insert before game_container
	var insert_idx := game_container.get_index()
	content_vbox.add_child(_flag_btn)
	content_vbox.move_child(_flag_btn, insert_idx)


func _on_flag_mode_toggled() -> void:
	_flag_mode = not _flag_mode
	if _flag_btn != null and is_instance_valid(_flag_btn):
		if _flag_mode:
			_flag_btn.text = "⚑ Flag Mode: ON"
			_flag_btn.modulate = Color(1.0, 0.6, 0.3)
			status_label.text = "FLAG MODE — tap a tile to mark/unmark treasure."
		else:
			_flag_btn.text = "⚑ Flag Mode: OFF"
			_flag_btn.modulate = Color.WHITE
			status_label.text = "DIG MODE — tap a tile to dig."

	# Tell the MiningGame about flag mode
	if _mining_game != null and is_instance_valid(_mining_game):
		_mining_game.touch_flag_mode = _flag_mode


func _build_magnify_button(magnify_count: int) -> void:
	# Remove old magnify row (the HBoxContainer wrapping the button) if it exists
	var old_row := content_vbox.get_node_or_null("MagnifyRow")
	if old_row != null:
		old_row.queue_free()
	_magnify_btn = null
	_magnify_count_label = null

	# Wrap button + count label in a row
	var row := HBoxContainer.new()
	row.name = "MagnifyRow"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)

	_magnify_btn = Button.new()
	_magnify_btn.custom_minimum_size = Vector2(48, 48)
	_magnify_btn.visible = true
	_magnify_btn.disabled = magnify_count <= 0
	_magnify_btn.tooltip_text = "Magnifying Glass (%d left) — reveals 3×3 safe area" % magnify_count
	_magnify_btn.pressed.connect(_on_mining_use_magnify)

	var mag_tex: Texture2D = load("res://Assets/magnify_glass.png")
	if mag_tex:
		var mag_sprite := TextureRect.new()
		mag_sprite.texture = mag_tex
		mag_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		mag_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		mag_sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
		mag_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_magnify_btn.add_child(mag_sprite)
	else:
		_magnify_btn.text = "🔍"

	row.add_child(_magnify_btn)

	_magnify_count_label = Label.new()
	_magnify_count_label.name = "MagnifyCount"
	_magnify_count_label.add_theme_font_size_override("font_size", 13)
	_magnify_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_refresh_magnify_count_label(magnify_count)
	row.add_child(_magnify_count_label)

	# Hide entire row when count is 0 (no tools owned at all)
	row.visible = magnify_count > 0

	# Insert after game_container
	var insert_idx := game_container.get_index() + 1
	content_vbox.add_child(row)
	content_vbox.move_child(row, insert_idx)


func _refresh_magnify_count_label(count: int) -> void:
	if _magnify_count_label == null:
		return
	_magnify_count_label.text = "×%d" % count
	if count > 0:
		_magnify_count_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.6))
	else:
		_magnify_count_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))


func _on_mining_use_magnify() -> void:
	if _mining_game == null or not _mining_game.is_game_active():
		return
	if not PlayerData.consume_tool(PlayerData.ToolType.MAGNIFYING_GLASS):
		return
	_mining_game._magnify_mode = true
	var remaining := PlayerData.get_tool_count(PlayerData.ToolType.MAGNIFYING_GLASS)
	_magnify_btn.tooltip_text = "Magnifying Glass (%d left) — click a tile to reveal 3×3 area" % remaining
	_refresh_magnify_count_label(remaining)
	status_label.text = "Magnify active! Click a tile to reveal the 3×3 area around it."
	if remaining <= 0:
		_magnify_btn.disabled = true


func _on_magnify_mode_changed(is_active: bool) -> void:
	if _magnify_btn == null or not is_instance_valid(_magnify_btn):
		return
		
	if is_active:
		_magnify_btn.disabled = true
		_magnify_btn.modulate = Color(0.5, 0.8, 1.0)
		status_label.text = "🔍 Magnify active! Tap a tile to reveal the 3×3 area around it."
	else:
		var remaining := PlayerData.get_tool_count(PlayerData.ToolType.MAGNIFYING_GLASS)
		_magnify_btn.disabled = remaining <= 0
		_magnify_btn.modulate = Color.WHITE

## ── Private: Game completion handlers ────────────────────────────


func _on_mining_won() -> void:
	var treasure_count: int = _mining_game.get_mine_count()
	var is_large: bool = treasure_count > 10
	var expedition_coins: int = 100000 if is_large else 10000

	var rewards := _generate_mining_rewards(treasure_count)

	# Apply rewards — base expedition coins + fill inventory until full, sell overflow at full price
	var coins_earned := expedition_coins
	PlayerData.coins += expedition_coins
	var pieces_earned: Dictionary = {}  # Piece.Type -> count
	var seeds_earned: Dictionary = {}   # plant_type (int) -> count
	var gems_earned: Dictionary = {}    # gem_type (String) -> count
	var overflow_coins := 0
	for reward in rewards:
		if reward["type"] == "coins":
			coins_earned += int(reward["amount"])
			PlayerData.coins += int(reward["amount"])
		elif reward["type"] == "gemstone":
			var gt: String = reward["gem_type"]
			gems_earned[gt] = gems_earned.get(gt, 0) + 1
			PlayerData.add_gemstones(gt, 1)  ## routes through add_gemstones → MissionBoard hook
		elif reward["type"] == "piece":
			var pt: Piece.Type = reward["piece_type"]
			if PlayerData.inventory.size() >= PlayerData.MAX_INVENTORY:
				# Inventory full — sell at full value
				var sell_value := PlayerData.get_piece_price(pt)
				overflow_coins += sell_value
				PlayerData.coins += sell_value
			else:
				pieces_earned[pt] = pieces_earned.get(pt, 0) + 1
				var def := PieceRegistry.get_def(pt)
				var dir := int(PieceDefinition.Direction.NONE)
				if def:
					dir = int(def.effect_direction)
				PlayerData.inventory.append({"type": int(pt), "direction": dir})
		elif reward["type"] == "seed":
			var plant_type: int = reward["plant_type"]
			var qty: int = reward["quantity"]
			seeds_earned[plant_type] = seeds_earned.get(plant_type, 0) + qty
			Garden.add_seeds(plant_type, qty, false)
	PlayerData.save_data()

	# Notify garden UI that seeds were added
	if not seeds_earned.is_empty():
		Garden.garden_updated.emit()

	# Build ChestPopup reward list
	var display_rewards: Array = []
	var total_coins := coins_earned + overflow_coins
	if total_coins > 0:
		display_rewards.append({"type": "coins", "amount": total_coins})
	for pt in pieces_earned:
		var count: int = pieces_earned[pt]
		for _i in range(count):
			display_rewards.append({"type": "piece", "piece_type": pt})
	for seed_type in seeds_earned:
		display_rewards.append({"type": "seed", "plant_type": seed_type, "quantity": seeds_earned[seed_type]})
	for gem_type in gems_earned:
		display_rewards.append({"type": "gemstone", "gem_type": gem_type, "value": gems_earned[gem_type]})

	var chest_level: int = 5 if is_large else 3
	ChestPopup.enqueue(get_tree(), chest_level, display_rewards,
		"Expedition Complete!",
		"%s expedition cleared!" % ("Large" if is_large else "Small"),
		_cleanup_game)

	status_label.text = "Victory! All treasures flagged! Coins: %s" % PlayerData.format_number(PlayerData.coins)
	results_label.visible = false
	small_mine_btn.visible = true
	large_mine_btn.visible = true
	gold_panning_btn.visible = true
	prospectors_btn.visible = true
	_set_deep_mine_btn_visible(true)
	if _magnify_btn != null and is_instance_valid(_magnify_btn):
		var magnify_row := content_vbox.get_node_or_null("MagnifyRow")
		if magnify_row != null:
			magnify_row.visible = false
	_refresh_mine_buttons()

	# Track mining achievements
	Achievements.record_mining_win(is_large)
	MissionBoard.on_expedition_complete()

	# Award XP for mining success
	var mining_xp := 150000 if is_large else 5000
	PlayerData.award_xp(mining_xp)


func _on_mining_lost() -> void:
	status_label.text = "The Town Council has fined you!"
	results_label.text = "You disturbed the site before finding all treasures.\nThe Council confiscated everything. Better luck next time!\nCoins: %s" % PlayerData.format_number(PlayerData.coins)
	results_label.visible = true
	rewards_container.visible = false
	small_mine_btn.visible = true
	large_mine_btn.visible = true
	gold_panning_btn.visible = true
	prospectors_btn.visible = true
	_set_deep_mine_btn_visible(true)
	_refresh_mine_buttons()
	_cleanup_game()

	# Track mining achievements (first-click loss detection).
	# Use player digs (not total cells revealed) so a first-click loss still
	# counts when the safe-tiles prestige pre-reveals tiles at the start.
	var player_digs: int = _mining_game.get_player_digs() if _mining_game != null and is_instance_valid(_mining_game) else 0
	Achievements.record_mining_loss(player_digs)


## ── Private: Post-game cleanup ───────────────────────────────────


## Tears down the MiningGame node and all dynamically added tool buttons.
## Called after the chest popup is dismissed (win) or immediately on loss.
func _cleanup_game() -> void:
	## Remove and free the MiningGame instance
	if _mining_game != null and is_instance_valid(_mining_game):
		if _mining_game.game_won.is_connected(_on_mining_won):
			_mining_game.game_won.disconnect(_on_mining_won)
		if _mining_game.game_lost.is_connected(_on_mining_lost):
			_mining_game.game_lost.disconnect(_on_mining_lost)
		if _mining_game.magnify_mode_changed.is_connected(_on_magnify_mode_changed):
			_mining_game.magnify_mode_changed.disconnect(_on_magnify_mode_changed)
		game_container.remove_child(_mining_game)
		_mining_game.queue_free()
		_mining_game = null

	## Remove magnify row
	var magnify_row := content_vbox.get_node_or_null("MagnifyRow")
	if magnify_row != null:
		magnify_row.queue_free()
	_magnify_btn = null
	_magnify_count_label = null

	## Remove flag button
	if _flag_btn != null and is_instance_valid(_flag_btn):
		_flag_btn.queue_free()
		_flag_btn = null
	_flag_mode = false


## ── Private: Reward generation ───────────────────────────────────


func _generate_mining_rewards(treasure_count: int) -> Array:
	var rewards := []
	# Use SHOP_WEIGHTS excluding pawns
	var weights := PlayerData.SHOP_WEIGHTS.duplicate()
	weights.erase(Piece.Type.PAWN)
	var total_weight: int = 0
	for w in weights.values():
		total_weight += w

	# Gem types and values for mining rewards
	var gem_types: Array = ["gold", "blue_stone", "pink_stone", "violet_stone", "black_pearl", "emerald", "ruby", "diamond"]
	var gem_weights: Array = [25, 20, 20, 15, 10, 5, 3, 2]
	var gem_values: Dictionary = {
		"gold": 50, "blue_stone": 75, "pink_stone": 75, "violet_stone": 100,
		"black_pearl": 150, "emerald": 200, "ruby": 300, "diamond": 500,
	}
	var gem_total_weight: int = 100

	for i in range(treasure_count):
		# 50% gems, 25% tiles, 25% seeds
		var roll_type := randi() % 100
		if roll_type < 50:
			# Gemstone — weighted random selection
			var gem_roll := randi_range(1, gem_total_weight)
			var cumulative := 0
			for j in range(gem_types.size()):
				cumulative += gem_weights[j]
				if gem_roll <= cumulative:
					var gt: String = gem_types[j]
					rewards.append({"type": "gemstone", "gem_type": gt, "value": gem_values[gt]})
					break
		elif roll_type < 75:
			# Roll a random piece type
			var roll := randi() % total_weight
			var cumulative := 0
			for piece_type in weights:
				cumulative += weights[piece_type]
				if roll < cumulative:
					rewards.append({"type": "piece", "piece_type": piece_type})
					break
		else:
			# Random seeds (1-3)
			var seed_type := randi() % GardenData.PLANT_DEFS.size()
			var seed_qty := randi_range(1, 3)
			rewards.append({"type": "seed", "plant_type": seed_type, "quantity": seed_qty})
	return rewards


## ── Private: Reward display helpers ──────────────────────────────


func _make_reward_item(icon: Texture2D, label_text: String) -> VBoxContainer:
	var item := VBoxContainer.new()
	item.add_theme_constant_override("separation", 2)
	item.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	if icon != null:
		var tex_rect := TextureRect.new()
		tex_rect.texture = icon
		tex_rect.custom_minimum_size = Vector2(40, 40)
		tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		item.add_child(tex_rect)
	else:
		# Coin reward — show coin emoji placeholder
		var coin_label := Label.new()
		coin_label.text = "🪙"
		coin_label.add_theme_font_size_override("font_size", 24)
		coin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		coin_label.custom_minimum_size = Vector2(40, 40)
		item.add_child(coin_label)

	var name_label := Label.new()
	name_label.text = label_text
	name_label.add_theme_font_size_override("font_size", 9)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	item.add_child(name_label)

	return item


func _clear_rewards() -> void:
	rewards_container.visible = false
	for child in rewards_container.get_children():
		rewards_container.remove_child(child)
		child.queue_free()


func _refresh_status() -> void:
	status_label.text = "Coins: %s" % PlayerData.format_number(PlayerData.coins)


func _refresh_mine_buttons() -> void:
	var lvl: int = PlayerData.level
	small_mine_btn.disabled = PlayerData.coins < 100 or lvl < 2
	small_mine_btn.text = "Small Expedition (100c)" if lvl >= 2 else "🔒 Small Expedition — Lv.2"
	large_mine_btn.disabled = PlayerData.coins < 300 or lvl < 5
	large_mine_btn.text = "Large Expedition (300c)" if lvl >= 5 else "🔒 Large Expedition — Lv.5"
	gold_panning_btn.disabled = lvl < 3
	gold_panning_btn.text = "Gold Panning" if lvl >= 3 else "🔒 Gold Panning — Lv.3"
	prospectors_btn.disabled = lvl < 10
	prospectors_btn.text = "Prospectors" if lvl >= 10 else "🔒 Prospectors — Lv.10"
