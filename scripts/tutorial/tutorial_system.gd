extends Node

## Autoload: TutorialSystem
## Central singleton managing guided tutorial state, step progression, persistence,
## and coordination with ScreenNavigator for cross-screen tutorial flows.
##
## Requirements: 1.1, 1.2, 1.3, 3.1, 3.2, 3.3, 4.2, 4.3, 5.2, 5.3, 12.1, 12.2, 12.3, 14.3

## ── Signals ────────────────────────────────────────────────────
signal tutorial_started
signal tutorial_completed
signal step_changed(step_index: int)

## ── Constants ──────────────────────────────────────────────────
const OVERLAY_SCENE_PATH := "res://scenes/tutorial/tutorial_overlay.tscn"

## ── State ──────────────────────────────────────────────────────
enum State { INACTIVE, ACTIVE, COMPLETED }

var current_state: State = State.INACTIVE
var current_step_index: int = -1
var is_replay: bool = false

## Reference to the active TutorialOverlay instance.
var _overlay: Node = null

## Reference to ScreenNavigator (resolved in _ready).
var _screen_navigator: Node = null

## Tracks the currently connected action signal for disconnection on advance.
var _connected_action_source: Node = null
var _connected_action_signal: String = ""
var _connected_callable: Callable = Callable()

## Tracks whether the currently active step has granted its resources
var _granted_steps: Dictionary = {}

## Step sequence matching user specification:
var STEP_SEQUENCE: Array[Dictionary] = [
	# ── Step 0: Welcome / Choose your name / Register for the online market ──
	{
		"id": "welcome_name_market",
		"screen": "home",
		"target_path": "",
		"text": "Welcome: Choose your name.\nRegister for the online market.",
		"action_required": false,
		"navigate_to": "",
		"continue_text": "Continue",
		"highlight_padding": 8,
		"bubble_position": "below",
		"grants": {},
		"grant_condition": "",
	},

	# ── Step 1: Force navigation to garden & intro ─────────────────────
	{
		"id": "garden_intro",
		"screen": "garden",
		"target_path": "",
		"text": "Here's Your garden. plant seeds and watch them grow. then you can sell your produce either to the game or to other players on the online market.",
		"action_required": false,
		"navigate_to": "garden",
		"continue_text": "Next",
		"highlight_padding": 12,
		"bubble_position": "below",
		"grants": {},
		"grant_condition": "",
	},

	# ── Step 2: Grant 5 bean seeds ─────────────────────────────────────
	{
		"id": "garden_grant_beans",
		"screen": "garden",
		"target_path": "",
		"text": "Here's 5 bean seeds to get you started.",
		"action_required": false,
		"navigate_to": "",
		"continue_text": "Next",
		"highlight_padding": 8,
		"bubble_position": "below",
		"grants": {"seeds": {"type": 0, "qty": 5}},
		"grant_condition": "always",
	},

	# ── Step 3: Plant your 5 beans ─────────────────────────────────────
	{
		"id": "garden_plant_beans",
		"screen": "garden",
		"target_path": "",
		"text": "Plant your 5 beans\nSelect beans from your seed bar above, then tap empty plots to plant them.",
		"action_required": false,
		"allow_interaction": true,
		"navigate_to": "",
		"continue_text": "Done Planting",
		"highlight_padding": 8,
		"bubble_position": "bottom",
		"grants": {},
		"grant_condition": "",
	},

	# ── Step 4: Growth tip + pause ────────────────────────────────────
	{
		"id": "garden_growth_tip",
		"screen": "garden",
		"target_path": "",
		"text": "Congrats now you just gotta wait for those sweet sweet rewards. Your Beans will be ready in 5 Minutes.",
		"action_required": false,
		"navigate_to": "",
		"pause_after": true,
		"continue_text": "Continue",
		"highlight_padding": 8,
		"bubble_position": "below",
		"grants": {},
		"grant_condition": "",
	},

	# ── Step 5: Explore other features prompt ─────────────────────────
	{
		"id": "garden_explore_prompt",
		"screen": "garden",
		"target_path": "",
		"text": "Let's go explore some other features while we got you here.",
		"action_required": false,
		"navigate_to": "",
		"continue_text": "Let's Go!",
		"highlight_padding": 8,
		"bubble_position": "below",
		"grants": {},
		"grant_condition": "",
	},

	# ── Step 6: Marketplace transition & cheat code ───────────────────
	{
		"id": "marketplace_intro",
		"screen": "marketplace",
		"target_path": "",
		"text": "Here you can buy Pho tiles, Seeds or tools to help you out.\n\nEnter code SlothRegisterMarket in the cheat code section to register for the online marketplace and trade goods with others.",
		"action_required": false,
		"navigate_to": "marketplace",
		"continue_text": "Next",
		"highlight_padding": 12,
		"bubble_position": "below",
		"grants": {},
		"grant_condition": "",
	},

	# ── Step 7: Missions transition & info ────────────────────────────
	{
		"id": "missions_intro",
		"screen": "mission_board",
		"target_path": "",
		"text": "These are your missions, you have 48hrs from the time it spawns to claim a mission. Once you claim, attempt the task described in the mission and come back here to claim your rewards.",
		"action_required": false,
		"navigate_to": "mission_board",
		"continue_text": "Next",
		"highlight_padding": 12,
		"bubble_position": "below",
		"grants": {},
		"grant_condition": "",
	},

	# ── Step 8: Town transition, XP, prestige & cheat code ────────────
	{
		"id": "town_overview",
		"screen": "town",
		"target_path": "",
		"text": "This is the main Town screen. It's where most of the fun stuff lives.\n\nSome things are locked until you level up.\n\nSelling Items and playing games, doing missions all earns you XP. When you get enough you can spend it in the prestige screen to unlock powerful boosts, but at the expense of your xp and level.\n\nEnter code SlothsFreshStart in the cheat code section of Settings for a small boost to help you get started.",
		"action_required": false,
		"navigate_to": "town",
		"continue_text": "Finish Tutorial",
		"highlight_padding": 12,
		"bubble_position": "below",
		"grants": {},
		"grant_condition": "",
	},
]

