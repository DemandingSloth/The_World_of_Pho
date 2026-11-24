class_name ScreenNavigator
extends Node
## Central orchestrator for screen transitions in the screen-per-scene architecture.
## Maps screen names to .tscn paths, handles navigation stack via AndroidLifecycleManager,
## manages screen lifecycle (exit/enter), caching, and error cases.
##
## Requirements: 1.1, 2.1, 2.2, 2.3, 2.4, 2.6, 2.7, 2.8, 6.1, 6.2, 6.6, 7.1, 9.6, 10.1, 10.2, 10.3, 10.4, 10.5

const SCREEN_PARENTS := {
	"town": "home",
	"inventory": "home",
	"marketplace": "home",
	"online_marketplace": "marketplace",
	"achievements": "home",
	"settings": "home",
	"games": "town",
	"mission_board": "town",
	"garden": "town",
	"hare_chase": "garden",
	"orchard": "garden",
	"mining": "town",
	"school": "town",
	"prestige": "town",
	"business_district": "town",
	"setup": "games",
	"prep": "setup",
	"battle": "prep",
	"result": "setup",
	"run_complete": "home",
	"tutorial": "school",
	"gold_panning": "mining",
	"prospectors": "mining",
	"deep_mine": "mining",
	"workshop": "home",
	"guilds": "home",
	## Back from a guild goes Home, not to the "guilds" lobby: the lobby
	## immediately redirects members back to guild_detail, which made Back
	## look like it did nothing.
	"guild_detail": "home",
	"active_bonuses": "home",
	## Money Gun + Jewelry (equipment) are reached from the Inventory screen.
	"money_gun": "inventory",
	"equipment": "inventory",
	## Horse Racing: Equestrian Center hub (from Town) + its areas.
	"equestrian": "town",
	"stable": "equestrian",
	"pasture": "equestrian",
	"racetrack": "equestrian"
	# Add any additional child-to-parent mappings here
}
## Emitted after a screen transition completes successfully.
signal screen_changed(screen_name: String)


## Path to the container Control node where screen scenes are instantiated as children.
@export var screen_container_path: NodePath

## Resolved reference to the screen container node.
var screen_container: Control


## Mapping of all screen names to their .tscn file paths.
const SCREEN_PATHS: Dictionary = {
	"home": "res://scenes/screens/home_screen.tscn",
	"town": "res://scenes/screens/town_screen.tscn",
	"marketplace": "res://scenes/screens/marketplace_screen.tscn",
	"online_marketplace": "res://scenes/screens/online_marketplace_screen.tscn",
	"inventory": "res://scenes/screens/inventory_screen.tscn",
	"garden": "res://scenes/screens/garden_screen.tscn",
	"hare_chase": "res://scenes/screens/hare_chase_screen.tscn",
	"orchard": "res://scenes/screens/orchard_screen.tscn",
	"mining": "res://scenes/screens/mining_screen.tscn",
	"school": "res://scenes/screens/school_screen.tscn",
	"achievements": "res://scenes/screens/achievements_screen.tscn",
	"setup": "res://scenes/screens/setup_screen.tscn",
	"prep": "res://scenes/screens/prep_screen.tscn",
	"battle": "res://scenes/screens/battle_screen.tscn",
	"result": "res://scenes/screens/result_screen.tscn",
	"run_complete": "res://scenes/screens/run_complete_screen.tscn",
	"tutorial": "res://scenes/screens/tutorial_screen.tscn",
	"games": "res://scenes/screens/games_screen.tscn",
	"gold_panning": "res://scenes/screens/gold_panning_screen.tscn",
	"prospectors": "res://scenes/screens/prospectors_screen.tscn",
	"mission_board": "res://scenes/screens/mission_board_screen.tscn",
	"prestige": "res://scenes/screens/prestige_screen.tscn",
	"business_district": "res://scenes/screens/business_district_screen.tscn",
	"deep_mine": "res://scenes/screens/deep_mine_screen.tscn",
	"workshop": "res://scenes/screens/workshop_screen.tscn",
	"guilds": "res://scenes/screens/guilds_screen.tscn",
	"guild_detail": "res://scenes/screens/guild_detail_screen.tscn",
	"active_bonuses": "res://scenes/screens/active_bonuses_screen.tscn",
	"money_gun": "res://scenes/screens/money_gun_screen.tscn",
	"equipment": "res://scenes/screens/equipment_screen.tscn",
	"equestrian": "res://scenes/screens/equestrian_center_screen.tscn",
	"stable": "res://scenes/screens/stable_screen.tscn",
	"pasture": "res://scenes/screens/pasture_screen.tscn",
	"racetrack": "res://scenes/screens/racetrack_screen.tscn",
}


