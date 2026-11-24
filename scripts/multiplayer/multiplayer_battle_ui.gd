extends Node

## Multiplayer battle UI controller.
## Manages the 8x8 board, hand display, placement, and movement phases for PvP.
## Loads after piece selection confirms and both players transition here.

# ── Node References ───────────────────────────────────────────────────────────

@onready var board_grid      : GridContainer  = $Root/BoardSection/BoardGrid
@onready var battle_header   : Label          = $Root/BoardSection/BattleHeader
@onready var board_label     : Label          = $Root/BoardSection/BoardLabel
@onready var south_label     : Label          = $Root/BoardSection/SouthLabel
@onready var status_label    : Label          = $Root/SidePanel/StatusLabel
@onready var terrain_label   : Label          = $Root/SidePanel/TerrainLabel
@onready var hand_grid       : GridContainer  = $Root/SidePanel/HandScroll/HandGrid
@onready var done_placing_btn: Button         = $Root/SidePanel/DonePlacingBtn
@onready var pass_turn_btn   : Button         = $Root/SidePanel/PassTurnBtn
@onready var log_label       : RichTextLabel  = $Root/SidePanel/LogScroll/Log

# ── Constants ─────────────────────────────────────────────────────────────────

const TILE_SIZE := Vector2(62, 62)
const HAND_TILE := Vector2(62, 62)

const C_DARK          := Color(0.16, 0.16, 0.16)
const C_LIGHT         := Color(0.80, 0.78, 0.72)
const C_VALID         := Color(0.20, 0.42, 0.20)
const C_OCCUPIED      := Color(0.42, 0.22, 0.10)
const C_MOVE_SRC      := Color(0.70, 0.65, 0.10)
const C_HOVER_DARK    := Color(0.28, 0.28, 0.30)
const C_HOVER_LIGHT   := Color(0.90, 0.88, 0.82)
const C_HAND_NORMAL   := Color(0.22, 0.22, 0.36)
const C_HAND_SELECTED := Color(0.80, 0.70, 0.10)
const C_BORDER        := Color(0.20, 0.20, 0.20)

const MATCH_RESULT_PATH := "res://scenes/multiplayer/match_result.tscn"

# ── State ─────────────────────────────────────────────────────────────────────

var game_manager: MultiplayerGameManager = null
var selected_piece: Piece = null
var move_source: Array = []

## True when this player is the host (places on rows 0-3, dark tiles).
var _is_host: bool = false

## This player's owner mapping: host = PLAYER, guest = ENEMY.
var _local_owner: Piece.Owner = Piece.Owner.PLAYER


# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	_is_host = NetworkManager.is_host
	_local_owner = Piece.Owner.PLAYER if _is_host else Piece.Owner.ENEMY

	## Create the game manager node
	game_manager = MultiplayerGameManager.new()
	game_manager.name = "MultiplayerGameManager"
	add_child(game_manager)

	## Connect signals
	game_manager.phase_changed.connect(_on_phase_changed)
	game_manager.board_updated.connect(_refresh_board)
	game_manager.scores_ready.connect(_on_scores_ready)
	game_manager.match_ended.connect(_on_match_ended)
	game_manager.placement_rejected.connect(_on_placement_rejected)
	game_manager.opponent_placement_confirmed.connect(_on_opponent_confirmed)
	game_manager.opponent_move_received.connect(_on_opponent_move)
	game_manager.opponent_disconnected.connect(_on_opponent_disconnected)
	game_manager.host_disconnected.connect(_on_host_disconnected)

	## Wire buttons
	done_placing_btn.pressed.connect(_on_done_placing)
	pass_turn_btn.pressed.connect(_on_pass_turn)

	## Build the board
	_build_board()

	## Initialize the PvP match via the game manager
	_start_match()

	## Update labels
	_update_orientation_labels()
	status_label.text = "Placement Phase — place your pieces"
	_rebuild_hand()


func _exit_tree() -> void:
	if game_manager != null and is_instance_valid(game_manager):
		game_manager.queue_free()


## Right-click anywhere rotates the currently selected piece in hand.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if game_manager == null:
				return
			if game_manager.pvp_phase != MultiplayerGameManager.PvPPhase.PVP_PLACEMENT:
				return
			if selected_piece != null and selected_piece.is_rotatable():
				selected_piece.rotate_cw()
				_rebuild_hand()
				_refresh_board()
				get_viewport().set_input_as_handled()


