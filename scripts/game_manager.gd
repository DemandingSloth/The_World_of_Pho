class_name GameManager
extends Node

enum Phase {
	CAMPAIGN_SETUP,  ## Player picks enemy count and terrain
	BATTLE_PREP,     ## Player selects tiles from pool to bring into battle
	PLACEMENT,       ## Player places selected tiles on board
	MOVEMENT,        ## Two rounds of movement
	SCORING,         ## Calculate and display final scores
	BATTLE_RESULT,   ## Show result, prompt continue or end
	RUN_COMPLETE,    ## All enemies defeated
	GAME_OVER,       ## Player lost a battle — run ends
}

signal phase_changed(new_phase: Phase)
signal board_updated
signal scores_ready(result: Dictionary)
signal turn_changed(label: String)
signal campaign_updated
## Emitted for each piece the wind tried to push but couldn't move anywhere
## (blocked in all directions). The board view plays a "spin in place" animation
## on the tile at (row, col).
signal wind_spun(row: int, col: int)

var board: BoardState
var player_hand: Hand
var enemy_hand: Hand
var movement: Movement
var ai: AIBase
var campaign: CampaignManager
var current_phase: Phase = Phase.CAMPAIGN_SETUP
var current_terrain: Terrain.Type = Terrain.Type.INDOORS

var placement_turn: Piece.Owner = Piece.Owner.PLAYER
var selected_piece: Piece = null
var last_coin_reward: int = 0
var current_enemy_count: int = 1  ## track for reward calculation

const AI_ACTION_DELAY := 0.4

func _ready() -> void:
	campaign = CampaignManager.new()

## ── CAMPAIGN SETUP ─────────────────────────────────────────────

func start_campaign(enemy_count: int, terrain: Terrain.Type, forced_enemy: EnemyDefinitions.EnemyType = -1) -> void:
	current_terrain = terrain
	current_enemy_count = enemy_count
	last_coin_reward = 0

	## Build player pool from persistent inventory
	campaign.start_campaign_from_inventory(enemy_count, forced_enemy)
	_save_campaign_state()
	_auto_select_all_pieces()
	_start_battle()

## Resumes an in-progress gauntlet after a battle→result→battle transition.
## Restores the enemy sequence and progress from PlayerData.active_campaign,
## rebuilds the pool from current inventory, and starts the next battle.
func resume_campaign() -> void:
	var state: Dictionary = PlayerData.active_campaign
	if state.is_empty():
		## No run in progress — nothing to resume. Caller should start fresh.
		return
	current_terrain = int(state.get("terrain", Terrain.Type.INDOORS)) as Terrain.Type
	current_enemy_count = int(state.get("enemy_count", 1))
	last_coin_reward = 0

	## Restore campaign run progress, then rebuild the pool from inventory.
	campaign.enemy_sequence = (state.get("enemy_sequence", []) as Array).duplicate()
	campaign.current_battle = int(state.get("current_battle", 0))
	campaign.wins = int(state.get("wins", 0))
	campaign.losses = int(state.get("losses", 0))
	campaign.is_active = true
	campaign.rebuild_pool_from_inventory()

	_auto_select_all_pieces()
	_start_battle()

## Snapshots the current gauntlet progress to PlayerData so it survives the
## destruction of this scene's GameManager/CampaignManager between battles.
func _save_campaign_state() -> void:
	PlayerData.active_campaign = {
		"enemy_sequence": campaign.enemy_sequence.duplicate(),
		"current_battle": campaign.current_battle,
		"wins": campaign.wins,
		"losses": campaign.losses,
		"enemy_count": current_enemy_count,
		"terrain": int(current_terrain),
	}

## ── BATTLE PREP ────────────────────────────────────────────────

func _auto_select_all_pieces() -> void:
	campaign.battle_hand = []
	var pool_copy := campaign.player_pool.duplicate()
	for piece in pool_copy:
		campaign.select_for_battle(piece)

