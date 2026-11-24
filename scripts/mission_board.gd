extends Node
## Autoload: MissionBoard
## Manages 3 active missions (easy, medium, hard) that refresh every 48 hours
## or immediately when completed. Missions involve collecting gems, harvesting
## crops, winning games of Pho, or completing mining expeditions.

const SAVE_PATH := "user://missions.cfg"
const REFRESH_INTERVAL := 172800.0  ## 48 hours in seconds

signal mission_updated(slot: int)
signal mission_completed(slot: int)

enum Difficulty { EASY, MEDIUM, HARD }
enum MissionType {
	GEMS, CROPS, EXPEDITIONS, DEEP_MINE, POLISH, SMELT, FRUIT, CHOP, SELL_POLISHED, SELL_BARS,
	## Pho battle missions (replace the old single GAME_WINS type):
	GAME_EASY,     ## Complete a full game (gauntlet) on Easy
	GAME_MEDIUM,   ## Complete a full game on Medium
	GAME_HARD,     ## Complete a full game on Hard
	GAME_BRUTAL,   ## Complete a full game on Brutal
	BEAT_WOLVES,   ## Beat N Wolf-Pack battles
	BEAT_BEARS,    ## Beat N Bear battles
	BEAT_NPCS,     ## Beat N NPC/Rival battles
	WIN_TERRAIN,   ## Win a battle on a specific terrain
	PROSPECTORS,   ## Acquire (buy) N prospectors — Mines category
	DEPOSIT,       ## Deposit N items into Business District shops
}

## ── Mission categories ──────────────────────────────────────────
## A mission is chosen by first rolling a CATEGORY by weight, then a random
## member MissionType within it (filtered by difficulty + unlock level). Weights
## sum to 100: Mines 15, Garden 15, the other five 14 each.
enum Category { MINES, GARDEN, GAMES, BUSINESS, ORCHARD, WORKSHOP, MARKETPLACE }

const CATEGORY_WEIGHTS: Dictionary = {
	Category.MINES: 15,
	Category.GARDEN: 15,
	Category.GAMES: 14,
	Category.BUSINESS: 14,
	Category.ORCHARD: 14,
	Category.WORKSHOP: 14,
	Category.MARKETPLACE: 14,
}

## MissionTypes belonging to each category.
const CATEGORY_TYPES: Dictionary = {
	Category.MINES: [MissionType.EXPEDITIONS, MissionType.DEEP_MINE, MissionType.PROSPECTORS],
	Category.GARDEN: [MissionType.CROPS],
	Category.GAMES: [
		MissionType.GAME_EASY, MissionType.GAME_MEDIUM, MissionType.GAME_HARD, MissionType.GAME_BRUTAL,
		MissionType.BEAT_WOLVES, MissionType.BEAT_BEARS, MissionType.BEAT_NPCS, MissionType.WIN_TERRAIN,
	],
	Category.BUSINESS: [MissionType.DEPOSIT],
	Category.ORCHARD: [MissionType.FRUIT, MissionType.CHOP],
	Category.WORKSHOP: [MissionType.POLISH, MissionType.SMELT, MissionType.GEMS],
	Category.MARKETPLACE: [MissionType.SELL_POLISHED, MissionType.SELL_BARS],
}

## Difficulty (enemy_count) that each GAME_* mission requires a completed run of.
const GAME_MISSION_ENEMY_COUNT := {
	MissionType.GAME_EASY: 1,
	MissionType.GAME_MEDIUM: 3,
	MissionType.GAME_HARD: 5,
	MissionType.GAME_BRUTAL: 9,
}

## Rare mission chance: CHOP ("chop down trees") is a special hard mission that
## only spawns roughly 1 in every 250 hard-mission rolls.
const RARE_CHOP_CHANCE := 250

