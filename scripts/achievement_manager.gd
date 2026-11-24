extends Node

## Autoload: Achievements
## Tracks player achievements, awards coin rewards on unlock, persists to disk.
## Tiered achievements have 10 levels with escalating thresholds.
## One-time achievements unlock once when their condition is met.

const SAVE_PATH := "user://achievements.cfg"

## Tiered achievement thresholds (levels 1–10). Used by "count" achievements
## (enemies beaten, crops harvested, expeditions completed, etc.). Ramps from an
## accessible start up to 50,000 at the top tier so these are long-haul goals —
## difficult but reachable. NOTE: streak achievements (kill_streak, mining_streak)
## do NOT use this; they define their own small, sane thresholds.
const TIER_THRESHOLDS: Array[int] = [50, 150, 400, 1000, 2500, 5000, 10000, 20000, 35000, 50000]

## Thresholds for STREAK achievements (consecutive wins). Kept small and sane —
## a 50,000 win streak is impossible, so these top out at a challenging-but-real 50.
const STREAK_TIER_THRESHOLDS: Array[int] = [3, 5, 8, 12, 16, 20, 25, 30, 40, 50]

## Total terrain count for Adventure Seeker (all 7 terrains)
const TOTAL_TERRAINS := 7

## Max seconds between two mission completions for them to count toward the
## "quick succession" achievement (missions_speed). 5 minutes.
const MISSION_SPEED_WINDOW := 300.0

## ── Signals ────────────────────────────────────────────────────

signal achievement_unlocked(achievement_id: String, level: int, chest_level: int)

## ── Achievement Definitions ────────────────────────────────────

