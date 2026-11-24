class_name PieceSelectionUI
extends MarginContainer

## Multiplayer piece selection screen.
## Presents the player's persistent inventory for selecting pieces to bring into battle.
## Enforces minimum 3 / maximum 20 pieces per player.
## Auto-confirms after 120 seconds if the minimum is met.
## When both players confirm, transitions to the Placement Phase.

# ── Constants ─────────────────────────────────────────────────────────────────

const MIN_PIECES := 3
const MAX_PIECES := 20
const SELECTION_TIME_LIMIT := 120.0  ## seconds

const MULTIPLAYER_MENU_PATH := "res://scenes/multiplayer/multiplayer_menu.tscn"

# ── Node References ───────────────────────────────────────────────────────────

@onready var title_label       : Label    = $VBox/TitleLabel
@onready var timer_label       : Label    = $VBox/TopRow/TimerLabel
@onready var status_label      : Label    = $VBox/StatusLabel
@onready var count_label       : Label    = $VBox/TopRow/CountLabel
@onready var error_label       : Label    = $VBox/ErrorLabel
@onready var inventory_list    : ItemList = $VBox/ListsRow/InventoryPanel/InventoryList
@onready var selected_list     : ItemList = $VBox/ListsRow/SelectedPanel/SelectedList
@onready var add_btn           : Button   = $VBox/ListsRow/ButtonPanel/AddBtn
@onready var remove_btn        : Button   = $VBox/ListsRow/ButtonPanel/RemoveBtn
@onready var confirm_btn       : Button   = $VBox/BtnRow/ConfirmBtn
@onready var cancel_btn        : Button   = $VBox/BtnRow/CancelBtn

# ── State ─────────────────────────────────────────────────────────────────────

## The player's full inventory as piece dictionaries from PlayerData.
var _inventory_items: Array = []

## Indices into _inventory_items that have been selected for battle.
var _selected_indices: Array[int] = []

## Whether this player has confirmed their selection.
var _confirmed: bool = false

## Whether the opponent has confirmed their selection.
var _opponent_confirmed: bool = false

## Countdown timer remaining seconds.
var _time_remaining: float = SELECTION_TIME_LIMIT

## Whether the timer is active.
var _timer_active: bool = true


# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	## Wire button signals
	add_btn.pressed.connect(_on_add_pressed)
	remove_btn.pressed.connect(_on_remove_pressed)
	confirm_btn.pressed.connect(_on_confirm_pressed)
	cancel_btn.pressed.connect(_on_cancel_pressed)

	## Wire NetworkManager signals
	NetworkManager.disconnected.connect(_on_disconnected)

	## Load the player's inventory
	_load_inventory()

	## Check minimum inventory requirement (Req 9.5)
	if PlayerData.get_inventory_size() < MIN_PIECES:
		error_label.text = "Insufficient pieces! You need at least %d pieces in your inventory." % MIN_PIECES
		error_label.visible = true
		confirm_btn.disabled = true
		add_btn.disabled = true
		_timer_active = false
	else:
		error_label.visible = false

	## Initial UI state
	confirm_btn.disabled = true
	_update_count_label()
	_update_timer_display()


func _exit_tree() -> void:
	if NetworkManager.disconnected.is_connected(_on_disconnected):
		NetworkManager.disconnected.disconnect(_on_disconnected)


func _process(delta: float) -> void:
	if not _timer_active:
		return

	_time_remaining -= delta
	_update_timer_display()

	if _time_remaining <= 0.0:
		_timer_active = false
		_time_remaining = 0.0
		_update_timer_display()
		## Auto-confirm if minimum is met (Req 9.6)
		if _selected_indices.size() >= MIN_PIECES and not _confirmed:
			_do_confirm()


# ── Inventory Loading ─────────────────────────────────────────────────────────


## Loads pieces from PlayerData's persistent inventory into the left list.
func _load_inventory() -> void:
	_inventory_items = PlayerData.inventory.duplicate()
	_rebuild_inventory_list()