## Player level at which each mission type's underlying feature unlocks. A
## mission type is only offered once the player can actually work toward it.
## GEMS is intentionally 0 (always available): gems also drop from reward
## chests, so gem-collection missions can be completed at any level even
## before Gold Panning (Lv.3) is unlocked.
const TYPE_UNLOCK_LEVEL: Dictionary = {
	MissionType.GEMS: 0,          ## Always available (chests grant gems)
	MissionType.CROPS: 1,         ## Garden — Lv.1
	MissionType.EXPEDITIONS: 2,   ## Mining expeditions — Lv.2
	MissionType.DEEP_MINE: 20,    ## Deep Mine — Lv.20
	MissionType.POLISH: 3,        ## Workshop saw needs gems to polish — Gold Panning Lv.3
	MissionType.SMELT: 20,        ## Workshop foundry needs ores — Deep Mine Lv.20
	MissionType.FRUIT: 1,         ## Orchard fruit — Orchard/Garden Lv.1
	MissionType.CHOP: 1,          ## Chop orchard trees — Lv.1 (rare spawn)
	MissionType.SELL_POLISHED: 3, ## Sell polished gems — needs gems to polish (Lv.3)
	MissionType.SELL_BARS: 20,    ## Sell smelted bars — needs ores to smelt (Lv.20)
	## Pho battle missions — the Game of Pho unlocks at Lv.4.
	MissionType.GAME_EASY: 4,
	MissionType.GAME_MEDIUM: 4,
	MissionType.GAME_HARD: 4,
	MissionType.GAME_BRUTAL: 4,
	MissionType.BEAT_WOLVES: 4,
	MissionType.BEAT_BEARS: 4,
	MissionType.BEAT_NPCS: 4,
	MissionType.WIN_TERRAIN: 4,
	MissionType.PROSPECTORS: 3,   ## Prospectors become relevant around Gold Panning (Lv.3)
	MissionType.DEPOSIT: 25,      ## Business District unlocks at Lv.25
}


## Whether a mission type's feature is unlocked at the player's current level.
func is_type_available(type: int) -> bool:
	var req: int = int(TYPE_UNLOCK_LEVEL.get(type, 0))
	return PlayerData.level >= req

## Gem types matching PlayerData.gemstones keys
const GEM_TYPES: Array[String] = [
	"gold", "blue_stone", "pink_stone", "violet_stone",
	"black_pearl", "emerald", "ruby", "diamond"
]

## Crop names matching GardenData.PLANT_DEFS order
const CROP_NAMES: Array[String] = [
	"Beans", "Cucumbers", "Peppers", "Squash", "Grapes",
	"Sunflower", "Cauliflower", "Pineapple", "Watermelon"
]

## Orchard fruit ids matching Orchard.TREE_DEFS order (tree_type index -> fruit id).
const FRUIT_IDS: Array[String] = ["plum", "lemon", "apple", "banana", "coconut"]

## Amount ranges per difficulty per type [min, max]
const AMOUNT_RANGES: Dictionary = {
	Difficulty.EASY: {
		MissionType.GEMS: [1, 5],
		MissionType.CROPS: [1, 5],
		MissionType.GAME_EASY: [1, 1],     ## Complete an easy game
		MissionType.BEAT_WOLVES: [1, 2],   ## Beat 1-2 wolves
		MissionType.WIN_TERRAIN: [1, 1],   ## Win a game on a specific terrain
		MissionType.DEPOSIT: [1, 5],       ## Deposit items into businesses
	},
	Difficulty.MEDIUM: {
		MissionType.GEMS: [30, 50],
		MissionType.CROPS: [50, 100],
		MissionType.EXPEDITIONS: [1, 3],
		MissionType.POLISH: [30, 55],
		MissionType.FRUIT: [25, 35],
		MissionType.SELL_POLISHED: [25, 35],
		MissionType.SELL_BARS: [25, 35],
		MissionType.GAME_MEDIUM: [1, 1],   ## Complete a medium game
		MissionType.BEAT_BEARS: [3, 5],    ## Beat 3-5 bears
		MissionType.PROSPECTORS: [1, 2],   ## Acquire 1-2 prospectors
		MissionType.DEPOSIT: [25, 35],      ## Deposit items into businesses
	},
	Difficulty.HARD: {
		MissionType.GEMS: [160, 300],
		MissionType.CROPS: [160, 300],
		MissionType.EXPEDITIONS: [3, 5],
		MissionType.DEEP_MINE: [160, 300],
		MissionType.POLISH: [160, 300],
		MissionType.SMELT: [100, 200],
		MissionType.SELL_POLISHED: [160, 300],
		MissionType.SELL_BARS: [160, 300],
		MissionType.GAME_HARD: [1, 2],     ## Complete 1-2 hard games
		MissionType.GAME_BRUTAL: [1, 1],   ## Complete 1 brutal game
		MissionType.BEAT_NPCS: [5, 7],     ## Beat 5-7 NPCs
		MissionType.PROSPECTORS: [15, 20],   ## Acquire 3-5 prospectors
		MissionType.DEPOSIT: [160, 300],     ## Deposit items into businesses
	},
}

