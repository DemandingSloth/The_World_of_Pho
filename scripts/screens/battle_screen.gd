class_name BattleScreen
extends BaseScreen
## Battle screen — the most complex screen. Embeds GameManager as a child node,
## builds the 8×8 board grid, hand grid, and all battle UI.
## Handles placement, movement, scoring phases, and navigates to result/run_complete/home
## when the battle resolves.
##
## Requirements: 1.2, 1.3, 1.5, 1.6, 5.1, 5.2, 5.3, 5.4, 5.5, 6.5, 7.2, 7.4, 7.6, 10.1, 10.2


## ── Node References ──────────────────────────────────────────────

@onready var game_manager: GameManager = $GameManager
@onready var vbox: VBoxContainer = $VBox
@onready var board_section: VBoxContainer = $VBox/BoardSection
@onready var battle_header: Label = $VBox/BoardSection/BattleHeader
@onready var board_label: Label = $VBox/BoardSection/BoardLabel
@onready var board_grid: GridContainer = $VBox/BoardSection/BoardGrid
@onready var south_label: Label = $VBox/BoardSection/SouthLabel
@onready var battle_panel: VBoxContainer = $VBox/BattlePanel
@onready var status_label: Label = $VBox/BattlePanel/StatusLabel
@onready var terrain_active_label: Label = $VBox/BattlePanel/TerrainActiveLabel
@onready var score_label: Label = $VBox/BattlePanel/ScoreLabel
@onready var hand_label: Label = $VBox/BattlePanel/HandLabel
@onready var hand_grid: GridContainer = $VBox/BattlePanel/HandGrid
@onready var finish_placement_btn: Button = $VBox/BattlePanel/FinishPlacementBtn
@onready var pass_turn_btn: Button = $VBox/BattlePanel/PassTurnBtn
@onready var log_scroll: ScrollContainer = $VBox/BattlePanel/LogScroll
@onready var log_label: RichTextLabel = $VBox/BattlePanel/LogScroll/Log


## ── Constants ────────────────────────────────────────────────────

const HAND_TILE := Vector2(62, 62)

## Tile size computed at build time based on board size and viewport width
var _tile_size := Vector2(62, 62)

const C_DARK          := Color(0.16, 0.16, 0.16)
const C_LIGHT         := Color(0.80, 0.78, 0.72)
const C_VALID         := Color(0.20, 0.42, 0.20)
const C_OCCUPIED      := Color(0.42, 0.22, 0.10)
const C_MOVE_SRC      := Color(0.70, 0.65, 0.10)
const C_HOVER_DARK    := Color(0.28, 0.28, 0.30)
const C_HOVER_LIGHT   := Color(0.90, 0.88, 0.82)
const C_BORDER        := Color(0.20, 0.20, 0.20)


## ── State ────────────────────────────────────────────────────────

var selected_piece: Piece = null
var move_source: Array = []
var rotating_piece: Piece = null
var last_player_score: int = 0
var last_enemy_score: int = 0
var _signals_connected: bool = false
var _rotate_btn: Button = null


## ── BaseScreen Overrides ─────────────────────────────────────────

func get_screen_name() -> String:
	return "battle"


func show_top_bar() -> bool:
	return true