func select_pool_piece(piece: Piece) -> bool:
	if current_phase != Phase.BATTLE_PREP:
		return false
	var ok := campaign.select_for_battle(piece)
	if ok:
		emit_signal("campaign_updated")
	return ok

func deselect_pool_piece(piece: Piece) -> void:
	if current_phase != Phase.BATTLE_PREP:
		return
	campaign.deselect_from_battle(piece)
	emit_signal("campaign_updated")

func confirm_battle_selection() -> void:
	if current_phase != Phase.BATTLE_PREP:
		return
	_start_battle()

## ── BATTLE START ───────────────────────────────────────────────

func _start_battle() -> void:
	board = BoardState.new()

	## Build player hand from the campaign battle selection
	player_hand = Hand.new()
	for p in campaign.battle_hand:
		player_hand.pieces.append(p)

	## Build enemy hand from enemy definitions
	var enemy_type := campaign.get_current_enemy_type()
	enemy_hand = EnemyDefinitions.build_hand(enemy_type)

	movement = Movement.new(board)
	ai = _build_ai_for_enemy(enemy_type)
	current_phase = Phase.PLACEMENT
	placement_turn = Piece.Owner.ENEMY
	selected_piece = null

	emit_signal("phase_changed", current_phase)
	emit_signal("turn_changed", "Enemy is placing pieces...")
	emit_signal("board_updated")
	_run_ai_placement()

func _build_ai_for_enemy(t: EnemyDefinitions.EnemyType) -> AIBase:
	match t:
		EnemyDefinitions.EnemyType.WOLF:
			return AIWolf.new(board, enemy_hand, Piece.Owner.ENEMY)
		EnemyDefinitions.EnemyType.BEAR:
			return AIBear.new(board, enemy_hand, Piece.Owner.ENEMY)
		EnemyDefinitions.EnemyType.NPC:
			return AINPC.new(board, enemy_hand, Piece.Owner.ENEMY)
		_:
			return AIWolf.new(board, enemy_hand, Piece.Owner.ENEMY)

## ── PLACEMENT ──────────────────────────────────────────────────

func select_hand_piece(piece: Piece) -> void:
	if current_phase != Phase.PLACEMENT:
		return
	selected_piece = piece

func place_selected_piece(row: int, col: int) -> bool:
	if current_phase != Phase.PLACEMENT:
		return false
	if selected_piece == null:
		return false

	## Only the side whose turn it is may place. If the player selected a piece
	## while the enemy was still placing, tapping the board is a no-op until it's
	## the player's turn — WITHOUT clearing the selection (so the piece stays
	## picked and placement works the moment the enemy finishes).
	if placement_turn != selected_piece.owner:
		return false

	## Use the hand matching the selected piece's owner (not placement_turn),
	## so a stale placement_turn can't point at the wrong hand.
	var hand := _get_hand(selected_piece.owner)
	var idx := hand.pieces.find(selected_piece)
	if idx == -1:
		## Selection is genuinely no longer in hand — clear it.
		selected_piece = null
		return false

	if not BoardState.in_bounds(row, col):
		return false
	if not BoardState.is_valid_tile(row, col, selected_piece.owner):
		return false
	if board.get_piece(row, col) != null:
		return false

	## Enforce one King per board. The player can hold multiple Kings in hand
	## (so the inventory count is visible), but only one may be placed.
	if selected_piece.type == Piece.Type.KING and _has_king_on_board(selected_piece.owner):
		emit_signal("turn_changed", "You can only place one King on the board.")
		return false

	var piece := hand.take_piece(idx)
	board.place_piece(piece, row, col)

	## Consume the tile from persistent inventory the moment the player commits
	## it to the board. Doing it here (rather than scanning survivors at scoring
	## time) guarantees the tile is spent even if the battle is forfeited/quit or
	## the tile is later captured or pushed off the board.
	if piece.owner == Piece.Owner.PLAYER:
		PlayerData.consume_one_piece(int(piece.type), int(piece.direction))

	## Wind effect: on Desert terrain, blow adjacent tiles one space away
	if piece.type == Piece.Type.WIND and current_terrain == Terrain.Type.DESERT:
		_apply_wind_push(row, col)
		Achievements.record_wind_activated_desert()

	selected_piece = null
	emit_signal("board_updated")
	_advance_placement_turn()
	return true