## Tiered achievements: progress through 10 levels based on a tracked stat.
## Chest reward: level 1 = chest index 0 (300c budget), level 10 = chest index 9 (3000c budget).
const ACHIEVEMENTS: Dictionary = {
	"bully": {
		"title": "Bully",
		"description": "Beat %d enemies",
		"type": "tiered",
	},
	"canine_killer": {
		"title": "Canine Killer",
		"description": "Beat %d Wolves",
		"type": "tiered",
	},
	"bear_beater": {
		"title": "Bear Beater",
		"description": "Beat %d Bears",
		"type": "tiered",
	},
	"npc_wrangler": {
		"title": "NPC Wrangler",
		"description": "Beat %d NPCs",
		"type": "tiered",
	},
	"kill_streak": {
		"title": "Kill Streak X",
		"description": "Achieve a win streak of %d",
		"type": "tiered",
		"tier_thresholds": STREAK_TIER_THRESHOLDS,
	},
	## Slayer (multiplayer win streak) — hidden until multiplayer is hooked up.
	## Kept here (commented) so it's easy to re-enable later. While commented out,
	## it won't appear on the achievements screen or be trackable.
#	"slayer": {
#		"title": "Slayer",
#		"description": "Achieve a multiplayer win streak of %d",
#		"type": "tiered",
#	},
	"pawn_manipulator": {
		"title": "Pawn Manipulator",
		"description": "Win using only pawns",
		"type": "one_time",
	},
	"kingly_placement": {
		"title": "Kingly Placement",
		"description": "Correctly place a King (score 7 pts)",
		"type": "one_time",
	},
	"rooted_deep": {
		"title": "Rooted Deep",
		"description": "Correctly place a Tree (score 5+ pts)",
		"type": "one_time",
	},
	"watchful_eye": {
		"title": "The Watchful Eye",
		"description": "Correctly place a Watchtower in corner (score 6 pts)",
		"type": "one_time",
	},
	"always_learning": {
		"title": "Always Down to Learn",
		"description": "Read the tutorial",
		"type": "one_time",
	},
	"baby_steps": {
		"title": "Baby Steps",
		"description": "Win your first battle",
		"type": "one_time",
	},
	"adventure_seeker": {
		"title": "Adventure Seeker",
		"description": "Play on each terrain at least once",
		"type": "one_time",
	},
	"blown_away": {
		"title": "Blown Away",
		"description": "Activate a Wind tile on Desert terrain",
		"type": "one_time",
	},
	"location_luster": {
		"title": "Location Luster",
		"description": "Activate a terrain bonus",
		"type": "one_time",
	},
	## ── Mining Achievements ─────────────────────────────────────
	"mining_small_wins": {
		"title": "Small Excavator",
		"description": "Complete %d small expeditions (8×8)",
		"type": "tiered",
	},
	"mining_large_wins": {
		"title": "Deep Miner",
		"description": "Complete %d large expeditions (16×16)",
		"type": "tiered",
	},
	"mining_streak": {
		"title": "Lucky Prospector",
		"description": "Achieve a mining win streak of %d",
		"type": "tiered",
		"tier_thresholds": STREAK_TIER_THRESHOLDS,
	},
	"mining_first_small": {
		"title": "First Dig",
		"description": "Complete a small expedition",
		"type": "one_time",
	},
	"mining_first_large": {
		"title": "Ambitious Miner",
		"description": "Complete a large expedition",
		"type": "one_time",
	},
	"mining_first_click_loss": {
		"title": "Unlucky Strike",
		"description": "Hit a treasure on your very first dig",
		"type": "one_time",
	},
	"mining_triple_first_click": {
		"title": "Cursed Prospector",
		"description": "Lose on the first click 3 times in a row",
		"type": "one_time",
		"chest_level": 4,
	},
	## ── Garden Achievements ─────────────────────────────────────
	"garden_first_harvest": {
		"title": "Green Thumb",
		"description": "Harvest your first crop",
		"type": "one_time",
		"chest_level": 2,
	},
	"garden_beans": {
		"title": "Bean Counter",
		"description": "Harvest %d Beans",
		"type": "tiered",
	},
	"garden_cucumbers": {
		"title": "Cool as a Cucumber",
		"description": "Harvest %d Cucumbers",
		"type": "tiered",
	},
	"garden_peppers": {
		"title": "Spice Lord",
		"description": "Harvest %d Peppers",
		"type": "tiered",
	},
	"garden_squash": {
		"title": "Squash Master",
		"description": "Harvest %d Squash",
		"type": "tiered",
	},
	"garden_grapes": {
		"title": "Vintner",
		"description": "Harvest %d Grapes",
		"type": "tiered",
	},
	"garden_sunflower": {
		"title": "Sunshine Grower",
		"description": "Harvest %d Sunflowers",
		"type": "tiered",
	},
	"garden_cauliflower": {
		"title": "Head of the Garden",
		"description": "Harvest %d Cauliflower",
		"type": "tiered",
	},
	"garden_pineapple": {
		"title": "Tropical Farmer",
		"description": "Harvest %d Pineapples",
		"type": "tiered",
	},
	"garden_watermelon": {
		"title": "Melon Mogul",
		"description": "Harvest %d Watermelons",
		"type": "tiered",
	},
	"garden_full": {
		"title": "Master Gardener",
		"description": "Fill a full 16×16 garden",
		"type": "one_time",
		"chest_level": 9,
	},
	## ── Garden Single-Crop Full Garden Achievements ──────────────
	"garden_full_beans": {
		"title": "The Bean Farm",
		"description": "Fill the full 16×16 garden with only Beans",
		"type": "one_time",
		"chest_level": 5,
	},
	"garden_full_cucumbers": {
		"title": "Cucumber Kingdom",
		"description": "Fill the full 16×16 garden with only Cucumbers",
		"type": "one_time",
		"chest_level": 5,
	},
	"garden_full_peppers": {
		"title": "The Pepper Patch",
		"description": "Fill the full 16×16 garden with only Peppers",
		"type": "one_time",
		"chest_level": 6,
	},
	"garden_full_squash": {
		"title": "Squash Supreme",
		"description": "Fill the full 16×16 garden with only Squash",
		"type": "one_time",
		"chest_level": 6,
	},
	"garden_full_grapes": {
		"title": "The Vineyard",
		"description": "Fill the full 16×16 garden with only Grapes",
		"type": "one_time",
		"chest_level": 7,
	},
	"garden_full_sunflower": {
		"title": "Fields of Gold",
		"description": "Fill the full 16×16 garden with only Sunflowers",
		"type": "one_time",
		"chest_level": 7,
	},
	"garden_full_cauliflower": {
		"title": "Cauliflower Crown",
		"description": "Fill the full 16×16 garden with only Cauliflower",
		"type": "one_time",
		"chest_level": 7,
	},
	"garden_full_pineapple": {
		"title": "Tropical Paradise",
		"description": "Fill the full 16×16 garden with only Pineapples",
		"type": "one_time",
		"chest_level": 8,
	},
	"garden_full_watermelon": {
		"title": "The Melon Patch",
		"description": "Fill the full 16×16 garden with only Watermelons",
		"type": "one_time",
		"chest_level": 8,
	},
	## ── Orchard Achievements ────────────────────────────────────
	## Per-tree planting achievements: same early pacing as garden crops but
	## capped at 250 (trees take a full plot, so 1000 is unreachable). The
	## total-trees "Arborist" achievement was removed.
	"orchard_trees_plum": {
		"title": "Plum Planter",
		"description": "Plant %d Plum trees",
		"type": "tiered",
		"tier_thresholds": [5, 15, 30, 60, 100, 150, 200, 225, 240, 250],
	},
	"orchard_trees_lemon": {
		"title": "Lemon Planter",
		"description": "Plant %d Lemon trees",
		"type": "tiered",
		"tier_thresholds": [5, 15, 30, 60, 100, 150, 200, 225, 240, 250],
	},
	"orchard_trees_apple": {
		"title": "Apple Planter",
		"description": "Plant %d Apple trees",
		"type": "tiered",
		"tier_thresholds": [5, 15, 30, 60, 100, 150, 200, 225, 240, 250],
	},
	"orchard_trees_banana": {
		"title": "Banana Planter",
		"description": "Plant %d Banana trees",
		"type": "tiered",
		"tier_thresholds": [5, 15, 30, 60, 100, 150, 200, 225, 240, 250],
	},
	"orchard_trees_coconut": {
		"title": "Coconut Planter",
		"description": "Plant %d Coconut trees",
		"type": "tiered",
		"tier_thresholds": [5, 15, 30, 60, 100, 150, 200, 225, 240, 250],
	},
	"orchard_full": {
		"title": "Grand Orchard",
		"description": "Fill the full 16×16 orchard with trees",
		"type": "one_time",
		"chest_level": 9,
	},
	## ── Orchard Single-Tree-Type Full Orchard Achievements ─────
	"orchard_full_plum": {
		"title": "Plum Paradise",
		"description": "Fill the full 16×16 orchard with only Plum trees",
		"type": "one_time",
		"chest_level": 7,
	},
	"orchard_full_lemon": {
		"title": "Lemon Grove",
		"description": "Fill the full 16×16 orchard with only Lemon trees",
		"type": "one_time",
		"chest_level": 7,
	},
	"orchard_full_apple": {
		"title": "The Apple Orchard",
		"description": "Fill the full 16×16 orchard with only Apple trees",
		"type": "one_time",
		"chest_level": 8,
	},
	"orchard_full_banana": {
		"title": "Banana Plantation",
		"description": "Fill the full 16×16 orchard with only Banana trees",
		"type": "one_time",
		"chest_level": 8,
	},
	"orchard_full_coconut": {
		"title": "Coconut Coast",
		"description": "Fill the full 16×16 orchard with only Coconut trees",
		"type": "one_time",
		"chest_level": 9,
	},
	## ── Gold Panning Achievements ────────────────────────────────
	"first_diamond_panned": {
		"title": "Diamond in the Rough",
		"description": "Pan your first diamond",
		"type": "one_time",
	},
	"panning_enthusiast": {
		"title": "Panning Enthusiast",
		"description": "Complete 10 panning rounds",
		"type": "one_time",
		"progress_threshold": 10,
	},
	"panning_master": {
		"title": "Panning Master",
		"description": "Complete 50 panning rounds",
		"type": "one_time",
		"chest_level": 6,
		"progress_threshold": 50,
	},
	"complete_collection": {
		"title": "Complete Collection",
		"description": "Collect at least 1 of all 8 gem types",
		"type": "one_time",
		"chest_level": 8,
		"progress_threshold": 8,
	},
	## ── Presents Achievement ────────────────────────────────────
	"presents_all": {
		"title": "All Wrapped Up",
		"description": "Hold all 8 presents in your inventory at once",
		"type": "one_time",
		"chest_level": 9,
	},
	## ── Prospector Achievements ─────────────────────────────────
	"prospector_novice": {
		"title": "Novice Prospector",
		"description": "Own 1 prospector",
		"type": "one_time",
		"chest_level": 2,
		"progress_threshold": 1,
	},
	"prospector_5": {
		"title": "Prospector Team",
		"description": "Own 5 prospectors total",
		"type": "one_time",
		"chest_level": 3,
		"progress_threshold": 5,
	},
	"prospector_10": {
		"title": "Prospector Crew",
		"description": "Own 10 prospectors total",
		"type": "one_time",
		"chest_level": 4,
		"progress_threshold": 10,
	},
	"prospector_25": {
		"title": "Prospector Foreman",
		"description": "Own 25 prospectors total",
		"type": "one_time",
		"chest_level": 5,
		"progress_threshold": 25,
	},
	"prospector_50": {
		"title": "Prospector Boss",
		"description": "Own 50 prospectors total",
		"type": "one_time",
		"chest_level": 6,
		"progress_threshold": 50,
	},
	"prospector_100": {
		"title": "Mining Magnate",
		"description": "Own 100 prospectors total",
		"type": "one_time",
		"chest_level": 7,
		"progress_threshold": 100,
	},
	"prospector_250": {
		"title": "Gem Baron",
		"description": "Own 250 prospectors total",
		"type": "one_time",
		"chest_level": 8,
		"progress_threshold": 250,
	},
	"prospector_500": {
		"title": "Prospector Tycoon",
		"description": "Own 500 prospectors total",
		"type": "one_time",
		"chest_level": 9,
		"progress_threshold": 500,
	},
	"prospector_750": {
		"title": "Prospector Empire",
		"description": "Own 750 prospectors total",
		"type": "one_time",
		"chest_level": 9,
		"progress_threshold": 750,
	},
	"prospector_1000": {
		"title": "Prospector Legend",
		"description": "Own 1000 prospectors total",
		"type": "one_time",
		"chest_level": 9,
		"progress_threshold": 1000,
	},
	## ── Mission Board Achievements ──────────────────────────────
	"missions_completed": {
		"title": "Mission Specialist",
		"description": "Complete %d missions",
		"type": "tiered",
	},
	"missions_easy": {
		"title": "Easy Rider",
		"description": "Complete %d easy missions",
		"type": "tiered",
	},
	"missions_medium": {
		"title": "Seasoned Operative",
		"description": "Complete %d medium missions",
		"type": "tiered",
	},
	"missions_hard": {
		"title": "Elite Agent",
		"description": "Complete %d hard missions",
		"type": "tiered",
	},
	## Speed run: only increments when two missions are completed within 5
	## minutes of each other (see record_mission_completed / MISSION_SPEED_WINDOW).
	"missions_speed": {
		"title": "Rapid Responder",
		"description": "Complete %d missions in quick succession (within 5 min)",
		"type": "tiered",
	},
	## ── Level Milestone Achievement ─────────────────────────────
	## One tiered achievement covering every 5th level from 5 to 100 (20 tiers).
	## Chests are granted by record_level_reached() (not the generic tiered
	## chest path) so higher milestones can award multiple top-tier chests:
	## levels 5–45 → 1 chest, 50–95 → 2 chests, 100 → 3 chests. See MILESTONE_LEVELS.
	"level_milestones": {
		"title": "Rising Star",
		"description": "Reach level %d",
		"type": "tiered",
		"tier_thresholds": [5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100],
	},
}