func enter(params: Dictionary = {}) -> void:
	_connect_signals()

	## Read params
	var enemy_count: int = params.get("enemy_count", 3)
	var terrain: Terrain.Type = params.get("terrain", Terrain.Type.INDOORS) as Terrain.Type
	var forced_enemy: int = params.get("forced_enemy", -1)
	var board_size: int = params.get("board_size", 4)
	var continue_campaign: bool = bool(params.get("continue_campaign", false))

	## Set board size BEFORE building the board (must be 4 or 6)
	BoardState.BOARD_SIZE = clampi(board_size, 4, 6)

	## Now build the board grid with the correct size
	_build_board()

	## Wire button signals
	finish_placement_btn.pressed.connect(_on_finish_placement)
	pass_turn_btn.pressed.connect(_on_pass_turn)

	## Add a Rotate button for mobile (no right-click available)
	_rotate_btn = Button.new()
	_rotate_btn.text = "↻ Rotate"
	_rotate_btn.add_theme_font_size_override("font_size", 12)
	_rotate_btn.custom_minimum_size = Vector2(100, 36)
	_rotate_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_rotate_btn.pressed.connect(_on_rotate_pressed)
	_rotate_btn.visible = false  ## Only show when a rotatable piece is selected
	battle_panel.add_child(_rotate_btn)
	battle_panel.move_child(_rotate_btn, hand_grid.get_index() + 1)

	## Add piece description label below terrain label (created in code to avoid scene cache issues)
	if battle_panel.get_node_or_null("PieceDescLabel") == null:
		var piece_desc := Label.new()
		piece_desc.name = "PieceDescLabel"
		piece_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		piece_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		piece_desc.add_theme_font_size_override("font_size", 10)
		piece_desc.add_theme_color_override("font_color", Color.BLACK)
		piece_desc.visible = false
		battle_panel.add_child(piece_desc)
		battle_panel.move_child(piece_desc, terrain_active_label.get_index() + 1)

	## Apply layout
	_apply_layout()
	ResponsiveLayoutManager.layout_recalculated.connect(_on_layout_recalculated)

	## Start a new gauntlet, or resume the in-progress one after "Next Battle".
	## Campaign progress lives in PlayerData.active_campaign because this scene's
	## GameManager/CampaignManager are recreated on every battle transition.
	## Resume whenever there's an in-progress gauntlet. The persisted
	## active_campaign is the source of truth: the setup screen clears it before
	## starting a fresh game, so a non-empty run here always means "continue".
	## (This is more robust than relying on the continue_campaign flag surviving
	## the result → battle navigation.)
	if not PlayerData.active_campaign.is_empty():
		game_manager.resume_campaign()
	else:
		game_manager.start_campaign(enemy_count, terrain, forced_enemy)


func exit() -> void:
	## Disconnect signals FIRST. forfeit_battle() emits phase_changed(GAME_OVER),
	## and if _on_phase_changed were still connected during teardown it would
	## trigger _navigate_to_game_over() — sending the player home mid-transition
	## even when leaving normally to the result screen after a win.
	_disconnect_signals()
	if game_manager != null and is_instance_valid(game_manager):
		game_manager.forfeit_battle()
	if ResponsiveLayoutManager.layout_recalculated.is_connected(_on_layout_recalculated):
		ResponsiveLayoutManager.layout_recalculated.disconnect(_on_layout_recalculated)
	if finish_placement_btn.pressed.is_connected(_on_finish_placement):
		finish_placement_btn.pressed.disconnect(_on_finish_placement)
	if pass_turn_btn.pressed.is_connected(_on_pass_turn):
		pass_turn_btn.pressed.disconnect(_on_pass_turn)


## ── Signal Management ────────────────────────────────────────────

func _connect_signals() -> void:
	if _signals_connected:
		return
	game_manager.phase_changed.connect(_on_phase_changed)
	game_manager.board_updated.connect(_refresh_board)
	game_manager.scores_ready.connect(_on_scores_ready)
	game_manager.turn_changed.connect(_on_turn_changed)
	game_manager.campaign_updated.connect(_on_campaign_updated)
	game_manager.wind_spun.connect(_on_wind_spun)
	_signals_connected = true


func _disconnect_signals() -> void:
	if not _signals_connected:
		return
	if game_manager.phase_changed.is_connected(_on_phase_changed):
		game_manager.phase_changed.disconnect(_on_phase_changed)
	if game_manager.board_updated.is_connected(_refresh_board):
		game_manager.board_updated.disconnect(_refresh_board)
	if game_manager.scores_ready.is_connected(_on_scores_ready):
		game_manager.scores_ready.disconnect(_on_scores_ready)
	if game_manager.turn_changed.is_connected(_on_turn_changed):
		game_manager.turn_changed.disconnect(_on_turn_changed)
	if game_manager.campaign_updated.is_connected(_on_campaign_updated):
		game_manager.campaign_updated.disconnect(_on_campaign_updated)
	if game_manager.wind_spun.is_connected(_on_wind_spun):
		game_manager.wind_spun.disconnect(_on_wind_spun)
	_signals_connected = false