# ── Match Initialization ──────────────────────────────────────────────────────


func _start_match() -> void:
	## Build config from NetworkManager lobby
	var config := MatchConfig.new()
	if NetworkManager.lobby and NetworkManager.lobby.match_config:
		config = NetworkManager.lobby.match_config

	## Set peer IDs on the game manager
	game_manager.host_peer_id = 1
	if NetworkManager.lobby and NetworkManager.lobby.guest_info:
		game_manager.guest_peer_id = NetworkManager.lobby.guest_info.peer_id
	elif not _is_host:
		## We are the guest; host is peer 1, we use our own ID
		game_manager.guest_peer_id = NetworkManager.local_peer_id

	## Start the PvP match (this creates an empty board and empty hands)
	game_manager.start_pvp_match(config)

	## Populate the LOCAL player's hand from the saved piece selection
	var local_hand := _get_local_hand()
	if local_hand != null:
		local_hand.pieces.clear()
		for item in NetworkManager.local_battle_pieces:
			var piece_type: Piece.Type = item.get("type", 0) as Piece.Type
			var direction: PieceDefinition.Direction = item.get("direction", PieceDefinition.Direction.NONE) as PieceDefinition.Direction
			var piece := Piece.create(piece_type, _local_owner)
			piece.direction = direction
			local_hand.pieces.append(piece)

	## If we're the guest, send our piece list to the host so the host can validate placements
	## If we're the host, we already have our own hand; wait for guest to send theirs
	if not _is_host:
		_send_hand_to_host.rpc_id(1, NetworkManager.local_battle_pieces)

	## Update terrain label
	terrain_label.text = "Terrain: %s" % Terrain.get_terrain_name(game_manager.current_terrain)


func _update_orientation_labels() -> void:
	board_label.text = "NORTH"
	south_label.text = "SOUTH"


# ── Board Building ────────────────────────────────────────────────────────────


func _build_board() -> void:
	for child in board_grid.get_children():
		child.queue_free()
	board_grid.columns = BoardState.BOARD_SIZE
	for r in range(BoardState.BOARD_SIZE):
		for c in range(BoardState.BOARD_SIZE):
			var btn := Button.new()
			btn.custom_minimum_size = TILE_SIZE
			btn.flat = false
			btn.clip_text = true
			btn.focus_mode = Control.FOCUS_NONE
			btn.icon = null
			btn.set_meta("row", r)
			btn.set_meta("col", c)
			btn.pressed.connect(_on_board_cell_pressed.bind(btn))
			btn.add_to_group("board_cells")
			board_grid.add_child(btn)


# ── Board Rendering ───────────────────────────────────────────────────────────


func _refresh_board() -> void:
	_clear_board_overlays()
	if game_manager == null:
		return

	var phase := game_manager.pvp_phase
	var is_place := phase == MultiplayerGameManager.PvPPhase.PVP_PLACEMENT
	var is_move := phase == MultiplayerGameManager.PvPPhase.MOVEMENT

	## Update movement status text when board updates during movement
	if is_move:
		_update_movement_status()
	var is_my_turn := is_move and _is_my_turn()

	## Also rebuild hand during placement (pieces may have been removed by accepted RPC)
	if is_place:
		_rebuild_hand()

	for btn in board_grid.get_children():
		var r: int = btn.get_meta("row")
		var c: int = btn.get_meta("col")
		var piece := game_manager.board.get_piece(r, c)
		var is_dark := (r + c) % 2 == 1

		var bg := C_DARK if is_dark else C_LIGHT

		## During placement, hide opponent's pieces — only show your own
		var visible_piece: Piece = null
		if is_place:
			if piece != null and piece.owner == _local_owner:
				visible_piece = piece
			## else: hide opponent's pieces (they placed hidden)
		else:
			visible_piece = piece

		## Highlight valid placement tiles
		if is_place and selected_piece != null:
			if _is_valid_placement_tile(r, c):
				bg = C_VALID if visible_piece == null else C_OCCUPIED

		## Highlight move source and valid move targets
		if is_my_turn:
			if move_source.size() == 2:
				if move_source[0] == r and move_source[1] == c:
					bg = C_MOVE_SRC
				elif _is_valid_placement_tile(r, c) and piece == null:
					bg = C_VALID

		_apply_style(btn, bg, is_dark)
		_apply_piece_text(btn, visible_piece, phase)


