class_name Movement
extends RefCounted

## Tracks the movement phase state.
## Two rounds total. Each round: first_mover moves, then second_mover moves.
## A piece can only move once across both rounds.

enum MoveResult {
	OK,
	PIECE_ALREADY_MOVED,
	INVALID_DESTINATION,
	NOT_YOUR_TURN,
	PHASE_OVER,
}

var board: BoardState

## Which owner moves first (determined by coin flip)
var first_mover: Piece.Owner
var second_mover: Piece.Owner

## Current round (1 or 2)
var current_round: int = 1

## Whose turn it is this half-turn
var current_turn: Piece.Owner

## Tracks which pieces have already moved: piece -> true
var moved_pieces: Dictionary = { }

## Whether the movement phase is complete
var phase_complete: bool = false


func _init(p_board: BoardState) -> void:
	board = p_board


## Coin flip to decide who goes first. Returns the first mover.
func coin_flip() -> Piece.Owner:
	first_mover = Piece.Owner.PLAYER if randi() % 2 == 0 else Piece.Owner.ENEMY
	second_mover = Piece.Owner.ENEMY if first_mover == Piece.Owner.PLAYER else Piece.Owner.PLAYER
	current_turn = first_mover
	current_round = 1
	phase_complete = false
	moved_pieces.clear()
	return first_mover


## Attempt to move a piece from (from_r, from_c) to (to_r, to_c).
## If to cell is occupied by an allied piece, swap them.
## If to cell is empty, move there.
## Returns a MoveResult.
func attempt_move(owner: Piece.Owner, from_r: int, from_c: int, to_r: int, to_c: int) -> MoveResult:
	if phase_complete:
		return MoveResult.PHASE_OVER
	if owner != current_turn:
		return MoveResult.NOT_YOUR_TURN

	var piece = board.get_piece(from_r, from_c)
	if piece == null or piece.owner != owner:
		return MoveResult.INVALID_DESTINATION
	if moved_pieces.has(piece):
		return MoveResult.PIECE_ALREADY_MOVED

	var target = board.get_piece(to_r, to_c)

	## Destination must be valid for this owner's colour
	if not BoardState.is_valid_tile(to_r, to_c, owner):
		return MoveResult.INVALID_DESTINATION

	var success := false
	if target == null:
		success = board.move_piece(from_r, from_c, to_r, to_c)
	elif target.owner == owner:
		## Swap with allied piece — mark both as moved
		success = board.swap_pieces(from_r, from_c, to_r, to_c)
		if success:
			moved_pieces[target] = true
	else:
		## Cannot move onto enemy squares
		return MoveResult.INVALID_DESTINATION

	if not success:
		return MoveResult.INVALID_DESTINATION

	moved_pieces[piece] = true
	_advance_turn()
	return MoveResult.OK


## Advance turn order:
## Round 1: first_mover → second_mover → (round 2)
## Round 2: first_mover → second_mover → phase complete
## Skips a player's turn if they have no unmoved pieces on the board.
func _advance_turn() -> void:
	if current_turn == first_mover:
		current_turn = second_mover
		if not _has_movable_pieces(second_mover):
			_end_round()
	else:
		_end_round()


func _end_round() -> void:
	if current_round >= 2:
		phase_complete = true
	else:
		current_round += 1
		current_turn = first_mover
		if not _has_movable_pieces(first_mover):
			current_turn = second_mover
			if not _has_movable_pieces(second_mover):
				phase_complete = true


## Returns true if the given owner has at least one piece that hasn't moved yet.
func _has_movable_pieces(owner: Piece.Owner) -> bool:
	for entry in board.get_all_pieces(owner):
		var piece: Piece = entry[0]
		if not moved_pieces.has(piece):
			return true
	return false


func get_turn_label() -> String:
	if phase_complete:
		return "Movement phase complete"
	var name = "Player" if current_turn == Piece.Owner.PLAYER else "Enemy"
	return "Round %d — %s's turn" % [current_round, name]
