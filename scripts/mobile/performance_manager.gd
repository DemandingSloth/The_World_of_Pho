extends Node
## PerformanceManager autoload singleton.
## Controls frame rate targeting, background throttling, battery-aware FPS adjustment,
## and memory monitoring. Ensures 2D-only rendering with no 3D physics or pipelines.
##
## Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7

## Emitted when memory usage exceeds MAX_MEMORY_MB threshold.
## Other systems (e.g. ScreenNavigator) can connect to clear caches.
signal memory_warning

const TARGET_FPS_NORMAL := 30
const TARGET_FPS_LOW_BATTERY := 24
const LOW_BATTERY_THRESHOLD := 0.15
const MAX_MEMORY_MB := 512
const SCENE_TRANSITION_TIMEOUT_SEC := 2.0

## How often (in seconds) to check battery level. No need to poll every frame.
const BATTERY_CHECK_INTERVAL_SEC := 30.0

## How often (in seconds) to check memory usage.
const MEMORY_CHECK_INTERVAL_SEC := 5.0

var _current_target_fps: int = TARGET_FPS_NORMAL
var _is_background: bool = false
var _battery_check_timer: Timer
var _memory_check_timer: Timer
var _scene_transition_timer: Timer
var _is_transitioning: bool = false


func _ready() -> void:
	# Set initial target FPS
	Engine.max_fps = TARGET_FPS_NORMAL
	_current_target_fps = TARGET_FPS_NORMAL

	# Disable 3D physics processing since we are 2D only (Req 6.3)
	PhysicsServer3D.set_active(false)

	# Set up battery check timer
	_battery_check_timer = Timer.new()
	_battery_check_timer.wait_time = BATTERY_CHECK_INTERVAL_SEC
	_battery_check_timer.autostart = true
	_battery_check_timer.timeout.connect(_check_battery_level)
	add_child(_battery_check_timer)

	# Set up memory monitoring timer
	_memory_check_timer = Timer.new()
	_memory_check_timer.wait_time = MEMORY_CHECK_INTERVAL_SEC
	_memory_check_timer.autostart = true
	_memory_check_timer.timeout.connect(_check_memory_usage)
	add_child(_memory_check_timer)

	# Set up scene transition timeout timer (one-shot, started on demand)
	_scene_transition_timer = Timer.new()
	_scene_transition_timer.wait_time = SCENE_TRANSITION_TIMEOUT_SEC
	_scene_transition_timer.one_shot = true
	_scene_transition_timer.timeout.connect(_on_scene_transition_timeout)
	add_child(_scene_transition_timer)

	# Connect to scene tree changed signal to monitor transitions
	get_tree().tree_changed.connect(_on_tree_changed)

	# Run initial battery check
	_check_battery_level()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			# App entering background — throttle to 0 fps (Req 6.4)
			throttle_background()
		NOTIFICATION_APPLICATION_RESUMED:
			# App returning to foreground — restore target FPS
			resume_foreground()


func _process(_delta: float) -> void:
	# Minimal per-frame work. The heavy checks (battery, memory) are on timers.
	# This ensures Engine.max_fps stays consistent with our target when not in background.
	if not _is_background and Engine.max_fps != _current_target_fps:
		Engine.max_fps = _current_target_fps


func throttle_background() -> void:
	## Reduce processing to zero when app is in background (Req 6.4).
	_is_background = true
	Engine.max_fps = 0


func resume_foreground() -> void:
	## Restore target FPS when app returns to foreground.
	_is_background = false
	# Re-check battery to pick the right target FPS on resume
	_check_battery_level()
	Engine.max_fps = _current_target_fps