## CHOP ("chop down trees") is a rare HARD mission handled separately from the
## uniform picker so it stays a 1-in-RARE_CHOP_CHANCE spawn. Range: 1–15 trees.
const CHOP_AMOUNT_RANGE: Array[int] = [1, 15]

## Chest level awarded on completion per difficulty
const CHEST_LEVELS: Dictionary = {
	Difficulty.EASY: 0,    ## Level 1 chest (index 0)
	Difficulty.MEDIUM: 4,  ## Level 5 chest (index 6)
	Difficulty.HARD: 9,    ## Level 10 chest (index 9)
}

## Coin bonus per required item, scaled by difficulty
const COIN_PER_ITEM: Dictionary = {
	Difficulty.EASY: 500,
	Difficulty.MEDIUM: 1200,
	Difficulty.HARD: 25000,
}

## Each slot holds one mission Dictionary:
## {
##   "type": MissionType,
##   "difficulty": Difficulty,
##   "target_label": String,   ## Display name of gem/crop/action
##   "target_key": Variant,    ## gem_type string or plant_type int or null
##   "required": int,
##   "progress": int,
##   "claimed": bool,
##   "accepted": bool,         ## True after player hits Accept/Go
##   "generated_at": float,    ## unix timestamp when this mission was generated
##   "accepted_at": float,     ## unix timestamp when player accepted (0 if not yet)
##   "completed_at": float,    ## unix timestamp when progress reached required (0 if not yet)
## }
var missions: Array = [null, null, null]  ## [easy, medium, hard]


func _ready() -> void:
	load_data()
	_ensure_all_slots_filled()

	## Defer signal connections so all autoloads are initialized first
	call_deferred("_connect_signals")

	## Periodic check for expired missions (every 5 minutes)
	var timer := Timer.new()
	timer.wait_time = 300.0
	timer.autostart = true
	timer.timeout.connect(_check_refresh_all)
	add_child(timer)


func _connect_signals() -> void:
	if Garden != null and not Garden.garden_updated.is_connected(_on_garden_updated):
		Garden.garden_updated.connect(_on_garden_updated)
	if Achievements != null and not Achievements.achievement_unlocked.is_connected(_on_achievement_unlocked):
		Achievements.achievement_unlocked.connect(_on_achievement_unlocked)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST \
			or what == NOTIFICATION_APPLICATION_PAUSED:
		save_data()


## ── Public API ─────────────────────────────────────────────────


func _is_tracking(m) -> bool:
	return m != null and bool(m.get("accepted", false)) and not bool(m.get("claimed", false))


func _add_progress(slot: int, amount: int = 1) -> void:
	var m = missions[slot]
	if not _is_tracking(m):
		return
	var before: int = int(m["progress"])
	m["progress"] = mini(before + amount, int(m["required"]))
	if int(m["progress"]) == before:
		return
	mission_updated.emit(slot)
	_check_complete(slot)


## Additive guild hook (§8 of the implementation plan).
## Called by every on_* tracker method after it records solo progress.
## Forwards the same event to GuildManager so it can write a
## guild_mission_contributions row — no existing logic is changed.
## `mission_type` is a MissionType enum int; `amount` is the progress increment.
func _record_guild_contribution(mission_type: int, amount: int = 1) -> void:
	if get_node_or_null("/root/GuildManager") == null:
		return
	if not GuildManager.is_in_guild() or not GuildManager.perks_active():
		return
	var base_key := GuildManager.mission_type_to_base_key(mission_type)
	if base_key == "":
		return
	GuildManager.record_contribution(base_key, amount)


## Call when a gem is collected (from gold panning or mining).
func on_gem_collected(gem_type: String) -> void:
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		if int(m["type"]) == MissionType.GEMS and str(m["target_key"]) == gem_type:
			_add_progress(i)
			changed = true
	if changed:
		_record_guild_contribution(MissionType.GEMS)
		save_data()


## Call when a crop is harvested. plant_type is GardenData.PlantType index.
func on_crop_harvested(plant_type: int) -> void:
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		if int(m["type"]) == MissionType.CROPS and int(m["target_key"]) == plant_type:
			_add_progress(i)
			changed = true
	if changed:
		## Guild "crops" missions are contributed via manual deposit on the
		## guild screen — do NOT auto-record here.
		save_data()


