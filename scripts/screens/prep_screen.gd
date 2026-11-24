extends BaseScreen
## Prep screen — displays the player's available tile pool and selected tiles for battle.
## Currently auto-selects all pieces (matching existing GameManager behavior).
## Navigates to "battle" with selected_pieces, terrain, and enemy_count.
##
## Requirements: 1.2, 1.3, 6.4, 6.7, 9.1


## ── State ────────────────────────────────────────────────────────
var _enemy_count: int = 1
var _terrain: Terrain.Type = Terrain.Type.INDOORS
var _pool_pieces: Array[Piece] = []
var _selected_pieces: Array[Piece] = []

## ── Dynamic UI references (built in _build_ui) ──────────────────
var _pool_grid: GridContainer = null
var _selected_grid: GridContainer = null
var _enemy_label: Label = null
var _confirm_btn: Button = null


func enter(params: Dictionary = {}) -> void:
	# Read enemy_count and terrain from params, fallback to defaults (Req 6.4)
	_enemy_count = int(params.get("enemy_count", 1))
	_terrain = int(params.get("terrain", Terrain.Type.INDOORS)) as Terrain.Type

	# Build the player's piece pool from inventory (Req 9.1)
	_pool_pieces = PlayerData.get_inventory_as_pieces()
	_selected_pieces = []

	# Auto-select all available pieces (matches current game behavior)
	_auto_select_all()

	_build_ui()


func exit() -> void:
	for child in get_children():
		child.queue_free()


func get_screen_name() -> String:
	return "prep"


## ── Private: Auto-select ─────────────────────────────────────────


func _auto_select_all() -> void:
	_selected_pieces = _pool_pieces.duplicate()
	_pool_pieces.clear()


## ── Private: Build UI ────────────────────────────────────────────


func _build_ui() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "PrepScroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	# Title
	var title := Label.new()
	title.name = "TitleLabel"
	title.text = "Choose your tiles"
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Enemy info label
	_enemy_label = Label.new()
	_enemy_label.name = "PrepEnemyLabel"
	_enemy_label.add_theme_font_size_override("font_size", 12)
	_enemy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_enemy_label.text = "Battles: %d  |  Terrain: %s" % [
		_enemy_count, Terrain.get_terrain_name(_terrain)]
	vbox.add_child(_enemy_label)

	# Pool section
	var pool_label := Label.new()
	pool_label.name = "PoolLabel"
	pool_label.text = "Your Pool:"
	pool_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(pool_label)

	var pool_scroll := ScrollContainer.new()
	pool_scroll.name = "PoolScroll"
	pool_scroll.custom_minimum_size.y = 80
	pool_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pool_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(pool_scroll)

	_pool_grid = GridContainer.new()
	_pool_grid.name = "PoolGrid"
	_pool_grid.columns = 3
	_pool_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pool_scroll.add_child(_pool_grid)

	# Selected section
	var selected_label := Label.new()
	selected_label.name = "SelectedLabel"
	selected_label.text = "Selected for battle:"
	selected_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(selected_label)

	var selected_scroll := ScrollContainer.new()
	selected_scroll.name = "SelectedScroll"
	selected_scroll.custom_minimum_size.y = 80
	selected_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	selected_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(selected_scroll)

	_selected_grid = GridContainer.new()
	_selected_grid.name = "SelectedGrid"
	_selected_grid.columns = 3
	_selected_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	selected_scroll.add_child(_selected_grid)

	# Confirm button
	_confirm_btn = Button.new()
	_confirm_btn.name = "ConfirmBattleBtn"
	_confirm_btn.text = "Go to Battle"
	_confirm_btn.add_theme_font_size_override("font_size", 15)
	_confirm_btn.custom_minimum_size.y = 48
	_confirm_btn.pressed.connect(_on_confirm_pressed)
	vbox.add_child(_confirm_btn)

	# Back button
	var back_btn := Button.new()
	back_btn.name = "BackBtn"
	back_btn.text = "< Back"
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.custom_minimum_size.y = 48
	back_btn.pressed.connect(_on_back_pressed)
	vbox.add_child(back_btn)

	# Populate grids
	_refresh_grids()


## ── Private: Grid population ─────────────────────────────────────


func _refresh_grids() -> void:
	_refresh_pool_grid()
	_refresh_selected_grid()


func _refresh_pool_grid() -> void:
	var counts := _build_counts(_pool_pieces)
	UiPieceGrid.build_grid(_pool_grid, counts, -1, Callable(self, "_on_pool_piece_clicked"))


func _refresh_selected_grid() -> void:
	var counts := _build_counts(_selected_pieces)
	UiPieceGrid.build_grid(_selected_grid, counts, -1, Callable(self, "_on_selected_piece_clicked"))


func _build_counts(pieces: Array[Piece]) -> Dictionary:
	var counts: Dictionary = {}
	for p in pieces:
		counts[p.type] = counts.get(p.type, 0) + 1
	return counts


## ── Private: Piece selection callbacks ───────────────────────────


func _on_pool_piece_clicked(piece_type: int) -> void:
	# Move one piece of this type from pool to selected
	for i in range(_pool_pieces.size()):
		if int(_pool_pieces[i].type) == piece_type:
			_selected_pieces.append(_pool_pieces[i])
			_pool_pieces.remove_at(i)
			break
	_refresh_grids()


func _on_selected_piece_clicked(piece_type: int) -> void:
	# Move one piece of this type from selected back to pool
	for i in range(_selected_pieces.size()):
		if int(_selected_pieces[i].type) == piece_type:
			_pool_pieces.append(_selected_pieces[i])
			_selected_pieces.remove_at(i)
			break
	_refresh_grids()


## ── Private: Navigation ──────────────────────────────────────────


func _on_confirm_pressed() -> void:
	var params := {
		"selected_pieces": _selected_pieces as Array,
		"terrain": _terrain,
		"enemy_count": _enemy_count,
	}
	_get_navigator().navigate_to("battle", params)


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()