## Player levels that grant a milestone reward, and how many top-tier (index 9,
## "Lv.10") chests each grants. Levels 5–45 give 1 chest, 50–95 give 2, and the
## final level 100 gives 3.
const MILESTONE_LEVELS: Array[int] = [5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100]

## The highest chest tier (index 9 = the "Lv.10" chest) used for level milestones.
const MILESTONE_CHEST_LEVEL := 9

## ── Runtime State ──────────────────────────────────────────────

## Achievement progress: { achievement_id -> { "progress": int, "level": int } }
var _progress: Dictionary = {}

## Kill streak tracking
var _current_streak: int = 0
var _current_mp_streak: int = 0
var _current_mining_streak: int = 0
var _first_click_loss_streak: int = 0

## Best streak records (all-time highs)
var best_win_streak: int = 0
var best_mining_streak: int = 0

## Set of terrains played (stored as Array of ints for serialization)
var _terrains_played: Array = []

## Unix time of the most recent mission completion, used to detect completions
## within MISSION_SPEED_WINDOW for the "missions_speed" achievement. 0 = none yet.
var _last_mission_complete_time: float = 0.0

## One-time flag: whether the first-click-loss achievement reset migration has
## run. The old logic could unlock these without truly consecutive first-click
## losses, so existing unlocks are cleared once to be re-earned legitimately.
var _first_click_reset_done: bool = false

## ── Lifecycle ──────────────────────────────────────────────────

func _ready() -> void:
	_init_progress()
	load_data()
	achievement_unlocked.connect(_show_chest_popup)
	## Defer sync so PlayerData is fully loaded first
	call_deferred("_sync_prospector_achievements")
	call_deferred("_sync_orchard_achievements")
	call_deferred("_connect_level_milestones")
	## Catch up the "all 8 presents" achievement for saves that already hold them.
	call_deferred("record_presents_checked")


## Connects to PlayerData's level-up signal so reaching a milestone level (every
## 5th level to 100) grants its chest(s). Also runs one catch-up pass so players
## already past a milestone unlock the ones they've earned. Deferred from _ready
## so PlayerData is fully loaded first.
func _connect_level_milestones() -> void:
	if get_node_or_null("/root/PlayerData") == null:
		return
	if not PlayerData.leveled_up.is_connected(_on_player_leveled_up):
		PlayerData.leveled_up.connect(_on_player_leveled_up)
	## Catch up any milestones already reached, based on peak_level (the all-time
	## high-water mark) so prestige spending XP never loses an earned milestone.
	## batch=true merges all owed chests into a single combined chest so an
	## existing high-level player opens one chest instead of a long stack.
	record_level_reached(PlayerData.peak_level, true)


func _on_player_leveled_up(_new_level: int, _rewards: Array) -> void:
	## Milestones track peak_level (the all-time high-water mark), NOT the
	## fluctuating current level — prestige can spend XP and lower `level`, but
	## an earned milestone must never un-earn or re-trigger. peak_level is
	## already updated by recalculate_level() before this signal fires.
	record_level_reached(PlayerData.peak_level)


## Syncs prospector and panning achievements against current save data.
## Catches up players whose data predates the achievement tracking calls.
func _sync_prospector_achievements() -> void:
	## Total prospectors owned right now
	var total_owned := 0
	for gt in PlayerData.prospectors:
		total_owned += PlayerData.prospectors[gt]
	if total_owned > 0:
		record_prospector_purchase(total_owned)

	## Panning rounds — read from PlayerData's save file under [panning] section
	var panning_cfg := ConfigFile.new()
	if panning_cfg.load(PlayerData.SAVE_PATH) == OK:
		var rounds: int = int(panning_cfg.get_value("panning", "lifetime_rounds", 0))
		if rounds > 0:
			for entry in [["panning_enthusiast", 10], ["panning_master", 50]]:
				var ach_id: String = entry[0]
				var threshold: int = entry[1]
				if not _progress.has(ach_id):
					_progress[ach_id] = {"progress": 0, "level": 0}
				if rounds > int(_progress[ach_id].get("progress", 0)):
					_progress[ach_id]["progress"] = rounds
				if rounds >= threshold and _progress[ach_id].get("level", 0) < 1:
					_try_unlock_one_time(ach_id)
		save_data()


