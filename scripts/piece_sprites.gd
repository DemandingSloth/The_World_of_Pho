extends Node

## Loads the piece spritesheet once and provides AtlasTexture slices per piece.
## Registered as an autoload named "PieceSprites" in project settings.

const SHEET_PATH  := "res://Assets/sprite_battle_system.png"
const ICON_SIZE   := 64   ## each icon is 64x64 px
const ICON_COUNT  := 16   ## Pawn, Soldier, Mage, Watchtower, King, Clergy, Druid, Claw, Sleep, Sail, Tree, Bite, Wind, Shield, Dome, BlackHole

var _sheet: Texture2D = null
var _cache: Dictionary = {}   ## index -> AtlasTexture

func _ready() -> void:
	_sheet = load(SHEET_PATH)
	if _sheet == null:
		push_error("PieceSprites: could not load %s" % SHEET_PATH)

## Returns an AtlasTexture for the given sprite index, or null if unavailable.
func get_icon(sprite_index: int) -> AtlasTexture:
	if _sheet == null or sprite_index < 0:
		return null
	if _cache.has(sprite_index):
		return _cache[sprite_index]
	var atlas := AtlasTexture.new()
	atlas.atlas = _sheet
	atlas.region = Rect2(sprite_index * ICON_SIZE, 0, ICON_SIZE, ICON_SIZE)
	_cache[sprite_index] = atlas
	return atlas

## Convenience: get icon directly from a Piece
func get_piece_icon(piece: Piece) -> AtlasTexture:
	return get_icon(PieceRegistry.sprite_index(piece.type))