## Call when a single Pho battle is won. `enemy_type` is EnemyDefinitions.EnemyType
## (0=Wolf, 1=Bear, 2=NPC; -1 for none/PvP) and `terrain` is Terrain.Type.
## Advances BEAT_* missions matching the enemy and any WIN_TERRAIN mission whose
## target terrain matches.
func on_battle_won(enemy_type: int, terrain: int) -> void:
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		var t := int(m["type"])
		var hit := false
		match t:
			MissionType.BEAT_WOLVES: hit = (enemy_type == 0)
			MissionType.BEAT_BEARS:  hit = (enemy_type == 1)
			MissionType.BEAT_NPCS:   hit = (enemy_type == 2)
			MissionType.WIN_TERRAIN: hit = (int(m["target_key"]) == terrain)
		if hit:
			_add_progress(i)
			changed = true
	if changed:
		## Guild hook: map enemy_type to the most specific matching type.
		var guild_type := MissionType.BEAT_WOLVES
		match enemy_type:
			1: guild_type = MissionType.BEAT_BEARS
			2: guild_type = MissionType.BEAT_NPCS
		_record_guild_contribution(guild_type)
		save_data()


## Call when a full Pho gauntlet (campaign run) is completed. `enemy_count` is
## the difficulty size: 1=Easy, 3=Medium, 5=Hard, 9=Brutal. Advances the
## matching GAME_* mission.
func on_run_completed(enemy_count: int) -> void:
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		var required_count: int = int(GAME_MISSION_ENEMY_COUNT.get(int(m["type"]), -1))
		if required_count == enemy_count:
			_add_progress(i)
			changed = true
	if changed:
		## Guild hook: map enemy_count back to the game mission type.
		var guild_type := MissionType.GAME_EASY
		match enemy_count:
			3: guild_type = MissionType.GAME_MEDIUM
			5: guild_type = MissionType.GAME_HARD
			9: guild_type = MissionType.GAME_BRUTAL
		_record_guild_contribution(guild_type)
		save_data()


## Call when a mining expedition is successfully completed.
func on_expedition_complete() -> void:
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		if int(m["type"]) == MissionType.EXPEDITIONS:
			_add_progress(i)
			changed = true
	if changed:
		_record_guild_contribution(MissionType.EXPEDITIONS)
		save_data()


## Call when tiles are dug in the Deep Mine. `count` is how many tiles were dug.
func on_deep_mine_dug(count: int = 1) -> void:
	if count <= 0:
		return
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		if int(m["type"]) == MissionType.DEEP_MINE:
			_add_progress(i, count)
			changed = true
	if changed:
		_record_guild_contribution(MissionType.DEEP_MINE, count)
		save_data()


## Call when gems finish polishing in the Workshop saw. `count` = gems collected.
func on_gems_polished(count: int = 1) -> void:
	if count <= 0:
		return
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		if int(m["type"]) == MissionType.POLISH:
			_add_progress(i, count)
			changed = true
	if changed:
		_record_guild_contribution(MissionType.POLISH, count)
		save_data()


## Call when bars finish smelting in the Workshop foundry. `count` = bars collected.
func on_bars_smelted(count: int = 1) -> void:
	if count <= 0:
		return
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		if int(m["type"]) == MissionType.SMELT:
			_add_progress(i, count)
			changed = true
	if changed:
		_record_guild_contribution(MissionType.SMELT, count)
		save_data()


## Call when orchard fruit is harvested. fruit_id is the tree's fruit id string
## (e.g. "plum"); count is how many fruit were picked. Matches FRUIT missions
## whose target fruit (stored as a tree-type index) corresponds to fruit_id.
func on_fruit_harvested(fruit_id: String, count: int = 1) -> void:
	if count <= 0:
		return
	var target_idx: int = FRUIT_IDS.find(fruit_id)
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		if int(m["type"]) == MissionType.FRUIT and int(m["target_key"]) == target_idx:
			_add_progress(i, count)
			changed = true
	if changed:
		_record_guild_contribution(MissionType.FRUIT, count)
		save_data()


## Call when orchard trees are chopped down (removed with the shovel). `count`
## is how many trees were removed.
func on_tree_chopped(count: int = 1) -> void:
	if count <= 0:
		return
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		if int(m["type"]) == MissionType.CHOP:
			_add_progress(i, count)
			changed = true
	if changed:
		_record_guild_contribution(MissionType.CHOP, count)
		save_data()