## Syncs orchard achievements against saved orchard state.
func _sync_orchard_achievements() -> void:
	var orchard_cfg := ConfigFile.new()
	if orchard_cfg.load(OrchardData.SAVE_PATH) == OK:
		## (The total-trees "Arborist" achievement was removed; per-type sync below.)
		var by_type = orchard_cfg.get_value("orchard", "lifetime_trees_planted_by_type", {})
		if by_type is Dictionary:
			for tt in by_type:
				var type_idx: int = int(tt)
				var count: int = int(by_type[tt])
				if type_idx >= 0 and type_idx < ORCHARD_PLANT_TREE_ACHIEVEMENT_IDS.size():
					var ach_id: String = ORCHARD_PLANT_TREE_ACHIEVEMENT_IDS[type_idx]
					if not _progress.has(ach_id):
						_progress[ach_id] = {"progress": 0, "level": 0}
					if count > int(_progress[ach_id].get("progress", 0)):
						_progress[ach_id]["progress"] = count
						_check_tiered_levelup(ach_id)

		var rows: int = int(orchard_cfg.get_value("orchard", "rows", 0))
		var cols: int = int(orchard_cfg.get_value("orchard", "cols", 0))
		var grid_data = orchard_cfg.get_value("orchard", "grid", [])
		if rows >= OrchardData.MAX_ROWS and cols >= OrchardData.MAX_COLS and grid_data is Array:
			var all_filled := true
			var first_type := -1
			var all_same_type := true
			for r in range(rows):
				if r >= grid_data.size() or not (grid_data[r] is Array):
					all_filled = false
					break
				for c in range(cols):
					if c >= grid_data[r].size() or grid_data[r][c] == null:
						all_filled = false
						all_same_type = false
						break
					var cell = grid_data[r][c]
					if cell is Dictionary and cell.get("is_stump", false):
						all_filled = false
						all_same_type = false
						break
					var cell_type: int = cell.get("tree_type", -1) if cell is Dictionary else -1
					if first_type == -1:
						first_type = cell_type
					elif cell_type != first_type:
						all_same_type = false
				if not all_filled:
					break
			if all_filled:
				_try_unlock_one_time("orchard_full")
				if all_same_type and first_type >= 0:
					record_orchard_full_single_tree(first_type)
		save_data()


## Shows a ChestPopup when any achievement unlocks. Generates rewards based on chest_level.
func _show_chest_popup(achievement_id: String, level: int, chest_level: int) -> void:
	var def: Dictionary = ACHIEVEMENTS.get(achievement_id, {})
	var title: String = def.get("title", achievement_id)
	var desc: String = def.get("description", "")
	## For tiered achievements, format description with the threshold
	if def.get("type", "") == "tiered":
		var thresholds: Array = def.get("tier_thresholds", TIER_THRESHOLDS)
		if level > 0 and level <= thresholds.size():
			desc = desc % thresholds[level - 1]

	## Generate rewards: budget = (chest_level + 1) * 300
	var budget: int = (chest_level + 1) * 300
	var rewards: Array = PlayerData._generate_level_rewards_from_budget(budget, PlayerData.get_chest_piece_cap(chest_level), chest_level)

	## Orchard achievements pay out much larger coin rewards. Override the
	## generated coin entry (or add one) with the orchard-specific amount.
	var orchard_coins: int = _orchard_coin_reward(achievement_id, level)
	if orchard_coins > 0:
		var found_coins := false
		for reward in rewards:
			if reward is Dictionary and reward.has("type") and reward["type"] == "coins":
				reward["amount"] = orchard_coins
				found_coins = true
				break
		if not found_coins:
			rewards.append({"type": "coins", "amount": orchard_coins})

	PlayerData._add_reward_pieces(rewards)
	PlayerData.save_data()

	## Build display-friendly reward list for the popup
	var display_rewards: Array = []
	for reward in rewards:
		if reward is Dictionary and reward.has("type") and reward["type"] == "coins":
			display_rewards.append({"type": "coins", "amount": int(reward["amount"])})
		elif reward is Dictionary and reward.get("type", "") == "sapling":
			display_rewards.append({
				"type": "sapling",
				"tree_type": int(reward["tree_type"]),
				"quantity": int(reward.get("quantity", 1)),
			})
		elif reward is Dictionary and reward.get("type", "") == "prospector":
			display_rewards.append({
				"type": "prospector",
				"gem_type": str(reward["gem_type"]),
				"quantity": int(reward.get("quantity", 1)),
			})
		elif reward is Dictionary and reward.has("seed_type"):
			display_rewards.append({
				"type": "seed",
				"plant_type": int(reward["seed_type"]),
				"quantity": int(reward["quantity"]),
			})
		elif reward is Dictionary and reward.has("gem_type"):
			var gval := 0
			for gdef in PlayerData.PROSPECTOR_GEM_ORDER:
				if gdef["gem_type"] == reward["gem_type"]:
					gval = int(gdef["value"])
					break
			display_rewards.append({
				"type": "gemstone",
				"gem_type": str(reward["gem_type"]),
				"value": gval,
			})
		elif reward is Dictionary and str(reward.get("type", "")) in ["resource", "material"]:
			## Ores/bars and WonderStones — ChestPopup renders these shapes as-is.
			display_rewards.append(reward)
		elif reward is int or reward is float:
			display_rewards.append({
				"type": "piece",
				"piece_type": int(reward),
			})
		## Anything else is an unknown reward shape: granted, just not displayed.

	ChestPopup.enqueue(get_tree(), chest_level, display_rewards, title, desc)


## Coin reward for orchard achievements. Returns 0 for non-orchard achievements
## (so the normal chest coin reward is used instead).
##   Tiered planting achievements: 500k at tier 1, +500k per tier (up to 5m at tier 10).
##   Full-orchard one-time achievements: large fixed payouts, with a full
##   coconut orchard awarding 1 billion coins.
func _orchard_coin_reward(achievement_id: String, level: int) -> int:
	match achievement_id:
		"orchard_full_coconut":
			return 1_000_000_000
		"orchard_full":
			return 500_000_000
		"orchard_full_apple", "orchard_full_banana":
			return 250_000_000
		"orchard_full_plum", "orchard_full_lemon":
			return 100_000_000

	## Tiered planting achievements: at least 500k, incrementing per tier.
	if achievement_id.begins_with("orchard_trees_"):
		return 500_000 * maxi(level, 1)

	return 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_data()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		save_data()


## Initializes progress dictionary with defaults for all achievements.
func _init_progress() -> void:
	for id in ACHIEVEMENTS:
		if not _progress.has(id):
			_progress[id] = { "progress": 0, "level": 0 }


## Coerces an arbitrary saved value into a well-formed { "progress": int,
## "level": int } entry. Older/partial saves may store a differently-shaped
## value (a bare int, a dict missing "level", null, etc.). Reading prog["level"]
## off such a value would yield 0 and make a completed achievement look
## incomplete — so we repair the shape here instead of storing it raw. If a
## legacy entry stored only a scalar, we treat it as progress and infer level
## conservatively (>=1 means at least tier/unlock 1 so completion isn't lost).
func _normalize_progress_entry(raw) -> Dictionary:
	if raw is Dictionary:
		return {
			"progress": maxi(int(raw.get("progress", 0)), 0),
			"level": maxi(int(raw.get("level", 0)), 0),
		}
	## Legacy scalar (int/float/bool) — interpret as progress, infer unlock.
	if raw is int or raw is float:
		var p := int(raw)
		return { "progress": maxi(p, 0), "level": (1 if p >= 1 else 0) }
	if raw is bool:
		return { "progress": (1 if raw else 0), "level": (1 if raw else 0) }
	return { "progress": 0, "level": 0 }