func _clear_board_overlays() -> void:
	for btn in board_grid.get_children():
		var overlay = btn.get_node_or_null("ScoreOverlay")
		if overlay:
			btn.remove_child(overlay)
			overlay.queue_free()
		var sprite = btn.get_node_or_null("PieceSprite")
		if sprite:
			btn.remove_child(sprite)
			sprite.queue_free()
		var dir_arrow = btn.get_node_or_null("DirArrow")
		if dir_arrow:
			btn.remove_child(dir_arrow)
			dir_arrow.queue_free()


func _apply_style(btn: Button, bg: Color, is_dark: bool) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_width_left   = 1
	s.border_width_right  = 1
	s.border_width_top    = 1
	s.border_width_bottom = 1
	s.border_color = C_BORDER
	btn.add_theme_stylebox_override("normal",  s)
	btn.add_theme_stylebox_override("pressed", s)
	var h := s.duplicate() as StyleBoxFlat
	h.bg_color = C_HOVER_DARK if is_dark else C_HOVER_LIGHT
	btn.add_theme_stylebox_override("hover", h)


func _apply_piece_text(btn: Button, piece: Piece, phase: MultiplayerGameManager.PvPPhase) -> void:
	btn.add_theme_font_size_override("font_size", 11)

	if piece == null:
		btn.text = ""
		btn.icon = null
		btn.tooltip_text = ""
		if btn.has_meta("piece"):
			btn.remove_meta("piece")
		return

	var is_scoring := phase == MultiplayerGameManager.PvPPhase.SCORING \
					  or phase == MultiplayerGameManager.PvPPhase.RESULT
	var pts := str(piece.final_points) if is_scoring else str(piece.base_points)

	## Moved marker during movement
	var moved_mark := ""
	if phase == MultiplayerGameManager.PvPPhase.MOVEMENT:
		if game_manager.movement and game_manager.movement.moved_pieces.has(piece):
			moved_mark = "·"

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

		## Tint for owner distinction
		var piece_tint := Color(0.75, 0.92, 1.00) if piece.owner == Piece.Owner.PLAYER \
						  else Color(1.00, 0.70, 0.70)
		sprite_rect.self_modulate = piece_tint
	else:
		btn.icon = null
		btn.text = "" if is_scoring else "%s%s\n%s" % [piece.get_label(), moved_mark, pts]

	btn.tooltip_text = "%s\n%s" % [piece.display_name, piece.description]
	btn.set_meta("piece", piece)
	if is_scoring:
		var overlay := Label.new()
		overlay.name = "ScoreOverlay"
		overlay.text = str(piece.final_points)
		overlay.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		overlay.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		overlay.add_theme_font_size_override("font_size", 24)
		overlay.add_theme_color_override("font_color", Color.WHITE)
		overlay.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
		overlay.add_theme_constant_override("shadow_offset_x", 1)
		overlay.add_theme_constant_override("shadow_offset_y", 1)
		overlay.anchors_preset = Control.PRESET_FULL_RECT
		overlay.mouse_filter   = Control.MOUSE_FILTER_IGNORE
		btn.add_child(overlay)


# ── Hand Display ──────────────────────────────────────────────────────────────


func _rebuild_hand() -> void:
	if game_manager == null:
		for child in hand_grid.get_children():
			child.queue_free()
		return
	if game_manager.pvp_phase != MultiplayerGameManager.PvPPhase.PVP_PLACEMENT:
		for child in hand_grid.get_children():
			child.queue_free()
		return

	var hand := _get_local_hand()
	if hand == null:
		for child in hand_grid.get_children():
			child.queue_free()
		return

	## Group pieces by type and count remaining
	var counts: Dictionary = {}
	for piece in hand.pieces:
		counts[piece.type] = counts.get(piece.type, 0) + 1

	## Determine which type is currently selected
	var sel_type: int = selected_piece.type if selected_piece != null else -1

	## Build grid using shared helper, passing hand pieces for long-press tooltip meta
	UiPieceGrid.build_grid(hand_grid, counts, sel_type, _on_hand_type_selected, HAND_TILE, hand.pieces)


