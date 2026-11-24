class_name HaulGenerator
## Static helper class for generating randomized haul contents
## using weighted probability tables for gem selection.

const GEM_WEIGHTS: Dictionary = {
	"gold": 25,
	"blue_stone": 20,
	"pink_stone": 20,
	"violet_stone": 15,
	"black_pearl": 10,
	"emerald": 5,
	"ruby": 3,
	"diamond": 2,
}
const TOTAL_WEIGHT := 100

const GEM_VALUES: Dictionary = {
	"gold": 50,
	"blue_stone": 75,
	"pink_stone": 75,
	"violet_stone": 100,
	"black_pearl": 150,
	"emerald": 200,
	"ruby": 300,
	"diamond": 500,
}

const MAX_SEPARATION := 100.0


## Generates a randomized haul containing silt, sand, and collectibles.
## Collectible count uses a bell curve: 1(5%) 2(20%) 3(50%) 4(20%) 5(5%)
## `luck` biases gem selection toward rarer/higher-value gems (equipped ruby
## "rarer_gems" jewelry). 1 = neutral (no bias). Defaults to the live effective
## gem-roll luck when not supplied.
static func generate_haul(luck: int = -1) -> Dictionary:
	if luck < 0:
		luck = _effective_gem_luck()
	var silt_count: int = randi_range(15, 25)
	var sand_count: int = randi_range(10, 20)
	var num_collectibles: int = _roll_gem_count()

	var collectibles: Array = []
	for i in range(num_collectibles):
		var gem_type: String = pick_gem_type(luck)
		var threshold: float = MAX_SEPARATION * (i + 1.0) / num_collectibles
		collectibles.append({
			"gem_type": gem_type,
			"value": GEM_VALUES[gem_type],
			"threshold": threshold,
			"revealed": false,
			"collected": false,
		})

	return {
		"silt_count": silt_count,
		"sand_count": sand_count,
		"collectibles": collectibles,
	}


## Bell curve gem count: 1(5%), 2(20%), 3(50%), 4(20%), 5(5%)
static func _roll_gem_count() -> int:
	var roll: int = randi_range(1, 100)
	if roll <= 5:
		return 5
	elif roll <= 25:
		return 7
	elif roll <= 75:
		return 9
	elif roll <= 95:
		return 11
	else:
		return 15


## Selects a gem type using weighted random selection. When `luck` > 1 and the
## Luck autoload is available, the base weights are value-biased toward rarer
## gems (equipped ruby jewelry); otherwise it's the plain weighted pick.
static func pick_gem_type(luck: int = 1) -> String:
	var types: Array = GEM_WEIGHTS.keys()
	if luck > 1:
		var luck_node = _luck_node()
		if luck_node != null:
			var weights: Array = []
			var values: Array = []
			for gt in types:
				weights.append(GEM_WEIGHTS[gt])
				values.append(GEM_VALUES[gt])
			var idx: int = luck_node.biased_pick(weights, values, luck)
			if idx >= 0 and idx < types.size():
				return str(types[idx])

	## Plain cumulative weighted pick.
	var roll: int = randi_range(1, TOTAL_WEIGHT)
	var cumulative: int = 0
	for gem_type in GEM_WEIGHTS:
		cumulative += GEM_WEIGHTS[gem_type]
		if roll <= cumulative:
			return gem_type
	return "gold"


## Live effective gem-roll luck (base Luck + ruby jewelry), or 1 if unavailable.
static func _effective_gem_luck() -> int:
	if Engine.get_main_loop() == null:
		return 1
	var root := (Engine.get_main_loop() as SceneTree).root
	if root == null:
		return 1
	var luck := 1
	var jb = root.get_node_or_null("JewelryBonus")
	if jb != null:
		luck = int(jb.gem_roll_luck())
	## Citrus Melon Lemonade recipe boost ("Eagle Eye"): biases the pick toward
	## higher-tier gems while active. value is a fraction (0.15) → +luck weight.
	var pd = root.get_node_or_null("PlayerData")
	if pd != null and pd.boost_active("eagle_eye"):
		## Scale luck up by (1 + value); at minimum +1 so it has an effect even
		## when base luck is 1.
		luck = maxi(luck + 1, int(round(luck * (1.0 + pd.boost_value("eagle_eye")))))
	return maxi(luck, 1)


static func _luck_node():
	if Engine.get_main_loop() == null:
		return null
	var root := (Engine.get_main_loop() as SceneTree).root
	return root.get_node_or_null("Luck") if root != null else null
