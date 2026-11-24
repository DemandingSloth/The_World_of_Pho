class_name ChestPopup
extends Window

## Animated chest opening popup. Shows the chest animating open, then displays rewards.
## Spritesheet: 10 columns (chest levels 0-9) × 4 rows (animation frames).
##
## Use ChestPopup.enqueue() to ensure only one popup shows at a time.
## Subsequent chests wait for the current one to close before animating.

signal chest_closed

const CHEST_SHEET_PATH := "res://Assets/chests.png"
const CHEST_SCRIPT_PATH := "res://scripts/chest_popup.gd"
const COLUMNS := 10      ## 10 chest levels
const ROWS    := 4       ## 4 animation frames per chest
const FRAME_DELAY := 0.2 ## Seconds between animation frames

## ── Static queue — one popup at a time ───────────────────────────
static var _queue: Array = []     ## Array of { level, rewards, title, desc, on_closed }
static var _showing: bool = false ## True while a popup is visible

## Enqueue a chest popup. Shows immediately if none is active, otherwise waits.
## on_closed is an optional Callable invoked when THIS popup is dismissed.
static func enqueue(
	scene_tree: SceneTree,
	chest_level: int,
	rewards: Array,
	title: String = "",
	desc: String = "",
	on_closed: Callable = Callable()
) -> void:
	_queue.append({
		"level": chest_level,
		"rewards": rewards,
		"title": title,
		"desc": desc,
		"on_closed": on_closed,
	})
	if not _showing:
		_show_next(scene_tree)


static func _show_next(scene_tree: SceneTree) -> void:
	if _queue.is_empty():
		_showing = false
		return
	_showing = true
	var entry: Dictionary = _queue.pop_front()
	## Load via script to avoid circular self-reference at parse time
	var script: GDScript = load(CHEST_SCRIPT_PATH)
	var popup: Window = script.new()
	popup.setup(entry["level"], entry["rewards"], entry["title"], entry["desc"])
	popup._scene_tree_ref = scene_tree
	popup._on_closed_callback = entry.get("on_closed", Callable())
	scene_tree.root.add_child(popup)
	popup.popup_centered()


## ── Instance variables ────────────────────────────────────────────
var _scene_tree_ref: SceneTree = null
var _on_closed_callback: Callable = Callable()

var _chest_level: int = 0
var _rewards: Array = []
var _achievement_title: String = ""
var _achievement_desc: String = ""
var _sheet: Texture2D = null
var _frame_size: Vector2 = Vector2.ZERO
var _current_frame: int = 0
var _timer: Timer = null
var _sprite: TextureRect = null
var _reward_container: VBoxContainer = null
var _animation_done: bool = false


func _init() -> void:
	title = "Chest Reward!"
	size = Vector2i(500, 550)
	unresizable = false
	close_requested.connect(_on_close)


func setup(chest_level: int, rewards: Array, achievement_title: String = "", achievement_desc: String = "") -> void:
	_chest_level = clampi(chest_level, 0, 9)
	_rewards = rewards
	_achievement_title = achievement_title
	_achievement_desc = achievement_desc
	_sheet = load(CHEST_SHEET_PATH)
	if _sheet == null:
		push_error("ChestPopup: could not load chest spritesheet")
		return
	var sheet_size: Vector2 = _sheet.get_size()
	_frame_size = Vector2(sheet_size.x / COLUMNS, sheet_size.y / ROWS)


func _ready() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(root)

	if _achievement_title != "":
		var title_lbl := Label.new()
		title_lbl.text = "Achievement: %s" % _achievement_title
		title_lbl.add_theme_font_size_override("font_size", 15)
		title_lbl.add_theme_color_override("font_color", Color(0.53, 0.81, 0.98))
		title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root.add_child(title_lbl)
	if _achievement_desc != "":
		var desc_lbl := Label.new()
		desc_lbl.text = _achievement_desc
		desc_lbl.add_theme_font_size_override("font_size", 12)
		desc_lbl.add_theme_color_override("font_color", Color(0.53, 0.81, 0.98))
		desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		root.add_child(desc_lbl)

	var sprite_container := CenterContainer.new()
	sprite_container.custom_minimum_size = Vector2(128, 128)
	root.add_child(sprite_container)

	_sprite = TextureRect.new()
	_sprite.custom_minimum_size = Vector2(96, 96)
	_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_show_frame(0)
	sprite_container.add_child(_sprite)

	var reward_scroll := ScrollContainer.new()
	reward_scroll.name = "RewardScroll"
	reward_scroll.visible = false
	reward_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	reward_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_reward_container = VBoxContainer.new()
	_reward_container.add_theme_constant_override("separation", 4)
	_reward_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reward_scroll.add_child(_reward_container)
	root.add_child(reward_scroll)

	var ok_btn := Button.new()
	ok_btn.name = "OKBtn"
	ok_btn.text = "Collect!"
	ok_btn.add_theme_font_size_override("font_size", 14)
	ok_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ok_btn.custom_minimum_size.x = 120
	ok_btn.visible = false
	ok_btn.pressed.connect(_on_close)
	root.add_child(ok_btn)

	_current_frame = 0
	_timer = Timer.new()
	_timer.wait_time = FRAME_DELAY
	_timer.one_shot = false
	_timer.timeout.connect(_advance_frame)
	add_child(_timer)
	_timer.start()