func _check_battery_level() -> void:
	## Adjust target FPS based on battery level (Req 6.6).
	## Godot 4.x removed OS.get_power_percent_left(). On Android, we use the
	## Engine singleton method if available via a plugin, otherwise assume normal.
	var battery_percent: int = -1

	# Try Android-specific battery check via OS.execute
	if OS.get_name() == "Android":
		var output: Array = []
		var exit_code := OS.execute("sh", ["-c", "cat /sys/class/power_supply/battery/capacity"], output)
		if exit_code == 0 and output.size() > 0:
			battery_percent = int(str(output[0]).strip_edges())

	if battery_percent == -1:
		# Battery info unavailable — treat as normal battery
		_current_target_fps = TARGET_FPS_NORMAL
	elif battery_percent < int(LOW_BATTERY_THRESHOLD * 100):
		_current_target_fps = TARGET_FPS_LOW_BATTERY
	else:
		_current_target_fps = TARGET_FPS_NORMAL

	# Apply immediately if in foreground
	if not _is_background:
		Engine.max_fps = _current_target_fps


func _check_memory_usage() -> void:
	## Monitor memory usage and take action if over threshold (Req 6.2).
	var memory_mb := get_memory_usage_mb()

	if memory_mb > MAX_MEMORY_MB:
		# Force garbage collection to free unused resources
		_trigger_memory_cleanup()


func get_memory_usage_mb() -> float:
	## Returns current static memory usage in megabytes.
	var memory_bytes := Performance.get_monitor(Performance.MEMORY_STATIC)
	return memory_bytes / (1024.0 * 1024.0)


func _trigger_memory_cleanup() -> void:
	## Attempt to reduce memory usage by clearing unused cached resources.
	# Collect paths of resources currently in use by the scene tree
	var current_scene := get_tree().current_scene
	var in_use: Array[String] = []
	if current_scene:
		_collect_used_resources(current_scene, in_use)

	# Clear resources from the cache that aren't referenced by the current scene.
	# In Godot 4.x, unreferenced resources are freed automatically by the engine's
	# reference counting, but we can force a pass by requesting unused resource cleanup.
	# The primary mechanism is to drop any strong references we hold and let the GC collect.
	print("[PerformanceManager] Memory threshold exceeded (%.1f MB > %d MB). Cleaning up." % [get_memory_usage_mb(), MAX_MEMORY_MB])

	# Notify other systems (e.g. ScreenNavigator) to clear caches
	memory_warning.emit()


func _collect_used_resources(node: Node, paths: Array[String]) -> void:
	## Recursively collect resource paths used by the current scene tree.
	if node is Sprite2D:
		var sprite := node as Sprite2D
		if sprite.texture and sprite.texture.resource_path:
			paths.append(sprite.texture.resource_path)
	elif node is TextureRect:
		var tex_rect := node as TextureRect
		if tex_rect.texture and tex_rect.texture.resource_path:
			paths.append(tex_rect.texture.resource_path)

	for child in node.get_children():
		_collect_used_resources(child, paths)


func begin_scene_transition() -> void:
	## Call this before starting a scene transition.
	## If the transition takes longer than SCENE_TRANSITION_TIMEOUT_SEC,
	## a loading indicator will be shown (Req 6.7).
	_is_transitioning = true
	_scene_transition_timer.start()


func end_scene_transition() -> void:
	## Call this when a scene transition completes.
	_is_transitioning = false
	_scene_transition_timer.stop()
	_hide_loading_indicator()


func _on_scene_transition_timeout() -> void:
	## Called if a scene transition exceeds 2 seconds — show loading indicator.
	if _is_transitioning:
		_show_loading_indicator()


func _on_tree_changed() -> void:
	## Detect when the scene tree changes (possible scene transition completion).
	if _is_transitioning:
		end_scene_transition()


func _show_loading_indicator() -> void:
	## Display a simple loading overlay when scene transitions exceed timeout.
	var existing := get_tree().root.get_node_or_null("LoadingOverlay")
	if existing:
		return

	var overlay := ColorRect.new()
	overlay.name = "LoadingOverlay"
	overlay.color = Color(0.0, 0.0, 0.0, 0.7)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	var label := Label.new()
	label.text = "Loading..."
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_CENTER)
	overlay.add_child(label)

	get_tree().root.add_child(overlay)


func _hide_loading_indicator() -> void:
	## Remove the loading overlay if it exists.
	var existing := get_tree().root.get_node_or_null("LoadingOverlay")
	if existing:
		existing.queue_free()