## Cache of preloaded PackedScene resources keyed by screen name.
var _screen_cache: Dictionary = {}

## Whether a transition is currently in progress.
var _is_transitioning: bool = false

## Queue of pending navigation requests made during an active transition.
## Each entry is a Dictionary with "screen_name" and "params" keys.
var _transition_queue: Array[Dictionary] = []


func _ready() -> void:
	# Resolve the screen_container NodePath to a Control reference
	if screen_container_path != NodePath(""):
		screen_container = get_node(screen_container_path) as Control
	
	# Connect to PerformanceManager memory_warning signal to clear cache under pressure.
	var perf_mgr := get_node_or_null("/root/PerformanceManager")
	if perf_mgr != null and perf_mgr.has_signal("memory_warning"):
		perf_mgr.memory_warning.connect(_on_memory_warning)


## Navigate to a named screen, pushing current screen onto the navigation stack.
## If a transition is already in progress, the request is queued.
## [param screen_name]: The key in SCREEN_PATHS identifying the target screen.
## [param params]: Optional dictionary passed to the new screen's enter() method.
func navigate_to(screen_name: String, params: Dictionary = {}) -> void:
	# Queue if a transition is already active (Req 2.8)
	if _is_transitioning:
		_transition_queue.append({"screen_name": screen_name, "params": params})
		return

	_is_transitioning = true

	# Handle unknown screen names — log error and fallback to home (Req 2.6)
	if screen_name not in SCREEN_PATHS:
		push_error("ScreenNavigator: Unknown screen name '%s'. Falling back to 'home'." % screen_name)
		screen_name = "home"

	# Step 1: Exit current screen and save data (Req 10.1, 9.6)
	var current := get_current_screen()
	if current != null:
		current.exit()
		PlayerData.save_data()
		screen_container.remove_child(current)
		current.queue_free()

	# Step 2: Push onto navigation stack via AndroidLifecycleManager (Req 2.3)
	AndroidLifecycleManager.push_screen(screen_name)

	# Step 3: Load the screen scene (Req 2.7 — handle load failures)
	var scene: PackedScene = _load_screen(screen_name)
	if scene == null:
		push_error("ScreenNavigator: Failed to load scene for '%s'. Staying on current screen." % screen_name)
		_is_transitioning = false
		_process_queue()
		return

	# Step 4: Instantiate and add to container (Req 2.1, 2.2, 10.3)
	var instance: BaseScreen = scene.instantiate() as BaseScreen
	if instance == null:
		push_error("ScreenNavigator: Instantiated scene for '%s' is not a BaseScreen." % screen_name)
		_is_transitioning = false
		_process_queue()
		return

	screen_container.add_child(instance)

	# Step 5: Set full-rect anchors so screen fills available space (Req 7.1)
	instance.anchor_left = 0.0
	instance.anchor_top = 0.0
	instance.anchor_right = 1.0
	instance.anchor_bottom = 1.0
	instance.offset_left = 0.0
	instance.offset_top = 0.0
	instance.offset_right = 0.0
	instance.offset_bottom = 0.0

	# Step 6: Enter the new screen with parameters (Req 6.1, 6.2)
	instance.enter(params)

	# Step 7: Update top bar and background
	_update_top_bar(instance)
	_update_background(instance)

	# Step 8: Emit signal and finish transition
	screen_changed.emit(screen_name)
	_is_transitioning = false

	# Process any queued transitions
	_process_queue()


