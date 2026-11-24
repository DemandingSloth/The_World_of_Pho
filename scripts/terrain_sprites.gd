extends Node

## Loads the terrain spritesheet and provides AtlasTexture slices per terrain type.
## Registered as an autoload named "TerrainSprites" in project settings.

const SHEET_PATH := "res://Assets/sprite_terrain_battle_system.png"
const ICON_SIZE  := 64   ## each terrain tile is 64x64 px

var _sheet: Texture2D = null
var _cache: Dictionary = {}   ## terrain index -> AtlasTexture

func _ready() -> void:
	_sheet = load(SHEET_PATH)
	if _sheet == null:
		push_error("TerrainSprites: could not load %s" % SHEET_PATH)

## Returns an AtlasTexture for the given terrain type index, or null if unavailable.
func get_icon(terrain_index: int) -> AtlasTexture:
	if _sheet == null or terrain_index < 0:
		return null
	if _cache.has(terrain_index):
		return _cache[terrain_index]
	var atlas := AtlasTexture.new()
	atlas.atlas = _sheet
	atlas.region = Rect2(terrain_index * ICON_SIZE, 0, ICON_SIZE, ICON_SIZE)
	_cache[terrain_index] = atlas
	return atlas

## Convenience: get icon from Terrain.Type enum
func get_terrain_icon(terrain: Terrain.Type) -> AtlasTexture:
	return get_icon(int(terrain))
