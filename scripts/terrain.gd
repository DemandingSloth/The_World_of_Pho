class_name Terrain
extends RefCounted

## All terrain types. Add new ones here as the game expands.
enum Type {
	INDOORS,
	OUTDOORS,
	SWAMP,
	FOREST,
	PLAIN,
	WATERSIDE,
	DESERT,
}

## Human-readable names for UI display
static func get_terrain_name(t: Type) -> String:
	match t:
		Type.INDOORS:   return "Indoors"
		Type.OUTDOORS:  return "Outdoors"
		Type.SWAMP:     return "Swamp"
		Type.FOREST:    return "Forest"
		Type.PLAIN:     return "Plain"
		Type.WATERSIDE: return "Waterside"
		Type.DESERT:    return "Desert"
	return "Unknown"

## Returns the flat base-point bonus a piece receives from the current terrain.
## Return 0 for no effect.
## Add new piece/terrain interactions here — no other file needs to change.
static func get_piece_bonus(piece_type: Piece.Type, terrain: Type) -> int:
	match piece_type:

		Piece.Type.DRUID:
			## +1 base in nature terrains (total becomes 4)
			if terrain in [Type.FOREST, Type.OUTDOORS, Type.PLAIN]:
				return 1

		Piece.Type.CLERGY:
			## +1 base indoors (total becomes 4)
			if terrain == Type.INDOORS:
				return 1

		## ── Future pieces go here ──────────────────────────────
		## Example:
		## Piece.Type.SWAMP_WITCH:
		##     if terrain == Type.SWAMP:
		##         return 2

	return 0
