class_name BoardState
extends RefCounted

## NxN board (configurable: 3, 4, or 5). Row 0 = North (enemy side).
## Player pieces live on BLACK tiles, enemy pieces live on WHITE tiles.
## A tile is BLACK when (row + col) % 2 == 1
## A tile is WHITE when (row + col) % 2 == 0

static var BOARD_SIZE: int = 4  ## Default 4x4, can be set to 4 or 6 before battle starts

## grid[row][col] -> Piece or null
var grid: Array = []

func _init() -> void:
	_clear_grid()

func _clear_grid() -> void:
	grid = []
	for r in range(BOARD_SIZE):
		var row = []
		for c in range(BOARD_SIZE):
			row.append(null)
		grid.append(row)

## Returns true if this cell is a valid placement tile for the given owner
static func is_valid_tile(row: int, col: int, owner: Piece.Owner) -> bool:
	var is_black := (row + col) % 2 == 1
	if owner == Piece.Owner.PLAYER:
		return is_black
	else:
		return !is_black

## Returns true if (row, col) is within the board
static func in_bounds(row: int, col: int) -> bool:
	return row >= 0 and row < BOARD_SIZE and col >= 0 and col < BOARD_SIZE

## Returns true if (row, col) is a corner
static func is_corner(row: int, col: int) -> bool:
	return (row == 0 or row == BOARD_SIZE - 1) and (col == 0 or col == BOARD_SIZE - 1)

## Place a piece. Returns false if the cell is invalid or occupied.
func place_piece(piece: Piece, row: int, col: int) -> bool:
	if not in_bounds(row, col):
		return false
	if not is_valid_tile(row, col, piece.owner):
		return false
	if grid[row][col] != null:
		return false
	grid[row][col] = piece
	return true

## Remove a piece from a cell. Returns the piece or null.
func remove_piece(row: int, col: int) -> Piece:
	if not in_bounds(row, col):
		return null
	var p = grid[row][col]
	grid[row][col] = null
	return p

## Get piece at a cell
func get_piece(row: int, col: int) -> Piece:
	if not in_bounds(row, col):
		return null
	return grid[row][col]

## Returns the piece directly north of (row, col) — lower row index
func get_north(row: int, col: int) -> Piece:
	return get_piece(row - 1, col)

## Returns the piece directly south of (row, col) — higher row index
func get_south(row: int, col: int) -> Piece:
	return get_piece(row + 1, col)

## Returns the piece directly east of (row, col) — higher col index
func get_east(row: int, col: int) -> Piece:
	return get_piece(row, col + 1)

## Returns the piece directly west of (row, col) — lower col index
func get_west(row: int, col: int) -> Piece:
	return get_piece(row, col - 1)

## Returns all 4 diagonal neighbors [NW, NE, SE, SW]
func get_diagonals(row: int, col: int) -> Array:
	var result = []
	var offsets = [[-1, -1], [-1, 1], [1, 1], [1, -1]]
	for o in offsets:
		var r = row + o[0]
		var c = col + o[1]
		if in_bounds(r, c):
			result.append(grid[r][c])
		else:
			result.append(null)
	return result

## Returns all 8 surrounding neighbors
func get_all_adjacent(row: int, col: int) -> Array:
	var result = []
	for dr in [-1, 0, 1]:
		for dc in [-1, 0, 1]:
			if dr == 0 and dc == 0:
				continue
			var r = row + dr
			var c = col + dc
			if in_bounds(r, c):
				result.append(grid[r][c])
	return result

## Returns the [row, col] of a piece, or [-1, -1] if not found
func find_piece(piece: Piece) -> Array:
	for r in range(BOARD_SIZE):
		for c in range(BOARD_SIZE):
			if grid[r][c] == piece:
				return [r, c]
	return [-1, -1]

## Swap two pieces on the board (movement phase)
func swap_pieces(r1: int, c1: int, r2: int, c2: int) -> bool:
	if not in_bounds(r1, c1) or not in_bounds(r2, c2):
		return false
	var tmp = grid[r1][c1]
	grid[r1][c1] = grid[r2][c2]
	grid[r2][c2] = tmp
	return true

## Move piece from src to empty dst. Returns false if dst is occupied or invalid color.
func move_piece(from_r: int, from_c: int, to_r: int, to_c: int) -> bool:
	if not in_bounds(from_r, from_c) or not in_bounds(to_r, to_c):
		return false
	var piece = grid[from_r][from_c]
	if piece == null:
		return false
	if grid[to_r][to_c] != null:
		return false
	if not is_valid_tile(to_r, to_c, piece.owner):
		return false
	grid[to_r][to_c] = piece
	grid[from_r][from_c] = null
	return true

## Returns all pieces belonging to an owner as Array of [piece, row, col]
func get_all_pieces(owner: Piece.Owner) -> Array:
	var result = []
	for r in range(BOARD_SIZE):
		for c in range(BOARD_SIZE):
			var p = grid[r][c]
			if p != null and p.owner == owner:
				result.append([p, r, c])
	return result

## Returns ALL pieces on the board in top-down, left-right order: [piece, row, col, owner]
func get_all_pieces_ordered() -> Array:
	var result = []
	for r in range(BOARD_SIZE):
		for c in range(BOARD_SIZE):
			var p = grid[r][c]
			if p != null:
				result.append([p, r, c])
	return result
