extends SceneTree

var _done := false

func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("=== Running Guild Orchard Fruit & Produce Missions Test ===")

	var player_data = root.get_node_or_null("PlayerData")
	if player_data == null:
		printerr("[FAIL] Autoload PlayerData not found!")
		quit(1)
		return true

	# ── Test 1: PlayerData Orchard Fruit & Present exclusion ──
	print("Test 1: Testing orchard fruit vs present identification...")
	var expected_fruits := ["plum", "lemon", "apple", "banana", "coconut"]
	for f in expected_fruits:
		if not player_data.is_orchard_fruit(f):
			printerr("[FAIL] Expected %s to be recognized as orchard fruit!" % f)
			quit(1)
			return true

	if player_data.is_orchard_fruit("present"):
		printerr("[FAIL] 'present' MUST NOT be recognized as an orchard fruit!")
		quit(1)
		return true

	if player_data.is_orchard_fruit("beans"):
		printerr("[FAIL] 'beans' (crop) must not be recognized as an orchard fruit!")
		quit(1)
		return true

	if player_data.is_orchard_fruit(""):
		printerr("[FAIL] Empty string must not be recognized as an orchard fruit!")
		quit(1)
		return true

	print("  -> Passed Test 1: Orchard fruits recognized, presents and crops excluded.")

	# ── Test 2: PlayerData Crop identification ──
	print("Test 2: Testing crop identification...")
	var expected_crops := [
		"beans", "cucumbers", "peppers", "squash",
		"grapes", "sunflower", "cauliflower", "pineapple", "watermelon"
	]
	for c in expected_crops:
		if not player_data.is_garden_crop(c):
			printerr("[FAIL] Expected %s to be recognized as garden crop!" % c)
			quit(1)
			return true

	if player_data.is_garden_crop("apple"):
		printerr("[FAIL] 'apple' (fruit) must not be recognized as a garden crop!")
		quit(1)
		return true

	if player_data.is_garden_crop("present"):
		printerr("[FAIL] 'present' must not be recognized as a garden crop!")
		quit(1)
		return true

	print("  -> Passed Test 2: Garden crops recognized correctly.")

	# ── Test 3: PlayerData Produce identification ──
	print("Test 3: Testing produce identification (crops + fruit, excluding presents)...")
	for c in expected_crops:
		if not player_data.is_produce(c):
			printerr("[FAIL] Expected crop %s to be recognized as produce!" % c)
			quit(1)
			return true

	for f in expected_fruits:
		if not player_data.is_produce(f):
			printerr("[FAIL] Expected fruit %s to be recognized as produce!" % f)
			quit(1)
			return true

	if player_data.is_produce("present"):
		printerr("[FAIL] 'present' MUST NOT be recognized as produce!")
		quit(1)
		return true

	if player_data.is_produce("wood"):
		printerr("[FAIL] 'wood' must not be recognized as produce!")
		quit(1)
		return true

	print("  -> Passed Test 3: Produce identification verified (presents strictly excluded).")

	# ── Test 4: Inventory consumption and unified helpers ──
	print("Test 4: Testing unified crop & fruit inventory helpers...")
	player_data.fruits.clear()
	player_data.crops.clear()

	# Add fruit and crop via unified helper
	player_data.add_crop_or_fruit("apple", 10)
	player_data.add_crop_or_fruit("beans", 15)

	if player_data.get_crop_or_fruit_count("apple") != 10:
		printerr("[FAIL] Expected 10 apples, got %d" % player_data.get_crop_or_fruit_count("apple"))
		quit(1)
		return true

	if player_data.get_crop_or_fruit_count("beans") != 15:
		printerr("[FAIL] Expected 15 beans, got %d" % player_data.get_crop_or_fruit_count("beans"))
		quit(1)
		return true

	# Total produce count
	var total_prod: int = player_data.get_total_produce_count()
	if total_prod != 25:
		printerr("[FAIL] Expected total produce count to be 25, got %d" % total_prod)
		quit(1)
		return true

	# Consume fruit
	var consumed_fruit: bool = player_data.consume_crop_or_fruit("apple", 4)
	if not consumed_fruit or player_data.get_crop_or_fruit_count("apple") != 6:
		printerr("[FAIL] Consuming 4 apples failed or gave wrong count!")
		quit(1)
		return true

	# Cannot consume more than owned
	var over_consume: bool = player_data.consume_crop_or_fruit("apple", 10)
	if over_consume:
		printerr("[FAIL] consume_crop_or_fruit allowed consuming more than owned!")
		quit(1)
		return true

	# Consume crop
	var consumed_crop: bool = player_data.consume_crop_or_fruit("beans", 5)
	if not consumed_crop or player_data.get_crop_or_fruit_count("beans") != 10:
		printerr("[FAIL] Consuming 5 beans failed or gave wrong count!")
		quit(1)
		return true

	print("  -> Passed Test 4: Inventory consumption and counts verified.")

	# ── Test 5: GuildDetailScreen Mission cards ──
	print("Test 5: Testing GuildDetailScreen mission card creation...")
	var screen_script = load("res://scripts/screens/guild_detail_screen.gd")
	var screen = screen_script.new()

	var fruit_mission := {"base_mission_key": "deposit_fruit", "target": 20, "difficulty": "easy"}
	var produce_mission := {"base_mission_key": "deposit_produce", "target": 30, "difficulty": "medium"}
	var plum_mission := {"base_mission_key": "deposit_plum", "target": 18, "difficulty": "medium"}
	var cucumber_mission := {"base_mission_key": "deposit_cucumbers", "target": 15, "difficulty": "easy"}

	var card_fruit = screen._make_mission_card(fruit_mission)
	var card_produce = screen._make_mission_card(produce_mission)
	var card_plum = screen._make_mission_card(plum_mission)
	var card_cucumber = screen._make_mission_card(cucumber_mission)

	if card_fruit == null or card_produce == null or card_plum == null or card_cucumber == null:
		printerr("[FAIL] Failed to build mission cards!")
		quit(1)
		return true

	print("  -> Passed Test 5: Built mission cards successfully for fruit, produce, and specific items.")

	card_fruit.free()
	card_produce.free()
	card_plum.free()
	card_cucumber.free()
	screen.free()

	print("\n=== All Guild Orchard Fruit & Produce Missions tests PASSED! ===")
	quit(0)
	return true
