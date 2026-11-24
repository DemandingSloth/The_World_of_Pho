class_name EnemyDefinitions
extends RefCounted

## Central registry of all enemy types.
## Add new enemies here — AI classes, hand builders, and UI all read from this.

enum EnemyType {
	WOLF,
	BEAR,
	NPC,
}

## Human-readable name for UI
static func get_enemy_name(t: EnemyType) -> String:
	match t:
		EnemyType.WOLF: return "Wolf Pack"
		EnemyType.BEAR: return "Bear"
		EnemyType.NPC:  return "Rival"
	return "Unknown"

## Flavour description for UI
static func get_description(t: EnemyType) -> String:
	match t:
		EnemyType.WOLF: return "Weak. Random placement. Pawns, Watchtowers, and Claws."
		EnemyType.BEAR: return "Medium. Uses Soldiers to attack. No magic."
		EnemyType.NPC:  return "Dangerous. Full piece access. Plays intelligently."
	return ""

## Which piece types this enemy is allowed to use
static func get_piece_pool(t: EnemyType) -> Array[Piece.Type]:
	match t:
		EnemyType.WOLF:
			return [Piece.Type.PAWN, Piece.Type.WATCHTOWER, Piece.Type.CLAW, Piece.Type.BITE]
		EnemyType.BEAR:
			return [Piece.Type.PAWN, Piece.Type.WATCHTOWER, Piece.Type.SOLDIER, Piece.Type.CLAW, Piece.Type.BITE]
		EnemyType.NPC:
			return [
				Piece.Type.PAWN,
				Piece.Type.SOLDIER,
				Piece.Type.MAGE,
				Piece.Type.WATCHTOWER,
				Piece.Type.KING,
				Piece.Type.CLERGY,
				Piece.Type.DRUID,
				Piece.Type.SLEEP,
				Piece.Type.SAIL,
			]
	return []

## Max total base-point value the hand may contain
static func get_max_hand_value(t: EnemyType) -> int:
	match t:
		EnemyType.WOLF: return 5
		EnemyType.BEAR: return 10
		EnemyType.NPC:  return 20
	return 5

## Max number of pawns allowed in the hand
static func get_max_pawns(t: EnemyType) -> int:
	match t:
		EnemyType.WOLF: return 99
		EnemyType.BEAR: return 99
		EnemyType.NPC:  return 5
	return 99

## Only one King per board — flag whether this enemy can ever use one
static func can_use_king(t: EnemyType) -> bool:
	return t == EnemyType.NPC

## Build a random hand obeying all constraints for this enemy type
static func build_hand(t: EnemyType) -> Hand:
	var pool      := get_piece_pool(t)
	var max_value := get_max_hand_value(t)
	var max_pawns := get_max_pawns(t)
	var use_king  := can_use_king(t)

	var h          := Hand.new()
	var total_pts  := 0
	var pawn_count := 0
	var has_king   := false

	var available := pool.duplicate()
	var attempts  := 0

	while total_pts < max_value and attempts < 200:
		attempts += 1
		available.shuffle()
		var added := false
		for piece_type in available:
			if piece_type == Piece.Type.KING:
				if not use_king or has_king:
					continue
			if piece_type == Piece.Type.PAWN and pawn_count >= max_pawns:
				continue
			var cost := Piece.create(piece_type, Piece.Owner.ENEMY).base_points
			if total_pts + cost > max_value:
				continue
			var piece := Piece.create(piece_type, Piece.Owner.ENEMY)
			## Randomly rotate directional pieces for variety
			if piece.is_rotatable():
				var rotations := randi() % 4
				for _r in range(rotations):
					piece.rotate_cw()
			h.pieces.append(piece)
			total_pts += cost
			if piece_type == Piece.Type.PAWN:
				pawn_count += 1
			if piece_type == Piece.Type.KING:
				has_king = true
			added = true
			break
		if not added:
			break

	return h
