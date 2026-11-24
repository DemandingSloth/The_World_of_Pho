class_name AINPC
extends AIBase

## NPC AI — intelligent placement and movement.
##
## PLACEMENT PRIORITIES (in order):
##   1. Place King only if 4 diagonal neighbours are already allied Soldiers
##   2. Place Soldiers diagonally adjacent to an already-placed allied King
##   3. Place Mage where it will negate the player's highest-value piece (rotates to face target)
##   4. Place Clergy where it buffs the most allied diagonals
##   5. Place Watchtower in a corner if available
##   6. Fall back to random placement
##
## MOVEMENT PRIORITIES (in order):
##   1. Move a Mage to negate the player's highest-value piece (rotates to face)
##   2. Complete King guard (move Soldier to fill a King's empty diagonal)
##   3. Move Druid adjacent to the player's cluster of highest-value pieces
##   4. Fall back to random

func choose_placement() -> Array:
	if hand.is_empty():
		return [-1, -1]

	## Try each strategy in priority order (enemy places BEFORE player — no targeting)
	var result := _try_place_watchtower_corner()
	if result[0] != -1: return result

	result = _try_place_king_guard()
	if result[0] != -1: return result

	result = _try_place_king_if_ready()
	if result[0] != -1: return result

	result = _try_place_clergy()
	if result[0] != -1: return result

	return _random_placement()

func choose_move(moved_pieces: Dictionary) -> Dictionary:
	var result := _try_move_negator(moved_pieces)
	if not result.is_empty(): return result

	result = _try_move_sleep(moved_pieces)
	if not result.is_empty(): return result

	result = _try_complete_king_guard(moved_pieces)
	if not result.is_empty(): return result

	result = _try_move_druid(moved_pieces)
	if not result.is_empty(): return result

	return _random_move(moved_pieces)

## ── Placement strategies ───────────────────────────────────────

func _try_place_king_if_ready() -> Array:
	var king_idx := _find_in_hand(Piece.Type.KING)
	if king_idx == -1:
		return [-1, -1]
	for cell in get_empty_valid_cells():
		var r: int = cell[0]
		var c: int = cell[1]
		if _king_condition_met_at(r, c):
			return [r, c, king_idx]
	return [-1, -1]

func _king_condition_met_at(row: int, col: int) -> bool:
	var offsets := [[-1,-1],[-1,1],[1,1],[1,-1]]
	for o in offsets:
		var p := board.get_piece(row + o[0], col + o[1])
		if p == null or p.owner != owner:
			return false
		if p.type != Piece.Type.SOLDIER:
			return false
	return true

## Place a Soldier diagonally adjacent to an existing allied King
func _try_place_king_guard() -> Array:
	var king_pos := _find_own_piece_on_board(Piece.Type.KING)
	if king_pos[0] == -1:
		return [-1, -1]
	var soldier_idx := _find_in_hand(Piece.Type.SOLDIER)
	if soldier_idx == -1:
		return [-1, -1]
	var offsets := [[-1,-1],[-1,1],[1,1],[1,-1]]
	for o in offsets:
		var r: int = king_pos[0] + int(o[0])
		var c: int = king_pos[1] + int(o[1])
		if BoardState.in_bounds(r, c) and BoardState.is_valid_tile(r, c, owner) \
		   and board.get_piece(r, c) == null:
			return [r, c, soldier_idx]
	return [-1, -1]

## Place Clergy where it buffs the most allied diagonal neighbours
func _try_place_clergy() -> Array:
	var clergy_idx := _find_in_hand(Piece.Type.CLERGY)
	if clergy_idx == -1:
		return [-1, -1]
	var best_cell := [-1, -1]
	var best_count := 0
	for cell in get_empty_valid_cells():
		var r: int = cell[0]
		var c: int = cell[1]
		var count := 0
		for diag in board.get_diagonals(r, c):
			if diag != null and diag.owner == owner:
				count += 1
		if count > best_count:
			best_count = count
			best_cell = cell
	return [best_cell[0], best_cell[1], clergy_idx] if best_count > 0 else [-1, -1]

## Place Watchtower in a corner
func _try_place_watchtower_corner() -> Array:
	var wt_idx := _find_in_hand(Piece.Type.WATCHTOWER)
	if wt_idx == -1:
		return [-1, -1]
	var max_idx := BoardState.BOARD_SIZE - 1
	var corners := [[0,0], [0,max_idx], [max_idx,0], [max_idx,max_idx]]
	for corner in corners:
		var r: int = corner[0]
		var c: int = corner[1]
		if BoardState.in_bounds(r, c) and BoardState.is_valid_tile(r, c, owner) and board.get_piece(r, c) == null:
			return [r, c, wt_idx]
	return [-1, -1]

func _random_placement() -> Array:
	var cells := get_empty_valid_cells()
	if cells.is_empty():
		return [-1, -1]
	cells.shuffle()
	return [cells[0][0], cells[0][1], 0]

## ── Movement strategies ────────────────────────────────────────