## Rebuilds the inventory ItemList from current state.
func _rebuild_inventory_list() -> void:
	inventory_list.clear()
	for i in range(_inventory_items.size()):
		if i in _selected_indices:
			continue  ## Don't show already-selected pieces in inventory list
		var item: Dictionary = _inventory_items[i]
		var piece_type: Piece.Type = item["type"] as Piece.Type
		var display := PieceRegistry.display_name(piece_type)
		var points := PieceRegistry.base_points(piece_type)
		var def := PieceRegistry.get_def(piece_type)
		var desc: String = def.description if def else ""
		inventory_list.add_item("%s (%d pts)" % [display, points])
		var idx := inventory_list.item_count - 1
		## Store the original inventory index as metadata
		inventory_list.set_item_metadata(idx, i)
		## Set tooltip with piece description
		inventory_list.set_item_tooltip(idx, "%s — %d pts\n%s" % [display, points, desc])


## Rebuilds the selected ItemList from current state.
func _rebuild_selected_list() -> void:
	selected_list.clear()
	for sel_i in range(_selected_indices.size()):
		var inv_idx: int = _selected_indices[sel_i]
		var item: Dictionary = _inventory_items[inv_idx]
		var piece_type: Piece.Type = item["type"] as Piece.Type
		var display := PieceRegistry.display_name(piece_type)
		var points := PieceRegistry.base_points(piece_type)
		var def := PieceRegistry.get_def(piece_type)
		var desc: String = def.description if def else ""
		selected_list.add_item("%s (%d pts)" % [display, points])
		var idx := selected_list.item_count - 1
		selected_list.set_item_tooltip(idx, "%s — %d pts\n%s" % [display, points, desc])


# ── UI Updates ────────────────────────────────────────────────────────────────


func _update_count_label() -> void:
	count_label.text = "Selected: %d / %d (min %d)" % [_selected_indices.size(), MAX_PIECES, MIN_PIECES]


func _update_timer_display() -> void:
	var secs := ceili(_time_remaining)
	timer_label.text = "Time: %d s" % secs


func _update_confirm_button() -> void:
	if _confirmed:
		confirm_btn.disabled = true
		confirm_btn.text = "Confirmed"
	else:
		confirm_btn.disabled = _selected_indices.size() < MIN_PIECES
		confirm_btn.text = "Confirm Selection"


# ── Button Handlers ───────────────────────────────────────────────────────────


func _on_add_pressed() -> void:
	if _confirmed:
		return

	var selected_items := inventory_list.get_selected_items()
	if selected_items.is_empty():
		return

	## Check max limit
	if _selected_indices.size() >= MAX_PIECES:
		error_label.text = "Maximum %d pieces reached!" % MAX_PIECES
		error_label.visible = true
		return

	## Get the original inventory index from metadata
	var list_idx: int = selected_items[0]
	var inv_idx: int = inventory_list.get_item_metadata(list_idx)

	## Check King limit (max 1 King allowed per match)
	var item: Dictionary = _inventory_items[inv_idx]
	var piece_type: Piece.Type = item.get("type", 0) as Piece.Type
	if piece_type == Piece.Type.KING:
		var king_count: int = 0
		for idx in _selected_indices:
			var sel_item: Dictionary = _inventory_items[idx]
			if (sel_item.get("type", 0) as Piece.Type) == Piece.Type.KING:
				king_count += 1
		if king_count >= 1:
			error_label.text = "Maximum 1 King allowed per battle!"
			error_label.visible = true
			return

	_selected_indices.append(inv_idx)
	error_label.visible = false
	_rebuild_inventory_list()
	_rebuild_selected_list()
	_update_count_label()
	_update_confirm_button()


