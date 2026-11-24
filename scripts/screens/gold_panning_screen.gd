extends BaseScreen
## Gold Panning screen — gesture-driven minigame where players shake a gold pan
## to collect silt, sand, gold, and gems. Once filled, haul transfers to a sifter
## for further shaking to reveal collectibles.
##
## Requirements: 11.1, 11.2, 11.4, 11.5


enum Phase { PANNING, DUMP_ANIMATION, SIFTING, COLLECTING }

const MAX_FILL_LEVEL := 5
const SHAKE_DELTA := 20.0
const PAN_COST := 100  # coins charged per panning round

# ── Scene node references ─────────────────────────────────────────
@onready var back_btn: Button = $ContentVBox/BackBtn
@onready var river_background: TextureRect = $ContentVBox/RiverBackground
@onready var pan_sprite: TextureRect = $ContentVBox/PanSprite
@onready var sifter_container: Control = $ContentVBox/SifterContainer
@onready var collectibles_container: Control = $ContentVBox/SifterContainer/CollectiblesContainer

# ── State variables ───────────────────────────────────────────────
var _current_phase: Phase = Phase.PANNING
var _fill_level: int = 0
var _separation_progress: float = 0.0
var _max_separation: float = 500.0
var _haul: Dictionary = {}
var _shake_detector: ShakeDetector = null
var _panning_stats: PanningStats = null
var _collectible_nodes: Array = []
var _active_tween: Tween = null

# ── Pan dragging state ───────────────────────────────────────────
var _is_dragging_pan: bool = false
var _pan_drag_offset: Vector2 = Vector2.ZERO
var _pan_original_pos: Vector2 = Vector2.ZERO
var _last_drag_x: float = 0.0
var _drag_direction: int = 0  # -1 = left, 0 = none, 1 = right
var _direction_changes: int = 0
const DIRECTION_CHANGE_THRESHOLD := 20.0  # pixels before registering a direction

# ── Pan textures ─────────────────────────────────────────────────
var _pan_empty_tex: Texture2D = null
var _pan_half_tex: Texture2D = null
var _pan_full_tex: Texture2D = null

# ── River animation ──────────────────────────────────────────────
var _river_textures: Array[Texture2D] = []
var _river_frame: int = 0
var _river_timer: Timer = null


func get_screen_name() -> String:
	return "gold_panning"


func show_top_bar() -> bool:
	return true


func enter(params: Dictionary = {}) -> void:
	# Reset all state to defaults (Req 11.4, 11.5)
	_current_phase = Phase.PANNING
	_fill_level = 0
	_separation_progress = 0.0
	_haul = {}
	_collectible_nodes = []
	_is_dragging_pan = false
	_drag_direction = 0
	_direction_changes = 0

	# Instantiate helper objects
	_shake_detector = ShakeDetector.new()
	_panning_stats = PanningStats.new()
	var config := ConfigFile.new()
	if config.load(PlayerData.SAVE_PATH) == OK:
		_panning_stats.load_from_config(config)

	# Connect UI signals
	back_btn.pressed.connect(_on_back_pressed)

	# Load pan textures
	_pan_empty_tex = load("res://Assets/GoldPanning/Panning Pan/pan_empty.png") as Texture2D
	_pan_half_tex = load("res://Assets/GoldPanning/Panning Pan/pan_half.png") as Texture2D
	_pan_full_tex = load("res://Assets/GoldPanning/Panning Pan/pan_full.png") as Texture2D

	# Show panning phase UI
	pan_sprite.visible = true
	sifter_container.visible = false
	_update_pan_sprite()

	# ── River animation setup (Req 2.1) ──────────────────────────
	_river_textures = [
		load("res://Assets/GoldPanning/water_1.png") as Texture2D,
		load("res://Assets/GoldPanning/water_2.png") as Texture2D,
	]
	_river_frame = 0
	river_background.texture = _river_textures[_river_frame]

	_river_timer = Timer.new()
	_river_timer.wait_time = 0.5
	_river_timer.one_shot = false
	_river_timer.timeout.connect(_on_river_timer_timeout)
	add_child(_river_timer)
	_river_timer.start()

	# Enable input processing for this screen
	set_process_input(true)
	set_process(true)