func _make_piece_btn(piece: Piece, size: Vector2, bg: Color) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = size
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 11)
	## Allow right-click to pass through to gui_input (for rotation)
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

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
		sprite_rect.pivot_offset = size / 2.0
		sprite_rect.rotation_degrees = piece.get_rotation_degrees()
		btn.add_child(sprite_rect)
		btn.text = "%d pt" % piece.base_points
	else:
		btn.text = "%s\n%d pt" % [piece.get_label(), piece.base_points]

	var tip := "%s\n%s" % [piece.display_name, piece.description]
	if piece.is_rotatable():
		tip += "\nClick again to rotate"
	btn.tooltip_text = tip

	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_width_left = 2; s.border_width_right = 2
	s.border_width_top  = 2; s.border_width_bottom = 2
	s.border_color = Color(0.5, 0.5, 0.6)
	s.corner_radius_top_left    = 4; s.corner_radius_top_right    = 4
	s.corner_radius_bottom_left = 4; s.corner_radius_bottom_right = 4
	btn.add_theme_stylebox_override("normal",  s)
	btn.add_theme_stylebox_override("pressed", s)
	var h := s.duplicate() as StyleBoxFlat
	h.bg_color = bg.lightened(0.15)
	btn.add_theme_stylebox_override("hover", h)
	return btn


# ── Input: Hand ───────────────────────────────────────────────────────────────


func _on_hand_type_selected(piece_type: int) -> void:
	if game_manager.pvp_phase != MultiplayerGameManager.PvPPhase.PVP_PLACEMENT:
		return
	var hand := _get_local_hand()
	if hand == null:
		return
	## If already selected this type, rotate the first matching piece
	if selected_piece != null and selected_piece.type == piece_type and selected_piece.is_rotatable():
		selected_piece.rotate_cw()
		_rebuild_hand()
		_refresh_board()
		return
	## Select the first piece of this type from the hand
	for piece in hand.pieces:
		if piece.type == piece_type:
			selected_piece = piece
			_rebuild_hand()
			_refresh_board()
			return


func _on_hand_pressed(piece: Piece) -> void:
	if game_manager.pvp_phase != MultiplayerGameManager.PvPPhase.PVP_PLACEMENT:
		return
	## If clicking the already-selected piece, rotate it instead
	if piece == selected_piece and piece.is_rotatable():
		piece.rotate_cw()
		_rebuild_hand()
		_refresh_board()
		return
	selected_piece = piece
	_rebuild_hand()
	_refresh_board()


## Handles gui_input on hand buttons — right-click rotates the piece.
func _on_hand_gui_input(event: InputEvent, piece: Piece) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_on_hand_right_click(piece)
			get_viewport().set_input_as_handled()


## Rotates a piece when right-clicked in the hand (cycles direction clockwise).
func _on_hand_right_click(piece: Piece) -> void:
	if game_manager.pvp_phase != MultiplayerGameManager.PvPPhase.PVP_PLACEMENT:
		return
	if not piece.is_rotatable():
		return
	piece.rotate_cw()
	_rebuild_hand()
	_refresh_board()


# ── Input: Board ──────────────────────────────────────────────────────────────


func _on_board_cell_pressed(btn: Button) -> void:
	var row: int = btn.get_meta("row")
	var col: int = btn.get_meta("col")

	match game_manager.pvp_phase:
		MultiplayerGameManager.PvPPhase.PVP_PLACEMENT:
			_handle_place(row, col)
		MultiplayerGameManager.PvPPhase.MOVEMENT:
			_handle_move(row, col)