func _show_frame(frame_index: int) -> void:
	if _sheet == null:
		return
	var atlas := AtlasTexture.new()
	atlas.atlas = _sheet
	atlas.region = Rect2(
		_chest_level * _frame_size.x,
		frame_index * _frame_size.y,
		_frame_size.x,
		_frame_size.y
	)
	_sprite.texture = atlas


func _advance_frame() -> void:
	_current_frame += 1
	if _current_frame >= ROWS:
		_timer.stop()
		_show_frame(ROWS - 1)
		_show_rewards()
		return
	_show_frame(_current_frame)


func _show_rewards() -> void:
	_animation_done = true
	## Reveal the Collect button FIRST so the popup is always dismissable, even
	## if building a reward row below fails for any reason (prevents the "blank
	## chest with no close button" lock-up).
	_reveal_ok_button()

	var reward_scroll = get_node_or_null("RewardScroll")
	if reward_scroll == null:
		for child in get_children():
			if child is VBoxContainer:
				for sub in child.get_children():
					if sub is ScrollContainer and sub.name == "RewardScroll":
						reward_scroll = sub
						break
	if reward_scroll:
		reward_scroll.visible = true

	var header := Label.new()
	header.text = "You received:"
	header.add_theme_font_size_override("font_size", 13)
	header.add_theme_color_override("font_color", Color(0.53, 0.81, 0.98))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reward_container.add_child(header)

	var coins_total := 0
	var pieces: Dictionary = {}
	var seeds_total: Dictionary = {}
	var saplings_total: Dictionary = {}
	var gems_total: Dictionary = {}
	var prospectors_total: Dictionary = {}  ## gem_type -> count
	var resources_total: Dictionary = {}  ## item_id -> count
	var wonderstone_total: int = 0
	for reward in _rewards:
		var rtype := str(reward.get("type", ""))
		if rtype == "resource":
			var rid: String = str(reward["item_id"])
			resources_total[rid] = resources_total.get(rid, 0) + int(reward.get("quantity", 1))
			continue
		if rtype == "material":
			if str(reward.get("item_id", "")) == "wonderstone":
				wonderstone_total += int(reward.get("quantity", 1))
			continue
		if rtype == "coins":
			coins_total += int(reward["amount"])
		elif rtype == "piece":
			## Only real tile ids (ints) can be drawn; skip anything malformed
			## rather than crashing mid-render (which blanked the whole popup).
			var raw_pt = reward.get("piece_type", null)
			if not (raw_pt is int or raw_pt is float):
				continue
			var pt := int(raw_pt)
			pieces[pt] = pieces.get(pt, 0) + 1
		elif rtype == "seed":
			var st: int = reward["plant_type"]
			seeds_total[st] = seeds_total.get(st, 0) + int(reward["quantity"])
		elif rtype == "sapling":
			var tt: int = reward["tree_type"]
			saplings_total[tt] = saplings_total.get(tt, 0) + int(reward["quantity"])
		elif rtype == "prospector":
			var pgt: String = reward["gem_type"]
			prospectors_total[pgt] = prospectors_total.get(pgt, 0) + int(reward.get("quantity", 1))
		elif rtype == "gemstone":
			var gt: String = reward["gem_type"]
			gems_total[gt] = gems_total.get(gt, 0) + 1

	if coins_total > 0:
		var coin_lbl := Label.new()
		coin_lbl.text = "+%s coins" % PlayerData.format_number(coins_total)
		coin_lbl.add_theme_font_size_override("font_size", 12)
		coin_lbl.add_theme_color_override("font_color", Color(0.53, 0.81, 0.98))
		coin_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_reward_container.add_child(coin_lbl)

	if wonderstone_total > 0:
		var ws_item := VBoxContainer.new()
		ws_item.add_theme_constant_override("separation", 2)
		ws_item.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		var ws_tex := ItemKeyRegistry.get_texture("material:wonderstone")
		if ws_tex != null:
			var ws_rect := TextureRect.new()
			ws_rect.texture = ws_tex
			ws_rect.custom_minimum_size = Vector2(40, 40)
			ws_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			ws_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			ws_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			ws_item.add_child(ws_rect)
		var ws_lbl := Label.new()
		ws_lbl.text = "WonderStone x%d" % wonderstone_total
		ws_lbl.add_theme_font_size_override("font_size", 10)
		ws_lbl.add_theme_color_override("font_color", Color(0.8, 0.7, 1.0))
		ws_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ws_item.add_child(ws_lbl)
		_reward_container.add_child(ws_item)

	if pieces.size() > 0:
		var pieces_grid := GridContainer.new()
		pieces_grid.columns = 6
		pieces_grid.add_theme_constant_override("h_separation", 8)
		pieces_grid.add_theme_constant_override("v_separation", 8)
		pieces_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		for pt in pieces:
			var item := VBoxContainer.new()
			item.add_theme_constant_override("separation", 2)
			item.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			var def := PieceRegistry.get_def(pt as Piece.Type)
			if def:
				var icon: Texture2D = PieceSprites.get_icon(def.sprite_index)
				if icon:
					var tex_rect := TextureRect.new()
					tex_rect.texture = icon
					tex_rect.custom_minimum_size = Vector2(40, 40)
					tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
					tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
					tex_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
					item.add_child(tex_rect)
			var name_lbl := Label.new()
			name_lbl.text = "%s x%d" % [PieceRegistry.display_name(pt as Piece.Type), pieces[pt]]
			name_lbl.add_theme_font_size_override("font_size", 9)
			name_lbl.add_theme_color_override("font_color", Color(0.53, 0.81, 0.98))
			name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			item.add_child(name_lbl)
			pieces_grid.add_child(item)
		_reward_container.add_child(pieces_grid)

	if seeds_total.size() > 0:
		var seeds_grid := GridContainer.new()
		seeds_grid.columns = 6
		seeds_grid.add_theme_constant_override("h_separation", 8)
		seeds_grid.add_theme_constant_override("v_separation", 8)
		seeds_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		for st in seeds_total:
			var item := VBoxContainer.new()
			item.add_theme_constant_override("separation", 2)
			item.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			var seed_def: Dictionary = GardenData.PLANT_DEFS[st]
			var tex: Texture2D = load(seed_def["sprite"])
			if tex:
				var frame_w: float = tex.get_width() / 4.0
				var atlas := AtlasTexture.new()
				atlas.atlas = tex
				atlas.region = Rect2(0, 0, frame_w, tex.get_height())
				var tex_rect := TextureRect.new()
				tex_rect.texture = atlas
				tex_rect.custom_minimum_size = Vector2(40, 40)
				tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				tex_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
				item.add_child(tex_rect)
			var name_lbl := Label.new()
			name_lbl.text = "%s x%d" % [seed_def["name"], seeds_total[st]]
			name_lbl.add_theme_font_size_override("font_size", 9)
			name_lbl.add_theme_color_override("font_color", Color(0.53, 0.81, 0.98))
			name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			item.add_child(name_lbl)
			seeds_grid.add_child(item)
		_reward_container.add_child(seeds_grid)

	if saplings_total.size() > 0:
		var saplings_grid := GridContainer.new()
		saplings_grid.columns = 5
		saplings_grid.add_theme_constant_override("h_separation", 8)
		saplings_grid.add_theme_constant_override("v_separation", 8)
		saplings_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		for tt in saplings_total:
			var item := VBoxContainer.new()
			item.add_theme_constant_override("separation", 2)
			item.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			var atlas: AtlasTexture = null
			if get_node_or_null("/root/Orchard") != null:
				atlas = get_node("/root/Orchard").get_fruit_texture(tt)
			if atlas:
				var tex_rect := TextureRect.new()
				tex_rect.texture = atlas
				tex_rect.custom_minimum_size = Vector2(40, 40)
				tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				tex_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
				item.add_child(tex_rect)
			var tree_name := "Sapling"
			if get_node_or_null("/root/Orchard") != null:
				var def: Dictionary = get_node("/root/Orchard").get_tree_def(tt)
				tree_name = def.get("fruit_name", "Tree") + " Sapling"
			var name_lbl := Label.new()
			name_lbl.text = "%s x%d" % [tree_name, saplings_total[tt]]
			name_lbl.add_theme_font_size_override("font_size", 9)
			name_lbl.add_theme_color_override("font_color", Color(0.53, 0.81, 0.98))
			name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			item.add_child(name_lbl)
			saplings_grid.add_child(item)
		_reward_container.add_child(saplings_grid)

	if gems_total.size() > 0:
		var gems_grid := GridContainer.new()
		gems_grid.columns = 6
		gems_grid.add_theme_constant_override("h_separation", 8)
		gems_grid.add_theme_constant_override("v_separation", 8)
		gems_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		for gt in gems_total:
			var item := VBoxContainer.new()
			item.add_theme_constant_override("separation", 2)
			item.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			var gem_tex: Texture2D = load("res://Assets/GoldPanning/Gemstones/%s.png" % gt)
			if gem_tex:
				var tex_rect := TextureRect.new()
				tex_rect.texture = gem_tex
				tex_rect.custom_minimum_size = Vector2(40, 40)
				tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				tex_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
				item.add_child(tex_rect)
			var name_lbl := Label.new()
			name_lbl.text = "%s x%d" % [gt.replace("_", " ").capitalize(), gems_total[gt]]
			name_lbl.add_theme_font_size_override("font_size", 9)
			name_lbl.add_theme_color_override("font_color", Color(0.53, 0.81, 0.98))
			name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			item.add_child(name_lbl)
			gems_grid.add_child(item)
		_reward_container.add_child(gems_grid)

	if prospectors_total.size() > 0:
		var prosp_grid := GridContainer.new()
		prosp_grid.columns = 6
		prosp_grid.add_theme_constant_override("h_separation", 8)
		prosp_grid.add_theme_constant_override("v_separation", 8)
		prosp_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		for pgt in prospectors_total:
			var item := VBoxContainer.new()
			item.add_theme_constant_override("separation", 2)
			item.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			var prosp_tex: Texture2D = load("res://Assets/GoldPanning/Gemstones/%s.png" % pgt)
			if prosp_tex:
				var tex_rect := TextureRect.new()
				tex_rect.texture = prosp_tex
				tex_rect.custom_minimum_size = Vector2(40, 40)
				tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				tex_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
				item.add_child(tex_rect)
			var name_lbl := Label.new()
			name_lbl.text = "%s Prospector x%d" % [str(pgt).replace("_", " ").capitalize(), prospectors_total[pgt]]
			name_lbl.add_theme_font_size_override("font_size", 9)
			name_lbl.add_theme_color_override("font_color", Color(0.53, 0.81, 0.98))
			name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			item.add_child(name_lbl)
			prosp_grid.add_child(item)
		_reward_container.add_child(prosp_grid)

	if resources_total.size() > 0:
		var res_grid := GridContainer.new()
		res_grid.columns = 5
		res_grid.add_theme_constant_override("h_separation", 8)
		res_grid.add_theme_constant_override("v_separation", 8)
		res_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		for rid in resources_total:
			var item := VBoxContainer.new()
			item.add_theme_constant_override("separation", 2)
			item.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			var r_def: Dictionary = PlayerData.get_resource_def(rid)
			var sprite_key: String = str(r_def.get("ore_sprite", rid)) if not r_def.is_empty() else rid
			var res_tex: Texture2D = OreSprites.get_item_texture(sprite_key)
			if res_tex:
				var tex_rect := TextureRect.new()
				tex_rect.texture = res_tex
				tex_rect.custom_minimum_size = Vector2(40, 40)
				tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				tex_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
				item.add_child(tex_rect)
			var disp_name: String = str(r_def.get("name", rid)) if not r_def.is_empty() else str(rid).replace("_", " ").capitalize()
			var name_lbl := Label.new()
			name_lbl.text = "%s x%d" % [disp_name, resources_total[rid]]
			name_lbl.add_theme_font_size_override("font_size", 9)
			name_lbl.add_theme_color_override("font_color", Color(0.53, 0.81, 0.98))
			name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			item.add_child(name_lbl)
			res_grid.add_child(item)
		_reward_container.add_child(res_grid)

	## Ensure the OK button is visible (also revealed at the top as a safety net).
	_reveal_ok_button()


## Makes the Collect/OK button visible. Safe to call more than once.
func _reveal_ok_button() -> void:
	var btn := _find_ok_button()
	if btn != null:
		btn.visible = true


## Finds the "OKBtn" Button anywhere under this window, or null.
func _find_ok_button() -> Button:
	for child in get_children():
		if child is VBoxContainer:
			for sub in child.get_children():
				if sub is Button and sub.name == "OKBtn":
					return sub
	return null


func _on_close() -> void:
	chest_closed.emit()
	if _on_closed_callback.is_valid():
		_on_closed_callback.call()
	var tree: SceneTree = _scene_tree_ref if _scene_tree_ref != null else get_tree()
	queue_free()
	ChestPopup._showing = false
	if tree != null:
		ChestPopup._show_next(tree)