func exit() -> void:
	# Stop processing input immediately
	set_process_input(false)
	set_process(false)

	# Disconnect signals safely
	if back_btn.pressed.is_connected(_on_back_pressed):
		back_btn.pressed.disconnect(_on_back_pressed)

	# ── Stop and free river timer ────────────────────────────────
	if _river_timer != null:
		_river_timer.stop()
		if _river_timer.timeout.is_connected(_on_river_timer_timeout):
			_river_timer.timeout.disconnect(_on_river_timer_timeout)
		_river_timer.queue_free()
		_river_timer = null

	# Kill active tween if running
	if _active_tween != null:
		_active_tween.kill()
		_active_tween = null

	# Queue free dynamic child nodes in collectibles container
	for child in collectibles_container.get_children():
		collectibles_container.remove_child(child)
		child.queue_free()

	# Null references
	_shake_detector = null
	_panning_stats = null
	_collectible_nodes = []
	_haul = {}
	_river_textures = []


# ── Private: Input handling ────────────────────────────────────────


## Gravity constant for particles (pixels per second squared)
const PARTICLE_GRAVITY := 400.0


## Apply gravity during sifting — particles fall but stop when their center point
## hits another particle below them, creating a natural stacked pile.
func _process(delta: float) -> void:
	if _current_phase != Phase.SIFTING:
		return

	var container_size := collectibles_container.size
	if container_size == Vector2.ZERO:
		container_size = sifter_container.size
	if container_size == Vector2.ZERO:
		return

	var inset_y: float = container_size.y * 0.15
	var inner_h: float = container_size.y - inset_y * 2.0
	var floor_y: float = inset_y + inner_h - 20.0

	# Gather all visible particles for collision checks
	var all_particles: Array = []
	for child in collectibles_container.get_children():
		if not child.visible:
			continue
		if child.modulate.a < 0.5:
			continue
		if child.z_index == 1 or child.z_index == 2 or child in _collectible_nodes:
			all_particles.append(child)

	for child in all_particles:
		var bottom_edge: float = child.position.y + child.size.y
		if bottom_edge >= floor_y:
			continue  # Already on floor

		# Check if there's any particle directly below this one supporting it
		var center_x: float = child.position.x + child.size.x * 0.5
		var check_y: float = child.position.y + child.size.y  # Bottom of this particle

		var blocked := false
		for other in all_particles:
			if other == child:
				continue
			if other.modulate.a < 0.5:
				continue
			# Only check particles whose TOP is below our BOTTOM (they're underneath us)
			var other_top: float = other.position.y
			if other_top < check_y - 2.0:
				continue  # This particle is above us, skip

			# Check horizontal overlap — our center must be within the other's width
			var other_left: float = other.position.x
			var other_right: float = other.position.x + other.size.x
			if center_x < other_left or center_x > other_right:
				continue  # No horizontal overlap

			# The other particle is below us and overlaps horizontally — we're supported
			# Use a tight 1px tolerance so particles only block when actually touching
			if other_top <= check_y + 1.0:
				blocked = true
				break

		if not blocked:
			var gravity: float = PARTICLE_GRAVITY if child not in _collectible_nodes else PARTICLE_GRAVITY * 0.4
			child.position.y = minf(child.position.y + gravity * delta, floor_y - child.size.y)


func _input(event: InputEvent) -> void:
	# Only process input when this screen is actually visible and in the tree
	if not is_visible_in_tree():
		return
	if _current_phase == Phase.PANNING:
		_handle_panning_input(event)
	elif _current_phase == Phase.SIFTING:
		_handle_sifting_input(event)
	elif _current_phase == Phase.COLLECTING:
		_handle_collecting_input(event)


## Panning phase: grab pan, drag over river, shake left-right to fill.
func _handle_panning_input(event: InputEvent) -> void:
	var press := false
	var release := false
	var motion := false
	var pos := Vector2.ZERO

	# Unify mouse and touch events
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position
		if event.pressed:
			press = true
		else:
			release = true
	elif event is InputEventMouseMotion and _is_dragging_pan:
		pos = event.position
		motion = true
	elif event is InputEventScreenTouch:
		pos = event.position
		if event.pressed:
			press = true
		else:
			release = true
	elif event is InputEventScreenDrag and _is_dragging_pan:
		pos = event.position
		motion = true

	if press:
		# Check if player can afford a pan before allowing grab
		if PlayerData.coins < PAN_COST:
			return
		# Check if touch/click is on the pan
		var pan_rect := pan_sprite.get_global_rect()
		if pan_rect.has_point(pos):
			_is_dragging_pan = true
			_pan_drag_offset = pos - pan_sprite.global_position
			_pan_original_pos = pan_sprite.global_position
			_last_drag_x = pos.x
			_drag_direction = 0
			_direction_changes = 0

	elif motion and _is_dragging_pan:
		# Move the pan to follow the finger/mouse
		pan_sprite.global_position = pos - _pan_drag_offset

		# Only detect shakes while pan overlaps the river
		var pan_rect := pan_sprite.get_global_rect()
		var river_rect := river_background.get_global_rect()
		if pan_rect.intersects(river_rect):
			# Track horizontal direction changes as "shakes"
			var delta_x: float = pos.x - _last_drag_x
			if absf(delta_x) > DIRECTION_CHANGE_THRESHOLD:
				var new_direction: int = 1 if delta_x > 0 else -1
				if _drag_direction != 0 and new_direction != _drag_direction:
					# Direction changed — that's one shake motion
					_direction_changes += 1
					if _direction_changes >= 2:
						# Two direction changes = one full shake (left-right or right-left)
						_direction_changes = 0
						if _fill_level < MAX_FILL_LEVEL:
							_fill_level += 1
							_update_pan_sprite()
							if _fill_level >= MAX_FILL_LEVEL:
								_is_dragging_pan = false
								_snap_pan_back()
								_on_fill_complete()
								return
				_drag_direction = new_direction
				_last_drag_x = pos.x

	elif release and _is_dragging_pan:
		_is_dragging_pan = false
		_snap_pan_back()


