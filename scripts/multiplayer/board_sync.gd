class_name BoardSync
extends RefCounted

## Serializes and deserializes board state for network transmission.
## Handles partial board sync (during hidden placement) and full sync (after reveal).
## All methods are static — no instance state needed.


## Serialize the full board state for transmission.
## Returns an Array of piece dictionaries containing all pieces on the board.
static func serialize_board(board: BoardState) -> Array:
	var data: Array = []
	for r in range(BoardState.BOARD_SIZE):
		for c in range(BoardState.BOARD_SIZE):
			var piece: Piece = board.get_piece(r, c)
			if piece != null:
				data.append({
					"type": int(piece.type),
					"owner": int(piece.owner),
					"direction": int(piece.direction),
					"row": r,
					"col": c,
					"base_points": piece.base_points,
					"final_points": piece.final_points,
				})
	return data


## Serialize only pieces belonging to a specific owner (for hidden placement).
## Used during PVP_PLACEMENT so each player only sees their own pieces.
static func serialize_owner_pieces(board: BoardState, owner: Piece.Owner) -> Array:
	var data: Array = []
	for r in range(BoardState.BOARD_SIZE):
		for c in range(BoardState.BOARD_SIZE):
			var piece: Piece = board.get_piece(r, c)
			if piece != null and piece.owner == owner:
				data.append({
					"type": int(piece.type),
					"owner": int(piece.owner),
					"direction": int(piece.direction),
					"row": r,
					"col": c,
				})
	return data


## Reconstruct board state from serialized data.
## Validates bounds and tile-color ownership, skipping invalid entries.
static func deserialize_board(data: Array) -> BoardState:
	var board := BoardState.new()
	for entry in data:
		if not _is_valid_piece_entry(entry):
			continue

		var row: int = entry["row"]
		var col: int = entry["col"]
		var owner_value: int = entry["owner"]

		# Bounds validation
		if not BoardState.in_bounds(row, col):
			continue

		# Tile-color validation: owner must match tile color
		var owner: Piece.Owner = owner_value as Piece.Owner
		if not BoardState.is_valid_tile(row, col, owner):
			continue

		# Skip if cell already occupied (first entry wins)
		if board.get_piece(row, col) != null:
			continue

		var piece := _create_piece_from_entry(entry)
		board.place_piece(piece, row, col)
	return board


## Serialize a single piece placement action into a network-safe Dictionary.
static func serialize_piece_action(piece: Piece, row: int, col: int) -> Dictionary:
	return {
		"type": int(piece.type),
		"owner": int(piece.owner),
		"direction": int(piece.direction),
		"row": row,
		"col": col,
	}


## Deserialize and create a Piece from network data.
## Uses Piece.create factory to pull stats from PieceRegistry.
static func deserialize_piece(data: Dictionary) -> Piece:
	if not _is_valid_piece_data(data):
		return null

	var piece_type: Piece.Type = data["type"] as Piece.Type
	var owner: Piece.Owner = data["owner"] as Piece.Owner
	var piece := Piece.create(piece_type, owner)
	piece.direction = data.get("direction", PieceDefinition.Direction.NONE) as PieceDefinition.Direction
	return piece


# ── Private Helpers ───────────────────────────────────────────────────────────


## Validates that an entry dictionary has the required keys with integer values.
static func _is_valid_piece_entry(entry) -> bool:
	if not entry is Dictionary:
		return false
	for key in ["type", "owner", "direction", "row", "col"]:
		if not entry.has(key):
			return false
	# Validate enum ranges
	var type_value: int = entry["type"]
	var owner_value: int = entry["owner"]
	var direction_value: int = entry["direction"]
	if type_value < 0 or type_value > int(Piece.Type.BLACK_HOLE):
		return false
	if owner_value < 0 or owner_value > int(Piece.Owner.ENEMY):
		return false
	if direction_value < 0 or direction_value > int(PieceDefinition.Direction.WEST):
		return false
	return true


## Validates piece data dictionary has required keys (without row/col).
static func _is_valid_piece_data(data: Dictionary) -> bool:
	for key in ["type", "owner"]:
		if not data.has(key):
			return false
	var type_value: int = data["type"]
	var owner_value: int = data["owner"]
	if type_value < 0 or type_value > int(Piece.Type.BLACK_HOLE):
		return false
	if owner_value < 0 or owner_value > int(Piece.Owner.ENEMY):
		return false
	return true


## Creates a Piece from a validated entry dictionary.
static func _create_piece_from_entry(entry: Dictionary) -> Piece:
	var piece_type: Piece.Type = entry["type"] as Piece.Type
	var owner: Piece.Owner = entry["owner"] as Piece.Owner
	var direction: PieceDefinition.Direction = entry["direction"] as PieceDefinition.Direction
	var piece := Piece.create(piece_type, owner)
	piece.direction = direction
	# Restore points if present (used when transmitting scored boards)
	if entry.has("base_points"):
		piece.base_points = entry["base_points"]
	if entry.has("final_points"):
		piece.final_points = entry["final_points"]
	return piece
