class_name Scoring
extends RefCounted

## Scoring pipeline — evaluates effects top-down, left-right (row 0 col 0 first).
## Order:
##   0. Terrain base bonuses
##   1. Protection (Shield / Dome mark pieces as protected)
##   2. Removal (Black Hole removes target from board)
##   3. Negation (Mage / Sleep — blocked by protection)
##   4. Buffs (Diagonal, Corner, Guard, Terrain Adj, Isolated/Tree)
##   5. Debuffs (Soldier debuff, Druid halve — blocked by protection)
##   6. Finalise totals

static func calculate_scores(board: BoardState,
		terrain: Terrain.Type = Terrain.Type.INDOORS,
		player_tile_bonus: int = 0) -> Dictionary:
	## player_tile_bonus: flat points added to EACH non-pawn, non-negated PLAYER
	## piece (e.g. the Spiced Pho Noodle Bowl recipe boost, +1). 0 = no effect.

	var log    : Array[String] = []
	var bonuses: Dictionary    = {}   ## Piece -> int
	var druid_targets: Dictionary = {}

	## All pieces in board order (top-down, left-right)
	var all_entries := board.get_all_pieces_ordered()

	## Initialise
	for entry in all_entries:
		var piece: Piece = entry[0]
		piece.is_negated   = false
		piece.is_protected = false
		piece.final_points = piece.base_points
		bonuses[piece]     = 0

	## ── STEP 0: Terrain base bonuses ─────────────────────────────
	var terrain_name := Terrain.get_terrain_name(terrain)
	for entry in all_entries:
		var piece: Piece = entry[0]
		var row: int     = entry[1]
		var col: int     = entry[2]
		var def          := PieceRegistry.get_def(piece.type)
		if def == null: continue
		var tb := def.get_terrain_bonus(terrain)
		if tb != 0:
			piece.base_points += tb
			log.append("%s %s (%d,%d) terrain [%s] +%d base → %d" % [
				_owner(piece.owner), piece.display_name, row, col,
				terrain_name, tb, piece.base_points])

	## ── STEP 1: Protection (Shield / Dome) ───────────────────────
	for entry in all_entries:
		var piece: Piece = entry[0]
		var row: int     = entry[1]
		var col: int     = entry[2]
		var def          := PieceRegistry.get_def(piece.type)
		if def == null: continue

		match def.effect_type:
			PieceDefinition.EffectType.DIRECTIONAL_PROTECT:
				## Shield protects itself from negation/debuffs from its facing direction
				piece.is_protected = true
				log.append("%s %s (%d,%d) shield active (facing %s)" % [
					_owner(piece.owner), piece.display_name, row, col,
					_dir_name(piece.direction)])

			PieceDefinition.EffectType.DOME_PROTECT:
				## Dome protects all allied adjacent pieces
				piece.is_protected = true
				for nb in board.get_all_adjacent(row, col):
					if nb != null and nb.owner == piece.owner:
						nb.is_protected = true
						log.append("%s %s (%d,%d) dome protects %s" % [
							_owner(piece.owner), piece.display_name, row, col,
							nb.display_name])

	## ── STEP 2: Removal (Black Hole) ────────────────────────────
	## Must re-fetch entries after removals
	var removed_any := false
	for entry in all_entries:
		var piece: Piece = entry[0]
		var row: int     = entry[1]
		var col: int     = entry[2]
		if piece.is_negated: continue
		var def := PieceRegistry.get_def(piece.type)
		if def == null: continue

		if def.effect_type == PieceDefinition.EffectType.REMOVE_DIRECTIONAL:
			var t := _get_directional(board, row, col, piece.direction)
			if t != null:
				var t_pos := board.find_piece(t)
				if t.is_protected:
					log.append("%s %s (%d,%d) tried to remove %s but it's protected" % [
						_owner(piece.owner), piece.display_name, row, col, t.display_name])
				else:
					board.remove_piece(t_pos[0], t_pos[1])
					log.append("%s %s (%d,%d) removes %s from the board!" % [
						_owner(piece.owner), piece.display_name, row, col, t.display_name])
					removed_any = true

	## Refresh entries after removals
	if removed_any:
		all_entries = board.get_all_pieces_ordered()
		## Re-init bonuses for remaining pieces
		bonuses.clear()
		for entry in all_entries:
			var piece: Piece = entry[0]
			if not bonuses.has(piece):
				bonuses[piece] = 0

	## ── STEP 3: Negation (top-down, left-right) ──────────────────
	## A piece that has already been negated does NOT fire its negate.
	## Protected pieces cannot be negated.
	for entry in all_entries:
		var piece: Piece = entry[0]
		var row: int     = entry[1]
		var col: int     = entry[2]
		if piece.is_negated: continue
		var def          := PieceRegistry.get_def(piece.type)
		if def == null: continue

		match def.effect_type:
			PieceDefinition.EffectType.NEGATE:
				var t := _get_directional(board, row, col, piece.direction)
				if t != null:
					if t.is_protected and _is_facing_toward(piece.direction, row, col, board.find_piece(t)):
						log.append("%s %s (%d,%d) tried to negate %s but it's protected" % [
							_owner(piece.owner), piece.display_name, row, col, t.display_name])
					else:
						t.is_negated = true
						log.append("%s %s (%d,%d) negates %s" % [
							_owner(piece.owner), piece.display_name, row, col, t.display_name])

			PieceDefinition.EffectType.ADJACENT_NEGATE:
				for nb in board.get_all_adjacent(row, col):
					if nb != null and not nb.is_negated:
						if nb.is_protected:
							log.append("%s %s (%d,%d) tried to negate %s but it's protected" % [
								_owner(piece.owner), piece.display_name, row, col, nb.display_name])
						else:
							nb.is_negated = true
							log.append("%s %s (%d,%d) negates adjacent %s" % [
								_owner(piece.owner), piece.display_name, row, col, nb.display_name])

	## ── STEP 4: Buffs (top-down, left-right) ─────────────────────
	for entry in all_entries:
		var piece: Piece = entry[0]
		var row: int     = entry[1]
		var col: int     = entry[2]
		if piece.is_negated: continue
		var def := PieceRegistry.get_def(piece.type)
		if def == null: continue

		match def.effect_type:
			PieceDefinition.EffectType.DIAGONAL_BUFF:
				for diag in board.get_diagonals(row, col):
					if diag != null and diag.owner == piece.owner:
						bonuses[diag] += def.effect_value
						log.append("%s %s (%d,%d) +%d to %s" % [
							_owner(piece.owner), piece.display_name, row, col,
							def.effect_value, diag.display_name])

			PieceDefinition.EffectType.CORNER_BONUS:
				if BoardState.is_corner(row, col):
					bonuses[piece] += def.effect_value
					log.append("%s %s (%d,%d) corner +%d" % [
						_owner(piece.owner), piece.display_name, row, col, def.effect_value])

			PieceDefinition.EffectType.GUARD_BONUS:
				var diags  := board.get_diagonals(row, col)
				var valid  := true
				for d in diags:
					if d == null or d.owner != piece.owner or d.is_negated:
						valid = false; break
					if not def.guard_types.has(d.type):
						valid = false; break
				if valid:
					bonuses[piece] += def.effect_value
					log.append("%s %s (%d,%d) guarded +%d" % [
						_owner(piece.owner), piece.display_name, row, col, def.effect_value])
				else:
					log.append("%s %s (%d,%d) not guarded +0" % [
						_owner(piece.owner), piece.display_name, row, col])

			PieceDefinition.EffectType.TERRAIN_ADJ_BUFF:
				if def.terrain_bonuses.has(int(terrain)):
					for nb in board.get_all_adjacent(row, col):
						if nb != null and nb.owner == piece.owner:
							bonuses[nb] += def.effect_value
							log.append("%s %s (%d,%d) terrain buff +%d to %s" % [
								_owner(piece.owner), piece.display_name, row, col,
								def.effect_value, nb.display_name])

			PieceDefinition.EffectType.ISOLATED_BONUS:
				## Tree: scores base points only if no adjacent pieces at all
				var isolated := true
				for nb in board.get_all_adjacent(row, col):
					if nb != null:
						isolated = false
						break
				if not isolated:
					## Zero out base — Tree scores nothing if touching anyone
					bonuses[piece] -= piece.base_points
					log.append("%s %s (%d,%d) not isolated → 0 pts" % [
						_owner(piece.owner), piece.display_name, row, col])
				else:
					log.append("%s %s (%d,%d) isolated → full %d pts" % [
						_owner(piece.owner), piece.display_name, row, col, piece.base_points])

	## ── STEP 5: Debuffs (top-down, left-right) ───────────────────
	## Protected pieces are immune to debuffs.
	for entry in all_entries:
		var piece: Piece = entry[0]
		var row: int     = entry[1]
		var col: int     = entry[2]
		if piece.is_negated: continue
		var def := PieceRegistry.get_def(piece.type)
		if def == null: continue

		match def.effect_type:
			PieceDefinition.EffectType.DEBUFF:
				var t := _get_directional(board, row, col, piece.direction)
				if t != null and t.owner != piece.owner:
					if t.is_protected:
						log.append("%s %s (%d,%d) tried to debuff %s but it's protected" % [
							_owner(piece.owner), piece.display_name, row, col, t.display_name])
					else:
						bonuses[t] -= def.effect_value
						log.append("%s %s (%d,%d) -%d to %s" % [
							_owner(piece.owner), piece.display_name, row, col,
							def.effect_value, t.display_name])

			PieceDefinition.EffectType.ADJACENT_HALVE:
				for nb in board.get_all_adjacent(row, col):
					if nb != null and nb.owner != piece.owner:
						if nb.is_protected:
							log.append("%s %s (%d,%d) tried to halve %s but it's protected" % [
								_owner(piece.owner), piece.display_name, row, col, nb.display_name])
						else:
							druid_targets[nb] = true
							log.append("%s %s (%d,%d) will halve %s" % [
								_owner(piece.owner), piece.display_name, row, col, nb.display_name])

	## ── STEP 6: Finalise ─────────────────────────────────────────
	var player_score := 0
	var enemy_score  := 0

	for entry in all_entries:
		var piece: Piece = entry[0]
		var row: int     = entry[1]
		var col: int     = entry[2]

		if piece.is_negated:
			piece.final_points = 0
			log.append("%s %s (%d,%d) negated → 0" % [
				_owner(piece.owner), piece.display_name, row, col])
		else:
			var total: int = piece.base_points + int(bonuses.get(piece, 0))
			if druid_targets.has(piece):
				total = int(floor(total / 2.0))
				log.append("%s %s (%d,%d) halved → %d" % [
					_owner(piece.owner), piece.display_name, row, col, total])
			## Recipe boost: +player_tile_bonus to each non-pawn PLAYER piece.
			if player_tile_bonus != 0 and piece.owner == Piece.Owner.PLAYER \
					and piece.type != Piece.Type.PAWN:
				total += player_tile_bonus
			piece.final_points = total
			log.append("%s %s (%d,%d) → %d pts" % [
				_owner(piece.owner), piece.display_name, row, col, total])

		if piece.owner == Piece.Owner.PLAYER:
			player_score += piece.final_points
		else:
			enemy_score += piece.final_points

	log.append("── FINAL: Player %d  |  Enemy %d ──" % [player_score, enemy_score])
	return { "player": player_score, "enemy": enemy_score, "log": log }