## Sifting phase: drag finger across barrel to push silt/sand away and reveal gems, tap revealed gems to collect.
func _handle_sifting_input(event: InputEvent) -> void:
	var press := false
	var release := false
	var motion := false
	var pos := Vector2.ZERO

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position
		if event.pressed:
			press = true
		else:
			release = true
	elif event is InputEventMouseMotion:
		pos = event.position
		motion = true
	elif event is InputEventScreenTouch:
		pos = event.position
		if event.pressed:
			press = true
		else:
			release = true
	elif event is InputEventScreenDrag:
		pos = event.position
		motion = true

	if press:
		# First check if tapping a revealed gem
		for node in _collectible_nodes:
			if node == null or not is_instance_valid(node) or not node.visible:
				continue
			var gem_idx: int = node.get_meta("gem_index", -1)
			if gem_idx < 0:
				continue
			var collectibles: Array = _haul.get("collectibles", [])
			if gem_idx >= collectibles.size():
				continue
			var gem_data: Dictionary = collectibles[gem_idx]
			if gem_data.get("collected", false):
				continue
			if not gem_data.get("revealed", false):
				continue
			var node_rect: Rect2 = (node as Control).get_global_rect()
			if node_rect.has_point(pos):
				_collect_gem(gem_idx)
				return

		# Start dragging to push particles
		var sifter_rect := sifter_container.get_global_rect()
		if sifter_rect.has_point(pos):
			_is_dragging_pan = true
			_last_drag_x = pos.x
			_drag_direction = 0
			_direction_changes = 0

	elif motion and _is_dragging_pan:
		# Push particles away from the touch point as the finger moves
		_push_particles_from_touch(pos)

		# Also track shaking for separation progress
		var delta_x: float = pos.x - _last_drag_x
		if absf(delta_x) > DIRECTION_CHANGE_THRESHOLD:
			var new_direction: int = 1 if delta_x > 0 else -1
			if _drag_direction != 0 and new_direction != _drag_direction:
				_direction_changes += 1
				if _direction_changes >= 2:
					_direction_changes = 0
					_on_sifter_shake()
			_drag_direction = new_direction
			_last_drag_x = pos.x

	elif release:
		_is_dragging_pan = false