## ── Public Recording Methods ───────────────────────────────────

## Call after any win (SP or MP). Updates bully, enemy-specific, streak, and baby_steps.
func record_win(enemy_type: int) -> void:
	## Bully — total wins
	_increment_progress("bully")

	## Enemy-specific
	match enemy_type:
		EnemyDefinitions.EnemyType.WOLF:
			_increment_progress("canine_killer")
		EnemyDefinitions.EnemyType.BEAR:
			_increment_progress("bear_beater")
		EnemyDefinitions.EnemyType.NPC:
			_increment_progress("npc_wrangler")

	## Kill streak
	_current_streak += 1
	if _current_streak > best_win_streak:
		best_win_streak = _current_streak
	_update_streak_progress("kill_streak", _current_streak)

	## Baby steps — first win ever
	_try_unlock_one_time("baby_steps")

	save_data()


## Call after MP win specifically. Updates slayer streak.
func record_multiplayer_win() -> void:
	_current_mp_streak += 1
	_update_streak_progress("slayer", _current_mp_streak)
	save_data()


## Call after any loss. Resets kill streaks and their progress.
func record_loss() -> void:
	_current_streak = 0
	_current_mp_streak = 0
	## Reset streak achievement progress (player must rebuild their streak)
	if _progress.has("kill_streak"):
		_progress["kill_streak"]["progress"] = 0
	if _progress.has("slayer"):
		_progress["slayer"]["progress"] = 0
	save_data()


## Track terrains played. Awards Adventure Seeker when all 7 are visited.
func record_terrain_played(terrain: int) -> void:
	if terrain not in _terrains_played:
		_terrains_played.append(terrain)
	if _terrains_played.size() >= TOTAL_TERRAINS:
		_try_unlock_one_time("adventure_seeker")
	save_data()


## Call when the tutorial is read.
func record_tutorial_read() -> void:
	_try_unlock_one_time("always_learning")
	save_data()


## Call when a Wind tile is activated on Desert terrain.
func record_wind_activated_desert() -> void:
	_try_unlock_one_time("blown_away")
	save_data()


## Call when any terrain bonus is activated.
func record_terrain_bonus_activated() -> void:
	_try_unlock_one_time("location_luster")
	save_data()


## ── Mining Achievement Recording ───────────────────────────────

## Call after winning a mining expedition. is_large = true for 16×16 board.
func record_mining_win(is_large: bool) -> void:
	if is_large:
		_increment_progress("mining_large_wins")
		_try_unlock_one_time("mining_first_large")
	else:
		_increment_progress("mining_small_wins")
		_try_unlock_one_time("mining_first_small")

	## Mining win streak
	_current_mining_streak += 1
	if _current_mining_streak > best_mining_streak:
		best_mining_streak = _current_mining_streak
	_update_streak_progress("mining_streak", _current_mining_streak)

	## A win breaks the consecutive first-click-loss chain. Without this, wins
	## between first-click losses wouldn't reset the streak, so separated losses
	## could wrongly count toward the "three in a row" achievement.
	_first_click_loss_streak = 0

	save_data()


## Call after losing a mining expedition. player_digs = how many tiles the
## player actively dug before the loss (excludes prestige pre-reveals/magnify),
## so a first-click loss is detected even with the safe-tiles prestige active.
func record_mining_loss(player_digs: int) -> void:
	_current_mining_streak = 0
	if _progress.has("mining_streak"):
		_progress["mining_streak"]["progress"] = 0

	## First click loss — hit a mine on the player's very first dig
	if player_digs == 0:
		_try_unlock_one_time("mining_first_click_loss")
		_first_click_loss_streak += 1
		if _first_click_loss_streak >= 3:
			_try_unlock_one_time("mining_triple_first_click")
	else:
		## Got past the first click before losing — reset the streak
		_first_click_loss_streak = 0

	save_data()


## One-time migration: clears any prior unlock/progress on the two first-click
## achievements plus the tracking streak, so players re-earn them under the
## corrected consecutive-first-click logic. Guarded by _first_click_reset_done.
func _migrate_reset_first_click_achievements() -> void:
	for id in ["mining_first_click_loss", "mining_triple_first_click"]:
		_progress[id] = { "progress": 0, "level": 0 }
	_first_click_loss_streak = 0
	_first_click_reset_done = true
	save_data()


## ── Garden Achievement Recording ───────────────────────────────

## Map PlantType index to achievement ID
const GARDEN_ACHIEVEMENT_IDS: Array[String] = [
	"garden_beans", "garden_cucumbers", "garden_peppers", "garden_squash",
	"garden_grapes", "garden_sunflower", "garden_cauliflower", "garden_pineapple",
	"garden_watermelon",
]

## Call after harvesting a plant. plant_type is the GardenData.PlantType index.
func record_garden_harvest(plant_type: int) -> void:
	## First harvest ever
	_try_unlock_one_time("garden_first_harvest")

	## Per-plant tiered achievement
	if plant_type >= 0 and plant_type < GARDEN_ACHIEVEMENT_IDS.size():
		_increment_progress(GARDEN_ACHIEVEMENT_IDS[plant_type])

	save_data()


## Call when the garden is fully filled at 16×16.
func record_garden_full() -> void:
	_try_unlock_one_time("garden_full")
	save_data()


## Map PlantType index to single-crop full-garden achievement ID.
const GARDEN_FULL_CROP_ACHIEVEMENT_IDS: Array[String] = [
	"garden_full_beans", "garden_full_cucumbers", "garden_full_peppers", "garden_full_squash",
	"garden_full_grapes", "garden_full_sunflower", "garden_full_cauliflower",
	"garden_full_pineapple", "garden_full_watermelon",
]

## Call when the full 16×16 garden is filled entirely with one crop type.
func record_garden_full_single_crop(plant_type: int) -> void:
	if plant_type >= 0 and plant_type < GARDEN_FULL_CROP_ACHIEVEMENT_IDS.size():
		_try_unlock_one_time(GARDEN_FULL_CROP_ACHIEVEMENT_IDS[plant_type])
	save_data()


## ── Orchard Achievement Recording ──────────────────────────────

## Map TreeType index to single-tree planting achievement ID.
const ORCHARD_PLANT_TREE_ACHIEVEMENT_IDS: Array[String] = [
	"orchard_trees_plum",
	"orchard_trees_lemon",
	"orchard_trees_apple",
	"orchard_trees_banana",
	"orchard_trees_coconut",
]

## Map TreeType index to single-tree full-orchard achievement ID.
const ORCHARD_FULL_TREE_ACHIEVEMENT_IDS: Array[String] = [
	"orchard_full_plum",
	"orchard_full_lemon",
	"orchard_full_apple",
	"orchard_full_banana",
	"orchard_full_coconut",
]