func _handle_place(row: int, col: int) -> void:
	if selected_piece == null:
		status_label.text = "Select a piece from your hand first."
		return

	## Validate locally before sending RPC
	if not _is_valid_placement_tile(row, col):
		if _is_host:
			status_label.text = "Must place on a dark (black) tile."
		else:
			status_label.text = "Must place on a light (white) tile."
		return

	if game_manager.board.get_piece(row, col) != null:
		status_label.text = "That tile is already occupied."
		return

	## Build piece data for the RPC
	var piece_data := {
		"type": int(selected_piece.type),
		"owner": int(_local_owner),
		"direction": int(selected_piece.direction),
	}

	## Send placement request to the host
	if _is_host:
		## Host validates locally
		var success := game_manager.request_placement(
			1, piece_data, row, col)
		if success:
			_on_placement_success(row, col)
		else:
			status_label.text = "Placement rejected."
	else:
		## Client sends RPC to host and waits for acceptance
		game_manager._request_placement_rpc.rpc_id(1, piece_data, row, col)
		## Don't update locally yet — wait for _placement_accepted_rpc
		status_label.text = "Placing..."


func _on_placement_success(row: int, col: int) -> void:
	## Remove piece from local hand tracking
	var placed_type: Piece.Type = selected_piece.type if selected_piece else Piece.Type.PAWN
	var hand := _get_local_hand()
	if hand != null:
		for i in range(hand.pieces.size()):
			if hand.pieces[i] == selected_piece:
				hand.pieces.remove_at(i)
				break
	## Re-select the same piece type if more remain in hand
	selected_piece = null
	if hand != null:
		for piece in hand.pieces:
			if piece.type == placed_type:
				selected_piece = piece
				break
	_rebuild_hand()
	_refresh_board()
	_log("Placed piece at (%d, %d)" % [row, col])


func _handle_move(row: int, col: int) -> void:
	if not _is_my_turn():
		status_label.text = "Not your turn."
		return

	if move_source.is_empty():
		## Select a piece to move
		var piece := game_manager.board.get_piece(row, col)
		if piece == null:
			return
		if piece.owner != _local_owner:
			status_label.text = "That's not your piece."
			return
		if game_manager.movement and game_manager.movement.moved_pieces.has(piece):
			status_label.text = "That piece already moved this phase."
			return
		move_source = [row, col]
		_refresh_board()
	else:
		## Deselect if clicking same tile
		if move_source[0] == row and move_source[1] == col:
			move_source = []
			_refresh_board()
			return

		## Send move request
		var from_r: int = move_source[0]
		var from_c: int = move_source[1]
		move_source = []

		if _is_host:
			var result := game_manager.request_move(1, from_r, from_c, row, col)
			if result == Movement.MoveResult.OK:
				_log("Moved piece from (%d,%d) to (%d,%d)" % [from_r, from_c, row, col])
			else:
				status_label.text = "Can't move there."
		else:
			game_manager._request_move_rpc.rpc_id(1, from_r, from_c, row, col)
			_log("Requested move from (%d,%d) to (%d,%d)" % [from_r, from_c, row, col])

		_refresh_board()


# ── Button Handlers ───────────────────────────────────────────────────────────


func _on_done_placing() -> void:
	if game_manager.pvp_phase != MultiplayerGameManager.PvPPhase.PVP_PLACEMENT:
		return

	selected_piece = null

	if _is_host:
		var accepted := game_manager.confirm_placement_done(1)
		if accepted:
			done_placing_btn.disabled = true
			status_label.text = "Placement confirmed. Waiting for opponent..."
			_log("You confirmed placement.")
		else:
			status_label.text = "Place at least 3 pieces before confirming."
	else:
		game_manager._confirm_placement_rpc.rpc_id(1)
		done_placing_btn.disabled = true
		status_label.text = "Placement confirmed. Waiting for opponent..."
		_log("You confirmed placement.")


func _on_pass_turn() -> void:
	if game_manager.pvp_phase != MultiplayerGameManager.PvPPhase.MOVEMENT:
		return
	if not _is_my_turn():
		return

	move_source = []

	if _is_host:
		game_manager.request_pass_turn(1)
	else:
		game_manager._request_pass_rpc.rpc_id(1)

	_log("You ended your turn.")
	_refresh_board()


# ── Signal Handlers ───────────────────────────────────────────────────────────