func _on_remove_pressed() -> void:
	if _confirmed:
		return

	var selected_items := selected_list.get_selected_items()
	if selected_items.is_empty():
		return

	## Remove the piece from the selected list
	var list_idx: int = selected_items[0]
	if list_idx >= 0 and list_idx < _selected_indices.size():
		_selected_indices.remove_at(list_idx)

	error_label.visible = false
	_rebuild_inventory_list()
	_rebuild_selected_list()
	_update_count_label()
	_update_confirm_button()


func _on_confirm_pressed() -> void:
	if _confirmed:
		return

	if _selected_indices.size() < MIN_PIECES:
		error_label.text = "Select at least %d pieces!" % MIN_PIECES
		error_label.visible = true
		return

	_do_confirm()


func _on_cancel_pressed() -> void:
	## Disconnect and return to multiplayer menu
	NetworkManager.disconnect_from_match()
	get_tree().change_scene_to_file(MULTIPLAYER_MENU_PATH)


# ── Confirm Logic ─────────────────────────────────────────────────────────────


## Performs the actual confirmation, disables further changes, and notifies peer.
func _do_confirm() -> void:
	_confirmed = true
	_timer_active = false
	confirm_btn.disabled = true
	confirm_btn.text = "Confirmed"
	add_btn.disabled = true
	remove_btn.disabled = true
	inventory_list.allow_reselect = false

	status_label.text = "Waiting for opponent..."

	## Notify the other player that we've confirmed
	if NetworkManager.is_host:
		## Host tells client it confirmed
		_notify_peer_confirmed.rpc()
		_check_both_confirmed()
	else:
		## Client tells host it confirmed
		_notify_peer_confirmed.rpc_id(1)


## Checks if both players confirmed and initiates the transition to placement.
func _check_both_confirmed() -> void:
	if not _confirmed or not _opponent_confirmed:
		return

	## Both confirmed — transition to placement phase
	status_label.text = "Both confirmed! Starting battle..."
	cancel_btn.disabled = true

	if NetworkManager.is_host:
		## Small delay so players see the status update
		await get_tree().create_timer(0.5).timeout
		_transition_to_placement.rpc()


# ── Piece Hand Building ───────────────────────────────────────────────────────


## Builds a Hand from the selected pieces for use in the battle.
func build_selected_hand(owner: Piece.Owner) -> Hand:
	var hand := Hand.new()
	for idx in _selected_indices:
		var item: Dictionary = _inventory_items[idx]
		var piece_type: Piece.Type = item["type"] as Piece.Type
		var direction: PieceDefinition.Direction = item["direction"] as PieceDefinition.Direction
		var piece := Piece.create(piece_type, owner)
		piece.direction = direction
		hand.pieces.append(piece)
	return hand


# ── NetworkManager Signal Handlers ────────────────────────────────────────────


func _on_disconnected(reason: String) -> void:
	status_label.text = "Disconnected: %s" % reason
	_timer_active = false
	confirm_btn.disabled = true
	add_btn.disabled = true
	remove_btn.disabled = true
	await get_tree().create_timer(1.5).timeout
	get_tree().change_scene_to_file(MULTIPLAYER_MENU_PATH)


# ── RPCs ──────────────────────────────────────────────────────────────────────


## Notifies the peer that this player has confirmed their selection.
@rpc("any_peer", "reliable")
func _notify_peer_confirmed() -> void:
	_opponent_confirmed = true
	status_label.text = "Opponent confirmed!"

	## If we are the host and both are confirmed, start the match
	if NetworkManager.is_host:
		_check_both_confirmed()


## Host → All: transition both peers to the placement phase.
@rpc("authority", "reliable", "call_local")
func _transition_to_placement() -> void:
	## Store selected pieces on NetworkManager so they persist across scene change
	NetworkManager.local_battle_pieces = []
	for idx in _selected_indices:
		var item: Dictionary = _inventory_items[idx]
		NetworkManager.local_battle_pieces.append(item.duplicate())
	get_tree().change_scene_to_file("res://scenes/multiplayer/multiplayer_battle.tscn")
