class_name TutorialData
extends RefCounted

## Piece entries are pulled live from PieceRegistry so adding a new .tres
## automatically adds it to the How to Play screen.

static func get_piece_entries() -> Array:
	var entries := []
	for def in PieceRegistry.get_all():
		entries.append({
			"type":   def.piece_type,
			"name":   def.display_name,
			"points": "%d pt%s" % [def.base_points, "s" if def.base_points != 1 else ""],
			"effect": def.description,
			"tip":    def.tutorial_tip,
		})
	## Sort by base points ascending so Pawns come first
	entries.sort_custom(func(a, b):
		return PieceRegistry.base_points(a["type"]) < PieceRegistry.base_points(b["type"]))
	return entries

static func get_rules_sections() -> Array:
	return [
		{
			"title": "The Board",
			"body":  "An 8x8 chessboard. You place pieces on the DARK tiles The enemy places on the LIGHT tiles. Pieces cannot cross to the other colour."
		},
		{
			"title": "Placement Phase",
			"body":  "The enemy places its pieces first (without knowing yours). Then you place yours, seeing the enemy's layout. Right-click a piece (in hand or on board) to rotate its facing direction. Place at least 3 pieces, then click 'Done Placing' to start the movement phase."
		},
		{
			"title": "Movement Phase",
			"body":  "A coin flip decides who moves first. Each round, both players move one piece. Two rounds total (4 moves between both players). Each piece can only move ONCE across both rounds. You can move to an empty tile OR swap with another of your own pieces. You may rotate your pieces BEFORE you move them. ."
		},
		{
			"title": "Scoring Order",
			"body":  "Effects resolve top-down, left-right across the board.\n1. Terrain bonuses applied to base points.\n2. Negation — pieces with Negate zero out their target in order. A negated piece cannot activate.\n3. Buffs — Diagonal Buff, Corner bonus, Guard bonus.\n4. Debuffs — Directional debuffs, Adjacent halving.\n5. Final totals tallied. Highest score wins.\n\nTies go to the player — if both sides score equally, you win!\n\nLose a battle and the campaign is over."
		},
		{
			"title": "Directions",
			"body":  "NORTH = toward the enemy (up the board).\nSOUTH = toward you (down the board).\nEffects like Soldier (-1 North) affect the piece directly above it. pieces may be rotated and change the direction they attack. all pieces have a red dot registration mark so you can tell which way is naturally north."
		},
		{
			"title": "Campaign",
			"body":  "Choose a difficulty: Easy (1 battle), Medium (3), Hard (5), or Brutal (9).  Placed tiles are consumed after each fight. Unplaced tiles stay in your pool for future battles. Manage your resources carefully."
		},
		{
			"title": "Terrain",
			"body":  "Each battle takes place in a terrain that can modify piece values. Check each piece's description for terrain bonuses. "
		},
	]