## Tracks whether the current action-required step's action has been completed.
var _action_completed: bool = false


## ── Lifecycle ──────────────────────────────────────────────────

func _ready() -> void:
	# Resolve ScreenNavigator reference (it's a child of Main, not an autoload)
	# Defer to ensure the scene tree is ready.
	call_deferred("_connect_screen_navigator")

	# On app start, check if we should resume in-progress tutorial
	call_deferred("_auto_start_if_needed")


## Deferred connection to ScreenNavigator (Req 12.3).
func _connect_screen_navigator() -> void:
	_screen_navigator = get_tree().root.get_node_or_null("Main/ScreenNavigator")
	if _screen_navigator != null:
		_screen_navigator.screen_changed.connect(_on_screen_changed)
	else:
		push_warning("TutorialSystem: Could not find Main/ScreenNavigator. Screen transition handling disabled.")


## Called one frame after _ready so the ScreenNavigator is already wired.
func _auto_start_if_needed() -> void:
	# Only resume if player was actively in the middle of a tutorial
	if not PlayerData.tutorial_completed and PlayerData.tutorial_step_index > 0:
		resume_tutorial()


## ── Public Interface ───────────────────────────────────────────

## Determines whether the tutorial should start, resume, or be skipped
## based on the current PlayerData state.
## Returns: "start", "resume", or "skip"
func get_decision() -> String:
	if PlayerData.tutorial_completed or PlayerData.tutorial_home_dismissed:
		return "skip"
	if PlayerData.tutorial_step_index > 0:
		return "resume"
	return "skip"


## Begin the tutorial from step 0. (Req 1.1)
func start_tutorial() -> void:
	is_replay = false
	current_step_index = 0
	current_state = State.ACTIVE
	_action_completed = false
	_granted_steps.clear()

	PlayerData.tutorial_completed = false
	PlayerData.tutorial_step_index = current_step_index
	PlayerData.tutorial_home_dismissed = true
	PlayerData.save_data()

	_ensure_overlay()

	# If not on home screen, navigate to home first
	if _screen_navigator != null:
		var current = _screen_navigator.get_current_screen()
		if current == null or current.get_screen_name() != "home":
			if _overlay != null:
				_overlay.visible = false
			_screen_navigator.navigate_to("home")
			tutorial_started.emit()
			step_changed.emit(current_step_index)
			return

	_show_current_step()

	tutorial_started.emit()
	step_changed.emit(current_step_index)


