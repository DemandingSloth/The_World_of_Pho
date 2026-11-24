class_name AIRandom
extends AIBase

## Difficulty: Random
## Placement — picks a random valid empty cell for each piece.
## Movement   — picks a random piece that hasn't moved, moves it to a random valid cell
##              (or swaps with a random allied piece if no empty cells available).

func choose_placement() -> Array:
	if hand.is_empty():
		return [-1, -1]

	var empty_cells = get_empty_valid_cells()
	if empty_cells.is_empty():
		return [-1, -1]

	## Pick a random cell
	empty_cells.shuffle()
	return empty_cells[0]

func choose_move(moved_pieces: Dictionary) -> Dictionary:
	var own = get_own_pieces()

	## Filter out already-moved pieces
	var movable = own.filter(func(entry): return not moved_pieces.has(entry[0]))
	if movable.is_empty():
		return {}

	movable.shuffle()

	## Try each movable piece until we find a valid move
	for entry in movable:
		var row: int = entry[1]
		var col: int = entry[2]

		## Build candidate destinations: empty valid cells + allied occupied cells (swaps)
		var destinations = []

		for r in range(BoardState.BOARD_SIZE):
			for c in range(BoardState.BOARD_SIZE):
				if r == row and c == col:
					continue
				if not BoardState.is_valid_tile(r, c, owner):
					continue
				var occupant = board.get_piece(r, c)
				if occupant == null:
					destinations.append([r, c])
				elif occupant.owner == owner and not moved_pieces.has(occupant):
					destinations.append([r, c])

		if destinations.is_empty():
			continue

		destinations.shuffle()
		return { "from": [row, col], "to": destinations[0] }

	return {}