static func _owner(owner: Piece.Owner) -> String:
	return "Player" if owner == Piece.Owner.PLAYER else "Enemy"

## Resolves a directional target from the board based on the piece's effect_direction.
static func _get_directional(board: BoardState, row: int, col: int,
		dir: PieceDefinition.Direction) -> Piece:
	match dir:
		PieceDefinition.Direction.NORTH:
			return board.get_north(row, col)
		PieceDefinition.Direction.SOUTH:
			return board.get_south(row, col)
		PieceDefinition.Direction.EAST:
			return board.get_east(row, col)
		PieceDefinition.Direction.WEST:
			return board.get_west(row, col)
	return null

static func _dir_name(dir: PieceDefinition.Direction) -> String:
	match dir:
		PieceDefinition.Direction.NORTH: return "North"
		PieceDefinition.Direction.SOUTH: return "South"
		PieceDefinition.Direction.EAST:  return "East"
		PieceDefinition.Direction.WEST:  return "West"
	return "None"

## Check if a source direction is facing toward a target position
## (used to determine if Shield blocks from that direction)
static func _is_facing_toward(_dir: PieceDefinition.Direction, _src_row: int, _src_col: int, _target_pos: Array) -> bool:
	## For simplicity, protection always applies if the piece is marked protected
	## (Shield protects itself, Dome protects allies — both are blanket protection)
	return true