## Call after planting a tree in the orchard.
func record_orchard_tree_planted(tree_type: int = -1) -> void:
	if tree_type >= 0 and tree_type < ORCHARD_PLANT_TREE_ACHIEVEMENT_IDS.size():
		_increment_progress(ORCHARD_PLANT_TREE_ACHIEVEMENT_IDS[tree_type])
	save_data()


## Call when the orchard is fully filled at 16×16.
func record_orchard_full() -> void:
	_try_unlock_one_time("orchard_full")
	save_data()


## Call when the full 16×16 orchard is filled entirely with one tree type.
func record_orchard_full_single_tree(tree_type: int) -> void:
	if tree_type >= 0 and tree_type < ORCHARD_FULL_TREE_ACHIEVEMENT_IDS.size():
		_try_unlock_one_time(ORCHARD_FULL_TREE_ACHIEVEMENT_IDS[tree_type])
	save_data()


## Call after purchasing a prospector. total_owned = total across all types.
func record_prospector_purchase(total_owned: int) -> void:
	var thresholds: Array = [
		["prospector_novice", 1],
		["prospector_5", 5],
		["prospector_10", 10],
		["prospector_25", 25],
		["prospector_50", 50],
		["prospector_100", 100],
		["prospector_250", 250],
		["prospector_500", 500],
		["prospector_750", 750],
		["prospector_1000", 1000],
	]
	for entry in thresholds:
		var ach_id: String = entry[0]
		var threshold: int = entry[1]
		if not _progress.has(ach_id):
			_progress[ach_id] = {"progress": 0, "level": 0}
		## Unlock (and award the chest) once the threshold is reached.
		if total_owned >= threshold and _progress[ach_id]["level"] < 1:
			_try_unlock_one_time(ach_id)
		## Record current progress so the achievements screen shows the real
		## count (e.g. "50/1000"). Use max() so a transiently-low total_owned
		## (e.g. prospectors not fully loaded, or a partial restore) can never
		## LOWER the stored progress and make the bar regress.
		_progress[ach_id]["progress"] = maxi(int(_progress[ach_id].get("progress", 0)), total_owned)
	save_data()


## Call whenever present counts may have changed (produced, bought, sold, used).
## Unlocks "All Wrapped Up" if the player currently holds all 8 present variants
## at the same time. Also records live progress (owned distinct variants / 8).
func record_presents_checked() -> void:
	if get_node_or_null("/root/PlayerData") == null:
		return
	var distinct := 0
	for v in range(PlayerData.PRESENT_COUNT):
		if PlayerData.get_present_count(v) > 0:
			distinct += 1
	if not _progress.has("presents_all"):
		_progress["presents_all"] = {"progress": 0, "level": 0}
	if distinct >= PlayerData.PRESENT_COUNT and _progress["presents_all"]["level"] < 1:
		_try_unlock_one_time("presents_all")
	else:
		## Show real progress (distinct owned / 8) until unlocked.
		if _progress["presents_all"]["level"] < 1:
			_progress["presents_all"]["progress"] = distinct
	save_data()


## Call when a mission is completed (reward claimed). Always advances the
## "Mission Specialist" total plus the per-difficulty track, and advances the
## "Rapid Responder" speed achievement only when this completion falls within
## MISSION_SPEED_WINDOW (5 minutes) of the previous one.
## difficulty: 0 = Easy, 1 = Medium, 2 = Hard (MissionBoard.Difficulty). -1 or
## any unknown value skips the per-difficulty track.
func record_mission_completed(difficulty: int = -1) -> void:
	## Total missions completed — increments every time.
	_increment_progress("missions_completed")

	## Per-difficulty track.
	match difficulty:
		0: _increment_progress("missions_easy")
		1: _increment_progress("missions_medium")
		2: _increment_progress("missions_hard")

	## Quick-succession: only counts if the previous completion was recent.
	var now := TrustedClock.now()
	if _last_mission_complete_time > 0.0 and (now - _last_mission_complete_time) <= MISSION_SPEED_WINDOW:
		_increment_progress("missions_speed")
	_last_mission_complete_time = now

	save_data()


## Call when the player's peak level advances (from PlayerData.leveled_up, or the
## catch-up pass on load). `peak` MUST be PlayerData.peak_level — the all-time
## high-water mark — NOT the current `level`, which prestige can lower by spending
## XP. Grants a reward for each milestone level (5,10,…,100) newly reached: levels
## 5–45 award 1 top-tier chest, 50–95 award 2, and level 100 awards 3. Uses the
## achievement's tier level to remember which milestones have already paid out, so
## nothing double-grants and level jumps (e.g. 48 → 52) still award every crossed
## milestone. Because it keys off peak_level and a monotonic paid-out counter, a
## dropped current level can never re-trigger or un-earn a milestone.
## When `batch` is false (live level-up), each owed milestone chest is shown as
## its own popup, honoring the 1/2/3 chest counts. When `batch` is true (the
## catch-up pass on load for players already past milestones), the rewards from
## every owed chest are granted and merged into a SINGLE combined chest popup so
## the player opens one chest instead of a long stack — the loot is identical.
func record_level_reached(peak: int, batch: bool = false) -> void:
	if not _progress.has("level_milestones"):
		_progress["level_milestones"] = {"progress": 0, "level": 0}

	var prog: Dictionary = _progress["level_milestones"]
	## Record the highest peak level reached for the achievements-screen progress
	## bar. Never lower it, so a fluctuating current level can't shrink the bar.
	if peak > int(prog.get("progress", 0)):
		prog["progress"] = peak

	var awarded := false
	## Accumulator for batch mode: all owed chests' rewards merged into one.
	var batched_display: Array = []
	var batched_chests: int = 0
	var highest_milestone: int = 0

	## Award every milestone tier the player has reached but not yet been granted.
	## prog["level"] is the count of milestones already paid out (0–20).
	while int(prog["level"]) < MILESTONE_LEVELS.size() \
			and peak >= MILESTONE_LEVELS[int(prog["level"])]:
		var tier: int = int(prog["level"])
		var milestone_level: int = MILESTONE_LEVELS[tier]
		prog["level"] = tier + 1
		awarded = true
		highest_milestone = milestone_level

		## Chest count: 1 up to level 45, 2 from 50–95, 3 at level 100.
		var chest_count: int = 1
		if milestone_level >= 100:
			chest_count = 3
		elif milestone_level >= 50:
			chest_count = 2

		for c in range(chest_count):
			## Always generate + grant the loot for this chest.
			var display_rewards := _grant_milestone_chest_rewards(MILESTONE_CHEST_LEVEL)
			if batch:
				## Merge into the single combined chest shown at the end.
				batched_display.append_array(display_rewards)
				batched_chests += 1
			else:
				## Live level-up — one popup per chest.
				var title := "Level %d Reached!" % milestone_level
				var desc := "Milestone reward (%d of %d)" % [c + 1, chest_count] if chest_count > 1 \
						else "Milestone reward for reaching level %d" % milestone_level
				ChestPopup.enqueue(get_tree(), MILESTONE_CHEST_LEVEL, display_rewards, title, desc)

	## In batch mode, show all accumulated loot as one chest.
	if batch and batched_chests > 0:
		var b_title := "Level Milestones Reached!"
		var b_desc := "Combined rewards for %d milestone chest%s (up to level %d)" % [
			batched_chests, "s" if batched_chests > 1 else "", highest_milestone]
		ChestPopup.enqueue(get_tree(), MILESTONE_CHEST_LEVEL, batched_display, b_title, b_desc)

	if awarded:
		save_data()