## Navigate back using AndroidLifecycleManager's navigation stack.
## Pops the stack and navigates to the previous screen with empty params. (Req 2.4)
func navigate_back() -> void:
	var current := get_current_screen()
	var current_name := current.get_screen_name() if current != null else ""
	
	# Determine target screen: try hierarchy first, then stack fallback, then default to "home"
	var target_screen: String = ""
	
	if SCREEN_PARENTS.has(current_name):
		target_screen = SCREEN_PARENTS[current_name]
	else:
		# Failsafe: Not in dictionary, fall back to previous screen in history stack
		target_screen = AndroidLifecycleManager.pop_screen()
		if target_screen == "":
			target_screen = "home"
	
	# If target resolves to the current screen or we are already on home with empty stack, ignore
	if current_name == target_screen:
		return

	if _is_transitioning:
		_transition_queue.append({"screen_name": target_screen, "params": {}})
		return

	_is_transitioning = true

	# Exit current screen and save data (Req 10.1, 9.6)
	if current != null:
		current.exit()
		PlayerData.save_data()
		screen_container.remove_child(current)
		current.queue_free()

	# Load and instantiate the target screen (Req 2.7)
	var scene: PackedScene = _load_screen(target_screen)
	if scene == null:
		push_error("ScreenNavigator: Failed to load scene for back navigation to '%s'." % target_screen)
		_is_transitioning = false
		_process_queue()
		return

	var instance: BaseScreen = scene.instantiate() as BaseScreen
	if instance == null:
		push_error("ScreenNavigator: Instantiated scene for '%s' is not a BaseScreen." % target_screen)
		_is_transitioning = false
		_process_queue()
		return

	screen_container.add_child(instance)

	# Set full-rect anchors (Req 7.1)
	instance.anchor_left = 0.0
	instance.anchor_top = 0.0
	instance.anchor_right = 1.0
	instance.anchor_bottom = 1.0
	instance.offset_left = 0.0
	instance.offset_top = 0.0
	instance.offset_right = 0.0
	instance.offset_bottom = 0.0

	# Enter with empty params for back navigation (Req 6.6)
	instance.enter({})

	# Update top bar and background
	_update_top_bar(instance)
	_update_background(instance)

	screen_changed.emit(target_screen)
	_is_transitioning = false

	_process_queue()
## Returns the currently active screen node, or null if ScreenContainer is empty.
func get_current_screen() -> BaseScreen:
	if screen_container == null:
		return null
	if screen_container.get_child_count() == 0:
		return null
	return screen_container.get_child(0) as BaseScreen


## Preload a screen scene into the cache for faster future transitions.
## [param screen_name]: The key in SCREEN_PATHS to preload.
func preload_screen(screen_name: String) -> void:
	if screen_name not in SCREEN_PATHS:
		push_error("ScreenNavigator: Cannot preload unknown screen '%s'." % screen_name)
		return
	if screen_name in _screen_cache:
		return  # Already cached
	var scene: PackedScene = load(SCREEN_PATHS[screen_name]) as PackedScene
	if scene != null:
		_screen_cache[screen_name] = scene


## ── Private Helpers ─────────────────────────────────────────────────


## Load a screen scene from cache or disk. Returns null on failure.
func _load_screen(screen_name: String) -> PackedScene:
	if screen_name in _screen_cache:
		return _screen_cache[screen_name]

	var path: String = SCREEN_PATHS.get(screen_name, "")
	if path == "":
		return null

	var scene: PackedScene = load(path) as PackedScene
	return scene


## Process any queued navigation requests after a transition completes.
func _process_queue() -> void:
	if _transition_queue.is_empty():
		return
	var next: Dictionary = _transition_queue.pop_front()
	navigate_to(next["screen_name"], next["params"])


## Update TopBar visibility and state for the active screen.
func _update_top_bar(screen: BaseScreen) -> void:
	var top_bar := get_parent().get_node_or_null("TopBar")
	if top_bar == null:
		return
	top_bar.visible = true  ## Hotbar is visible on EVERY screen
	if top_bar.has_method("refresh"):
		top_bar.refresh()
	if top_bar.has_method("set_active_screen"):
		top_bar.set_active_screen(screen.get_screen_name())


## Update the Background TextureRect based on the active screen's get_background_override().
func _update_background(screen: BaseScreen) -> void:
	var background: TextureRect = get_parent().get_node_or_null("Background") as TextureRect
	if background == null:
		return

	var override_path: String = screen.get_background_override()
	if override_path == "":
		# Restore default background (the one assigned at app start)
		if background.has_meta("default_texture"):
			background.texture = background.get_meta("default_texture")
	else:
		var tex: Texture2D = load(override_path) as Texture2D
		if tex != null:
			# Store default texture on first override if not already stored
			if not background.has_meta("default_texture"):
				background.set_meta("default_texture", background.texture)
			background.texture = tex
		else:
			push_warning("ScreenNavigator: Background override path '%s' failed to load." % override_path)


## Handle memory warning from PerformanceManager by clearing the screen cache. (Req 10.4)
func _on_memory_warning() -> void:
	print("[ScreenNavigator] Memory warning received. Clearing screen cache (%d entries)." % _screen_cache.size())
	_screen_cache.clear()