## Call when polished gems are sold in the Marketplace. `count` = number sold.
func on_polished_gems_sold(count: int = 1) -> void:
	if count <= 0:
		return
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		if int(m["type"]) == MissionType.SELL_POLISHED:
			_add_progress(i, count)
			changed = true
	if changed:
		_record_guild_contribution(MissionType.SELL_POLISHED, count)
		save_data()


## Call when smelted bars/ingots are sold in the Marketplace. `count` = number sold.
func on_bars_sold(count: int = 1) -> void:
	if count <= 0:
		return
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		if int(m["type"]) == MissionType.SELL_BARS:
			_add_progress(i, count)
			changed = true
	if changed:
		_record_guild_contribution(MissionType.SELL_BARS, count)
		save_data()


## Call when the player ACQUIRES (buys) prospectors. `count` = number bought.
func on_prospector_acquired(count: int = 1) -> void:
	if count <= 0:
		return
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		if int(m["type"]) == MissionType.PROSPECTORS:
			_add_progress(i, count)
			changed = true
	if changed:
		_record_guild_contribution(MissionType.PROSPECTORS, count)
		save_data()


## Call when the player deposits items into a Business District shop. `count` =
## number of items deposited.
func on_business_deposit(count: int = 1) -> void:
	if count <= 0:
		return
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if not _is_tracking(m):
			continue
		if int(m["type"]) == MissionType.DEPOSIT:
			_add_progress(i, count)
			changed = true
	if changed:
		_record_guild_contribution(MissionType.DEPOSIT, count)
		save_data()


## Accept a mission — stamps accepted_at and enables progress tracking.
## Returns true if successful (mission exists and isn't already accepted/claimed).
func accept_mission(slot: int) -> bool:
	if slot < 0 or slot >= missions.size():
		return false
	var m = missions[slot]
	if m == null or m.get("accepted", false) or m.get("claimed", false):
		return false
	m["accepted"] = true
	m["accepted_at"] = TrustedClock.now()
	mission_updated.emit(slot)
	save_data()
	return true


## Claim the reward for a completed mission. Returns true if successful.
func claim_mission(slot: int) -> bool:
	if slot < 0 or slot >= missions.size():
		return false
	var m = missions[slot]
	if m == null or m["claimed"]:
		return false
	if m["progress"] < m["required"]:
		return false

	m["claimed"] = true

	## Coin reward
	var coin_reward: int = m["required"] * COIN_PER_ITEM[m["difficulty"]]
	PlayerData.coins += coin_reward
	PlayerData.save_data()
	PlayerData.data_changed.emit()

	## Chest reward via Achievements system
	var chest_level: int = CHEST_LEVELS[m["difficulty"]]
	var rewards: Array = PlayerData._generate_level_rewards_from_budget((chest_level + 1) * 300, PlayerData.get_chest_piece_cap(chest_level), chest_level)
	PlayerData._add_reward_pieces(rewards)
	PlayerData.save_data()

	## Show chest popup
	var diff_names := ["Easy", "Medium", "Hard"]
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
			## Look up the gem value from the order table since the new generator
			## doesn't embed a "value" key in gem reward entries.
			var gval := 0
			for gdef in PlayerData.PROSPECTOR_GEM_ORDER:
				if gdef["gem_type"] == reward["gem_type"]:
					gval = int(gdef["value"])
					break
			display_rewards.append({"type": "gemstone", "gem_type": str(reward["gem_type"]), "value": gval})
		else:
			display_rewards.append({"type": "piece", "piece_type": reward})
	ChestPopup.enqueue(get_tree(), chest_level, display_rewards,
		"Mission Complete!",
		"%s mission: %s\n+%s coins" % [diff_names[m["difficulty"]], m["target_label"], PlayerData.format_number(coin_reward)])

	mission_completed.emit(slot)

	## Track mission-completion achievements (total + per-difficulty + quick-succession).
	if get_node_or_null("/root/Achievements") != null:
		Achievements.record_mission_completed(int(m["difficulty"]))

	## Immediately replace with a new mission
	_replace_mission(slot)
	return true


## Returns time remaining (seconds) before a mission's 48hr window expires.
## Clock starts when the offer is issued (generated_at), never on screen close.
func get_time_remaining(slot: int) -> float:
	if slot < 0 or slot >= missions.size() or missions[slot] == null:
		return 0.0
	var m = missions[slot]
	var start := _offer_start_time(m)
	if start <= 0.0:
		return REFRESH_INTERVAL
	var elapsed := TrustedClock.now() - start
	return maxf(0.0, REFRESH_INTERVAL - elapsed)


