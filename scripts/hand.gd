class_name Hand
extends RefCounted

## The collection of pieces a player has available to place.
## For testing, the player draws a fixed set.
## Enemy hand mirrors the same set for balance testing.

var pieces: Array[Piece] = []

## Build the test hand for a given owner
static func build_test_hand(owner: Piece.Owner) -> Hand:
	var h = Hand.new()

	## Mix of pieces for testing
	for i in range(3):
		h.pieces.append(Piece.create(Piece.Type.PAWN, owner))
	for i in range(4):
		h.pieces.append(Piece.create(Piece.Type.SOLDIER, owner))
	for i in range(2):
		h.pieces.append(Piece.create(Piece.Type.MAGE, owner))
	h.pieces.append(Piece.create(Piece.Type.CLAW, owner))

	## 2-point tiles
	h.pieces.append(Piece.create(Piece.Type.WATCHTOWER, owner))

	## 3-point tiles
	h.pieces.append(Piece.create(Piece.Type.CLERGY, owner))
	h.pieces.append(Piece.create(Piece.Type.DRUID, owner))

	## King
	h.pieces.append(Piece.create(Piece.Type.KING, owner))

	return h

## Remove a piece from hand by index. Returns null if index invalid.
func take_piece(index: int) -> Piece:
	if index < 0 or index >= pieces.size():
		return null
	var p = pieces[index]
	pieces.remove_at(index)
	return p

## Return a piece to hand (e.g. player unplaced it)
func return_piece(piece: Piece) -> void:
	pieces.append(piece)

func is_empty() -> bool:
	return pieces.is_empty()

func count() -> int:
	return pieces.size()

func size() -> int:
	return pieces.size()