## Resume the tutorial from the persisted step index. (Req 1.3)
func resume_tutorial() -> void:
	is_replay = false
	current_step_index = PlayerData.tutorial_step_index
	# Clamp to valid range
	if current_step_index < 0:
		current_step_index = 0
	if STEP_SEQUENCE.size() > 0:
		current_step_index = mini(current_step_index, STEP_SEQUENCE.size() - 1)

	current_state = State.ACTIVE
	_action_completed = false

	# Instantiate TutorialOverlay
	_ensure_overlay()
	_show_current_step()

	tutorial_started.emit()
	step_changed.emit(current_step_index)


## Advance to the next step in the sequence. (Req 3.1, 3.2)
func advance_step() -> void:
	if current_state != State.ACTIVE:
		return

	var step := get_current_step()
	if step.is_empty():
		return

	# Block advancement if action is required but not completed (Req 3.2)
	if step.get("action_required", false) and not _action_completed:
		return

	# Disconnect previous action signal before moving forward (Task 8.3)
	_disconnect_action_signal()
	if Garden.garden_updated.is_connected(_on_garden_planting_updated):
		Garden.garden_updated.disconnect(_on_garden_planting_updated)

	# Move to next step
	current_step_index += 1
	_action_completed = false

	# Check if we've completed all steps (Req 3.3)
	if current_step_index >= STEP_SEQUENCE.size():
		_complete_tutorial()
		return

	# Persist progress (Req 14.1)
	if not is_replay:
		PlayerData.tutorial_step_index = current_step_index
		PlayerData.save_data()

	_show_current_step()
	step_changed.emit(current_step_index)


## Mark the tutorial as completed and dismiss the overlay. (Req 4.2, 4.3)
func skip_tutorial() -> void:
	_disconnect_action_signal()
	if Garden.garden_updated.is_connected(_on_garden_planting_updated):
		Garden.garden_updated.disconnect(_on_garden_planting_updated)
	if not is_replay:
		PlayerData.tutorial_completed = true
		PlayerData.tutorial_step_index = -1
		PlayerData.tutorial_home_dismissed = true
		PlayerData.save_data()

	current_state = State.COMPLETED
	_dismiss_overlay()
	tutorial_completed.emit()


## Start the tutorial from the beginning as a replay. (Req 5.2, 5.3)
func replay_tutorial() -> void:
	is_replay = true
	current_step_index = 0
	current_state = State.ACTIVE
	_action_completed = false
	_granted_steps.clear()

	# Instantiate TutorialOverlay
	_ensure_overlay()

	# If not on home screen, navigate to home first!
	if _screen_navigator != null:
		var current = _screen_navigator.get_current_screen()
		if current == null or current.get_screen_name() != "home":
			if _overlay != null:
				_overlay.visible = false
			_screen_navigator.navigate_to("home")
			tutorial_started.emit()
			step_changed.emit(current_step_index)
			return

	_show_current_step()

	tutorial_started.emit()
	step_changed.emit(current_step_index)


## Returns the current step's data dictionary, or an empty dictionary if invalid.
func get_current_step() -> Dictionary:
	if current_step_index < 0 or current_step_index >= STEP_SEQUENCE.size():
		return {}
	return STEP_SEQUENCE[current_step_index]


## Called externally when an action-required step's action is completed.
func mark_action_completed() -> void:
	_action_completed = true


## ── Private Helpers ────────────────────────────────────────────

## Complete the tutorial after the final step. (Req 3.3)
func _complete_tutorial() -> void:
	_disconnect_action_signal()
	if Garden.garden_updated.is_connected(_on_garden_planting_updated):
		Garden.garden_updated.disconnect(_on_garden_planting_updated)
	if not is_replay:
		PlayerData.tutorial_completed = true
		PlayerData.tutorial_step_index = -1
		PlayerData.tutorial_home_dismissed = true
		PlayerData.save_data()

	current_state = State.COMPLETED
	_dismiss_overlay()
	tutorial_completed.emit()