## Pays to reroll a single mission slot, limited by the shared daily allowance
## (base 3/day + prestige). Returns true on success.
## Refuses to reroll a completed-but-unclaimed mission so earned rewards aren't lost.
func refresh_mission(slot: int) -> bool:
	if slot < 0 or slot >= missions.size():
		return false
	var m = missions[slot]
	## Block rerolling a mission whose reward is ready to claim.
	if m != null and not bool(m.get("claimed", false)):
		if int(m.get("progress", 0)) >= int(m.get("required", 1)):
			return false
	if not PlayerData.can_refresh_mission():
		return false
	## Consume a daily reroll allowance, then charge coins.
	if not PlayerData.use_mission_refresh():
		return false
	PlayerData.coins -= PlayerData.MISSION_REFRESH_COST
	PlayerData.save_data()
	PlayerData.data_changed.emit()
	_replace_mission(slot)
	return true


## ── Internal ───────────────────────────────────────────────────


func _check_complete(slot: int) -> void:
	var m = missions[slot]
	if m != null and not m["claimed"] and m["progress"] >= m["required"]:
		if float(m.get("completed_at", 0.0)) == 0.0:
			m["completed_at"] = TrustedClock.now()
		mission_completed.emit(slot)


func _offer_start_time(m: Dictionary) -> float:
	var start := float(m.get("generated_at", 0.0))
	if start <= 0.0:
		start = TrustedClock.now()
		m["generated_at"] = start
	return start


func _check_refresh_all() -> void:
	var now := TrustedClock.now()
	var changed := false
	for i in range(missions.size()):
		var m = missions[i]
		if m == null or bool(m.get("claimed", false)):
			_replace_mission(i)
			changed = true
			continue
		## Completed missions stay until claimed — do not roll a new one on close/pause
		if int(m["progress"]) >= int(m["required"]):
			continue
		var start := _offer_start_time(m)
		if now - start >= REFRESH_INTERVAL:
			_replace_mission(i)
			changed = true
	if changed:
		save_data()


func _replace_mission(slot: int) -> void:
	var difficulty: Difficulty = slot as Difficulty
	missions[slot] = _generate_mission(difficulty)
	mission_updated.emit(slot)
	save_data()


func _ensure_all_slots_filled() -> void:
	for i in range(3):
		if missions[i] == null or bool(missions[i].get("claimed", false)):
			missions[i] = _generate_mission(i as Difficulty)
	save_data()


## Weighted random pick: returns an element of `items` chosen by parallel
## `weights`. Falls back to a uniform pick if weights sum to <= 0.
func _weighted_pick(items: Array, weights: Array):
	var total := 0
	for w in weights:
		total += int(w)
	if total <= 0:
		return items[randi() % items.size()]
	var roll := randi() % total
	var cumulative := 0
	for i in range(items.size()):
		cumulative += int(weights[i])
		if roll < cumulative:
			return items[i]
	return items[items.size() - 1]


## Valid mission types in a category for a difficulty: must be unlocked AND have
## an amount range defined for that difficulty. CHOP is excluded here (it's a
## rare special-cased spawn, not part of the normal category pool).
func _valid_types_in_category(category: int, difficulty: int) -> Array:
	var ranges_for_difficulty: Dictionary = AMOUNT_RANGES[difficulty]
	var out: Array = []
	for t in CATEGORY_TYPES.get(category, []):
		if int(t) == MissionType.CHOP:
			continue
		if is_type_available(int(t)) and ranges_for_difficulty.has(t):
			out.append(t)
	return out