## Move a Mage adjacent to the player's highest piece and rotate to face it
func _try_move_negator(moved_pieces: Dictionary) -> Dictionary:
	var target := _get_player_highest()
	if target.is_empty():
		return {}
	var tr: int = target["row"]
	var tc: int = target["col"]

	var own := get_own_pieces()
	own.shuffle()
	for entry in own:
		var piece: Piece = entry[0]
		var row: int     = entry[1]
		var col: int     = entry[2]
		if moved_pieces.has(piece):
			continue
		if piece.type != Piece.Type.MAGE:
			continue

		## Try to place adjacent to target facing it
		## AI only negates from above (facing SOUTH) or from the left (facing EAST)
		var attempts := [
			[tr - 1, tc, PieceDefinition.Direction.SOUTH],
			[tr, tc - 1, PieceDefinition.Direction.EAST],
		]
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

## Move Sleep tile to the area with the most player pieces adjacent
func _try_move_sleep(moved_pieces: Dictionary) -> Dictionary:
	var sleep_entry: Array = []
	for entry in get_own_pieces():
		if entry[0].type == Piece.Type.SLEEP and not moved_pieces.has(entry[0]):
			sleep_entry = entry
			break
	if sleep_entry.is_empty():
		return {}

	var best_dest := [-1, -1]
	var best_count := 0
	for r in range(BoardState.BOARD_SIZE):
		for c in range(BoardState.BOARD_SIZE):
			if not BoardState.is_valid_tile(r, c, owner):
				continue
			var occ := board.get_piece(r, c)
			if occ != null and occ.owner == owner:
				continue
			var count := 0
			for nb in board.get_all_adjacent(r, c):
				if nb != null and nb.owner == Piece.Owner.PLAYER:
					count += 1
			if count > best_count:
				best_count = count
				best_dest = [r, c]

	if best_dest[0] == -1 or best_count < 2:
		return {}
	return { "from": [sleep_entry[1], sleep_entry[2]], "to": best_dest }

## Move a Soldier to fill an empty diagonal of the allied King
func _try_complete_king_guard(moved_pieces: Dictionary) -> Dictionary:
	var king_pos := _find_own_piece_on_board(Piece.Type.KING)
	if king_pos[0] == -1:
		return {}
	var offsets := [[-1,-1],[-1,1],[1,1],[1,-1]]
	var empty_diag := [-1, -1]
	for o in offsets:
		var r: int = king_pos[0] + int(o[0])
		var c: int = king_pos[1] + int(o[1])
		if BoardState.in_bounds(r, c) and BoardState.is_valid_tile(r, c, owner) \
		   and board.get_piece(r, c) == null:
			empty_diag = [r, c]
			break
	if empty_diag[0] == -1:
		return {}

	for entry in get_own_pieces():
		var piece: Piece = entry[0]
		var row: int     = entry[1]
		var col: int     = entry[2]
		if moved_pieces.has(piece):
			continue
		if piece.type != Piece.Type.SOLDIER:
			continue
		return { "from": [row, col], "to": empty_diag }
	return {}

## Move Druid adjacent to the largest cluster of high-value player pieces
func _try_move_druid(moved_pieces: Dictionary) -> Dictionary:
	var druid_entry: Array = []
	for entry in get_own_pieces():
		if entry[0].type == Piece.Type.DRUID and not moved_pieces.has(entry[0]):
			druid_entry = entry
			break
	if druid_entry.is_empty():
		return {}

	var best_dest := [-1, -1]
	var best_score := -1
	for r in range(BoardState.BOARD_SIZE):
		for c in range(BoardState.BOARD_SIZE):
			if not BoardState.is_valid_tile(r, c, owner):
				continue
			var occ := board.get_piece(r, c)
			if occ != null and occ.owner == owner:
				continue
			var score := 0
			for neighbor in board.get_all_adjacent(r, c):
				if neighbor != null and neighbor.owner == Piece.Owner.PLAYER:
					score += neighbor.base_points
			if score > best_score:
				best_score = score
				best_dest = [r, c]

	if best_dest[0] == -1 or best_score == 0:
		return {}
	return { "from": [druid_entry[1], druid_entry[2]], "to": best_dest }

func _random_move(moved_pieces: Dictionary) -> Dictionary:
	var own := get_own_pieces()
	var movable := own.filter(func(e): return not moved_pieces.has(e[0]))
	if movable.is_empty():
		return {}
	movable.shuffle()
	for entry in movable:
		var row: int = entry[1]
		var col: int = entry[2]
		var dests := _get_destinations(row, col, moved_pieces)
		if dests.is_empty():
			continue
		dests.shuffle()
		return { "from": [row, col], "to": dests[0] }
	return {}

## ── Utilities ─────────────────────────────────────────────────

func _hand_has(t: Piece.Type) -> bool:
	return _find_in_hand(t) != -1

func _find_in_hand(t: Piece.Type) -> int:
	for i in range(hand.pieces.size()):
		if hand.pieces[i].type == t:
			return i
	return -1

func _find_own_piece_on_board(t: Piece.Type) -> Array:
	for entry in get_own_pieces():
		if entry[0].type == t:
			return [entry[1], entry[2]]
	return [-1, -1]

func _get_player_highest() -> Dictionary:
	var entries := board.get_all_pieces(Piece.Owner.PLAYER)
	if entries.is_empty():
		return {}
	## Filter out Sleep tiles — NPC should not waste a Mage negating player's Sleep
	entries = entries.filter(func(e): return e[0].type != Piece.Type.SLEEP)
	if entries.is_empty():
		return {}
	entries.sort_custom(func(a, b): return a[0].base_points > b[0].base_points)
	return { "piece": entries[0][0], "row": entries[0][1], "col": entries[0][2] }

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