## Display the current step on the overlay.
## Handles navigation, resource grants, action signal wiring, and overlay display.
func _show_current_step() -> void:
	var step := get_current_step()
	if step.is_empty():
		return

	# ── Task 8.1: Navigation if step requires a different screen ──
	var navigate_to: String = step.get("navigate_to", "")
	if navigate_to != "" and _screen_navigator != null:
		var current_screen_name: String = ""
		var current_scr = _screen_navigator.get_current_screen()
		if current_scr != null:
			current_screen_name = current_scr.get_screen_name()
		if current_screen_name != navigate_to:
			if _overlay != null:
				_overlay.visible = false
			_screen_navigator.navigate_to(navigate_to)
			return

	# ── Task 8.4: Resource grants before showing step ──
	_process_grants(step)

	# Special handling for step 0 (welcome / choose name)
	if step.get("id") == "welcome_name_market":
		if not PlayerData.has_set_name:
			var screen_container := get_tree().root.get_node_or_null("Main/ScreenContainer")
			if screen_container != null and screen_container.get_child_count() > 0:
				var home_screen = screen_container.get_child(0)
				if home_screen.has_method("_show_name_prompt"):
					home_screen._show_name_prompt()

	# ── Task 8.3: Wire action signal if step requires an action ──
	_connect_action_signal(step)

	# ── Show step on overlay ──
	if _overlay != null:
		_overlay.visible = true
		if _overlay.highlight_frame != null:
			_overlay.highlight_frame.visible = true
		if _overlay.text_bubble != null:
			_overlay.text_bubble.visible = true
		_overlay.show_step(step)

	# Special handling for planting step: listen to Garden updates
	if step.get("id") == "garden_plant_beans":
		if not Garden.garden_updated.is_connected(_on_garden_planting_updated):
			Garden.garden_updated.connect(_on_garden_planting_updated)

	# Special handling for growth tip pause:
	if step.get("pause_after", false):
		_start_pause_timer()

	# ── Req 12.1: If target not found and action_required, auto-mark completed ──
	if step.get("action_required", false):
		var target_path: String = step.get("target_path", "")
		if target_path != "" and not _can_resolve_target(target_path):
			_action_completed = true


## Remove the overlay from the scene tree.
func _dismiss_overlay() -> void:
	_disconnect_action_signal()
	if _overlay != null:
		_overlay.hide_overlay()
		_overlay.queue_free()
		_overlay = null


## Check if a target_path can be resolved on the current screen.
## Returns true if the target node exists, false otherwise. (Req 12.1)
func _can_resolve_target(target_path: String) -> bool:
	if target_path == "":
		return false
	var screen_container_node := get_tree().root.get_node_or_null("Main/ScreenContainer")
	if screen_container_node == null or screen_container_node.get_child_count() == 0:
		return false
	var current_screen: Control = screen_container_node.get_child(0) as Control
	if current_screen == null:
		return false
	var target := current_screen.get_node_or_null(NodePath(target_path))
	return target != null


## Skip forward to the next step whose screen is available in ScreenNavigator.
## If no valid step is found, completes the tutorial. (Req 12.1 error handling)
func _skip_to_next_available_step() -> void:
	var start_index := current_step_index + 1
	while start_index < STEP_SEQUENCE.size():
		var candidate_step: Dictionary = STEP_SEQUENCE[start_index]
		var candidate_nav: String = candidate_step.get("navigate_to", "")
		var candidate_screen: String = candidate_step.get("screen", "")

		# A step is available if it doesn't require navigation to a missing screen
		var target_screen := candidate_nav if candidate_nav != "" else candidate_screen
		if target_screen == "" or target_screen in ScreenNavigator.SCREEN_PATHS:
			# Found a valid step — jump to it
			current_step_index = start_index
			_action_completed = false
			if not is_replay:
				PlayerData.tutorial_step_index = current_step_index
				PlayerData.save_data()
			_show_current_step()
			step_changed.emit(current_step_index)
			return
		start_index += 1

	# No valid steps remaining — complete the tutorial
	push_warning("TutorialSystem: No remaining steps target available screens. Completing tutorial.")
	_complete_tutorial()


## Instantiate the TutorialOverlay if not already present.
func _ensure_overlay() -> void:
	if _overlay != null:
		return
	var overlay_scene: PackedScene = load(OVERLAY_SCENE_PATH) as PackedScene
	if overlay_scene == null:
		push_error("TutorialSystem: Failed to load TutorialOverlay scene at '%s'. Marking tutorial complete." % OVERLAY_SCENE_PATH)
		# Avoid blocking the player if overlay can't load
		if not is_replay:
			PlayerData.tutorial_completed = true
			PlayerData.save_data()
		current_state = State.COMPLETED
		return

	_overlay = overlay_scene.instantiate()
	get_tree().root.add_child(_overlay)

	# Connect overlay signals
	_overlay.continue_pressed.connect(_on_overlay_continue)
	_overlay.skip_requested.connect(_on_overlay_skip_requested)
	_overlay.skip_confirmed.connect(_on_overlay_skip_confirmed)
	_overlay.skip_cancelled.connect(_on_overlay_skip_cancelled)