func _generate_mission(difficulty: Difficulty) -> Dictionary:
	var ranges_for_difficulty: Dictionary = AMOUNT_RANGES[difficulty]

	var type: MissionType
	var range_arr: Array

	## Rare special: on HARD rolls, ~1 in RARE_CHOP_CHANCE becomes a CHOP mission
	## (chop down 1–5 orchard trees), if the player has the orchard unlocked.
	if difficulty == Difficulty.HARD and is_type_available(MissionType.CHOP) \
			and randi() % RARE_CHOP_CHANCE == 0:
		type = MissionType.CHOP
		range_arr = CHOP_AMOUNT_RANGE
	else:
		## Roll a CATEGORY by weight (Mines/Garden 15%, others 14%), but only
		## among categories that actually have a valid type for this difficulty
		## (respecting unlock levels). Then pick a random type within it.
		var eligible: Array = []      ## [category, ...]
		var weights: Array = []       ## parallel weights
		for cat in CATEGORY_TYPES.keys():
			if not _valid_types_in_category(cat, difficulty).is_empty():
				eligible.append(cat)
				weights.append(int(CATEGORY_WEIGHTS.get(cat, 0)))

		if eligible.is_empty():
			## Nothing unlocked at all — fall back to GEMS (always available).
			type = MissionType.GEMS
			range_arr = ranges_for_difficulty.get(type, [1, 5])
		else:
			var chosen_cat: int = _weighted_pick(eligible, weights)
			var pool: Array = _valid_types_in_category(chosen_cat, difficulty)
			type = pool[randi() % pool.size()] as MissionType
			range_arr = ranges_for_difficulty[type]
	var required: int = randi_range(range_arr[0], range_arr[1])

	var target_label: String = ""
	var target_key = null

	match type:
		MissionType.GEMS:
			var gem_idx: int = randi() % GEM_TYPES.size()
			target_key = GEM_TYPES[gem_idx]
			target_label = "Collect %d %s" % [required, target_key.replace("_", " ").capitalize()]
		MissionType.CROPS:
			var crop_idx: int = randi() % CROP_NAMES.size()
			target_key = crop_idx
			target_label = "Harvest %d %s" % [required, CROP_NAMES[crop_idx]]
		MissionType.GAME_EASY:
			target_label = "Complete a game of Pho on Easy"
		MissionType.GAME_MEDIUM:
			target_label = "Complete a game of Pho on Medium"
		MissionType.GAME_HARD:
			target_label = "Complete %d game%s of Pho on Hard" % [required, "s" if required > 1 else ""]
		MissionType.GAME_BRUTAL:
			target_label = "Complete a game of Pho on Brutal"
		MissionType.BEAT_WOLVES:
			target_label = "Beat %d Wolf Pack%s" % [required, "s" if required > 1 else ""]
		MissionType.BEAT_BEARS:
			target_label = "Beat %d Bear%s" % [required, "s" if required > 1 else ""]
		MissionType.BEAT_NPCS:
			target_label = "Beat %d Rival%s" % [required, "s" if required > 1 else ""]
		MissionType.WIN_TERRAIN:
			var terrain_idx: int = randi() % Terrain.Type.size()
			target_key = terrain_idx
			target_label = "Win a game of Pho on %s" % Terrain.get_terrain_name(terrain_idx)
		MissionType.EXPEDITIONS:
			target_label = "Complete %d mining expedition%s" % [required, "s" if required > 1 else ""]
		MissionType.DEEP_MINE:
			target_label = "Dig %d tile%s in the Deep Mine" % [required, "s" if required > 1 else ""]
		MissionType.POLISH:
			target_label = "Polish %d gem%s in the Workshop" % [required, "s" if required > 1 else ""]
		MissionType.SMELT:
			target_label = "Smelt %d bar%s in the Foundry" % [required, "s" if required > 1 else ""]
		MissionType.FRUIT:
			var fruit_idx: int = randi() % FRUIT_IDS.size()
			target_key = fruit_idx
			target_label = "Harvest %d %s from the Orchard" % [required, FRUIT_IDS[fruit_idx].capitalize()]
		MissionType.CHOP:
			target_label = "Chop down %d tree%s in the Orchard" % [required, "s" if required > 1 else ""]
		MissionType.SELL_POLISHED:
			target_label = "Sell %d polished gem%s" % [required, "s" if required > 1 else ""]
		MissionType.SELL_BARS:
			target_label = "Sell %d smelted bar%s" % [required, "s" if required > 1 else ""]
		MissionType.PROSPECTORS:
			target_label = "Acquire %d prospector%s" % [required, "s" if required > 1 else ""]
		MissionType.DEPOSIT:
			target_label = "Deposit %d item%s into your businesses" % [required, "s" if required > 1 else ""]

	return {
		"type": int(type),
		"difficulty": int(difficulty),
		"target_label": target_label,
		"target_key": target_key,
		"required": required,
		"progress": 0,
		"claimed": false,
		"accepted": false,
		"generated_at": TrustedClock.now(),
		"accepted_at": 0.0,
		"completed_at": 0.0,
	}


## Garden signal — scan grid for harvests (garden_updated fires on harvest too,
## but we track via the direct on_crop_harvested call from garden_data).
func _on_garden_updated() -> void:
	pass  ## Crop tracking handled via direct on_crop_harvested calls


