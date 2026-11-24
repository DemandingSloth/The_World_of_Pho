extends SceneTree

## Tests for the client production layer (Task 11): GuildProduction autoload
## parse + remaining-time math, the Production panel nodes, and a RECIPE-SYNC
## cross-check that the GDScript ITEM_DEFS recipes match the authoritative
## migration-055 seed values (so the two sources can't silently drift).
##
##   godot --headless --script tests/test_guild_production.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0

## The authoritative recipes as seeded in the migrations (recipe_id ->
## {key:qty}, craft_minutes). If you change a recipe, change it in
## player_data.gd ITEM_DEFS, the migration, AND here.
##   Jewelry → migration 055.  Horseshoes → 081.  Food recipes → 097.
const SEED_RECIPES := {
	"gold_ring":            {"inputs": {"gem:gold": 20, "resource:gold_ingot": 5},            "minutes": 20},
	"blue_stone_necklace":  {"inputs": {"polished:blue_stone": 15, "resource:iron_bar": 5},   "minutes": 30},
	"pink_stone_necklace":  {"inputs": {"polished:pink_stone": 15, "resource:iron_bar": 5},   "minutes": 30},
	"violet_stone_ring":    {"inputs": {"polished:violet_stone": 12, "resource:copper_ingot": 5}, "minutes": 45},
	"black_pearl_necklace": {"inputs": {"polished:black_pearl": 12, "resource:copper_ingot": 8}, "minutes": 60},
	"emerald_necklace":     {"inputs": {"polished:emerald": 10, "resource:gold_ingot": 8},    "minutes": 90},
	"ruby_ring":            {"inputs": {"polished:ruby": 10, "resource:gold_ingot": 10},      "minutes": 120},
	"diamond_ring":         {"inputs": {"polished:diamond": 8, "resource:gold_ingot": 12},    "minutes": 180},
	## ── Food recipes (migration 097; craft 30 min; 10 of every ingredient) ──
	"sparkling_grape_juice":           {"inputs": {"crop:grapes": 10, "fruit:lemon": 10}, "minutes": 30},
	"sun_dried_trail_mix":             {"inputs": {"crop:sunflower": 10, "fruit:banana": 10}, "minutes": 30},
	"summer_melon_salad":              {"inputs": {"crop:watermelon": 10, "crop:cucumbers": 10, "fruit:lemon": 10}, "minutes": 30},
	"stuffed_roasted_peppers":         {"inputs": {"crop:peppers": 10, "crop:beans": 10, "crop:squash": 10}, "minutes": 30},
	"spiced_plum_jam":                 {"inputs": {"fruit:plum": 10, "crop:peppers": 10}, "minutes": 30},
	"roasted_cauliflower_squash_soup": {"inputs": {"crop:cauliflower": 10, "crop:squash": 10}, "minutes": 30},
	"smoked_apple_glaze":              {"inputs": {"fruit:apple": 10, "fruit:lemon": 10}, "minutes": 30},
	"tropical_oat_fruit_mash":         {"inputs": {"fruit:pineapple": 10, "fruit:coconut": 10, "fruit:banana": 10}, "minutes": 30},
	"coconut_water_hydration":         {"inputs": {"fruit:coconut": 10}, "minutes": 30},
	"sweet_banana_crisp":              {"inputs": {"fruit:banana": 10, "crop:sunflower": 10}, "minutes": 30},
	"citrus_melon_lemonade":           {"inputs": {"fruit:lemon": 10, "crop:watermelon": 10}, "minutes": 30},
	"curried_veggie_bowl":             {"inputs": {"crop:cauliflower": 10, "crop:beans": 10, "crop:peppers": 10, "crop:squash": 10}, "minutes": 30},
	"spiced_pho_noodle_bowl":          {"inputs": {"crop:beans": 10, "crop:peppers": 10, "crop:cauliflower": 10, "fruit:lemon": 10}, "minutes": 30},
}


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" Guild Production Client Tests")
	print("========================================\n")

	var gp = root.get_node_or_null("GuildProduction")
	var pd = root.get_node_or_null("PlayerData")
	if gp == null or pd == null:
		printerr("[FAIL] GuildProduction or PlayerData autoload not found!")
		quit(1)
		return true

	_test_apply_payload(gp)
	_test_remaining_time(gp)
	_test_scene_nodes()
	_test_recipe_sync(pd)

	print("\n----------------------------------------")
	print(" Results: %d passed, %d failed, %d total" % [_passed, _failed, _run])
	print("----------------------------------------\n")
	quit(1 if _failed > 0 else 0)
	return true