func _advance_placement_turn() -> void:
	if placement_turn == Piece.Owner.PLAYER and player_hand.is_empty():
		_start_movement_phase()

func _get_hand(owner: Piece.Owner) -> Hand:
	return player_hand if owner == Piece.Owner.PLAYER else enemy_hand

## True if the given owner already has a King placed on the board.
func _has_king_on_board(owner: Piece.Owner) -> bool:
	for entry in board.get_all_pieces(owner):
		var p: Piece = entry[0]
		if p != null and p.type == Piece.Type.KING:
			return true
	return false

const MIN_PLAYER_PIECES := 3

func rotate_piece(piece: Piece) -> bool:
	if piece == null or not piece.is_rotatable():
		return false
	if current_phase == Phase.PLACEMENT:
		piece.rotate_cw()
		emit_signal("board_updated")
		return true
	elif current_phase == Phase.MOVEMENT:
		if piece.owner != movement.current_turn:
			return false
		## Rotation is free — doesn't consume the move
		piece.rotate_cw()
		emit_signal("board_updated")
		return true
	return false

## Confirm rotation — no longer consumes a move, just finalizes the visual
func confirm_rotation(piece: Piece) -> void:
	if current_phase != Phase.MOVEMENT:
		return
	if piece == null:
		return
	## Rotation is free, so we just emit board_updated (no turn advance)
	emit_signal("board_updated")

func pass_turn() -> void:
	if current_phase != Phase.MOVEMENT:
		return
	movement._advance_turn()
	emit_signal("board_updated")
	_post_move_check()

func finish_placement() -> void:
	if current_phase != Phase.PLACEMENT:
		return
	var placed_count := board.get_all_pieces(Piece.Owner.PLAYER).size()
	if placed_count < MIN_PLAYER_PIECES:
		emit_signal("turn_changed", "Place at least %d pieces before moving on!" % MIN_PLAYER_PIECES)
		return
	_start_movement_phase()


## Forfeits the current battle (used when player doesn't have enough pieces).
## Transitions directly to GAME_OVER phase.
func forfeit_battle() -> void:
	current_phase = Phase.GAME_OVER
	emit_signal("phase_changed", current_phase)

func _run_ai_placement() -> void:
	if current_phase != Phase.PLACEMENT:
		return
	if enemy_hand.is_empty():
		_start_player_placement()
		return

	var cell = ai.choose_placement()
	if cell[0] == -1:
		_start_player_placement()
		return

	var piece_idx := 0
	if cell.size() >= 3 and cell[2] >= 0 and cell[2] < enemy_hand.pieces.size():
		piece_idx = cell[2]

	var piece = enemy_hand.take_piece(piece_idx)
	if piece == null:
		_start_player_placement()
		return

	var placed := board.place_piece(piece, cell[0], cell[1])
	if not placed:
		## Fallback: try any empty valid cell on the board
		var placed_fallback := false
		for r in range(BoardState.BOARD_SIZE):
			for c in range(BoardState.BOARD_SIZE):
				if board.place_piece(piece, r, c):
					placed_fallback = true
					break
			if placed_fallback:
				break
		if not placed_fallback:
			enemy_hand.return_piece(piece)
			_start_player_placement()
			return

	emit_signal("board_updated")

	if enemy_hand.is_empty():
		_start_player_placement()
	else:
		get_tree().create_timer(AI_ACTION_DELAY).timeout.connect(_run_ai_placement)

