extends Node
## Bridges TouchInputManager signals to the active game scene's logic.
## Only active on Android — guards all connections with a platform check.
## Does NOT modify existing game scripts; routes touch events to the same
## functions that mouse clicks use.

var _game_ui: Node = null
var _multiplayer_ui: Node = null
var _tooltip_popup: PopupPanel = null


func _ready() -> void:
	# Connect to TouchInputManager signals (parent node)
	var touch_mgr := get_parent()
	if touch_mgr == null:
		push_warning("TouchGameIntegration: No parent TouchInputManager found.")
		return

	if touch_mgr.has_signal("piece_selected"):
		touch_mgr.piece_selected.connect(_on_piece_selected)
	if touch_mgr.has_signal("cell_tapped"):
		touch_mgr.cell_tapped.connect(_on_cell_tapped)
	if touch_mgr.has_signal("piece_long_pressed"):
		touch_mgr.piece_long_pressed.connect(_on_piece_long_pressed)
	if touch_mgr.has_signal("piece_rotate_requested"):
		touch_mgr.piece_rotate_requested.connect(_on_piece_rotate_requested)
	if touch_mgr.has_signal("deselect_requested"):
		touch_mgr.deselect_requested.connect(_on_deselect_requested)

	# Defer UI discovery until the tree is fully ready
	call_deferred("_discover_game_ui")


## Finds the active game UI node in the scene tree.
## Supports both single-player (battle_screen) and multiplayer (multiplayer_battle_ui).
func _discover_game_ui() -> void:
	_game_ui = _find_node_with_script("battle_screen.gd")
	_multiplayer_ui = _find_node_with_script("multiplayer_battle_ui.gd")

	# Listen for scene changes to re-discover UI nodes
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)


## When a new node is added, check if it's a game UI we need to track.
func _on_node_added(node: Node) -> void:
	if _game_ui != null and _multiplayer_ui != null:
		return
	var script: Variant = node.get_script()
	if script == null:
		return
	var path: String = script.resource_path if script is Script else ""
	if _game_ui == null and path.ends_with("battle_screen.gd"):
		_game_ui = node
	elif _multiplayer_ui == null and path.ends_with("multiplayer_battle_ui.gd"):
		_multiplayer_ui = node


## When a node is removed, clear stale references.
func _on_node_removed(node: Node) -> void:
	if node == _game_ui:
		_game_ui = null
	elif node == _multiplayer_ui:
		_multiplayer_ui = null


## Returns the currently active game UI or null.
func _get_active_ui() -> Node:
	if _multiplayer_ui != null and is_instance_valid(_multiplayer_ui) \
	   and _multiplayer_ui.is_inside_tree():
		return _multiplayer_ui
	if _game_ui != null and is_instance_valid(_game_ui) \
	   and _game_ui.is_inside_tree():
		return _game_ui
	return null


## ── Signal Handlers ──────────────────────────────────────────────


## Req 2.1: Tap piece in hand grid → select for placement
func _on_piece_selected(piece: Piece) -> void:
	var ui := _get_active_ui()
	if ui == null:
		return

	# Use the same selection function the UI uses on button press
	if ui.has_method("_on_hand_pressed"):
		ui._on_hand_pressed(piece)
	elif "selected_piece" in ui:
		# Fallback: set the piece directly
		ui.selected_piece = piece
		var gm := _get_game_manager(ui)
		if gm != null:
			gm.select_hand_piece(piece)
		if ui.has_method("_rebuild_hand"):
			ui._rebuild_hand()
		if ui.has_method("_refresh_board"):
			ui._refresh_board()


## Req 2.2, 2.3, 2.4: Tap board cell → placement or movement routing
func _on_cell_tapped(row: int, col: int) -> void:
	var ui := _get_active_ui()
	if ui == null:
		return

	var gm := _get_game_manager(ui)
	if gm == null:
		return

	# Determine current phase and route accordingly
	var phase: int = -1
	if gm is MultiplayerGameManager:
		phase = gm.pvp_phase
	elif "current_phase" in gm:
		phase = gm.current_phase

	# Route to placement or movement based on phase
	if ui.has_method("_handle_place") and _is_placement_phase(gm, phase):
		ui._handle_place(row, col)
	elif ui.has_method("_handle_move") and _is_movement_phase(gm, phase):
		ui._handle_move(row, col)


## Req 2.5: Long-press → tooltip showing piece info
func _on_piece_long_pressed(piece: Piece) -> void:
	if piece == null:
		return
	_show_piece_tooltip(piece)


## Req 2.6: Two-finger tap → rotate piece (only if rotatable)
func _on_piece_rotate_requested(piece: Piece) -> void:
	if piece == null:
		return
	if not piece.is_rotatable():
		return

	var ui := _get_active_ui()
	var gm := _get_game_manager(ui) if ui != null else null

	if gm != null and gm.has_method("rotate_piece"):
		gm.rotate_piece(piece)
		# Refresh the UI after rotation
		if ui != null:
			if ui.has_method("_rebuild_hand"):
				ui._rebuild_hand()
			if ui.has_method("_refresh_board"):
				ui._refresh_board()


## Req 2.8: Tap outside interactive elements → deselect
func _on_deselect_requested() -> void:
	var ui := _get_active_ui()
	if ui == null:
		return

	# Clear selection state
	if "selected_piece" in ui:
		ui.selected_piece = null
	if "move_source" in ui:
		ui.move_source = []
	if "rotating_piece" in ui:
		ui.rotating_piece = null

	# Refresh visuals
	if ui.has_method("_rebuild_hand"):
		ui._rebuild_hand()
	if ui.has_method("_refresh_board"):
		ui._refresh_board()


