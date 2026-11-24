class_name OreSprites
extends RefCounted

## Static helper for slicing the ores sprite sheet (Assets/ores/ores.png).
##
## The sheet is a 10x10 grid of equally sized cells. Sprites are addressed by
## 1-indexed (row, col) to match how they were described in design, e.g.
## "4th row, 1st column". Textures are cached as AtlasTextures so repeated
## lookups are cheap.
##
## Item -> cell mapping (1-indexed row, col):
##   wood          -> (4, 1)
##   stick         -> (4, 2)
##   iron_ore      -> (5, 3)
##   iron_bar      -> (5, 4)
##   copper_ore    -> (7, 3)
##   copper_ingot  -> (7, 4)
##   gold_ingot    -> (6, 4)
## (The base "gold" ore keeps its existing Gold Panning gemstone sprite.)

## NOTE: path case MUST match the on-disk folder exactly ("Assets/Ores"). Windows
## is case-insensitive so a lowercase "ores" works on desktop, but Android's
## filesystem is case-sensitive and would fail to load the sheet.
const SHEET_PATH := "res://Assets/Ores/ores.png"
const GRID := 10  ## 10x10 grid

## Item id -> [row, col] (1-indexed) on the ores sheet.
const ITEM_CELLS := {
	"wood": [4, 1],
	"stick": [4, 2],
	"iron_ore": [5, 3],
	"iron_bar": [5, 4],
	"copper_ore": [7, 3],
	"copper_ingot": [7, 4],
	"gold_ingot": [6, 4],
}

## Cache: "row_col" -> AtlasTexture
static var _cache: Dictionary = {}
static var _sheet: Texture2D = null


## Returns the sliced AtlasTexture for a (1-indexed) row/col cell, or null.
static func get_cell(row_1: int, col_1: int) -> Texture2D:
	var key := "%d_%d" % [row_1, col_1]
	if _cache.has(key):
		return _cache[key]
	if _sheet == null:
		_sheet = load(SHEET_PATH)
	if _sheet == null:
		return null
	var cw := int(_sheet.get_width() / float(GRID))
	var ch := int(_sheet.get_height() / float(GRID))
	var atlas := AtlasTexture.new()
	atlas.atlas = _sheet
	atlas.region = Rect2((col_1 - 1) * cw, (row_1 - 1) * ch, cw, ch)
	_cache[key] = atlas
	return atlas


## Returns the sprite for a known item id (see ITEM_CELLS), or null if unknown.
static func get_item_texture(item_id: String) -> Texture2D:
	if not ITEM_CELLS.has(item_id):
		return null
	var cell: Array = ITEM_CELLS[item_id]
	return get_cell(int(cell[0]), int(cell[1]))