## Push silt and sand particles away from the player's touch position.
## Particles within a radius of the touch are nudged in the direction away from the finger.
## Particles settle on the barrel floor (bottom) and can only exit via the left/right edges.
func _push_particles_from_touch(touch_global_pos: Vector2) -> void:
	var push_radius := 50.0  # How close a particle must be to get pushed
	var push_strength := 14.0  # How far particles move per frame

	# Convert touch position to local collectibles_container space
	var local_pos: Vector2 = collectibles_container.get_global_transform().affine_inverse() * touch_global_pos

	# Get container bounds for clamping
	var container_size := collectibles_container.size
	if container_size == Vector2.ZERO:
		container_size = sifter_container.size

	const SIFT_IMG_ASPECT: float = 128.0 / 155.0
	var img_w: float = container_size.y * SIFT_IMG_ASPECT
	img_w = minf(img_w, container_size.x)
	var h_pad: float = (container_size.x - img_w) * 0.5
	var inset_left: float = h_pad + img_w * 0.10
	var inset_right: float = h_pad + img_w * 0.10
	var inset_y: float = container_size.y * 0.15
	var inner_w: float = container_size.x - inset_left - inset_right
	var inner_h: float = container_size.y - inset_y * 2.0
	var floor_y: float = inset_y + inner_h - 20.0  # Bottom of barrel (floor)

	for child in collectibles_container.get_children():
		# Only push silt (z_index 2) and sand (z_index 1) particles
		if child in _collectible_nodes:
			continue
		if child.z_index != 1 and child.z_index != 2:
			continue
		# Skip particles already fading out
		if child.modulate.a < 0.5:
			continue

		var particle_center: Vector2 = child.position + child.size * 0.5
		var diff: Vector2 = particle_center - local_pos
		var dist: float = diff.length()

		if dist < push_radius and dist > 0.01:
			# Push away from touch — stronger when closer
			var push_dir: Vector2 = diff.normalized()
			var strength: float = push_strength * (1.0 - dist / push_radius)
			var new_pos: Vector2 = child.position + push_dir * strength

			# Clamp: floor at bottom, ceiling at top, walls at sides
			# Dampen vertical push near the floor so particles don't get lifted and hover
			var floor_dist: float = floor_y - (child.position.y + child.size.y)
			if floor_dist < 20.0 and push_dir.y < 0.0:
				push_dir.y *= floor_dist / 20.0  # Reduce upward push as particle nears floor
			new_pos.x = clampf(new_pos.x, inset_left, inset_left + inner_w - child.size.x)
			new_pos.y = clampf(new_pos.y, inset_y, floor_y - child.size.y)
			child.position = new_pos

			# Particles can only be swiped out at left or right edges (not the floor)
			var at_left_edge: bool = new_pos.x <= inset_left + 2.0
			var at_right_edge: bool = new_pos.x >= inset_left + inner_w - child.size.x - 2.0
			if at_left_edge or at_right_edge:
				_remove_particle_at_edge(child)


## Fades out and removes a particle that has been pushed to the barrel edge.
## Also advances separation progress and checks for gem reveals.
func _remove_particle_at_edge(particle: Control) -> void:
	# Avoid double-processing (particle might already be tweening out)
	if particle.modulate.a < 0.5:
		return

	# Count it toward separation progress
	_separation_progress += 2.0
	_separation_progress = minf(_separation_progress, _max_separation)

	# Fade out and free, then check reveals once particle is fully gone
	var tween := create_tween()
	tween.tween_property(particle, "modulate:a", 0.0, 0.25)\
		.set_trans(Tween.TRANS_LINEAR)
	tween.tween_callback(particle.queue_free)
	tween.tween_callback(_check_reveal_collectibles)


## Collecting phase: tap/click revealed gems to collect them.
func _handle_collecting_input(event: InputEvent) -> void:
	var touch_pos := Vector2.ZERO
	var is_tap := false
	if event is InputEventScreenTouch and event.pressed:
		touch_pos = event.position
		is_tap = true
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		touch_pos = event.position
		is_tap = true

	if not is_tap:
		return

	for node in _collectible_nodes:
		if node == null or not is_instance_valid(node) or not node.visible:
			continue
		var gem_idx: int = node.get_meta("gem_index", -1)
		if gem_idx < 0:
			continue
		var collectibles: Array = _haul.get("collectibles", [])
		if gem_idx >= collectibles.size():
			continue
		var gem_data: Dictionary = collectibles[gem_idx]
		if gem_data.get("collected", false):
			continue
		if not gem_data.get("revealed", false):
			continue
		var node_rect: Rect2 = (node as Control).get_global_rect()
		if node_rect.has_point(touch_pos):
			_collect_gem(gem_idx)
			break


## Animates the pan back to its original layout position.
func _snap_pan_back() -> void:
	var tween := create_tween()
	tween.tween_property(pan_sprite, "global_position", _pan_original_pos, 0.2)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _update_pan_sprite() -> void:
	if _fill_level == 0:
		pan_sprite.texture = _pan_empty_tex
	elif _fill_level <= 2:
		pan_sprite.texture = _pan_half_tex
	else:  # 3, 4, or 5
		pan_sprite.texture = _pan_full_tex


func _on_fill_complete() -> void:
	# Wait 0.5s then transition to sifting phase (Req 3.5)
	var timer := Timer.new()
	timer.wait_time = 0.5
	timer.one_shot = true
	timer.timeout.connect(_transition_to_sifting)
	add_child(timer)
	timer.start()


# ── Private: River animation ──────────────────────────────────────


func _on_river_timer_timeout() -> void:
	_river_frame = 1 - _river_frame
	river_background.texture = _river_textures[_river_frame]


# ── Private: Button handlers ──────────────────────────────────────


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


# ── Private: Sifting phase transition (Req 4.1, 5.1, 5.2, 5.3, 5.4) ─


