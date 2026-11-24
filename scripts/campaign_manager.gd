class_name CampaignManager
extends RefCounted

## Owns the full run state across all battles.
## Now uses the persistent PlayerData inventory instead of dealing random tiles.

## Enemy sequence for this run — Array of EnemyDefinitions.EnemyType
var enemy_sequence: Array = []

## Index of the current battle (0-based)
var current_battle: int = 0

## The player's tile pool for this campaign (built from PlayerData inventory)
var player_pool: Array[Piece] = []

## Tiles the player has selected to bring into the current battle
var battle_hand: Array[Piece] = []

## Track wins/losses for the run
var wins: int = 0
var losses: int = 0

## Whether a campaign is currently active
var is_active: bool = false

## ── Setup ──────────────────────────────────────────────────────

## Start a campaign using the player's persistent inventory.
func start_campaign_from_inventory(enemy_count: int, forced_type: EnemyDefinitions.EnemyType = -1) -> void:
	current_battle  = 0
	wins            = 0
	losses          = 0
	enemy_sequence  = _generate_enemy_sequence(enemy_count, forced_type)
	battle_hand     = []
	is_active       = true
	rebuild_pool_from_inventory()

## Rebuild the pool from the current persistent inventory
func rebuild_pool_from_inventory() -> void:
	player_pool = PlayerData.get_inventory_as_pieces()

## Legacy entry point (redirects to inventory-based)
func start_campaign(enemy_count: int, forced_type: EnemyDefinitions.EnemyType = -1) -> void:
	start_campaign_from_inventory(enemy_count, forced_type)

## ── Enemy sequence ─────────────────────────────────────────────

func _generate_enemy_sequence(count: int, forced_type: EnemyDefinitions.EnemyType = -1) -> Array:
	var seq: Array = []
	for i in range(count):
		if int(forced_type) >= 0:
			seq.append(forced_type)
		else:
			var progress := float(i) / float(max(count - 1, 1))
			if progress < 0.33:
				seq.append(EnemyDefinitions.EnemyType.WOLF)
			elif progress < 0.66:
				seq.append(EnemyDefinitions.EnemyType.BEAR)
			else:
				seq.append(EnemyDefinitions.EnemyType.NPC)
	return seq

## ── Battle hand selection ──────────────────────────────────────

## Player selects a piece from their pool to bring into battle.
## Note: ALL owned pieces (including multiple Kings) are brought into the hand
## so the player can see their full inventory count. The one-King-per-board
## limit is enforced at placement time in GameManager.place_selected_piece.
func select_for_battle(piece: Piece) -> bool:
	if not player_pool.has(piece):
		return false
	battle_hand.append(piece)
	player_pool.erase(piece)
	return true

## Player removes a piece from their battle selection back to pool.
func deselect_from_battle(piece: Piece) -> void:
	if battle_hand.has(piece):
		battle_hand.erase(piece)
		player_pool.append(piece)

## Clear the battle hand selection without consuming pieces.
func clear_battle_selection() -> void:
	for p in battle_hand:
		player_pool.append(p)
	battle_hand.clear()

## ── Post-battle ────────────────────────────────────────────────

## Called after each battle resolves.
## Placed pieces are consumed from persistent inventory by GameManager.
## Unplaced pieces from battle_hand return to pool.
func resolve_battle(placed_pieces: Array[Piece], player_won: bool) -> void:
	battle_hand.clear()

	if player_won:
		wins += 1
	else:
		losses += 1

	current_battle += 1

## ── Accessors ──────────────────────────────────────────────────

func get_current_enemy_type() -> EnemyDefinitions.EnemyType:
	return enemy_sequence[current_battle]

func get_current_enemy_name() -> String:
	return EnemyDefinitions.get_enemy_name(get_current_enemy_type())

func is_run_complete() -> bool:
	return current_battle >= enemy_sequence.size()

func battles_remaining() -> int:
	return enemy_sequence.size() - current_battle

func pool_size() -> int:
	return player_pool.size()

func get_run_summary() -> String:
	return "Run complete!  Wins: %d  |  Losses: %d" % [wins, losses]