func _on_phase_changed(_phase) -> void:
	var pvp_phase := game_manager.pvp_phase

	match pvp_phase:
		MultiplayerGameManager.PvPPhase.PVP_PLACEMENT:
			status_label.text = "Placement Phase — place your pieces"
			done_placing_btn.visible = true
			done_placing_btn.disabled = false
			pass_turn_btn.visible = false
			_rebuild_hand()
		MultiplayerGameManager.PvPPhase.REVEAL:
			status_label.text = "Revealing board..."
			done_placing_btn.visible = false
			pass_turn_btn.visible = false
		MultiplayerGameManager.PvPPhase.MOVEMENT:
			_update_movement_status()
			done_placing_btn.visible = false
			pass_turn_btn.visible = true
			## Clear hand display during movement
			for child in hand_grid.get_children():
				child.queue_free()
		MultiplayerGameManager.PvPPhase.SCORING:
			status_label.text = "Scoring..."
			done_placing_btn.visible = false
			pass_turn_btn.visible = false
		MultiplayerGameManager.PvPPhase.RESULT:
			done_placing_btn.visible = false
			pass_turn_btn.visible = false

	_refresh_board()


func _on_scores_ready(result: Dictionary) -> void:
	var player_score: int = result.get("player", 0)
	var enemy_score: int = result.get("enemy", 0)
	var battle_log: Array = result.get("log", [])

	## Show scores in status
	if _is_host:
		status_label.text = "Score: You %d — Opponent %d" % [player_score, enemy_score]
	else:
		status_label.text = "Score: You %d — Opponent %d" % [enemy_score, player_score]

	## Display battle log
	for entry in battle_log:
		_log(str(entry))

	## Hide game buttons, show post-game buttons
	done_placing_btn.visible = false
	pass_turn_btn.visible = false
	_show_post_game_buttons()

	_refresh_board()


func _on_match_ended(result_data: Dictionary) -> void:
	var outcome: String = result_data.get("outcome", "draw")
	var points: int = result_data.get("points_awarded", 0)

	## Award XP based on outcome (win=50, draw=25, loss=10, forfeit=0)
	var xp_earned: int = 0
	match outcome:
		"victory":
			xp_earned = 50
			status_label.text = "VICTORY! +%d points, +%d XP" % [points, xp_earned]
		"defeat":
			xp_earned = 10
			status_label.text = "DEFEAT. +%d points, +%d XP" % [points, xp_earned]
		"draw":
			xp_earned = 25
			status_label.text = "DRAW. +%d points, +%d XP" % [points, xp_earned]
		"forfeit_win":
			status_label.text = "Opponent disconnected. Win by forfeit."
		"forfeit_loss":
			status_label.text = "You disconnected. Loss by forfeit."

	if xp_earned > 0:
		PlayerData.award_xp(xp_earned)

	## Achievement tracking for multiplayer
	match outcome:
		"victory":
			Achievements.record_win(-1)  ## -1 = no specific enemy type (PvP)
			## PvP wins don't map to the single-player Pho mission types
			## (no gauntlet difficulty / enemy / terrain target), so no
			## MissionBoard hook here.
			Achievements.record_multiplayer_win()
		"defeat":
			Achievements.record_loss()

	_log("Match ended: %s" % outcome)
	_refresh_board()

	## Show post-game buttons
	done_placing_btn.visible = false
	pass_turn_btn.visible = false
	_show_post_game_buttons()


func _on_placement_rejected(reason: String) -> void:
	status_label.text = "Placement rejected: %s" % reason
	_log("[color=red]Rejected: %s[/color]" % reason)


func _on_opponent_confirmed() -> void:
	_log("Opponent confirmed placement.")


func _on_opponent_move(from: Vector2i, to: Vector2i) -> void:
	_log("Opponent moved from (%d,%d) to (%d,%d)" % [from.y, from.x, to.y, to.x])
	_refresh_board()
	_update_movement_status()


func _on_opponent_disconnected() -> void:
	status_label.text = "Opponent disconnected. Waiting for reconnect..."
	_log("[color=yellow]Opponent disconnected.[/color]")


func _on_host_disconnected() -> void:
	status_label.text = "Host disconnected. Returning to menu..."
	_log("[color=red]Host disconnected.[/color]")


# ── Helpers ───────────────────────────────────────────────────────────────────


## Returns the local player's hand based on host/guest role.
func _get_local_hand() -> Hand:
	if game_manager == null:
		return null
	if _is_host:
		return game_manager.host_hand
	else:
		return game_manager.guest_hand