## Generates haul, plays dump animation, then transitions to sifting phase.
func _transition_to_sifting() -> void:
	# Charge the player for this panning round
	if PlayerData.coins < PAN_COST:
		# Not enough coins — reset to panning and show message
		_fill_level = 0
		_update_pan_sprite()
		return
	PlayerData.coins -= PAN_COST
	PlayerData.save_data()
	PlayerData.data_changed.emit()

	# Generate haul contents
	_haul = HaulGenerator.generate_haul()

	# Enter dump animation phase (disables shake detection on sifter)
	_current_phase = Phase.DUMP_ANIMATION

	# Switch UI: hide pan and river, show sifter
	pan_sprite.visible = false
	river_background.visible = false
	sifter_container.visible = true
	sifter_container.modulate = Color(1, 1, 1, 0)

	# Play dump animation (~1.0s) — fade sifter in to represent haul dumping
	_active_tween = create_tween()
	_active_tween.tween_property(sifter_container, "modulate", Color(1, 1, 1, 1), 1.0)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_active_tween.tween_callback(_on_dump_complete)


## Called when the dump animation finishes. Sets up the sifting phase.
func _on_dump_complete() -> void:
	_active_tween = null
	_current_phase = Phase.SIFTING
	_separation_progress = 0.0

	# Reset shake detector for sifting
	if _shake_detector != null:
		_shake_detector.reset()

	# Reset barrel shake state
	_is_dragging_pan = false
	_drag_direction = 0
	_direction_changes = 0

	# Wait one frame for layout to update container sizes, then render
	await get_tree().process_frame

	# Enable clipping so particles don't render outside the barrel bounds
	collectibles_container.clip_contents = true

	_render_sifter_contents()


## Creates visual nodes representing silt, sand, and collectibles
## inside the sifter using actual texture assets. Collectibles start obscured.
func _render_sifter_contents() -> void:
	# Clear any previous contents
	for child in collectibles_container.get_children():
		collectibles_container.remove_child(child)
		child.queue_free()
	_collectible_nodes = []

	var container_size := collectibles_container.size
	if container_size == Vector2.ZERO:
		container_size = sifter_container.size
	var silt_count: int = _haul.get("silt_count", 20)
	var sand_count: int = _haul.get("sand_count", 15)
	# Increase density for smaller particles — multiply base counts
	silt_count = 80
	sand_count = 80
	var collectibles: Array = _haul.get("collectibles", [])

	# Inset area to keep particles inside the barrel.
	# siftcontainer.png is 128x155 and rendered with keep-aspect-centered,
	# so the barrel interior is horizontally centered and narrower than the full container.
	# Compute the scaled image width so insets track the actual barrel bounds.
	const SIFT_IMG_ASPECT: float = 128.0 / 155.0  # native width / height
	var img_w: float = container_size.y * SIFT_IMG_ASPECT  # scaled width to fit height
	img_w = minf(img_w, container_size.x)  # can't exceed container width
	var h_pad: float = (container_size.x - img_w) * 0.5  # letterbox padding each side
	var inset_left: float = h_pad + img_w * 0.10   # 10% inside the barrel image left edge
	var inset_right: float = h_pad + img_w * 0.10  # 10% inside the barrel image right edge
	var inset_y: float = container_size.y * 0.15
	var inner_w: float = container_size.x - inset_left - inset_right
	var inner_h: float = container_size.y - inset_y * 2.0
	var floor_y: float = inset_y + inner_h - 20.0  # Bottom edge of barrel interior

	# Load particle textures
	var silt_tex: Texture2D = load("res://Assets/GoldPanning/silt.png") as Texture2D
	var sand_tex: Texture2D = load("res://Assets/GoldPanning/sand.png") as Texture2D

	# ── Collectibles at lowest z-order (covered by silt/sand above) ──
	for i in range(collectibles.size()):
		var gem_data: Dictionary = collectibles[i]
		var gem_type: String = gem_data.get("gem_type", "gold")
		var gem_tex: Texture2D = load("res://Assets/GoldPanning/Gemstones/%s.png" % gem_type) as Texture2D

		var gem_node := TextureRect.new()
		gem_node.texture = gem_tex
		gem_node.custom_minimum_size = Vector2(48, 48)
		gem_node.size = Vector2(48, 48)
		gem_node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		gem_node.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		# Randomize collectible positions — start in the middle, will sink with gravity
		var x_pos: float = randf_range(inset_left + 10, inset_left + inner_w - 58.0)
		var y_pos: float = randf_range(floor_y - inner_h * 0.6, floor_y - inner_h * 0.35)
		gem_node.position = Vector2(x_pos, y_pos)
		gem_node.z_index = 0
		gem_node.visible = false  # Hidden until revealed by clearing sand above
		gem_node.set_meta("gem_index", i)
		collectibles_container.add_child(gem_node)
		_collectible_nodes.append(gem_node)

	# ── Pre-stacked sand and silt filling the barrel ─────────────────
	# Scatter particles randomly throughout the barrel like puzzle pieces dumped
	# from a box — overlapping naturally, no column stacking at spawn time.
	var total_sand: int = sand_count
	var total_silt: int = silt_count

	# Place sand scattered randomly across the full barrel area
	for j in range(total_sand):
		var sand_node := TextureRect.new()
		sand_node.texture = sand_tex
		var sand_size := Vector2(randi_range(8, 14), randi_range(6, 10))
		sand_node.custom_minimum_size = sand_size
		sand_node.size = sand_size
		sand_node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		sand_node.stretch_mode = TextureRect.STRETCH_SCALE
		sand_node.z_index = 1
		sand_node.position = Vector2(
			randf_range(inset_left, inset_left + inner_w - sand_size.x),
			randf_range(inset_y, floor_y - sand_size.y)
		)
		collectibles_container.add_child(sand_node)

	# Place silt scattered randomly on top (higher z so they cover sand)
	for k in range(total_silt):
		var silt_node := TextureRect.new()
		silt_node.texture = silt_tex
		var silt_size := Vector2(randi_range(8, 14), randi_range(6, 10))
		silt_node.custom_minimum_size = silt_size
		silt_node.size = silt_size
		silt_node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		silt_node.stretch_mode = TextureRect.STRETCH_SCALE
		silt_node.z_index = 2
		silt_node.position = Vector2(
			randf_range(inset_left, inset_left + inner_w - silt_size.x),
			randf_range(inset_y, floor_y - silt_size.y)
		)
		collectibles_container.add_child(silt_node)


