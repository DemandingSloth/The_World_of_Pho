class_name Piece
extends Resource

enum Type {
	PAWN,
	SOLDIER,
	MAGE,
	WATCHTOWER,
	KING,
	CLERGY,
	DRUID,
	CLAW,
	SLEEP,
	SAIL,
	TREE,
	BITE,
	WIND,
	SHIELD,
	DOME,
	BLACK_HOLE,
	## Add new types here — then create a matching .tres in res://data/pieces/
}

enum Owner {
	PLAYER,
	ENEMY,
}

@export var type        : Type
@export var owner       : Owner
@export var base_points : int
@export var display_name: String
@export var description : String

## Per-instance facing direction (initialized from PieceDefinition default)
@export var direction: PieceDefinition.Direction = PieceDefinition.Direction.NONE

## Computed during scoring — do not set manually
var final_points: int  = 0
var is_negated  : bool = false
var is_protected: bool = false  ## Set by Shield/Dome — prevents negation and debuffs

## Factory — reads stats from PieceRegistry
static func create(p_type: Type, p_owner: Owner) -> Piece:
	var p   := Piece.new()
	p.type  = p_type
	p.owner = p_owner
	var def: PieceDefinition = PieceRegistry.get_def(p_type)
	if def:
		p.base_points  = def.base_points
		p.display_name = def.display_name
		p.description  = def.description
		p.direction    = def.effect_direction
	else:
		push_warning("Piece.create: no definition found for type %d" % p_type)
		p.base_points  = 0
		p.display_name = "Unknown"
		p.description  = ""
	return p

## Rotate the piece's facing direction clockwise (N→E→S→W→N)
func rotate_cw() -> void:
	match direction:
		PieceDefinition.Direction.NORTH: direction = PieceDefinition.Direction.EAST
		PieceDefinition.Direction.EAST:  direction = PieceDefinition.Direction.SOUTH
		PieceDefinition.Direction.SOUTH: direction = PieceDefinition.Direction.WEST
		PieceDefinition.Direction.WEST:  direction = PieceDefinition.Direction.NORTH
		_: pass  ## NONE — no rotation for non-directional pieces

## Rotate the piece's facing direction counter-clockwise (N→W→S→E→N)
func rotate_ccw() -> void:
	match direction:
		PieceDefinition.Direction.NORTH: direction = PieceDefinition.Direction.WEST
		PieceDefinition.Direction.WEST:  direction = PieceDefinition.Direction.SOUTH
		PieceDefinition.Direction.SOUTH: direction = PieceDefinition.Direction.EAST
		PieceDefinition.Direction.EAST:  direction = PieceDefinition.Direction.NORTH
		_: pass

## Returns true if this piece has a directional effect that can be rotated
func is_rotatable() -> bool:
	return direction != PieceDefinition.Direction.NONE

## Returns the rotation angle in degrees for rendering (0° = North/up)
func get_rotation_degrees() -> float:
	match direction:
		PieceDefinition.Direction.NORTH: return 0.0
		PieceDefinition.Direction.EAST:  return 90.0
		PieceDefinition.Direction.SOUTH: return 180.0
		PieceDefinition.Direction.WEST:  return 270.0
	return 0.0

func get_sprite_index() -> int:
	var def: PieceDefinition = PieceRegistry.get_def(type)
	return def.sprite_index if def else -1

func get_label() -> String:
	var def: PieceDefinition = PieceRegistry.get_def(type)
	return def.short_label if def else "?"