## Checks if the given tile is valid for placement by this player.
## Host places on BLACK tiles (dark), guest places on WHITE tiles (light).
## No row restriction — can place anywhere on valid color tiles.
func _is_valid_placement_tile(row: int, col: int) -> bool:
	var is_dark := (row + col) % 2 == 1
	if _is_host:
		return is_dark
	else:
		return not is_dark


## Returns true if it's currently this player's turn to move.
func _is_my_turn() -> bool:
	if game_manager == null or game_manager.pvp_phase != MultiplayerGameManager.PvPPhase.MOVEMENT:
		return false
	return game_manager.movement_current_turn == _local_owner


func _update_movement_status() -> void:
	if _is_my_turn():
		status_label.text = "Movement Phase — YOUR TURN (move a piece or End Turn)"
		pass_turn_btn.disabled = false
	else:
		status_label.text = "Movement Phase — Opponent's turn"
		pass_turn_btn.disabled = true


func _log(msg: String) -> void:
	if log_label == null:
		return
	log_label.append_text(msg + "\n")


# ── Hand Sync RPCs ────────────────────────────────────────────────────────────


## Guest → Host: sends the guest's selected piece list so the host can validate placements.
## Called once when the battle scene loads on the guest side.
@rpc("any_peer", "reliable")
func _send_hand_to_host(piece_list: Array) -> void:
	if not _is_host:
		return  ## Only host processes this

	## Populate the guest's hand on the host's game manager
	var guest_hand := game_manager.guest_hand
	if guest_hand == null:
		return

	guest_hand.pieces.clear()
	for item in piece_list:
		if item is Dictionary:
			var piece_type: Piece.Type = item.get("type", 0) as Piece.Type
			var direction: PieceDefinition.Direction = item.get("direction", PieceDefinition.Direction.NONE) as PieceDefinition.Direction
			var piece := Piece.create(piece_type, Piece.Owner.ENEMY)
			piece.direction = direction
			guest_hand.pieces.append(piece)

	_log("Guest registered %d pieces." % guest_hand.pieces.size())


# ── Post-Game Buttons ─────────────────────────────────────────────────────────


## Creates and shows Rematch and Return to Menu buttons after match ends.
## Guards against being called multiple times.
var _post_game_buttons_shown: bool = false

func _show_post_game_buttons() -> void:
	if _post_game_buttons_shown:
		return
	_post_game_buttons_shown = true

	var side_panel: VBoxContainer = $Root/SidePanel

	var sep := HSeparator.new()
	sep.name = "PostGameSep"
	side_panel.add_child(sep)

	var rematch_btn := Button.new()
	rematch_btn.name = "RematchBtn"
	rematch_btn.text = "Rematch"
	rematch_btn.add_theme_font_size_override("font_size", 16)
	rematch_btn.pressed.connect(_on_rematch_pressed)
	side_panel.add_child(rematch_btn)

	var menu_btn := Button.new()
	menu_btn.name = "ReturnMenuBtn"
	menu_btn.text = "Return to Menu"
	menu_btn.add_theme_font_size_override("font_size", 16)
	menu_btn.pressed.connect(_on_return_menu_pressed)
	side_panel.add_child(menu_btn)


func _on_rematch_pressed() -> void:
	## For now, just return to piece selection (retaining connection)
	get_tree().change_scene_to_file("res://scenes/multiplayer/piece_selection.tscn")


func _on_return_menu_pressed() -> void:
	## Notify the opponent that we're leaving, then disconnect
	if multiplayer and multiplayer.has_multiplayer_peer():
		_notify_leaving.rpc()
	## Small delay to let the RPC send before closing
	await get_tree().create_timer(0.1).timeout
	NetworkManager.disconnect_from_match()
	get_tree().change_scene_to_file("res://scenes/multiplayer/multiplayer_menu.tscn")


## RPC: notifies the other player that this player is leaving the match.
## The recipient should return to menu as well.
@rpc("any_peer", "reliable")
func _notify_leaving() -> void:
	## Other player left — disconnect and return to menu
	NetworkManager.disconnect_from_match()
	get_tree().change_scene_to_file("res://scenes/multiplayer/multiplayer_menu.tscn")
