class_name UiPieceGrid
extends RefCounted

## Shared helper that builds a grid of piece tiles for any piece collection.
## Used by: inventory screen, single-player battle hand, multiplayer battle hand.

const SLOT_BG_PATH := "res://Assets/UI/slot_bg.png"

## Colors for tile selection highlight
const C_SELECTED_BORDER := Color(0.80, 0.70, 0.10)
const C_NORMAL_BORDER   := Color(0.5, 0.5, 0.6, 0.0)

## Build (or rebuild) a grid of piece-type tiles.
##
## Parameters:
##   grid          – GridContainer to populate (children cleared first)
##   counts        – Dictionary { Piece.Type -> int } count of each type
##   selected_type – currently selected Piece.Type (or -1 for none)
##   on_click      – Callable(piece_type: int) called when a tile is clicked, or Callable() for read-only
##   tile_size     – size of each tile (default 64x64)
##   piece_lookup  – optional Array[Piece] used to store a Piece instance in "piece" meta for long-press tooltips
static func build_grid(
	grid: GridContainer,
	counts: Dictionary,
	selected_type: int,
	on_click: Callable,
	tile_size: Vector2 = Vector2(64, 64),
	piece_lookup: Array = [],
) -> void:
	## Clear existing children
	for child in grid.get_children():
		child.queue_free()

	## Sort piece types by base_points for consistent ordering
	var sorted_types: Array = counts.keys()
	sorted_types.sort_custom(func(a, b):
		var def_a := PieceRegistry.get_def(a as Piece.Type)
		var def_b := PieceRegistry.get_def(b as Piece.Type)
		var pts_a := def_a.base_points if def_a else 0
		var pts_b := def_b.base_points if def_b else 0
		return pts_a < pts_b
	)

	var slot_tex: Texture2D = load(SLOT_BG_PATH)

	for piece_type in sorted_types:
		var count: int = counts[piece_type]
		var def: PieceDefinition = PieceRegistry.get_def(piece_type as Piece.Type)
		if def == null:
			continue

		var has_any: bool = count > 0
		var is_selected: bool = (int(piece_type) == selected_type)

		## Use a Button so we can handle clicks and hover
		var tile := Button.new()
		tile.custom_minimum_size = tile_size
		tile.focus_mode = Control.FOCUS_NONE
		tile.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if on_click.is_valid() else Control.CURSOR_ARROW

		## Style: slot_bg.png background via StyleBoxTexture
		if slot_tex:
			var style := StyleBoxTexture.new()
			style.texture = slot_tex
			style.texture_margin_left = 2
			style.texture_margin_top = 2
			style.texture_margin_right = 2
			style.texture_margin_bottom = 2
			style.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
			style.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
			tile.add_theme_stylebox_override("normal", style)
			tile.add_theme_stylebox_override("pressed", style)
			tile.add_theme_stylebox_override("hover", style)
		else:
			var flat := StyleBoxFlat.new()
			flat.bg_color = Color(0.15, 0.15, 0.22)
			tile.add_theme_stylebox_override("normal", flat)
			tile.add_theme_stylebox_override("pressed", flat)
			var h := flat.duplicate() as StyleBoxFlat
			h.bg_color = flat.bg_color.lightened(0.15)
			tile.add_theme_stylebox_override("hover", h)

		## Selection highlight border (drawn via a ColorRect frame overlay)
		if is_selected:
			var border := _make_selection_border(tile_size)
			tile.add_child(border)

		## Piece sprite
		var icon := PieceSprites.get_icon(def.sprite_index)
		if icon:
			var sprite := TextureRect.new()
			sprite.name = "PieceSprite"
			sprite.texture = icon
			sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			sprite.set_anchors_preset(Control.PRESET_FULL_RECT)
			sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
			## Gray out if count is 0
			if not has_any:
				sprite.self_modulate = Color(0.4, 0.4, 0.4)
			tile.add_child(sprite)

		## Count badge in top-left corner
		var count_lbl := Label.new()
		count_lbl.name = "CountBadge"
		count_lbl.text = str(count)
		count_lbl.add_theme_font_size_override("font_size", 12)
		count_lbl.add_theme_color_override("font_color", Color.WHITE)
		count_lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
		count_lbl.add_theme_constant_override("shadow_offset_x", 1)
		count_lbl.add_theme_constant_override("shadow_offset_y", 1)
		count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		count_lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		count_lbl.anchors_preset = Control.PRESET_FULL_RECT
		count_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.add_child(count_lbl)

		## Tooltip
		tile.tooltip_text = "%s (%d pt)\n%s\nOwned: %d" % [
			def.display_name, def.base_points, def.description, count]

		## Touch group + piece meta for long-press tooltips
		tile.add_to_group("hand_tiles")
		for p in piece_lookup:
			if p is Piece and p.type == piece_type:
				tile.set_meta("piece", p)
				break

		## Click callback
		if on_click.is_valid():
			tile.pressed.connect(on_click.bind(piece_type))

		grid.add_child(tile)


## Creates a colored border overlay to indicate selection.
static func _make_selection_border(tile_size: Vector2) -> Panel:
	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.80, 0.70, 0.10, 0.15)
	style.border_width_left = 3; style.border_width_right = 3
	style.border_width_top  = 3; style.border_width_bottom = 3
	style.border_color = C_SELECTED_BORDER
	style.corner_radius_top_left    = 3; style.corner_radius_top_right    = 3
	style.corner_radius_bottom_left = 3; style.corner_radius_bottom_right = 3
	panel.add_theme_stylebox_override("panel", style)
	return panel