## ── Layout ───────────────────────────────────────────────────────

func _on_layout_recalculated() -> void:
	_apply_layout()


func _apply_layout() -> void:
	## Apply portrait layout: board 60%, panel 40%
	ResponsiveLayoutManager.apply_layout(board_section, battle_panel)


## ── Board Building ───────────────────────────────────────────────

## Wind blew this piece but it had nowhere to go — spin it in place, then set
## it back to its real facing. Deferred so it runs after the board_updated
## refresh has rebuilt the tile's sprite.
func _on_wind_spun(row: int, col: int) -> void:
	_play_wind_spin.call_deferred(row, col)


func _play_wind_spin(row: int, col: int) -> void:
	if not is_inside_tree():
		return
	var sprite: TextureRect = null
	for btn in board_grid.get_children():
		if int(btn.get_meta("row", -1)) == row and int(btn.get_meta("col", -1)) == col:
			sprite = btn.get_node_or_null("PieceSprite") as TextureRect
			break
	if sprite == null:
		return
	var piece := game_manager.board.get_piece(row, col)
	var final_deg: float = piece.get_rotation_degrees() if piece != null else 0.0
	## Spin a few full turns from the current facing, landing back on it.
	sprite.rotation_degrees = final_deg
	var tween := create_tween()
	tween.tween_property(sprite, "rotation_degrees", final_deg + 360.0 * 3.0, 0.6) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	## Normalize back to the exact facing so nothing drifts on the next refresh.
	tween.tween_callback(func():
		if is_instance_valid(sprite):
			sprite.rotation_degrees = final_deg)


func _build_board() -> void:
	for child in board_grid.get_children():
		child.queue_free()

	## Compute tile size based on board size and available width (420px viewport)
	## For 4x4: 62px tiles (fits comfortably in 420px)
	## For 6x6: ~48px tiles to fit within 420px with 1px separators
	var available_width: float = 400.0  ## ~420 minus margins
	var tile_px: float = available_width / float(BoardState.BOARD_SIZE)
	tile_px = minf(tile_px, 62.0)  ## Cap at 62px max
	_tile_size = Vector2(tile_px, tile_px)

	board_grid.columns = BoardState.BOARD_SIZE
	for r in range(BoardState.BOARD_SIZE):
		for c in range(BoardState.BOARD_SIZE):
			var btn := Button.new()
			btn.custom_minimum_size = _tile_size
			btn.flat = false
			btn.clip_text = true
			btn.focus_mode = Control.FOCUS_NONE
			btn.icon = null
			btn.set_meta("row", r)
			btn.set_meta("col", c)
			btn.pressed.connect(_on_board_cell_pressed.bind(btn))
			btn.gui_input.connect(_on_board_cell_input.bind(r, c))
			btn.add_to_group("board_cells")
			board_grid.add_child(btn)


## ── Board Refresh ────────────────────────────────────────────────

func _clear_board_overlays() -> void:
	for btn in board_grid.get_children():
		var overlay = btn.get_node_or_null("ScoreOverlay")
		if overlay:
			btn.remove_child(overlay)
			overlay.queue_free()
		var arrow = btn.get_node_or_null("DirArrow")
		if arrow:
			btn.remove_child(arrow)
			arrow.queue_free()
		var sprite = btn.get_node_or_null("PieceSprite")
		if sprite:
			btn.remove_child(sprite)
			sprite.queue_free()


