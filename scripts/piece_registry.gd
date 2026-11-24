extends Node

## Autoload: PieceRegistry
## Loads every PieceDefinition .tres from res://data/pieces/ at startup.
## All game systems read piece data from here — no hardcoded stats anywhere else.

const DATA_PATH := "res://data/pieces/"

## piece_type (int) -> PieceDefinition
var _defs: Dictionary = {}

func _ready() -> void:
	_load_all()

func _load_all() -> void:
	## On Android, DirAccess cannot enumerate res:// paths inside the APK.
	## Use a hardcoded list of piece definition filenames.
	## Note: Godot may convert .tres to .res on export, but load() handles both
	## via the resource UID system. We try both extensions.
	var piece_names := [
		"bite",
		"black_hole",
		"claw",
		"clergy",
		"dome",
		"druid",
		"king",
		"mage",
		"pawn",
		"sail",
		"shield",
		"sleep",
		"soldier",
		"tree",
		"watchtower",
		"wind",
	]

	for pname in piece_names:
		var path_tres: String = DATA_PATH + pname + ".tres"
		var path_res: String = DATA_PATH + pname + ".res"
		var def: PieceDefinition = null

		# Try .tres first, then .res
		if ResourceLoader.exists(path_tres):
			def = load(path_tres) as PieceDefinition
		elif ResourceLoader.exists(path_res):
			def = load(path_res) as PieceDefinition
		else:
			# Last resort: try load directly (Godot may resolve via UID)
			def = load(path_tres) as PieceDefinition

		if def != null and def is PieceDefinition:
			_defs[int(def.piece_type)] = def
		else:
			push_warning("PieceRegistry: could not load piece '%s'" % pname)

	print("PieceRegistry: loaded %d piece definitions" % _defs.size())

## Returns the PieceDefinition for a type, or null if not registered
func get_def(piece_type: Piece.Type) -> PieceDefinition:
	return _defs.get(int(piece_type), null)

## Returns all loaded definitions as an Array[PieceDefinition]
func get_all() -> Array:
	return _defs.values()

## Convenience: base points for a type
func base_points(piece_type: Piece.Type) -> int:
	var d := get_def(piece_type)
	return d.base_points if d else 0

## Convenience: display name
func display_name(piece_type: Piece.Type) -> String:
	var d := get_def(piece_type)
	return d.display_name if d else "Unknown"

## Convenience: sprite index
func sprite_index(piece_type: Piece.Type) -> int:
	var d := get_def(piece_type)
	return d.sprite_index if d else -1

## Convenience: short label
func short_label(piece_type: Piece.Type) -> String:
	var d := get_def(piece_type)
	return d.short_label if d else "?"
