class_name PieceDefinition
extends Resource

## Fill all fields in the Godot Inspector.
## One .tres file per piece type lives in res://data/pieces/

## ── Identity ─────────────────────────────────────────────────────
@export var piece_type    : Piece.Type        ## Must be unique across all definitions
@export var display_name  : String
@export var short_label   : String            ## 2-3 chars shown on tile when no sprite
@export var base_points   : int

## ── Sprite ───────────────────────────────────────────────────────
@export var sprite_index  : int = -1          ## Column index in the spritesheet (-1 = text fallback)

## ── Effect ───────────────────────────────────────────────────────
@export_group("Effect")
@export var effect_type   : EffectType = EffectType.NONE
@export var effect_direction : Direction = Direction.NONE

enum EffectType {
	NONE,
	DEBUFF,              ## -N to enemy in the given direction
	NEGATE,              ## fully negate the piece in the given direction
	CORNER_BONUS,        ## +N if placed in a corner
	GUARD_BONUS,         ## +N if all 4 diagonals are allied guards
	DIAGONAL_BUFF,       ## +N to each allied diagonal piece
	ADJACENT_HALVE,      ## halve (floor) each adjacent enemy's total
	ADJACENT_NEGATE,     ## negate ALL adjacent pieces (ally and enemy)
	TERRAIN_ADJ_BUFF,    ## +N to each allied adjacent piece if on matching terrain
	ISOLATED_BONUS,      ## scores base points only if no adjacent ally or enemy pieces
	WIND_PUSH,           ## on Desert terrain, blows each tile one space away from this piece
	DIRECTIONAL_PROTECT, ## prevents negation/debuffs from the facing direction (Shield)
	DOME_PROTECT,        ## protects all allied adjacent pieces from negation/debuffs
	REMOVE_DIRECTIONAL,  ## removes the piece in the facing direction from the board entirely
}

enum Direction {
	NONE,
	NORTH,
	SOUTH,
	EAST,
	WEST,
}

## Magnitude of the effect (points added, subtracted, or bonus value)
@export var effect_value  : int = 0

## For GUARD_BONUS: which piece types count as valid guards
@export var guard_types   : Array[Piece.Type] = []

## ── Terrain bonuses ──────────────────────────────────────────────
@export_group("Terrain Bonuses")
## Maps Terrain.Type (as int) -> bonus points added to base
## Fill this in the Inspector using the Dictionary editor
## e.g. { 0: 1 } means +1 in Terrain INDOORS (index 0)
@export var terrain_bonuses: Dictionary = {}

## ── Tutorial / UI ────────────────────────────────────────────────
@export_group("Tutorial")
@export_multiline var description : String   ## shown in tooltip and How to Play
@export_multiline var tutorial_tip: String   ## strategic tip shown in How to Play

## ── Helpers ──────────────────────────────────────────────────────

## Returns the terrain bonus for a given terrain type (0 if none)
func get_terrain_bonus(terrain: Terrain.Type) -> int:
	return terrain_bonuses.get(int(terrain), 0)