func _refresh_board() -> void:
	_clear_board_overlays()
	if game_manager.current_phase in [
			GameManager.Phase.CAMPAIGN_SETUP,
			GameManager.Phase.BATTLE_PREP]:
		return

	var phase := game_manager.current_phase
	var is_place := phase == GameManager.Phase.PLACEMENT
	var is_move := phase == GameManager.Phase.MOVEMENT
	var player_turn := is_move and game_manager.movement.current_turn == Piece.Owner.PLAYER

	battle_header.text = game_manager.get_battle_header()

	for btn in board_grid.get_children():
		var r: int = btn.get_meta("row")
		var c: int = btn.get_meta("col")
		var piece := game_manager.board.get_piece(r, c)
		var is_dark := (r + c) % 2 == 1

		var bg := C_DARK if is_dark else C_LIGHT

		if is_place and selected_piece != null and is_dark:
			bg = C_VALID if piece == null else C_OCCUPIED

		if is_move and player_turn:
			if move_source.size() == 2:
				if move_source[0] == r and move_source[1] == c:
					bg = C_MOVE_SRC
				elif is_dark:
					if piece == null:
						bg = C_VALID
					elif piece.owner == Piece.Owner.PLAYER \
						 and not game_manager.movement.moved_pieces.has(piece):
						bg = lerp(bg, C_VALID, 0.4)

		_apply_style(btn, bg, is_dark)
		_apply_piece_text(btn, piece, phase)


func _apply_style(btn: Button, bg: Color, is_dark: bool) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.border_color = C_BORDER
	btn.add_theme_stylebox_override("normal", s)
	btn.add_theme_stylebox_override("pressed", s)
	var h := s.duplicate() as StyleBoxFlat
	h.bg_color = C_HOVER_DARK if is_dark else C_HOVER_LIGHT
	btn.add_theme_stylebox_override("hover", h)

	## Terrain background sprite
	var old_terrain = btn.get_node_or_null("TerrainBG")
	if old_terrain:
		btn.remove_child(old_terrain)
		old_terrain.queue_free()

	var terrain_tex: AtlasTexture = TerrainSprites.get_terrain_icon(game_manager.current_terrain)
	if terrain_tex != null:
		var bg_rect := TextureRect.new()
		bg_rect.name = "TerrainBG"
		bg_rect.texture = terrain_tex
		bg_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg_rect.stretch_mode = TextureRect.STRETCH_SCALE
		bg_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if is_dark:
			bg_rect.self_modulate = Color(0.45, 0.45, 0.5)
		else:
			bg_rect.self_modulate = Color(1.1, 1.1, 1.05)
		btn.add_child(bg_rect)
		btn.move_child(bg_rect, 0)


