extends SceneTree

var _done := false

func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("=== Running Seed Bar Repopulate Test ===")
	var garden = root.get_node_or_null("Garden")
	var garden_ui_script = load("res://scripts/garden/garden_ui.gd")
	var gui = garden_ui_script.new()
	root.add_child(gui)

	# Ensure beans count starts at 0 for this test
	garden.seeds[0] = 0

	gui._rebuild_all()
	var initial_children := 0
	for child in gui._seed_bar.get_children():
		if child.get_meta("plant_type", -1) == 0:
			initial_children += 1

	print("Initial bean buttons in seed bar: %d (expected 0)" % initial_children)

	# Now add 5 beans via Garden.add_seeds (simulating the grant)
	garden.add_seeds(0, 5)

	# Check if seed bar has been updated immediately without leaving the page
	var updated_children := 0
	for child in gui._seed_bar.get_children():
		if child.get_meta("plant_type", -1) == 0:
			updated_children += 1

	print("Updated bean buttons in seed bar: %d (expected 1)" % updated_children)

	gui.queue_free()

	if initial_children == 0 and updated_children == 1:
		print("[PASS] Seed bar automatically repopulated after granting beans!")
		quit(0)
	else:
		printerr("[FAIL] Seed bar failed to repopulate!")
		quit(1)

	return true