## Called when a shake gesture is detected during the SIFTING phase.
## Increments separation progress, animates particles, and reveals collectibles.
func _on_sifter_shake() -> void:
	# Req 6.5 — ignore further shakes once max separation is reached
	if _separation_progress >= _max_separation:
		return

	# Increment separation progress by fixed delta, clamped to max (Req 6.1)
	_separation_progress += SHAKE_DELTA
	_separation_progress = minf(_separation_progress, _max_separation)

	# If max separation reached, force-clear all remaining particles immediately
	if _separation_progress >= _max_separation:
		_clear_remaining_particles()

	# Animate silt/sand falling through mesh (Req 6.2)
	_animate_particles_falling()

	# Check if any collectibles should be revealed (Req 6.3, 6.4)
	# _check_reveal_collectibles also transitions to COLLECTING phase when all gems are revealed.
	_check_reveal_collectibles()


## Animates silt and sand particles falling through the mesh.
## Removes a portion of particles proportional to separation progress.
func _animate_particles_falling() -> void:
	var progress_ratio: float = _separation_progress / _max_separation

	# Gather silt (z_index == 2) and sand (z_index == 1) particles
	var silt_particles: Array = []
	var sand_particles: Array = []
	for child in collectibles_container.get_children():
		if child.z_index == 2 and child not in _collectible_nodes:
			silt_particles.append(child)
		elif child.z_index == 1 and child not in _collectible_nodes:
			sand_particles.append(child)

	# Determine how many particles to remove this shake.
	# Silt falls first (removed when progress < 60%), then sand (removed after 40%).
	var silt_to_remove: int = 0
	var sand_to_remove: int = 0

	if progress_ratio <= 0.6:
		silt_to_remove = mini(ceili(silt_particles.size() * 0.35), silt_particles.size())
	else:
		silt_to_remove = silt_particles.size()

	if progress_ratio > 0.4:
		sand_to_remove = mini(ceili(sand_particles.size() * 0.35), sand_particles.size())

	# Animate and remove silt particles
	for i in range(silt_to_remove):
		var particle: Control = silt_particles[i]
		var tween := create_tween()
		tween.set_parallel(true)
		tween.tween_property(particle, "position:y", particle.position.y + 60.0, 0.4)\
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.tween_property(particle, "modulate:a", 0.0, 0.4)\
			.set_trans(Tween.TRANS_LINEAR)
		tween.chain().tween_callback(particle.queue_free)
		tween.chain().tween_callback(_check_reveal_collectibles)

	# Animate and remove sand particles
	for j in range(sand_to_remove):
		var particle: Control = sand_particles[j]
		var tween := create_tween()
		tween.set_parallel(true)
		tween.tween_property(particle, "position:y", particle.position.y + 50.0, 0.35)\
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.tween_property(particle, "modulate:a", 0.0, 0.35)\
			.set_trans(Tween.TRANS_LINEAR)
		tween.chain().tween_callback(particle.queue_free)
		tween.chain().tween_callback(_check_reveal_collectibles)