## ── Task 8.1: Screen transition handler (Req 12.1, 12.2, 12.3) ──

## Called when ScreenNavigator completes a screen transition.
func _on_screen_changed(screen_name: String) -> void:
	if current_state != State.ACTIVE:
		return

	# Wait one frame for the new screen's nodes to be fully laid out
	await get_tree().process_frame

	var step := get_current_step()
	if step.is_empty():
		return

	# Only show step if it targets this screen
	if step.get("screen", "") == screen_name:
		_process_grants(step)
		_connect_action_signal(step)

		if step.get("hide_overlay", false):
			if _overlay != null:
				_overlay.visible = false
			return

		if _overlay != null:
			_overlay.visible = true
			if _overlay.highlight_frame != null:
				_overlay.highlight_frame.visible = true
			if _overlay.text_bubble != null:
				_overlay.text_bubble.visible = true
			_overlay.show_step(step)

		if step.get("id") == "garden_plant_beans":
			if not Garden.garden_updated.is_connected(_on_garden_planting_updated):
				Garden.garden_updated.connect(_on_garden_planting_updated)

		if step.get("pause_after", false):
			_start_pause_timer()


## ── Task 8.3: Generic action signal wiring (Req 3.2, 7.4, 8.4, 9.3, 10.4, 11.3) ──

## Connect to the action signal defined in the current step.
func _connect_action_signal(step: Dictionary) -> void:
	if not step.get("action_required", false):
		return

	var signal_name: String = step.get("action_signal", "")
	var source_path: String = step.get("action_source", "")

	if signal_name == "" or source_path == "":
		return

	var source_node: Node = _resolve_action_source(source_path)
	if source_node == null:
		push_warning("TutorialSystem: Could not find action source '%s' for step '%s'." % [source_path, step.get("id", "")])
		return

	if not source_node.has_signal(signal_name):
		push_warning("TutorialSystem: Source '%s' does not have signal '%s'." % [source_path, signal_name])
		return

	# Avoid double-connection
	if _connected_action_source == source_node and _connected_action_signal == signal_name:
		return

	# Disconnect any previous signal first
	_disconnect_action_signal()

	# Use unbind to ignore any arguments the signal may pass.
	# We need to discover the arg count from the signal's metadata.
	var arg_count: int = 0
	for sig_info in source_node.get_signal_list():
		if sig_info["name"] == signal_name:
			arg_count = sig_info["args"].size()
			break

	var callable := _on_action_signal_received.unbind(arg_count)
	source_node.connect(signal_name, callable)
	_connected_action_source = source_node
	_connected_action_signal = signal_name
	_connected_callable = callable


## Disconnect the previously connected action signal.
func _disconnect_action_signal() -> void:
	if _connected_action_source != null and _connected_action_signal != "":
		if is_instance_valid(_connected_action_source):
			if _connected_callable.is_valid() and _connected_action_source.is_connected(_connected_action_signal, _connected_callable):
				_connected_action_source.disconnect(_connected_action_signal, _connected_callable)
	_connected_action_source = null
	_connected_action_signal = ""
	_connected_callable = Callable()


## Resolve the action source node. It could be:
## - A node path relative to the current screen (e.g. "BgPanel/Content/TabTiles")
## - An autoload name (e.g. "GameManager", "Garden", "MiningGame")
## - A screen-level reference (e.g. "MarketplaceScreen" meaning the screen itself)
func _resolve_action_source(source_path: String) -> Node:
	# Try as an autoload first (single segment paths that aren't relative)
	if "/" not in source_path:
		# Check if it's an autoload at /root/SOURCE_PATH
		var autoload_node := get_tree().root.get_node_or_null(source_path)
		if autoload_node != null:
			return autoload_node

	# Try relative to the current screen
	var screen_container := get_tree().root.get_node_or_null("Main/ScreenContainer")
	if screen_container != null and screen_container.get_child_count() > 0:
		var current_screen: Node = screen_container.get_child(0)
		if current_screen != null:
			# If source_path matches the screen's node name, return the screen itself
			if source_path == current_screen.name:
				return current_screen

			# If it ends with "Screen", try matching loosely
			if source_path.ends_with("Screen"):
				var expected_name := source_path.replace("Screen", "").to_lower()
				if current_screen.name.to_lower().contains(expected_name):
					return current_screen

			# Try as relative path from screen (handles multi-segment paths)
			var node := current_screen.get_node_or_null(NodePath(source_path))
			if node != null:
				return node

			# Try finding by node name anywhere in the screen subtree
			# (handles cases like "GardenUI" when it's nested deeper)
			if "/" not in source_path:
				var found := _find_node_by_name(current_screen, source_path)
				if found != null:
					return found

	# Final fallback: try absolute from root
	var abs_node := get_tree().root.get_node_or_null(NodePath(source_path))
	return abs_node