func _apply_piece_text(btn: Button, piece: Piece, phase: GameManager.Phase) -> void:
	btn.add_theme_font_size_override("font_size", 11)

	var old_overlay = btn.get_node_or_null("ScoreOverlay")
	if old_overlay:
		btn.remove_child(old_overlay)
		old_overlay.queue_free()

	if piece == null:
		btn.text = ""
		btn.icon = null
		btn.tooltip_text = ""
		if btn.has_meta("piece"):
			btn.remove_meta("piece")
		var old_sprite = btn.get_node_or_null("PieceSprite")
		if old_sprite:
			btn.remove_child(old_sprite)
			old_sprite.queue_free()
		return

	var old_sprite = btn.get_node_or_null("PieceSprite")
	if old_sprite:
		btn.remove_child(old_sprite)
		old_sprite.queue_free()

	var moved_mark := "·" if (phase == GameManager.Phase.MOVEMENT \
		and game_manager.movement.moved_pieces.has(piece)) else ""
	var is_scoring := phase == GameManager.Phase.SCORING \
					  or phase == GameManager.Phase.BATTLE_RESULT \
					  or phase == GameManager.Phase.RUN_COMPLETE \
					  or phase == GameManager.Phase.GAME_OVER
	var pts := str(piece.final_points) if is_scoring else str(piece.base_points)
	var icon := PieceSprites.get_piece_icon(piece)
	if icon != null:
		btn.icon = null
		var sprite_rect := TextureRect.new()
		sprite_rect.name = "PieceSprite"
		sprite_rect.texture = icon
		sprite_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		sprite_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		sprite_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		sprite_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sprite_rect.pivot_offset = btn.custom_minimum_size / 2.0
		sprite_rect.rotation_degrees = piece.get_rotation_degrees()
		btn.add_child(sprite_rect)
		btn.text = "" if is_scoring else "%s%s" % [moved_mark, pts]
		btn.add_theme_font_size_override("font_size", 10)
	else:
		btn.icon = null
		btn.text = "" if is_scoring else "%s%s\n%s" % [piece.get_label(), moved_mark, pts]
	btn.modulate = Color.WHITE

	## Tint piece sprite for player/enemy distinction
	var piece_tint := Color(0.75, 0.92, 1.00) if piece.owner == Piece.Owner.PLAYER \
					  else Color(1.00, 0.70, 0.70)
	var sprite_node = btn.get_node_or_null("PieceSprite")
	if sprite_node:
		sprite_node.self_modulate = piece_tint

	## Tooltip and touch meta
	var dir_text := ""
	if piece.is_rotatable():
		match piece.direction:
			PieceDefinition.Direction.NORTH: dir_text = " (facing North)"
			PieceDefinition.Direction.SOUTH: dir_text = " (facing South)"
			PieceDefinition.Direction.EAST: dir_text = " (facing East)"
			PieceDefinition.Direction.WEST: dir_text = " (facing West)"
	btn.tooltip_text = "%s%s\n%s" % [piece.display_name, dir_text, piece.description]
	btn.set_meta("piece", piece)

	## Direction arrow for rotatable pieces
	if not is_scoring and piece.is_rotatable():
		var arrow := ""
		match piece.direction:
			PieceDefinition.Direction.NORTH: arrow = "↑"
			PieceDefinition.Direction.SOUTH: arrow = "↓"
			PieceDefinition.Direction.EAST: arrow = "→"
			PieceDefinition.Direction.WEST: arrow = "←"
		if arrow != "":
			var dir_label := Label.new()
			dir_label.name = "DirArrow"
			dir_label.text = arrow
			dir_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			dir_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
			dir_label.add_theme_font_size_override("font_size", 16)
			dir_label.add_theme_color_override("font_color", Color(1, 1, 0, 0.9))
			dir_label.anchors_preset = Control.PRESET_FULL_RECT
			dir_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			btn.add_child(dir_label)

	## During scoring/result, overlay a large final score number
	if is_scoring:
		var overlay := Label.new()
		overlay.name = "ScoreOverlay"
		overlay.text = str(piece.final_points)
		overlay.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		overlay.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		overlay.add_theme_font_size_override("font_size", 24)
		overlay.add_theme_color_override("font_color", Color.WHITE)
		overlay.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
		overlay.add_theme_constant_override("shadow_offset_x", 1)
		overlay.add_theme_constant_override("shadow_offset_y", 1)
		overlay.anchors_preset = Control.PRESET_FULL_RECT
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(overlay)


func _update_piece_desc() -> void:
	var lbl := battle_panel.get_node_or_null("PieceDescLabel") as Label
	if lbl == null:
		return
	if selected_piece != null and selected_piece.description != "":
		lbl.text = selected_piece.description
		lbl.visible = true
	else:
		lbl.text = ""
		lbl.visible = false


## ── Hand Grid ────────────────────────────────────────────────────

func _rebuild_hand() -> void:
	if game_manager.current_phase != GameManager.Phase.PLACEMENT:
		for child in hand_grid.get_children():
			child.queue_free()
		return
	var hand := game_manager.player_hand

	## Group pieces by type and count remaining
	var counts: Dictionary = {}
	for piece in hand.pieces:
		counts[piece.type] = counts.get(piece.type, 0) + 1

	## Determine which type is currently selected
	var sel_type: int = selected_piece.type if selected_piece != null else -1

	## Build grid using shared helper, passing hand pieces for long-press tooltip meta
	UiPieceGrid.build_grid(hand_grid, counts, sel_type, _on_hand_type_selected, HAND_TILE, hand.pieces)

	## Update piece description below terrain label
	_update_piece_desc()

	## Apply rotation visual after the frame (queue_free from build_grid is deferred)
	if selected_piece != null and selected_piece.is_rotatable():
		call_deferred("_apply_hand_rotation")


## ── Hand Input ───────────────────────────────────────────────────