## Checks each collectible's threshold against current separation progress.
## Reveals any collectible whose threshold has been reached by raising its z-index.
## Gems don't rise — they stay in place and become tappable once enough material is cleared.
## Only reveals a gem when there are very few sand/silt particles still covering its area.
func _check_reveal_collectibles() -> void:
	var collectibles: Array = _haul.get("collectibles", [])

	for i in range(collectibles.size()):
		var collectible: Dictionary = collectibles[i]
		var revealed: bool = collectible.get("revealed", false)

		# Skip already-revealed collectibles
		if revealed:
			continue

		if i >= _collectible_nodes.size():
			continue

		var gem_node: Control = _collectible_nodes[i]
		var gem_rect := Rect2(gem_node.position, gem_node.size)

		# Count how many sand/silt particles overlap this gem's area
		var covering := 0
		for child in collectibles_container.get_children():
			if child in _collectible_nodes:
				continue
			if child.z_index != 1 and child.z_index != 2:
				continue
			if child.modulate.a < 0.5:
				continue
			var particle_rect := Rect2(child.position, child.size)
			if gem_rect.intersects(particle_rect):
				covering += 1
				if covering >= 3:
					break  # No need to count more, it's still covered

		# Only reveal if 2 or fewer particles are covering this gem
		if covering < 3:
			collectible["revealed"] = true
			gem_node.visible = true
			gem_node.z_index = 10  # Above all silt/sand, now tappable

	# After updating reveals, check if all are now revealed — if so, enter collecting phase
	var all_revealed := true
	for collectible in collectibles:
		if not collectible.get("revealed", false):
			all_revealed = false
			break
	if all_revealed and collectibles.size() > 0 and _current_phase == Phase.SIFTING:
		_current_phase = Phase.COLLECTING
		_clear_remaining_particles()


# ── Private: Collecting phase (Req 7.1–7.5, 8.1–8.4, 9.1–9.3, 10.2, 10.6) ──


## Force-fades and frees any remaining sand/silt particles when collecting begins.
## Ensures no stray particles linger after all gems are revealed.
func _clear_remaining_particles() -> void:
	for child in collectibles_container.get_children():
		if child in _collectible_nodes:
			continue
		if child.z_index != 1 and child.z_index != 2:
			continue
		if child.modulate.a < 0.1:
			continue
		var tween := create_tween()
		tween.tween_property(child, "modulate:a", 0.0, 0.3)\
			.set_trans(Tween.TRANS_LINEAR)
		tween.tween_callback(child.queue_free)


## Collects or sells a revealed gem at the given haul index.
func _collect_gem(index: int) -> void:
	var collectibles: Array = _haul.get("collectibles", [])
	if index < 0 or index >= collectibles.size():
		return
	var gem_data: Dictionary = collectibles[index]
	if gem_data.get("collected", false):
		return

	# Mark as collected
	gem_data["collected"] = true

	var gem_type: String = gem_data.get("gem_type", "gold")

	# Always add gemstone to compact inventory (gemstones don't count toward tile capacity)
	PlayerData.add_gemstones(gem_type, 1)
	# Grant XP equal to the gem's unpolished sell value (matches the Deep Mine),
	# rewarding panning. award_xp handles save + level-up + data_changed.
	var xp := PlayerData.get_gem_value(gem_type)
	if xp > 0:
		PlayerData.award_xp(xp)

	# Play pickup animation on the collectible node (Req 7.4)
	var node: Control = null
	for n in _collectible_nodes:
		if n != null and is_instance_valid(n) and n.get_meta("gem_index", -1) == index:
			node = n
			break

	if node != null:
		var tween := create_tween()
		_active_tween = tween
		# Animate upward toward top of screen (inventory indicator area)
		tween.set_parallel(true)
		tween.tween_property(node, "position:y", node.position.y - 80.0, 0.4)\
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.tween_property(node, "modulate", Color(1, 1, 1, 0), 0.4)\
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.chain().tween_callback(_on_gem_collected.bind(index))
	else:
		# No node found — complete immediately
		_on_gem_collected(index)


## Called after a gem's pickup animation completes.
func _on_gem_collected(index: int) -> void:
	_active_tween = null

	# Remove the collected node from the scene
	for n in _collectible_nodes:
		if n != null and is_instance_valid(n) and n.get_meta("gem_index", -1) == index:
			collectibles_container.remove_child(n)
			n.queue_free()
			break

	# Update panning stats (Req 10.6)
	var collectibles: Array = _haul.get("collectibles", [])
	if index >= 0 and index < collectibles.size():
		var gem_type: String = collectibles[index].get("gem_type", "gold")
		_panning_stats.increment_gem(gem_type)

		# Check achievement milestones (Req 10.1, 10.7–10.10)
		_check_gem_achievements(gem_type)

	# Check if all collectibles are now collected
	var all_collected := true
	for gem in collectibles:
		if not gem.get("collected", false):
			all_collected = false
			break

	if all_collected:
		_on_round_complete()