## Recursively find a node by name within a subtree. Returns null if not found.
func _find_node_by_name(root: Node, target_name: String) -> Node:
	if root.name == target_name:
		return root
	for child in root.get_children():
		var result := _find_node_by_name(child, target_name)
		if result != null:
			return result
	return null


## Called when any action signal fires. Marks the action as completed and advances.
func _on_action_signal_received() -> void:
	mark_action_completed()
	advance_step()


## Called when garden updates during planting step
func _on_garden_planting_updated() -> void:
	var step := get_current_step()
	if step.get("id") == "garden_plant_beans":
		if Garden.get_seed_count(0) == 0:
			if Garden.garden_updated.is_connected(_on_garden_planting_updated):
				Garden.garden_updated.disconnect(_on_garden_planting_updated)
			advance_step()


## Pause timer before auto-advancing
func _start_pause_timer() -> void:
	var step_idx := current_step_index
	await get_tree().create_timer(2.5).timeout
	if current_state == State.ACTIVE and current_step_index == step_idx:
		advance_step()


## ── Task 8.4: Resource grants (Req 7.5, 11.5) ──

## Process grants for a step before showing it.
func _process_grants(step: Dictionary) -> void:
	var step_id: String = step.get("id", "")
	if step_id != "" and _granted_steps.get(step_id, false):
		return

	var grants: Dictionary = step.get("grants", {})
	var grant_condition: String = step.get("grant_condition", "")

	if grants.is_empty():
		return

	if _evaluate_grant_condition(grant_condition):
		_apply_grants(grants)
		if step_id != "":
			_granted_steps[step_id] = true


## Evaluate a grant condition string. Returns true if the condition is met.
func _evaluate_grant_condition(condition: String) -> bool:
	if condition == "always" or condition == "":
		return true
	elif condition.begins_with("coins_below:"):
		var threshold_str := condition.substr("coins_below:".length())
		var threshold := int(threshold_str)
		return PlayerData.coins < threshold
	elif condition == "seeds_empty":
		return Garden.get_total_seeds() == 0
	return false


## Apply grants to the player.
func _apply_grants(grants: Dictionary) -> void:
	# Grant coins
	if grants.has("coins"):
		var coin_amount: int = int(grants["coins"])
		PlayerData.coins += coin_amount
		PlayerData.save_data()

	# Grant seeds
	if grants.has("seeds"):
		var seed_info: Dictionary = grants["seeds"]
		var seed_type: int = int(seed_info.get("type", 0))
		var seed_qty: int = int(seed_info.get("qty", 0))
		if seed_qty > 0:
			Garden.add_seeds(seed_type, seed_qty)
			# Find active garden screen / GardenUI and force immediate repopulation
			var screen_container := get_tree().root.get_node_or_null("Main/ScreenContainer")
			if screen_container != null and screen_container.get_child_count() > 0:
				var current_screen = screen_container.get_child(0)
				if current_screen != null:
					var garden_ui = current_screen.get_node_or_null("GardenVBox/GardenUI")
					if garden_ui == null:
						garden_ui = current_screen.get_node_or_null("GardenUI")
					if garden_ui != null:
						if garden_ui.has_method("_rebuild_all"):
							garden_ui._rebuild_all()
						if garden_ui.has_method("_on_seed_selected") and garden_ui.get("_selected_seed") == -1:
							garden_ui._on_seed_selected(seed_type)


## ── Overlay Signal Handlers ────────────────────────────────────

func _on_overlay_continue() -> void:
	advance_step()


func _on_overlay_skip_requested() -> void:
	if _overlay != null:
		_overlay.show_confirm_dialog()


func _on_overlay_skip_confirmed() -> void:
	skip_tutorial()


func _on_overlay_skip_cancelled() -> void:
	if _overlay != null:
		_overlay.hide_confirm_dialog()
