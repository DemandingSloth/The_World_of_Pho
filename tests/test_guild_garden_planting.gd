extends SceneTree

var _done := false

func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("=== Running Guild Garden Optimistic Planting Test ===")

	var garden = root.get_node_or_null("Garden")
	var guild_garden = root.get_node_or_null("GuildGarden")

	if garden == null or guild_garden == null:
		printerr("[FAIL] Autoload Garden or GuildGarden not found!")
		quit(1)
		return true

	# Reset test state
	guild_garden.grid.clear()
	guild_garden._pending_cells.clear()
	garden.seeds[0] = 5 # 5 beans
	garden.seeds[1] = 0 # 0 cucumbers

	# Test 1: Optimistic plant immediately updates state
	print("Test 1: Testing plant_optimistic...")
	var ok1: bool = guild_garden.plant_optimistic(0, 0, 0)
	if not ok1:
		printerr("[FAIL] plant_optimistic(0, 0, 0) returned false!")
		quit(1)
		return true

	if garden.get_seed_count(0) != 4:
		printerr("[FAIL] Seed count not decremented immediately! Expected 4, got %d" % garden.get_seed_count(0))
		quit(1)
		return true

	if not guild_garden.is_occupied(0, 0):
		printerr("[FAIL] Cell (0, 0) is not marked as occupied in grid!")
		quit(1)
		return true

	if not guild_garden.is_cell_pending(0, 0):
		printerr("[FAIL] Cell (0, 0) is not marked as pending!")
		quit(1)
		return true

	print("  -> Passed Test 1: Cell occupied and seed decremented synchronously.")

	# Test 2: Double-plant guard on same cell
	print("Test 2: Double planting guard...")
	var ok_duplicate: bool = guild_garden.plant_optimistic(0, 0, 0)
	if ok_duplicate:
		printerr("[FAIL] plant_optimistic allowed duplicate planting on occupied cell (0, 0)!")
		quit(1)
		return true
	print("  -> Passed Test 2: Duplicate plant prevented.")

	# Test 3: Concurrent planting on neighboring cell
	print("Test 3: Concurrent planting on adjacent cell (0, 1)...")
	var ok2: bool = guild_garden.plant_optimistic(0, 1, 0)
	if not ok2:
		printerr("[FAIL] Could not plant adjacent cell (0, 1) while (0, 0) was in-flight!")
		quit(1)
		return true

	if garden.get_seed_count(0) != 3:
		printerr("[FAIL] Expected 3 seeds remaining, got %d" % garden.get_seed_count(0))
		quit(1)
		return true

	if not guild_garden.is_occupied(0, 1) or not guild_garden.is_cell_pending(0, 1):
		printerr("[FAIL] Cell (0, 1) state incorrect!")
		quit(1)
		return true
	print("  -> Passed Test 3: Multiple cells can be planted concurrently without blocking.")

	# Test 4: Out-of-seeds guard
	print("Test 4: Out of seeds guard...")
	var ok_no_seeds: bool = guild_garden.plant_optimistic(1, 0, 1)
	if ok_no_seeds:
		printerr("[FAIL] plant_optimistic allowed planting with 0 seeds!")
		quit(1)
		return true
	print("  -> Passed Test 4: Planting blocked when seed count is 0.")

	# Test 5: Rollback on server rejection
	print("Test 5: Testing rollback and seed refund on failure...")
	# Let's call commit_plant on cell (0, 0) with empty guild_id to simulate an error
	var fail_res = await guild_garden.commit_plant("", 0, 0, 0)
	if fail_res.get("ok", true):
		printerr("[FAIL] Expected commit_plant with empty guild_id to fail!")
		quit(1)
		return true

	if guild_garden.is_occupied(0, 0):
		printerr("[FAIL] Cell (0, 0) was not removed from grid upon failure!")
		quit(1)
		return true

	if guild_garden.is_cell_pending(0, 0):
		printerr("[FAIL] Cell (0, 0) is still marked pending after commit_plant failed!")
		quit(1)
		return true

	if garden.get_seed_count(0) != 4:
		printerr("[FAIL] Seed was not refunded upon failure! Expected 4, got %d" % garden.get_seed_count(0))
		quit(1)
		return true
	print("  -> Passed Test 5: Cell cleanly rolled back and seed refunded.")

	# Test 6: UI Widget integration
	print("Test 6: Testing GuildGardenUI responsiveness...")
	var guild_garden_ui_script = load("res://scripts/guilds/guild_garden_ui.gd")
	var gui = guild_garden_ui_script.new()
	root.add_child(gui)
	gui.setup("test_guild_id", 5, 5)

	if gui._cell_buttons.size() != 25:
		printerr("[FAIL] Expected 25 cell buttons in UI, found %d" % gui._cell_buttons.size())
		quit(1)
		return true

	# Select beans
	gui._on_seed_selected(0)
	if gui._selected_seed != 0:
		printerr("[FAIL] Seed was not selected!")
		quit(1)
		return true

	# Tap cell (2, 2)
	gui._on_cell_pressed(2, 2)
	if not guild_garden.is_occupied(2, 2):
		printerr("[FAIL] Cell (2, 2) not occupied after UI press!")
		quit(1)
		return true

	if garden.get_seed_count(0) != 3:
		printerr("[FAIL] Seed count not decremented after UI press! Expected 3, got %d" % garden.get_seed_count(0))
		quit(1)
		return true

	var btn: Button = gui._cell_buttons.get(Vector2i(2, 2))
	var sprite: TextureRect = btn.get_node_or_null("PlantSprite") as TextureRect
	if sprite == null or not sprite.visible:
		printerr("[FAIL] PlantSprite is not visible immediately on cell (2, 2)!")
		quit(1)
		return true

	gui.teardown()
	gui.queue_free()
	print("  -> Passed Test 6: GuildGardenUI displays plant immediately on tap.")

	print("\n*** ALL GUILD GARDEN PLANTING TESTS PASSED! ***")
	quit(0)
	return true
