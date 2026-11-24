class_name AIWolf
extends AIBase

## Wolf AI — fully random placement and movement.
## Identical to AIRandom but exists as its own class so
## difficulty/behaviour can diverge later without touching AIRandom.

func choose_placement() -> Array:
	if hand.is_empty():
		return [-1, -1]
	var empty_cells := get_empty_valid_cells()
	if empty_cells.is_empty():
		return [-1, -1]
	empty_cells.shuffle()
	return empty_cells[0]

func choose_move(moved_pieces: Dictionary) -> Dictionary:
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