## Generates one milestone chest's rewards at the given chest level, grants the
## underlying pieces/items to the player, and returns the display-ready reward
## list for a ChestPopup. Mirrors _show_chest_popup's reward generation. The
## caller decides whether to show these as their own popup or merge them into a
## combined one.
func _grant_milestone_chest_rewards(chest_level: int) -> Array:
	var budget: int = (chest_level + 1) * 300
	var rewards: Array = PlayerData._generate_level_rewards_from_budget(
		budget, PlayerData.get_chest_piece_cap(chest_level), chest_level)
	PlayerData._add_reward_pieces(rewards)
	PlayerData.save_data()

	var display_rewards: Array = []
	for reward in rewards:
		if reward is Dictionary and reward.has("type") and reward["type"] == "coins":
			display_rewards.append({"type": "coins", "amount": int(reward["amount"])})
		elif reward is Dictionary and reward.get("type", "") == "sapling":
			display_rewards.append({"type": "sapling", "tree_type": int(reward["tree_type"]), "quantity": int(reward.get("quantity", 1))})
		elif reward is Dictionary and reward.get("type", "") == "prospector":
			display_rewards.append({"type": "prospector", "gem_type": str(reward["gem_type"]), "quantity": int(reward.get("quantity", 1))})
		elif reward is Dictionary and reward.has("seed_type"):
			display_rewards.append({"type": "seed", "plant_type": int(reward["seed_type"]), "quantity": int(reward["quantity"])})
		elif reward is Dictionary and reward.has("gem_type"):
			var gval := 0
			for gdef in PlayerData.PROSPECTOR_GEM_ORDER:
				if gdef["gem_type"] == reward["gem_type"]:
					gval = int(gdef["value"])
					break
			display_rewards.append({"type": "gemstone", "gem_type": str(reward["gem_type"]), "value": gval})
		elif reward is Dictionary and str(reward.get("type", "")) in ["resource", "material"]:
			## Ores/bars and WonderStones — ChestPopup renders these shapes as-is.
			display_rewards.append(reward)
		elif reward is int or reward is float:
			display_rewards.append({"type": "piece", "piece_type": int(reward)})
		## Anything else is an unknown reward shape: granted, just not displayed.

	return display_rewards


## Check king/tree/watchtower/pawn-only conditions after scoring completes.
## board: BoardState, terrain: Terrain.Type
func check_post_scoring(board: BoardState, terrain: Terrain.Type) -> void:
	var player_pieces := board.get_all_pieces(Piece.Owner.PLAYER)
	var only_pawns := true

	for entry in player_pieces:
		var piece: Piece = entry[0]
		var row: int = entry[1]
		var col: int = entry[2]

		## Check if all player pieces are pawns (for pawn_manipulator)
		if piece.type != Piece.Type.PAWN:
			only_pawns = false

		## King: correctly placed if final_points >= 7
		if piece.type == Piece.Type.KING and piece.final_points >= 7:
			_try_unlock_one_time("kingly_placement")

		## Tree: correctly placed if final_points >= 5
		if piece.type == Piece.Type.TREE and piece.final_points >= 5:
			_try_unlock_one_time("rooted_deep")

		## Watchtower: correctly placed in corner if final_points >= 6
		if piece.type == Piece.Type.WATCHTOWER and piece.final_points >= 6:
			if BoardState.is_corner(row, col):
				_try_unlock_one_time("watchful_eye")

	## Pawn manipulator — must have at least one piece and all must be pawns
	if only_pawns and player_pieces.size() > 0:
		## This is tracked but only awarded on a win — caller should check win first
		_try_unlock_one_time("pawn_manipulator")

	save_data()


## Returns a single achievement's data for UI display.
func get_achievement_data(id: String) -> Dictionary:
	if not ACHIEVEMENTS.has(id):
		return {}

	var def: Dictionary = ACHIEVEMENTS[id]
	var prog: Dictionary = _progress.get(id, { "progress": 0, "level": 0 })
	var current_level: int = prog["level"]
	var progress: int = prog["progress"]

	var result := {
		"id": id,
		"title": def["title"],
		"description": def["description"],
		"type": def["type"],
		"progress": progress,
		"current_level": current_level,
	}

	if def["type"] == "tiered":
		var thresholds: Array = def.get("tier_thresholds", TIER_THRESHOLDS)
		var max_lvl: int = thresholds.size()
		var is_maxed: bool = current_level >= max_lvl
		var next_threshold: int = thresholds[mini(current_level, max_lvl - 1)]
		result["max_level"] = max_lvl
		result["threshold"] = next_threshold if not is_maxed else thresholds[max_lvl - 1]
		result["is_complete"] = is_maxed
	else:
		result["max_level"] = 1
		result["threshold"] = int(def.get("progress_threshold", 1))
		result["is_complete"] = current_level >= 1

	return result


## Returns all achievement dictionaries for UI display.
func get_all_achievements() -> Array:
	var result: Array = []
	for id in ACHIEVEMENTS:
		result.append(get_achievement_data(id))
	return result


## ── Internal Helpers ───────────────────────────────────────────

## Increments progress for a tiered achievement and checks for level-ups.
func _increment_progress(id: String) -> void:
	if not _progress.has(id):
		_progress[id] = { "progress": 0, "level": 0 }

	_progress[id]["progress"] += 1
	_check_tiered_levelup(id)


## Updates streak-based progress (uses max of current streak vs stored progress).
func _update_streak_progress(id: String, streak: int) -> void:
	if not _progress.has(id):
		_progress[id] = { "progress": 0, "level": 0 }

	## Streak achievements track the highest streak achieved
	if streak > _progress[id]["progress"]:
		_progress[id]["progress"] = streak
	_check_tiered_levelup(id)


## Checks if a tiered achievement has reached the next threshold and awards a chest.
## Tiered achievements give a chest matching the level achieved (level 1 = chest index 0, level 10 = chest index 9).
func _check_tiered_levelup(id: String) -> void:
	## Guard against ids that aren't currently defined (e.g. the commented-out
	## "slayer" achievement while multiplayer is disabled).
	if not ACHIEVEMENTS.has(id):
		return
	var def: Dictionary = ACHIEVEMENTS[id]
	var prog: Dictionary = _progress[id]
	var current_level: int = prog["level"]
	var progress: int = prog["progress"]
	var thresholds: Array = def.get("tier_thresholds", TIER_THRESHOLDS)
	var max_lvl: int = thresholds.size()

	while current_level < max_lvl:
		var threshold: int = thresholds[current_level]
		if progress >= threshold:
			current_level += 1
			prog["level"] = current_level

			## Chest level = current_level - 1 (index 0-9)
			var chest_level: int = clampi(current_level - 1, 0, 9)

			achievement_unlocked.emit(id, current_level, chest_level)
		else:
			break