## Not used for progress but kept for future expansion.
func _on_achievement_unlocked(_id: String, _level: int, _chest: int) -> void:
	pass


## ── Persistence ────────────────────────────────────────────────


func save_data() -> void:
	var config := ConfigFile.new()
	for i in range(missions.size()):
		var m = missions[i]
		if m == null:
			continue
		var sec := "mission_%d" % i
		config.set_value(sec, "type", int(m["type"]))
		config.set_value(sec, "difficulty", int(m["difficulty"]))
		config.set_value(sec, "target_label", str(m.get("target_label", "")))
		config.set_value(sec, "target_key", str(m["target_key"]) if m.get("target_key") != null else "")
		config.set_value(sec, "target_key_is_int", typeof(m.get("target_key")) == TYPE_INT)
		config.set_value(sec, "required", int(m["required"]))
		config.set_value(sec, "progress", int(m["progress"]))
		config.set_value(sec, "claimed", bool(m.get("claimed", false)))
		config.set_value(sec, "accepted", bool(m.get("accepted", false)))
		config.set_value(sec, "generated_at", float(m.get("generated_at", 0.0)))
		config.set_value(sec, "accepted_at", float(m.get("accepted_at", 0.0)))
		config.set_value(sec, "completed_at", float(m.get("completed_at", 0.0)))
	config.save(SAVE_PATH)


func _normalize_mission(data: Dictionary) -> Dictionary:
	if not data.has("accepted"):
		data["accepted"] = int(data.get("progress", 0)) > 0
	if not data.has("accepted_at"):
		data["accepted_at"] = float(data.get("generated_at", 0.0)) if data["accepted"] else 0.0
	if not data.has("completed_at"):
		data["completed_at"] = 0.0
	if not data.has("generated_at") or float(data.get("generated_at", 0.0)) <= 0.0:
		data["generated_at"] = TrustedClock.now()
	return data


## Detects a mission saved before the GAME_* enum refactor. The old single
## "GAME_WINS" type produced labels like "Win N games of Pho"; after new types
## were inserted into MissionType, its stored `type` int now resolves to an
## unrelated mission (e.g. a Mining one), so the label reads "Win N games of
## Pho" while the Go button routes to "Mining". Any such mission is stale and
## should be discarded on load so a fresh, correctly-typed one is generated.
## Current game-completion labels start with "Complete", never "Win ... games".
func _is_legacy_mission(data: Dictionary) -> bool:
	if not (data is Dictionary):
		return true
	var label := str(data.get("target_label", ""))
	var lower := label.to_lower()
	return lower.begins_with("win ") and lower.contains("games of pho")


func load_data() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return
	## Reset slots first so a blank/empty save reloads into fresh missions
	## instead of keeping stale in-memory ones (e.g. after a full wipe).
	for i in range(missions.size()):
		missions[i] = null
	for i in range(missions.size()):
		var sec := "mission_%d" % i
		var data = config.get_value(sec, "data", null)
		if data is Dictionary and data.has("type"):
			## Discard pre-refactor missions so a correctly-typed one regenerates.
			if _is_legacy_mission(data):
				missions[i] = null
				continue
			missions[i] = _normalize_mission(data)
			continue
		if not config.has_section_key(sec, "type"):
			continue
		var target_key_str := str(config.get_value(sec, "target_key", ""))
		var target_key: Variant = null
		if target_key_str != "":
			if bool(config.get_value(sec, "target_key_is_int", false)):
				target_key = int(target_key_str)
			else:
				target_key = target_key_str
		var legacy_data := {
			"type": int(config.get_value(sec, "type", 0)),
			"difficulty": int(config.get_value(sec, "difficulty", i)),
			"target_label": str(config.get_value(sec, "target_label", "")),
			"target_key": target_key,
			"required": int(config.get_value(sec, "required", 1)),
			"progress": int(config.get_value(sec, "progress", 0)),
			"claimed": bool(config.get_value(sec, "claimed", false)),
			"accepted": bool(config.get_value(sec, "accepted", false)),
			"generated_at": float(config.get_value(sec, "generated_at", 0.0)),
			"accepted_at": float(config.get_value(sec, "accepted_at", 0.0)),
			"completed_at": float(config.get_value(sec, "completed_at", 0.0)),
		}
		## Drop pre-refactor missions so a correctly-typed one regenerates.
		if _is_legacy_mission(legacy_data):
			missions[i] = null
			continue
		missions[i] = _normalize_mission(legacy_data)
	_ensure_all_slots_filled()
