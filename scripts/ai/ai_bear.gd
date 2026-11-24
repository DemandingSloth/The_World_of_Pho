class_name AIBear
extends AIBase

## Bear AI
## Placement: random.
## Movement:  prioritises moving Soldiers to a position directly
##            adjacent to the player's highest-scoring piece, facing it.
##            Falls back to random movement if no good target exists.

func choose_placement() -> Array:
	if hand.is_empty():
		return [-1, -1]
	var empty_cells := get_empty_valid_cells()
	if empty_cells.is_empty():
		return [-1, -1]
	empty_cells.shuffle()
	return empty_cells[0]

func choose_move(moved_pieces: Dictionary) -> Dictionary:
	## Try to move a Soldier into attack position first
	var attack_move := _try_soldier_attack(moved_pieces)
	if not attack_move.is_empty():
		return attack_move
	## Fall back to random
	return _random_move(moved_pieces)

## Find the player's highest base-point piece, then try to place a
## Soldier adjacent to it facing toward it for the debuff.
func _try_soldier_attack(moved_pieces: Dictionary) -> Dictionary:
	## Find player's highest value piece
	var player_pieces := board.get_all_pieces(Piece.Owner.PLAYER)
	if player_pieces.is_empty():
		return {}

	player_pieces.sort_custom(func(a, b):
		return a[0].base_points > b[0].base_points)
	var best_entry  = player_pieces[0]
	var target_row: int = best_entry[1]
	var target_col: int = best_entry[2]

	## Try each direction adjacent to the target
	var attempts := [
		[target_row - 1, target_col, PieceDefinition.Direction.SOUTH],
		[target_row + 1, target_col, PieceDefinition.Direction.NORTH],
		[target_row, target_col + 1, PieceDefinition.Direction.WEST],
		[target_row, target_col - 1, PieceDefinition.Direction.EAST],
	]

	var own := get_own_pieces()
	own.shuffle()
	for entry in own:
		var piece: Piece = entry[0]
		var row: int     = entry[1]
		var col: int     = entry[2]
		if piece.type != Piece.Type.SOLDIER:
			continue
		if moved_pieces.has(piece):
			continue
		for attempt in attempts:
			var dest_r: int = attempt[0]
			var dest_c: int = attempt[1]
			var dir: PieceDefinition.Direction = attempt[2]
			if not BoardState.in_bounds(dest_r, dest_c):
				continue
			if not BoardState.is_valid_tile(dest_r, dest_c, owner):
				continue
			var occ := board.get_piece(dest_r, dest_c)
			if occ != null and (occ.owner != owner or moved_pieces.has(occ)):
				continue
			piece.direction = dir
			return { "from": [row, col], "to": [dest_r, dest_c] }

	return {}

func _random_move(moved_pieces: Dictionary) -> Dictionary:
	var own := get_own_pieces()
	var movable := own.filter(func(e): return not moved_pieces.has(e[0]))
	if movable.is_empty():
		return {}
	movable.shuffle()

	for entry in movable:
		var row: int = entry[1]
		var col: int = entry[2]
		var destinations := _get_destinations(row, col, moved_pieces)
		if destinations.is_empty():
			continue
		destinations.shuffle()
		return { "from": [row, col], "to": destinations[0] }
	return {}

func _get_destinations(row: int, col: int, moved_pieces: Dictionary) -> Array:
	var result := []
	for r in range(BoardState.BOARD_SIZE):
		for c in range(BoardState.BOARD_SIZE):
			if r == row and c == col:
				continue
			if not BoardState.is_valid_tile(r, c, owner):
				continue
			var occ := board.get_piece(r, c)
			if occ == null or (occ.owner == owner and not moved_pieces.has(occ)):
				result.append([r, c])
	return result