func _start_player_placement() -> void:
	placement_turn = Piece.Owner.PLAYER
	emit_signal("turn_changed", "Your turn to place pieces.")
	emit_signal("board_updated")

## ── MOVEMENT ───────────────────────────────────────────────────

func _start_movement_phase() -> void:
	current_phase = Phase.MOVEMENT
	var first = movement.coin_flip()

	if movement.phase_complete:
		_start_scoring()
		return

	if not movement._has_movable_pieces(first):
		movement.current_turn = movement.second_mover
		if not movement._has_movable_pieces(movement.second_mover):
			movement.phase_complete = true
			_start_scoring()
			return

	var label = "Coin flip! %s moves first." % \
		("Player" if first == Piece.Owner.PLAYER else "Enemy")
	emit_signal("phase_changed", current_phase)
	emit_signal("turn_changed", label)
	emit_signal("board_updated")
	if movement.current_turn == Piece.Owner.ENEMY:
		get_tree().create_timer(AI_ACTION_DELAY).timeout.connect(_run_ai_move)

func attempt_move(owner: Piece.Owner, from_r: int, from_c: int,
		to_r: int, to_c: int) -> Movement.MoveResult:
	if current_phase != Phase.MOVEMENT:
		return Movement.MoveResult.PHASE_OVER
	var result = movement.attempt_move(owner, from_r, from_c, to_r, to_c)
	## Wind effect: if a Wind piece moved onto a new cell on Desert, push neighbors
	if result == Movement.MoveResult.OK and current_terrain == Terrain.Type.DESERT:
		var moved_piece := board.get_piece(to_r, to_c)
		if moved_piece != null and moved_piece.type == Piece.Type.WIND:
			_apply_wind_push(to_r, to_c)
			Achievements.record_wind_activated_desert()
	emit_signal("board_updated")
	_post_move_check()
	return result

func _run_ai_move() -> void:
	if current_phase != Phase.MOVEMENT:
		return
	if movement.current_turn != Piece.Owner.ENEMY:
		return
	if not movement._has_movable_pieces(Piece.Owner.ENEMY):
		movement._advance_turn()
		emit_signal("board_updated")
		_post_move_check()
		return
	var move_data = ai.choose_move(movement.moved_pieces)
	if move_data.is_empty():
		movement._advance_turn()
		emit_signal("board_updated")
		_post_move_check()
		return
	var from: Array = move_data["from"]
	var to: Array   = move_data["to"]
	var result = movement.attempt_move(Piece.Owner.ENEMY, from[0], from[1], to[0], to[1])
	if result != Movement.MoveResult.OK:
		push_warning("AI move failed: %s" % Movement.MoveResult.keys()[result])
	emit_signal("board_updated")
	_post_move_check()

func _post_move_check() -> void:
	if movement.phase_complete:
		_start_scoring()
		return
	if movement.current_turn == Piece.Owner.PLAYER \
	   and not movement._has_movable_pieces(Piece.Owner.PLAYER):
		movement._advance_turn()
		emit_signal("board_updated")
		_post_move_check()
		return
	emit_signal("turn_changed", movement.get_turn_label())
	if movement.current_turn == Piece.Owner.ENEMY:
		get_tree().create_timer(AI_ACTION_DELAY).timeout.connect(_run_ai_move)

## ── SCORING ────────────────────────────────────────────────────

func _start_scoring() -> void:
	current_phase = Phase.SCORING
	emit_signal("phase_changed", current_phase)
	## Spiced Pho Noodle Bowl recipe boost ("Pho Focus"): +1 to each non-pawn
	## PLAYER tile for the next few games (count-limited). Single-player only —
	## multiplayer scoring is host-authoritative and must stay unmodified.
	var tile_bonus := 0
	if get_node_or_null("/root/PlayerData") != null and PlayerData.boost_active("pho_focus"):
		tile_bonus = int(PlayerData.boost_value("pho_focus"))
		PlayerData.consume_boost_use("pho_focus")
	var result = Scoring.calculate_scores(board, current_terrain, tile_bonus)
	emit_signal("scores_ready", result)