## Tries to unlock a one-time achievement. Does nothing if already unlocked.
## One-time achievements give a level 5 chest (index 4) by default.
## Exception: "baby_steps" gives a level 2 chest (index 1).
## Achievements with a "chest_level" field in their definition use that instead.
func _try_unlock_one_time(id: String) -> void:
	if not _progress.has(id):
		_progress[id] = { "progress": 0, "level": 0 }

	if _progress[id]["level"] >= 1:
		return  ## Already unlocked

	_progress[id]["level"] = 1
	_progress[id]["progress"] = 1

	## Determine chest level for one-time achievements
	var def: Dictionary = ACHIEVEMENTS[id]
	var chest_level: int = 4  ## Default: level 5 chest (index 4)
	if def.has("chest_level"):
		chest_level = int(def["chest_level"])
	elif id == "baby_steps":
		chest_level = 1  ## Level 2 chest (index 1)

	achievement_unlocked.emit(id, 1, chest_level)


## ── Persistence ────────────────────────────────────────────────

func save_data() -> void:
	var config := ConfigFile.new()

	## Save progress dictionary
	config.set_value("achievements", "progress", _progress)

	## Save streak state
	config.set_value("achievements", "current_streak", _current_streak)
	config.set_value("achievements", "current_mp_streak", _current_mp_streak)
	config.set_value("achievements", "current_mining_streak", _current_mining_streak)
	config.set_value("achievements", "first_click_loss_streak", _first_click_loss_streak)
	config.set_value("achievements", "best_win_streak", best_win_streak)
	config.set_value("achievements", "best_mining_streak", best_mining_streak)

	## Save terrains played
	config.set_value("achievements", "terrains_played", _terrains_played)

	## Save last mission completion time (for the quick-succession achievement)
	config.set_value("achievements", "last_mission_complete_time", _last_mission_complete_time)

	## Save the one-time first-click reset migration flag
	config.set_value("achievements", "first_click_reset_done", _first_click_reset_done)

	config.save(SAVE_PATH)


func load_data() -> void:
	## Reset in-memory state to clean defaults FIRST so a restore (or reload)
	## fully replaces the current progress instead of merging on top of it.
	## Without this, achievements unlocked in the running session would linger
	## after restoring an older backup, and stale state could mask the loaded
	## values — which reads as "backup didn't restore achievements".
	_progress = {}
	_current_streak = 0
	_current_mp_streak = 0
	_current_mining_streak = 0
	_first_click_loss_streak = 0
	best_win_streak = 0
	best_mining_streak = 0
	_terrains_played = []
	_last_mission_complete_time = 0.0
	_first_click_reset_done = false
	_init_progress()

	var config := ConfigFile.new()
	var err := config.load(SAVE_PATH)
	if err != OK:
		return  ## First run / empty save — keep the clean defaults above.

	## Load progress (overlay saved values onto the clean defaults).
	## Each entry is shape-validated and merged so a malformed or partial save
	## can NEVER make an earned achievement read as incomplete:
	##   • bad shapes (non-dict, missing keys, bare ints) are repaired
	##   • progress/level are merged with max(), so a lower saved value — or a
	##     stale/partial restore — can't lower what was already earned.
	## This is the core guard against "completed, then reset to incomplete".
	var loaded_progress = config.get_value("achievements", "progress", {})
	if loaded_progress is Dictionary:
		for id in loaded_progress:
			var entry := _normalize_progress_entry(loaded_progress[id])
			if _progress.has(id) and _progress[id] is Dictionary:
				## Keep the higher of default-vs-saved for both fields.
				_progress[id] = {
					"progress": maxi(int(_progress[id].get("progress", 0)), entry["progress"]),
					"level": maxi(int(_progress[id].get("level", 0)), entry["level"]),
				}
			else:
				_progress[id] = entry

	## Load streaks
	_current_streak = config.get_value("achievements", "current_streak", 0)
	_current_mp_streak = config.get_value("achievements", "current_mp_streak", 0)
	_current_mining_streak = config.get_value("achievements", "current_mining_streak", 0)
	_first_click_loss_streak = config.get_value("achievements", "first_click_loss_streak", 0)
	best_win_streak = config.get_value("achievements", "best_win_streak", 0)
	best_mining_streak = config.get_value("achievements", "best_mining_streak", 0)

	## Load terrains played
	var loaded_terrains = config.get_value("achievements", "terrains_played", [])
	if loaded_terrains is Array:
		_terrains_played = loaded_terrains

	## Load last mission completion time (quick-succession achievement)
	_last_mission_complete_time = float(config.get_value("achievements", "last_mission_complete_time", 0.0))

	## Ensure all achievements have progress entries
	_init_progress()

	## Self-heal: re-derive each achievement's level from its DURABLE progress
	## counter so a save whose `level` was lost/zeroed (but whose progress is
	## intact) reads as complete again. Only ever RAISES level — never lowers —
	## so legitimately-earned tiers can't regress. This is what lets players who
	## were already stuck "reset to incomplete, can't complete again" recover on
	## next load without having to redo the work. (Runs silently: no reward
	## re-grant, since we set level directly rather than emitting unlocks.)
	_reconcile_levels_from_progress()

	## One-time migration: the first-click-loss achievements could previously be
	## unlocked without truly consecutive first-click losses. Clear any existing
	## unlock/progress once so they must be re-earned under the corrected logic.
	_first_click_reset_done = bool(config.get_value("achievements", "first_click_reset_done", false))
	if not _first_click_reset_done:
		_migrate_reset_first_click_achievements()


## Walks every achievement and lifts its stored `level` up to whatever its
## durable `progress` already justifies, if the save under-recorded it. For
## tiered achievements, level = number of thresholds the progress has crossed.
## For one-time achievements we DON'T infer unlock from progress here, because
## most one-time progress is display-only (e.g. "distinct presents owned") and a
## transient value shouldn't imply the one-shot event happened — those stay
## governed by their stored level. Never lowers a level; silent (no re-reward).
func _reconcile_levels_from_progress() -> void:
	for id in ACHIEVEMENTS:
		var def: Dictionary = ACHIEVEMENTS[id]
		if def.get("type", "") != "tiered":
			continue
		if not _progress.has(id) or not (_progress[id] is Dictionary):
			continue
		var prog: Dictionary = _progress[id]
		var progress: int = int(prog.get("progress", 0))
		var level: int = int(prog.get("level", 0))
		var thresholds: Array = def.get("tier_thresholds", TIER_THRESHOLDS)
		var earned_level := 0
		for t in thresholds:
			if progress >= int(t):
				earned_level += 1
			else:
				break
		if earned_level > level:
			prog["level"] = earned_level