func _ok(cond: bool, desc: String) -> void:
	_run += 1
	if cond:
		_passed += 1
		print("  ✓ %s" % desc)
	else:
		_failed += 1
		print("  ✗ FAIL: %s" % desc)


func _eq(actual, expected, desc: String) -> void:
	_ok(actual == expected, "%s  (got %s, expected %s)" % [desc, str(actual), str(expected)])


func _test_apply_payload(gp) -> void:
	print("apply_payload parses the production queue:")
	var now := Time.get_unix_time_from_system()
	_ok(gp.apply_payload({
		"capacity": 5, "parallel": 2, "now": now,
		"items": [
			{"id": "q1", "recipe_id": "emerald_necklace", "output_item_key": "item:emerald_necklace",
			 "enqueued_at": now - 60, "finish_at": now + 300, "ready": false},
			{"id": "q2", "recipe_id": "gold_ring", "output_item_key": "item:gold_ring",
			 "enqueued_at": now - 10, "finish_at": now - 1, "ready": true},
		],
	}), "apply_payload returns true")
	_eq(gp.capacity, 5, "capacity parsed")
	_eq(gp.parallel, 2, "parallel parsed")
	_eq(gp.items.size(), 2, "two queue items")
	_eq(gp.items[0]["recipe_id"], "emerald_necklace", "first item recipe_id")
	_eq(gp.ready_count(), 1, "ready_count == 1 (q2 finished)")
	_eq(gp.is_full(), false, "not full (2 < 5)")


func _test_remaining_time(gp) -> void:
	print("remaining_seconds uses server-time offset:")
	var now := Time.get_unix_time_from_system()
	gp.apply_payload({"capacity": 3, "parallel": 1, "now": now, "items": []})
	## A finish 120s after the server's now should read ~120s remaining.
	var rem: float = gp.remaining_seconds(now + 120.0)
	_ok(rem > 115.0 and rem <= 121.0, "future finish ~120s remaining (got %.1f)" % rem)
	## A past finish reads 0 (clamped).
	_eq(gp.remaining_seconds(now - 50.0), 0.0, "past finish -> 0 remaining")


func _test_scene_nodes() -> void:
	print("Production panel nodes resolve:")
	var scene: PackedScene = load("res://scenes/screens/guild_detail_screen.tscn")
	_ok(scene != null, "guild_detail_screen.tscn loads")
	if scene == null:
		return
	var inst = scene.instantiate()
	root.add_child(inst)
	var base := "MarginContainer/OuterVBox"
	_ok(inst.get_node_or_null("%s/NavRow/ProductionNavBtn" % base) != null, "ProductionNavBtn exists")
	var panel := "%s/ContentScroll/ContentVBox/ProductionPanel" % base
	_ok(inst.get_node_or_null(panel) != null, "ProductionPanel exists")
	_ok(inst.get_node_or_null("%s/EnqueueRow/RecipeOption" % panel) != null, "RecipeOption exists")
	_ok(inst.get_node_or_null("%s/EnqueueRow/EnqueueBtn" % panel) != null, "EnqueueBtn exists")
	_ok(inst.get_node_or_null("%s/CollectBtn" % panel) != null, "CollectBtn exists")
	_ok(inst.get_node_or_null("%s/ProductionList" % panel) != null, "ProductionList exists")
	_ok(inst._nav_production != null, "@onready _nav_production resolved")
	_ok(inst._prod_list != null, "@onready _prod_list resolved")
	inst.queue_free()


func _test_recipe_sync(pd) -> void:
	print("GDScript ITEM_DEFS recipes match migration-055 seed values:")
	for jid in SEED_RECIPES:
		var def = pd.get_jewelry_def(jid)
		_ok(not def.is_empty(), "%s has a jewelry def" % jid)
		if def.is_empty():
			continue
		var recipe = def.get("recipe", {})
		var expected = SEED_RECIPES[jid]["inputs"]
		## Same input keys + quantities.
		_eq(recipe.size(), expected.size(), "%s input count" % jid)
		var match_ok := true
		for key in expected:
			if int(recipe.get(key, -1)) != int(expected[key]):
				match_ok = false
		_ok(match_ok, "%s inputs match seed (%s)" % [jid, str(expected)])
		## craft_minutes matches (seed stores craft_seconds = minutes*60).
		_eq(int(def.get("craft_minutes", -1)), int(SEED_RECIPES[jid]["minutes"]),
			"%s craft_minutes matches" % jid)