## Called by UI after scores are shown — resolves battle and advances campaign
func confirm_result(player_score: int, enemy_score: int) -> void:
	var placed: Array[Piece] = []
	for entry in board.get_all_pieces(Piece.Owner.PLAYER):
		placed.append(entry[0])

	var player_won := player_score >= enemy_score

	## NOTE: Tiles are consumed at placement time (see place_selected_piece),
	## not here. Scanning survivors at scoring time missed tiles that were
	## captured/removed mid-battle or when a battle ended via forfeit/quit,
	## causing spent tiles to reappear in the next battle.

	## Achievement tracking
	Achievements.record_terrain_played(int(current_terrain))
	if player_won:
		var enemy_type: int = campaign.get_current_enemy_type() if campaign else 0
		Achievements.record_win(enemy_type)
		Achievements.check_post_scoring(board, current_terrain)
		## Per-battle mission progress: beat-enemy and win-on-terrain.
		MissionBoard.on_battle_won(enemy_type, int(current_terrain))
	else:
		Achievements.record_loss()

	## Check for Location Luster (terrain bonus activated)
	for entry in board.get_all_pieces(Piece.Owner.PLAYER):
		var piece: Piece = entry[0]
		var def := PieceRegistry.get_def(piece.type)
		if def and def.terrain_bonuses.has(int(current_terrain)):
			Achievements.record_terrain_bonus_activated()
			break

	## No per-battle coin reward — coins only awarded on full gauntlet completion
	last_coin_reward = 0

	campaign.resolve_battle(placed, player_won)

	if not player_won:
		## Run ended in defeat — clear the persisted run so the next battle starts fresh.
		PlayerData.active_campaign = {}
		current_phase = Phase.GAME_OVER
		emit_signal("phase_changed", current_phase)
		emit_signal("campaign_updated")
	elif campaign.is_run_complete():
		## Gauntlet complete — award coins now and clear the persisted run.
		last_coin_reward = PlayerData.award_win(current_enemy_count)
		## Full-game mission progress (GAME_EASY/MEDIUM/HARD/BRUTAL by difficulty).
		MissionBoard.on_run_completed(current_enemy_count)
		PlayerData.active_campaign = {}
		current_phase = Phase.RUN_COMPLETE
		emit_signal("phase_changed", current_phase)
		emit_signal("campaign_updated")
	else:
		## More battles remain — persist progress so the next battle scene
		## (a fresh GameManager/CampaignManager) can resume this same gauntlet.
		_save_campaign_state()
		current_phase = Phase.BATTLE_RESULT
		emit_signal("phase_changed", current_phase)
		emit_signal("campaign_updated")

## Called by UI when player clicks Next Battle — rebuild pool from persistent inventory
func advance_to_next_battle() -> void:
	selected_piece = null
	## Rebuild campaign pool from current persistent inventory
	campaign.rebuild_pool_from_inventory()
	_auto_select_all_pieces()
	_start_battle()

## ── UTILITIES ──────────────────────────────────────────────────

func get_current_turn_label() -> String:
	match current_phase:
		Phase.PLACEMENT:
			return "%s placing pieces" % \
				("Player" if placement_turn == Piece.Owner.PLAYER else "Enemy")
		Phase.MOVEMENT:
			return movement.get_turn_label()
		Phase.SCORING:
			return "Calculating scores..."
		Phase.BATTLE_RESULT:
			return "Battle resolved."
	return ""

func get_battle_header() -> String:
	if not campaign.is_active:
		return ""
	if campaign.is_run_complete():
		return "Campaign Complete — %d / %d won" % [campaign.wins, campaign.enemy_sequence.size()]
	return "Battle %d / %d  —  %s" % [
		campaign.current_battle + 1,
		campaign.enemy_sequence.size(),
		campaign.get_current_enemy_name()
	]