func _apply_hand_rotation() -> void:
	if selected_piece == null or not selected_piece.is_rotatable():
		return
	var rotation_deg: float = selected_piece.get_rotation_degrees()
	## Find the selected tile (has a Panel child = selection border)
	for tile in hand_grid.get_children():
		if not is_instance_valid(tile) or not tile is Button:
			continue
		var sprite_node = tile.get_node_or_null("PieceSprite")
		if sprite_node == null:
			continue
		var is_selected_tile := false
		for child in tile.get_children():
			if child is Panel and is_instance_valid(child):
				is_selected_tile = true
				break
		if is_selected_tile:
			sprite_node.pivot_offset = HAND_TILE / 2.0
			sprite_node.rotation_degrees = rotation_deg
			## Add direction arrow
			var arrow := ""
			match selected_piece.direction:
				PieceDefinition.Direction.NORTH: arrow = "↑"
				PieceDefinition.Direction.EAST: arrow = "→"
				PieceDefinition.Direction.SOUTH: arrow = "↓"
				PieceDefinition.Direction.WEST: arrow = "←"
			if arrow != "" and tile.get_node_or_null("DirIndicator") == null:
				var dir_lbl := Label.new()
				dir_lbl.name = "DirIndicator"
				dir_lbl.text = arrow
				dir_lbl.add_theme_font_size_override("font_size", 18)
				dir_lbl.add_theme_color_override("font_color", Color(1, 1, 0, 0.9))
				dir_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				dir_lbl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
				dir_lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
				dir_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
				tile.add_child(dir_lbl)
			break


func _on_hand_type_selected(piece_type: int) -> void:
	if game_manager.current_phase != GameManager.Phase.PLACEMENT:
		return
	var hand := game_manager.player_hand
	## If already selected this type, rotate the first matching piece
	if selected_piece != null and selected_piece.type == piece_type and selected_piece.is_rotatable():
		game_manager.rotate_piece(selected_piece)
		_rebuild_hand()
		_refresh_board()
		return
	## Select the first piece of this type from the hand
	for piece in hand.pieces:
		if piece.type == piece_type:
			selected_piece = piece
			game_manager.select_hand_piece(piece)
			_rebuild_hand()
			_refresh_board()
			_update_rotate_btn_visibility()
			return


## ── Board Input ──────────────────────────────────────────────────

func _on_board_cell_pressed(btn: Button) -> void:
	var row: int = btn.get_meta("row")
	var col: int = btn.get_meta("col")
	match game_manager.current_phase:
		GameManager.Phase.PLACEMENT:
			_handle_place(row, col)
		GameManager.Phase.MOVEMENT:
			_handle_move(row, col)