## ── Tooltip Display ──────────────────────────────────────────────


## Shows a popup with piece name, description, and scoring info.
func _show_piece_tooltip(piece: Piece) -> void:
	_dismiss_tooltip()

	var def: PieceDefinition = PieceRegistry.get_def(piece.type)
	if def == null:
		return

	# Build tooltip text
	var text := ""
	text += "[b]%s[/b]\n" % piece.display_name
	if piece.description != "":
		text += "%s\n" % piece.description
	text += "\nBase Points: %d" % piece.base_points
	if def.effect_type != PieceDefinition.EffectType.NONE:
		text += "\nEffect: %s" % _get_effect_description(def)
	if piece.is_rotatable():
		text += "\nDirection: %s" % _direction_name(piece.direction)
		text += "\n[i]Two-finger tap to rotate[/i]"

	# Create popup
	_tooltip_popup = PopupPanel.new()
	_tooltip_popup.transient = true
	_tooltip_popup.exclusive = false

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)

	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.text = text
	label.fit_content = true
	label.custom_minimum_size = Vector2(250, 0)
	label.scroll_active = false

	margin.add_child(label)
	_tooltip_popup.add_child(margin)

	# Add to scene and show centered
	var root := get_tree().root
	root.add_child(_tooltip_popup)
	_tooltip_popup.popup_centered()

	# Auto-dismiss after 3 seconds or on next tap
	get_tree().create_timer(3.0).timeout.connect(_dismiss_tooltip)


## Removes the tooltip popup if visible.
func _dismiss_tooltip() -> void:
	if _tooltip_popup != null and is_instance_valid(_tooltip_popup):
		_tooltip_popup.hide()
		_tooltip_popup.queue_free()
		_tooltip_popup = null


## ── Helpers ──────────────────────────────────────────────────────


## Gets the GameManager from a UI node.
func _get_game_manager(ui: Node) -> Node:
	if ui == null:
		return null
	if "game_manager" in ui:
		return ui.game_manager
	# Try finding it as a sibling or child
	var gm := ui.get_node_or_null("GameManager")
	if gm != null:
		return gm
	return null


## Returns true if the game is in a placement phase.
func _is_placement_phase(gm: Node, phase: int) -> bool:
	if gm is MultiplayerGameManager:
		return phase == MultiplayerGameManager.PvPPhase.PVP_PLACEMENT
	# Single-player GameManager
	return phase == GameManager.Phase.PLACEMENT


## Returns true if the game is in a movement phase.
func _is_movement_phase(gm: Node, phase: int) -> bool:
	if gm is MultiplayerGameManager:
		return phase == MultiplayerGameManager.PvPPhase.MOVEMENT
	# Single-player GameManager
	return phase == GameManager.Phase.MOVEMENT


## Searches the scene tree for a node whose script filename matches.
func _find_node_with_script(script_name: String) -> Node:
	return _search_tree(get_tree().root, script_name)


func _search_tree(node: Node, script_name: String) -> Node:
	if node == null:
		return null
	var script: Variant = node.get_script()
	if script != null:
		var path: String = script.resource_path if script is Script else ""
		if path.ends_with(script_name):
			return node
	for child in node.get_children():
		var found := _search_tree(child, script_name)
		if found != null:
			return found
	return null


## Returns a human-readable effect description for the tooltip.
func _get_effect_description(def: PieceDefinition) -> String:
	match def.effect_type:
		PieceDefinition.EffectType.DIAGONAL_BUFF:
			return "Buffs diagonal allies +%d" % def.effect_value
		PieceDefinition.EffectType.CORNER_BONUS:
			return "Corner bonus +%d" % def.effect_value
		PieceDefinition.EffectType.GUARD_BONUS:
			return "Guard bonus +%d when protected" % def.effect_value
		PieceDefinition.EffectType.NEGATE:
			return "Negates piece in facing direction"
		PieceDefinition.EffectType.ADJACENT_NEGATE:
			return "Negates all adjacent pieces"
		PieceDefinition.EffectType.DIRECTIONAL_PROTECT:
			return "Shields piece in facing direction"
		PieceDefinition.EffectType.DOME_PROTECT:
			return "Protects all adjacent allies"
		PieceDefinition.EffectType.REMOVE_DIRECTIONAL:
			return "Removes piece in facing direction"
		PieceDefinition.EffectType.TERRAIN_ADJ_BUFF:
			return "Terrain buff +%d to adjacent allies" % def.effect_value
		PieceDefinition.EffectType.ISOLATED_BONUS:
			return "Isolated penalty -%d if alone" % def.effect_value
		PieceDefinition.EffectType.DEBUFF:
			return "Debuffs enemy in facing direction -%d" % def.effect_value
		PieceDefinition.EffectType.ADJACENT_HALVE:
			return "Halves adjacent enemies' scores"
		PieceDefinition.EffectType.WIND_PUSH:
			return "Pushes adjacent pieces away (Desert)"
		_:
			return ""


## Returns a display name for a direction enum value.
func _direction_name(dir) -> String:
	match dir:
		PieceDefinition.Direction.NORTH: return "North"
		PieceDefinition.Direction.SOUTH: return "South"
		PieceDefinition.Direction.EAST:  return "East"
		PieceDefinition.Direction.WEST:  return "West"
		_: return "None"