## ── WIND PUSH ──────────────────────────────────────────────────
## Blows each adjacent tile away from Wind. Only active on Desert terrain.
## Cardinal (N/S/E/W): the adjacent piece is on the opposite color.
##   - Push it to the nearest valid-color empty tile in that direction (skip 1 for same-owner, skip 1 for different-owner).
## Diagonal: the adjacent piece is on the same color, push 1 space further diagonally.

func _apply_wind_push(wind_row: int, wind_col: int) -> void:
	## Cardinal offsets — the push-away direction for a cardinally-adjacent piece.
	var cardinal_offsets := [
		[-1, 0],  ## North
		[1, 0],   ## South
		[0, -1],  ## West
		[0, 1],   ## East
	]
	## Diagonal offsets — the push-away direction for a diagonally-adjacent piece.
	var diagonal_offsets := [
		[-1, -1], [-1, 1],
		[1, -1],  [1, 1],
	]

	var pushes: Array = []      ## [[from_r, from_c, to_r, to_c]]
	var spun: Array = []        ## [[r, c]] pieces that couldn't move (spin in place)
	## Tiles already claimed as a landing this activation, so two pushed pieces
	## can't be routed onto the same tile.
	var claimed: Dictionary = {}

	## Process every adjacent piece (cardinal + diagonal) the same way: try the
	## away direction first, then the two perpendicular directions (random order),
	## and if nothing is free, spin in place.
	for offset in cardinal_offsets + diagonal_offsets:
		var nr: int = wind_row + offset[0]
		var nc: int = wind_col + offset[1]
		if not BoardState.in_bounds(nr, nc):
			continue
		var target := board.get_piece(nr, nc)
		if target == null:
			continue

		## Build the ordered list of directions to try: away first, then the two
		## perpendiculars in a random order.
		var perp_a := [offset[1], offset[0]]      ## rotate 90°
		var perp_b := [-offset[1], -offset[0]]     ## rotate -90°
		var dirs: Array = [offset]
		if randi() % 2 == 0:
			dirs.append(perp_a); dirs.append(perp_b)
		else:
			dirs.append(perp_b); dirs.append(perp_a)

		var landed := false
		for dir in dirs:
			var land := _wind_find_landing(nr, nc, dir, target.owner, claimed)
			if not land.is_empty():
				pushes.append([nr, nc, land[0], land[1]])
				claimed["%d_%d" % [land[0], land[1]]] = true
				landed = true
				break
		if not landed:
			spun.append([nr, nc])

	## Apply moves, then notify the view of any pieces that spun in place.
	for push in pushes:
		board.move_piece(push[0], push[1], push[2], push[3])
	for s in spun:
		emit_signal("wind_spun", s[0], s[1])


## Finds where a pushed piece lands when blown in `dir` from (from_r, from_c):
## walks outward to the FIRST tile of the piece's valid (placeable) color, and
## returns [row, col] if that tile is empty and unclaimed, else [] (blocked).
## This guarantees the piece only ever lands on a tile it could have been played on.
func _wind_find_landing(from_r: int, from_c: int, dir: Array, owner: Piece.Owner, claimed: Dictionary) -> Array:
	var check_r: int = from_r + dir[0]
	var check_c: int = from_c + dir[1]
	while BoardState.in_bounds(check_r, check_c):
		if BoardState.is_valid_tile(check_r, check_c, owner):
			## First valid-color tile in this direction — usable only if empty
			## and not already claimed by another pushed piece this activation.
			var key := "%d_%d" % [check_r, check_c]
			if board.get_piece(check_r, check_c) == null and not claimed.has(key):
				return [check_r, check_c]
			return []  ## blocked at the first legal-color tile
		check_r += dir[0]
		check_c += dir[1]
	return []  ## walked off the board (wall) with no legal tile
