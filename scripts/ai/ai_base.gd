class_name AIBase
extends RefCounted

## Base class for all AI difficulty levels.
## Subclasses override the three virtual methods below.
## The GameManager calls these at the appropriate phase.

var board: BoardState
var hand: Hand
var owner: Piece.Owner = Piece.Owner.ENEMY

func _init(p_board: BoardState, p_hand: Hand, p_owner: Piece.Owner = Piece.Owner.ENEMY) -> void:
	board = p_board
	hand  = p_hand
	owner = p_owner

## Called once per piece during the placement phase.
## Returns [row, col] to place the next piece in hand, or [-1, -1] to skip.
## The GameManager will call this repeatedly until the hand is empty or [-1,-1] is returned.
func choose_placement() -> Array:
	push_error("AIBase.choose_placement() not implemented")
	return [-1, -1]

## Called once per movement turn.
## moved_pieces: Dictionary of piece -> true for pieces that have already moved.
## Returns { "from": [row, col], "to": [row, col] } or {} to pass.
func choose_move(moved_pieces: Dictionary) -> Dictionary:
	push_error("AIBase.choose_move() not implemented")
	return {}

## Utility — returns all empty valid cells for this owner
func get_empty_valid_cells() -> Array:
	var cells = []
	for r in range(BoardState.BOARD_SIZE):
		for c in range(BoardState.BOARD_SIZE):
			if BoardState.is_valid_tile(r, c, owner) and board.get_piece(r, c) == null:
				cells.append([r, c])
	return cells

## Utility — returns all [piece, row, col] entries for this owner
func get_own_pieces() -> Array:
	return board.get_all_pieces(owner)
