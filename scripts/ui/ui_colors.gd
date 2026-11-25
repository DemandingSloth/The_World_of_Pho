class_name UIColors
extends RefCounted
## Centralized semantic text colors and helpers for consistent readability
## across scenic/dark backgrounds (HUD) and light panel surfaces.

## Light text for labels rendered directly over scenic or dark backgrounds.
const TEXT_LIGHT := Color(0.96, 0.94, 0.88, 1.0)
const TEXT_MUTED_LIGHT := Color(0.84, 0.86, 0.82, 1.0)
const TEXT_GOLD := Color(1.0, 0.86, 0.35, 1.0)
const TEXT_OUTLINE := Color(0.06, 0.06, 0.09, 0.90)

## Dark text for labels rendered on light panel_bg.png surfaces.
const TEXT_DARK := Color(0.15, 0.12, 0.08, 1.0)
const TEXT_PANEL_MUTED := Color(0.28, 0.25, 0.20, 1.0)

## Semantic status colors.
const TEXT_SUCCESS := Color(0.35, 0.95, 0.45, 1.0)
const TEXT_ERROR := Color(1.0, 0.35, 0.35, 1.0)
const TEXT_WARNING := Color(1.0, 0.80, 0.25, 1.0)


## Styles a Label for crisp readability over scenic/dark backgrounds using
## light text and a dark outline.
static func apply_hud_text(
		label: Label,
		color: Color = TEXT_LIGHT,
		outline_size: int = 3
) -> void:
	if label == null:
		return
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", TEXT_OUTLINE)
	label.add_theme_constant_override("outline_size", outline_size)


## Styles a Label for readability on light panel_bg.png surfaces.
static func apply_panel_text(label: Label, color: Color = TEXT_DARK) -> void:
	if label == null:
		return
	label.add_theme_color_override("font_color", color)
	label.remove_theme_color_override("font_outline_color")
	label.remove_theme_constant_override("outline_size")

## Walks a node subtree and applies explicit theme overrides for any Label
## using HudLabel, HudGoldLabel, or HudMutedLabel variations. Ensures
## consistent rendering across both editor runs and exported release builds.
static func apply_hud_variations(root: Node) -> void:
	if root == null:
		return
	if root is Label:
		var lbl := root as Label
		match lbl.theme_type_variation:
			&"HudLabel":
				apply_hud_text(lbl, TEXT_LIGHT, 3)
			&"HudGoldLabel":
				apply_hud_text(lbl, TEXT_GOLD, 3)
			&"HudMutedLabel":
				apply_hud_text(lbl, TEXT_MUTED_LIGHT, 2)
	for child in root.get_children():
		apply_hud_variations(child)
