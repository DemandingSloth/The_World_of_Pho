extends Node
## Autoload: adds a bundled emoji font as a FALLBACK to the game's default font.
##
## Desktop/Android builds borrow emoji glyphs from the operating system, but
## Web (itch.io) builds can't see system fonts — so every emoji (📖 💍 ⚗️ 🍜 …)
## rendered as blank. Appending a bundled emoji font to the default font's
## fallback chain makes Godot draw emoji from it whenever the main font lacks
## the glyph. Regular text is unchanged (it still comes from the main font).
##
## Safe no-op if the font file is missing.

const EMOJI_FONT_PATH := "res://Assets/Fonts/NotoColorEmoji.ttf"


func _ready() -> void:
	if not ResourceLoader.exists(EMOJI_FONT_PATH):
		return
	var emoji := load(EMOJI_FONT_PATH) as Font
	if emoji == null:
		return
	## The project theme has no default_font, so every Control uses the engine
	## fallback font — attach the emoji font to that.
	_add_fallback(ThemeDB.fallback_font, emoji)
	## Also cover a custom default font if the project theme ever sets one.
	var project_theme := ThemeDB.get_project_theme()
	if project_theme != null and project_theme.default_font != null:
		_add_fallback(project_theme.default_font, emoji)


func _add_fallback(base: Font, emoji: Font) -> void:
	if base == null or base == emoji:
		return
	var chain: Array[Font] = base.fallbacks.duplicate()
	if emoji in chain:
		return
	chain.append(emoji)
	base.fallbacks = chain