## Checks and triggers gem-related achievement milestones.
func _check_gem_achievements(gem_type: String) -> void:
	# First diamond
	if gem_type == "diamond":
		Achievements._try_unlock_one_time("first_diamond_panned")
		Achievements.save_data()

	# Update panning round progress. Use max() so the bar never regresses if
	# lifetime_rounds is read lower than the stored progress (e.g. a corrupted
	# panning stat reset to 0) — mirrors the max-based guards in Achievements.
	if not Achievements._progress.has("panning_enthusiast"):
		Achievements._progress["panning_enthusiast"] = {"progress": 0, "level": 0}
	if Achievements._progress["panning_enthusiast"]["level"] < 1:
		Achievements._progress["panning_enthusiast"]["progress"] = maxi(
			int(Achievements._progress["panning_enthusiast"].get("progress", 0)), _panning_stats.lifetime_rounds)

	if not Achievements._progress.has("panning_master"):
		Achievements._progress["panning_master"] = {"progress": 0, "level": 0}
	if Achievements._progress["panning_master"]["level"] < 1:
		Achievements._progress["panning_master"]["progress"] = maxi(
			int(Achievements._progress["panning_master"].get("progress", 0)), _panning_stats.lifetime_rounds)

	# Complete collection — count how many unique gem types the player has (inventory + stats)
	var unique_count: int = 0
	for gt in PanningStats.GEM_TYPES:
		var has_in_stats: bool = _panning_stats.gem_counts.get(gt, 0) >= 1
		var has_in_inv: bool = PlayerData.get_gem_count(gt) >= 1
		if has_in_stats or has_in_inv:
			unique_count += 1

	if not Achievements._progress.has("complete_collection"):
		Achievements._progress["complete_collection"] = {"progress": 0, "level": 0}
	if Achievements._progress["complete_collection"]["level"] < 1:
		Achievements._progress["complete_collection"]["progress"] = unique_count

	if unique_count >= 8:
		Achievements._try_unlock_one_time("complete_collection")

	Achievements.save_data()


## Called when all collectibles in the sifter have been collected. (Req 7.5)
func _on_round_complete() -> void:
	# Increment round stats (Req 10.2)
	_panning_stats.increment_round()

	# Check round-based achievements (Req 10.3, 10.4)
	if _panning_stats.lifetime_rounds >= 50:
		Achievements._try_unlock_one_time("panning_master")
		Achievements.save_data()
	elif _panning_stats.lifetime_rounds >= 10:
		Achievements._try_unlock_one_time("panning_enthusiast")
		Achievements.save_data()

	# Award XP for completing a round (Req 9.2)
	PlayerData.award_xp(25)

	# Save panning stats to config
	var config := ConfigFile.new()
	if config.load(PlayerData.SAVE_PATH) == OK:
		_panning_stats.save_to_config(config)
		config.save(PlayerData.SAVE_PATH)

	# Wait 0.5s then reset to panning (Req 7.5)
	var timer := Timer.new()
	timer.wait_time = 0.5
	timer.one_shot = true
	timer.timeout.connect(_reset_to_panning)
	add_child(timer)
	timer.start()


## Resets all state back to the panning phase for a new round.
func _reset_to_panning() -> void:
	# Clear collectibles container
	for child in collectibles_container.get_children():
		collectibles_container.remove_child(child)
		child.queue_free()
	_collectible_nodes = []

	# Reset state variables
	_fill_level = 0
	_separation_progress = 0.0
	_haul = {}

	# Switch UI back to panning
	_current_phase = Phase.PANNING
	pan_sprite.visible = true
	river_background.visible = true
	sifter_container.visible = false
	_update_pan_sprite()

	# Reset shake detector for new round
	if _shake_detector != null:
		_shake_detector.reset()


## Shows a brief "+Xc" coins-earned indicator that floats upward and fades out.
func _show_coins_earned_indicator(global_pos: Vector2, amount: int) -> void:
	var label := Label.new()
	label.text = "+%s" % PlayerData.format_number(amount)
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.0))  # Gold color
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = (global_pos - collectibles_container.global_position) + Vector2(-20, -30)
	label.z_index = 10
	collectibles_container.add_child(label)

	# Float up and fade out over 1.0s
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 60.0, 1.0)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate", Color(1, 1, 1, 0), 1.0)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(label.queue_free)