func _on_board_cell_input(event: InputEvent, row: int, col: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_on_board_cell_right_click(row, col)
	elif event is InputEventScreenTouch and event.pressed and event.double_tap:
		# Double-tap on mobile to rotate placed pieces
		_on_board_cell_right_click(row, col)


func _on_board_cell_right_click(row: int, col: int) -> void:
	var piece := game_manager.board.get_piece(row, col)
	if piece == null or piece.owner != Piece.Owner.PLAYER:
		return
	if game_manager.current_phase == GameManager.Phase.PLACEMENT:
		game_manager.rotate_piece(piece)
		_refresh_board()
	elif game_manager.current_phase == GameManager.Phase.MOVEMENT:
		if game_manager.movement.current_turn != Piece.Owner.PLAYER:
			return
		rotating_piece = piece
		move_source = []
		game_manager.rotate_piece(piece)
		status_label.text = "Rotating %s — right-click again to keep rotating, left-click to continue." % piece.display_name
		_refresh_board()


func _handle_place(row: int, col: int) -> void:
	## Check if tapping an already-placed player piece — pick it up back to hand
	var existing := game_manager.board.get_piece(row, col)
	if existing != null and existing.owner == Piece.Owner.PLAYER:
		## Pick up the piece back to hand
		game_manager.board.remove_piece(row, col)
		game_manager.player_hand.pieces.append(existing)
		selected_piece = existing
		game_manager.select_hand_piece(existing)
		status_label.text = "Picked up %s. Tap a tile to re-place it." % existing.display_name
		_rebuild_hand()
		_refresh_board()
		_update_rotate_btn_visibility()
		return

	if selected_piece == null:
		status_label.text = "Select a piece from your hand first."
		return
	var placed := game_manager.place_selected_piece(row, col)
	if placed:
		## Re-select the same piece type if more remain in hand
		var placed_type: Piece.Type = selected_piece.type
		selected_piece = null
		var hand := game_manager.player_hand
		for piece in hand.pieces:
			if piece.type == placed_type:
				selected_piece = piece
				game_manager.select_hand_piece(piece)
				break
		_rebuild_hand()
		_refresh_board()
		_update_rotate_btn_visibility()
	else:
		status_label.text = "Can't place there. Choose a dark empty tile."


func _handle_move(row: int, col: int) -> void:
	if game_manager.movement.current_turn != Piece.Owner.PLAYER:
		return

	## If in rotation mode, left-clicking exits it (rotation is free)
	if rotating_piece != null:
		rotating_piece = null

	if move_source.is_empty():
		var piece := game_manager.board.get_piece(row, col)
		if piece != null and piece.owner == Piece.Owner.PLAYER \
		   and not game_manager.movement.moved_pieces.has(piece):
			move_source = [row, col]
			_refresh_board()
			_update_rotate_btn_visibility()
		else:
			status_label.text = "Pick one of your pieces that hasn't moved yet."
	else:
		if move_source[0] == row and move_source[1] == col:
			move_source = []
			_refresh_board()
			_update_rotate_btn_visibility()
			return
		var result := game_manager.attempt_move(
			Piece.Owner.PLAYER, move_source[0], move_source[1], row, col)
		move_source = []
		if result != Movement.MoveResult.OK:
			status_label.text = "Can't move there."
		_refresh_board()
		_update_rotate_btn_visibility()


## ── Battle Controls ──────────────────────────────────────────────

func _on_finish_placement() -> void:
	selected_piece = null
	_update_rotate_btn_visibility()
	game_manager.finish_placement()


func _on_pass_turn() -> void:
	if game_manager.current_phase != GameManager.Phase.MOVEMENT:
		return
	if game_manager.movement.current_turn != Piece.Owner.PLAYER:
		return
	rotating_piece = null
	move_source = []
	game_manager.pass_turn()
	_refresh_board()


func _on_rotate_pressed() -> void:
	if selected_piece != null and selected_piece.is_rotatable():
		game_manager.rotate_piece(selected_piece)
		_rebuild_hand()
		_refresh_board()
	elif game_manager.current_phase == GameManager.Phase.MOVEMENT:
		# During movement, rotate the piece at move_source if one is selected
		if move_source.size() == 2:
			var piece := game_manager.board.get_piece(move_source[0], move_source[1])
			if piece != null and piece.owner == Piece.Owner.PLAYER and piece.is_rotatable():
				game_manager.rotate_piece(piece)
				_refresh_board()


func _update_rotate_btn_visibility() -> void:
	if _rotate_btn == null:
		return
	var show := false
	if game_manager.current_phase == GameManager.Phase.PLACEMENT:
		show = selected_piece != null and selected_piece.is_rotatable()
	elif game_manager.current_phase == GameManager.Phase.MOVEMENT:
		show = move_source.size() == 2
		if show:
			var piece := game_manager.board.get_piece(move_source[0], move_source[1])
			show = piece != null and piece.owner == Piece.Owner.PLAYER and piece.is_rotatable()
	_rotate_btn.visible = show


## ── Phase Change Handler ─────────────────────────────────────────

func _on_phase_changed(new_phase: GameManager.Phase) -> void:
	match new_phase:
		GameManager.Phase.PLACEMENT:
			_clear_board_overlays()
			board_label.text = "NORTH"
			south_label.text = "SOUTH"
			terrain_active_label.text = "Terrain: %s" % \
				Terrain.get_terrain_name(game_manager.current_terrain)

			## Check if player has enough pieces to meet minimum
			var hand_size: int = game_manager.player_hand.pieces.size()
			if hand_size < game_manager.MIN_PLAYER_PIECES:
				status_label.text = "Not enough pieces! You need at least %d. Campaign lost." % game_manager.MIN_PLAYER_PIECES
				finish_placement_btn.visible = false
				pass_turn_btn.visible = false
				await get_tree().create_timer(2.0).timeout
				game_manager.forfeit_battle()
				return

			status_label.text = "Left-click to place. Right-click to rotate."
			finish_placement_btn.visible = true
			finish_placement_btn.text = "Done Placing"
			pass_turn_btn.visible = false
			score_label.text = ""
			log_label.text = ""
			selected_piece = null
			move_source = []
			rotating_piece = null
			_rebuild_hand()
			_refresh_board()

		GameManager.Phase.MOVEMENT:
			finish_placement_btn.visible = false
			pass_turn_btn.visible = true
			rotating_piece = null
			_update_piece_desc()  ## clears since selected_piece is null in movement
			_rebuild_hand()
			_refresh_board()

		GameManager.Phase.SCORING:
			pass_turn_btn.visible = false
			_rebuild_hand()
			_refresh_board()

		GameManager.Phase.BATTLE_RESULT:
			_refresh_board()
			_navigate_to_result()

		GameManager.Phase.RUN_COMPLETE:
			_refresh_board()
			_navigate_to_run_complete()

		GameManager.Phase.GAME_OVER:
			_refresh_board()
			_navigate_to_game_over()


## ── Turn and Campaign Updates ────────────────────────────────────

func _on_turn_changed(label: String) -> void:
	status_label.text = label


func _on_campaign_updated() -> void:
	battle_header.text = game_manager.get_battle_header()


## ── Scoring ──────────────────────────────────────────────────────

func _on_scores_ready(result: Dictionary) -> void:
	last_player_score = result["player"]
	last_enemy_score = result["enemy"]
	var p: int = result["player"]
	var e: int = result["enemy"]
	var winner := "Victory!" if p >= e else "Defeat!"
	score_label.text = "%s\nYou: %d pts  |  Enemy: %d pts" % [winner, p, e]
	log_label.text = "\n".join(result["log"] as Array)
	_refresh_board()

	## Show continue button so player can review scoring before proceeding
	finish_placement_btn.text = "Continue"
	finish_placement_btn.visible = true
	pass_turn_btn.visible = false

	## Temporarily rewire finish button to confirm scoring
	if finish_placement_btn.pressed.is_connected(_on_finish_placement):
		finish_placement_btn.pressed.disconnect(_on_finish_placement)
	finish_placement_btn.pressed.connect(_on_confirm_scoring.bind(p, e), CONNECT_ONE_SHOT)


func _on_confirm_scoring(p: int, e: int) -> void:
	finish_placement_btn.visible = false
	finish_placement_btn.text = "Done Placing"
	if not finish_placement_btn.pressed.is_connected(_on_finish_placement):
		finish_placement_btn.pressed.connect(_on_finish_placement)
	game_manager.confirm_result(p, e)


## ── Navigation ───────────────────────────────────────────────────

func _navigate_to_result() -> void:
	var navigator := _get_navigator()
	# Pop "battle" off the nav stack so back-swiping from result goes to prep/home,
	# not back into a fresh battle.
	AndroidLifecycleManager.pop_screen()
	navigator.navigate_to("result", {
		"player_score": last_player_score,
		"enemy_score": last_enemy_score,
		"game_manager_ref": game_manager,
	})


func _navigate_to_run_complete() -> void:
	var navigator := _get_navigator()
	AndroidLifecycleManager.pop_screen()
	navigator.navigate_to("run_complete", {
		"game_manager_ref": game_manager,
	})


func _navigate_to_game_over() -> void:
	var navigator := _get_navigator()
	navigator.navigate_to("home", {
		"from_game_over": true,
		"player_score": last_player_score,
		"enemy_score": last_enemy_score,
	})
