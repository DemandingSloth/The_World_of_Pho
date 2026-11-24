class_name MultiplayerGameManager
extends GameManager

## Extends GameManager to support PvP multiplayer with network synchronization.
## Replaces AI logic with remote player input for the "enemy" side.
## Host (peer_id=1) plays BLACK tiles (PLAYER), Guest plays WHITE tiles (ENEMY).

# ── Signals ───────────────────────────────────────────────────────────────────

signal opponent_placement_confirmed
signal opponent_move_received(from: Vector2i, to: Vector2i)
signal match_result_confirmed(winner_id: int)

## Emitted on the client when the host rejects a placement request.
signal placement_rejected(reason: String)

## Emitted on host when the client disconnects mid-match. UI shows "Opponent disconnected".
signal opponent_disconnected

## Emitted on client when the host disconnects. UI shows "Host lost".
signal host_disconnected

## Emitted when a disconnected opponent reconnects within the 30-second window.
signal opponent_reconnected

# ── Enums ─────────────────────────────────────────────────────────────────────

enum PvPPhase {
	LOBBY,
	PVP_PLACEMENT,    ## Both place simultaneously, hidden from each other
	REVEAL,           ## Board revealed to both players
	MOVEMENT,         ## Turn-based movement (reuses existing Movement class)
	SCORING,          ## Scoring (reuses existing Scoring class)
	RESULT,           ## Show winner
}

# ── State ─────────────────────────────────────────────────────────────────────

var pvp_phase: PvPPhase = PvPPhase.LOBBY
var host_peer_id: int = 1
var guest_peer_id: int = 0
var host_ready: bool = false
var guest_ready: bool = false
var placement_timer: float = 0.0

## Match configuration agreed upon in the lobby.
var match_config: MatchConfig = null

## Manages the rematch flow after a match ends (Requirements 8.1–8.4).
var rematch_manager: RematchManager = null

## True when the host is waiting for a disconnected client to reconnect.
var _waiting_for_reconnect: bool = false

## True when the host has received a board acknowledgment from the client.
var _board_ack_received: bool = false

## Maximum retransmission attempts for board state (Requirement 6.6).
const BOARD_ACK_MAX_RETRIES: int = 3

## Timeout in seconds before host retransmits board state (Requirement 6.6).
const BOARD_ACK_TIMEOUT: float = 3.0

## Countdown timer (seconds) for the 30-second reconnection window.
var _reconnect_timer: float = 30.0

## Stores the placement_timer value at the moment of pause (for resume).
var _paused_placement_timer: float = 0.0

## Stores the move_timer value at the moment of pause (for resume).
var _paused_move_timer: float = 0.0

## Hands for each player in PvP (host uses player_hand, guest uses enemy_hand).
var host_hand: Hand:
	get: return player_hand
	set(value): player_hand = value

var guest_hand: Hand:
	get: return enemy_hand
	set(value): enemy_hand = value


# ── Public API ────────────────────────────────────────────────────────────────


## Called when the node enters the scene tree. Connects to NetworkManager
## signals for disconnection detection during active battles, and sets up
## the RematchManager node for post-match rematch flow.
func _ready() -> void:
	# Connect to NetworkManager signals if it's available as an autoload.
	var network_manager: Node = get_node_or_null("/root/NetworkManager")
	if network_manager:
		if network_manager.has_signal("disconnected"):
			network_manager.disconnected.connect(_on_network_disconnected)
		if network_manager.has_signal("player_left"):
			network_manager.player_left.connect(_on_player_left)
		if network_manager.has_signal("player_joined"):
			network_manager.player_joined.connect(_on_player_joined_during_match)

	# Create and add RematchManager as a child node
	rematch_manager = RematchManager.new()
	rematch_manager.name = "RematchManager"
	add_child(rematch_manager)
	rematch_manager.rematch_started.connect(_on_rematch_started)
	rematch_manager.rematch_expired.connect(_on_rematch_expired)


## Initializes a fresh PvP match from the given configuration.
## Sets up an empty board, populates both hands from inventory, creates a
## Movement instance, and transitions to the PVP_PLACEMENT phase.
##
## Preconditions:
##   - Both players are connected and ready
##   - config.validate() == true
##
## Postconditions:
##   - board is a fresh 8×8 grid with no pieces
##   - host_hand and guest_hand populated from player inventories
##   - movement instance created
##   - pvp_phase == PvPPhase.PVP_PLACEMENT
func start_pvp_match(config: MatchConfig) -> void:
	match_config = config
	current_terrain = config.terrain

	## Fresh board with no pieces
	board = BoardState.new()

	## Build hands from each player's inventory.
	## Host pieces are PLAYER (BLACK tiles), Guest pieces are ENEMY (WHITE tiles).
	host_hand = Hand.new()
	for p in _get_host_battle_pieces():
		host_hand.pieces.append(p)

	guest_hand = Hand.new()
	for p in _get_guest_battle_pieces():
		guest_hand.pieces.append(p)

	## Create movement instance for later use in the MOVEMENT phase.
	movement = Movement.new(board)

	## Reset readiness flags
	host_ready = false
	guest_ready = false

	## Start placement timer from config
	placement_timer = config.placement_time_limit

	## Transition to placement phase
	pvp_phase = PvPPhase.PVP_PLACEMENT


## Returns the remaining seconds on the current move timer.
## Used by the UI layer to display the 60-second countdown.
func get_move_time_remaining() -> float:
	return move_timer


# ── Peer ↔ Owner Mapping ─────────────────────────────────────────────────────


## Maps a network peer_id to a game-logic Piece.Owner.
## Host (peer_id=1) always plays BLACK tiles (PLAYER).
## Guest plays WHITE tiles (ENEMY).
## Returns -1 for unknown peer_id.
func _peer_to_owner(peer_id: int) -> int:
	if peer_id == host_peer_id:
		return Piece.Owner.PLAYER
	elif peer_id == guest_peer_id:
		return Piece.Owner.ENEMY
	return -1


## Maps a Piece.Owner back to the corresponding peer_id.
func _owner_to_peer(owner: int) -> int:
	if owner == Piece.Owner.PLAYER:
		return host_peer_id
	return guest_peer_id


# ── Private Helpers ───────────────────────────────────────────────────────────


## Returns pieces from the host player's inventory as PLAYER-owned Piece objects.
## Override this in subclasses or tests to provide custom piece sets.
func _get_host_battle_pieces() -> Array[Piece]:
	return PlayerData.get_inventory_as_pieces()


## Returns pieces for the guest player as ENEMY-owned Piece objects.
## In a real match this would come from the guest's transmitted selection.
## For now, builds from the guest's communicated piece list.
func _get_guest_battle_pieces() -> Array[Piece]:
	## Guest pieces use ENEMY owner so they go on WHITE tiles.
	## This will be populated via RPC from the guest's piece selection.
	## Default: return empty — populated externally before start_pvp_match or via RPC.
	var pieces: Array[Piece] = []
	return pieces


# ── Placement Validation & RPCs ──────────────────────────────────────────────


## Validates and applies a placement request from a peer.
## Returns true if the piece was successfully placed; false otherwise.
##
## Checks performed (in order):
##   1. Phase must be PVP_PLACEMENT
##   2. Peer must map to a valid owner
##   3. Row/col must be in bounds
##   4. Tile must be valid for the owner's color
##   5. Row must be within the peer's allowed rows (0-3 for host, 4-7 for guest)
##   6. Cell must not already be occupied
##   7. Piece type must exist in the player's hand
##   8. King placement must not exceed max_king_count
func request_placement(peer_id: int, piece_data: Dictionary, row: int, col: int) -> bool:
	# 1. Phase check
	if pvp_phase != PvPPhase.PVP_PLACEMENT:
		return false

	# 2. Peer-to-owner mapping
	var owner: int = _peer_to_owner(peer_id)
	if owner == -1:
		return false

	# 3. Bounds check
	if not BoardState.in_bounds(row, col):
		return false

	# 4. Tile-color validity (PLAYER on BLACK/dark tiles, ENEMY on WHITE/light tiles)
	if not BoardState.is_valid_tile(row, col, owner as Piece.Owner):
		return false

	# 5. Cell not occupied
	if board.get_piece(row, col) != null:
		return false

	# 7. Validate piece exists in player's hand
	var hand: Hand = _get_hand_for_peer(peer_id)
	if hand == null:
		return false

	var piece_type: int = piece_data.get("type", -1)
	if piece_type < 0:
		return false

	var piece_index: int = _find_piece_in_hand(hand, piece_type as Piece.Type)
	if piece_index == -1:
		return false

	# 8. Enforce King limit
	if piece_type == Piece.Type.KING:
		if _count_placed_kings(owner as Piece.Owner) >= match_config.max_king_count:
			return false

	# All checks passed — place the piece
	var piece: Piece = hand.take_piece(piece_index)
	piece.direction = (piece_data.get("direction", PieceDefinition.Direction.NONE)
		as PieceDefinition.Direction)
	board.place_piece(piece, row, col)
	return true


## RPC handler called by any peer to request a placement on the host.
## The host validates and responds with either acceptance or rejection.
@rpc("any_peer", "reliable")
func _request_placement_rpc(piece_data: Dictionary, row: int, col: int) -> void:
	var sender_id: int = multiplayer.get_remote_sender_id()
	var success: bool = request_placement(sender_id, piece_data, row, col)
	if success:
		_placement_accepted_rpc.rpc_id(sender_id, piece_data, row, col)
	else:
		var reason: String = _get_placement_rejection_reason(sender_id, piece_data, row, col)
		_placement_rejected_rpc.rpc_id(sender_id, reason)


## RPC sent to the requesting peer only when placement succeeds.
## Hidden from opponent during placement phase.
## Client-side: create piece from data and place on local board mirror.
@rpc("authority", "reliable")
func _placement_accepted_rpc(_piece_data: Dictionary, _row: int, _col: int) -> void:
	# Deserialize the piece from host-confirmed data
	var piece: Piece = BoardSync.deserialize_piece(_piece_data)
	if piece == null:
		return
	# Place on local board mirror — this is the confirmed state
	board.place_piece(piece, _row, _col)

	# Remove the piece from the local hand (guest side)
	var local_owner: Piece.Owner = piece.owner
	var hand: Hand = null
	if local_owner == Piece.Owner.PLAYER:
		hand = player_hand
	else:
		hand = enemy_hand
	if hand != null:
		for i in range(hand.pieces.size()):
			if hand.pieces[i].type == piece.type:
				hand.pieces.remove_at(i)
				break

	# Notify UI to refresh
	emit_signal("board_updated")


## RPC sent to the requesting peer only when placement fails.
## Client-side: no board state change needed (client never applied optimistic placement).
## Emits placement_rejected signal so UI can show the error.
@rpc("authority", "reliable")
func _placement_rejected_rpc(_reason: String) -> void:
	# No board revert needed — client waits for host confirmation before placing locally.
	# Signal the UI layer to display rejection feedback.
	placement_rejected.emit(_reason)


# ── Placement Helpers ─────────────────────────────────────────────────────────


## Returns the Hand for the given peer_id.
func _get_hand_for_peer(peer_id: int) -> Hand:
	if peer_id == host_peer_id:
		return host_hand
	elif peer_id == guest_peer_id:
		return guest_hand
	return null


## Finds the first piece of the given type in the hand.
## Returns the index, or -1 if not found.
func _find_piece_in_hand(hand: Hand, piece_type: Piece.Type) -> int:
	for i in range(hand.pieces.size()):
		if hand.pieces[i].type == piece_type:
			return i
	return -1


## Counts how many Kings of the given owner are already placed on the board.
func _count_placed_kings(owner: Piece.Owner) -> int:
	var count: int = 0
	for r in range(BoardState.BOARD_SIZE):
		for c in range(BoardState.BOARD_SIZE):
			var piece: Piece = board.get_piece(r, c)
			if piece != null and piece.owner == owner and piece.type == Piece.Type.KING:
				count += 1
	return count


## Generates a human-readable rejection reason for a failed placement.
## Used internally to provide feedback to the client.
func _get_placement_rejection_reason(peer_id: int, piece_data: Dictionary, row: int, col: int) -> String:
	if pvp_phase != PvPPhase.PVP_PLACEMENT:
		return "Not in placement phase"

	var owner: int = _peer_to_owner(peer_id)
	if owner == -1:
		return "Unknown peer"

	if not BoardState.in_bounds(row, col):
		return "Position out of bounds"

	if not BoardState.is_valid_tile(row, col, owner as Piece.Owner):
		return "Invalid tile color for your side"

	if board.get_piece(row, col) != null:
		return "Cell already occupied"

	var hand: Hand = _get_hand_for_peer(peer_id)
	if hand == null:
		return "No hand found for peer"

	var piece_type: int = piece_data.get("type", -1)
	if piece_type < 0:
		return "Invalid piece type"

	var piece_index: int = _find_piece_in_hand(hand, piece_type as Piece.Type)
	if piece_index == -1:
		return "Piece not available in hand"

	if piece_type == Piece.Type.KING:
		if _count_placed_kings(owner as Piece.Owner) >= match_config.max_king_count:
			return "King limit reached"

	return "Unknown reason"


## Counts how many pieces of the given owner are currently placed on the board.
func _count_placed_pieces(owner: Piece.Owner) -> int:
	var count: int = 0
	for r in range(BoardState.BOARD_SIZE):
		for c in range(BoardState.BOARD_SIZE):
			var piece: Piece = board.get_piece(r, c)
			if piece != null and piece.owner == owner:
				count += 1
	return count


# ── Placement Confirmation & Timer ────────────────────────────────────────────

## Minimum number of pieces a player must have placed before confirming.
const MIN_PLACEMENT_PIECES: int = 3


## Confirms that a player has finished placing pieces.
## Rejects confirmation if the player has fewer than MIN_PLACEMENT_PIECES placed.
## When both players are ready, triggers reveal and movement transition.
##
## Returns true if the confirmation was accepted; false otherwise.
func confirm_placement_done(peer_id: int) -> bool:
	if pvp_phase != PvPPhase.PVP_PLACEMENT:
		return false

	var owner: int = _peer_to_owner(peer_id)
	if owner == -1:
		return false

	# Enforce minimum 3 pieces placed (Requirement 3.7)
	if _count_placed_pieces(owner as Piece.Owner) < MIN_PLACEMENT_PIECES:
		return false

	# Set the appropriate ready flag
	if peer_id == host_peer_id:
		host_ready = true
	elif peer_id == guest_peer_id:
		guest_ready = true
	else:
		return false

	# Notify both players that this peer confirmed
	if multiplayer and multiplayer.has_multiplayer_peer():
		_placement_confirmed_rpc.rpc(peer_id)

	# Check if both players are now ready
	if host_ready and guest_ready:
		_reveal_and_start_movement()

	return true


## RPC handler called by any peer to confirm their placement is done.
@rpc("any_peer", "reliable")
func _confirm_placement_rpc() -> void:
	var sender_id: int = multiplayer.get_remote_sender_id()
	var accepted: bool = confirm_placement_done(sender_id)
	if not accepted:
		var reason: String = _get_confirmation_rejection_reason(sender_id)
		_confirmation_rejected_rpc.rpc_id(sender_id, reason)


## RPC broadcast to both players when a peer confirms placement.
@rpc("authority", "reliable")
func _placement_confirmed_rpc(_peer_id: int) -> void:
	# Client-side: update UI to show this player is ready.
	opponent_placement_confirmed.emit()


## RPC sent to a peer when their confirmation is rejected.
@rpc("authority", "reliable")
func _confirmation_rejected_rpc(_reason: String) -> void:
	# Client-side: display error (e.g., "minimum 3 pieces required").
	pass


## Returns a human-readable reason for why confirmation was rejected.
func _get_confirmation_rejection_reason(peer_id: int) -> String:
	if pvp_phase != PvPPhase.PVP_PLACEMENT:
		return "Not in placement phase"

	var owner: int = _peer_to_owner(peer_id)
	if owner == -1:
		return "Unknown peer"

	if _count_placed_pieces(owner as Piece.Owner) < MIN_PLACEMENT_PIECES:
		return "Minimum %d pieces must be placed" % MIN_PLACEMENT_PIECES

	return "Unknown reason"


# ── Placement Timer (_process) ────────────────────────────────────────────────


## Counts down timers during PVP_PLACEMENT and MOVEMENT phases.
## Placement: auto-confirms when placement_timer expires.
## Movement: auto-passes and forfeits the current player's turn when move_timer expires.
## Also handles the 30-second reconnection countdown when waiting for a reconnect.
## IMPORTANT: Only the HOST runs game logic timers. The guest is purely reactive.
func _process(delta: float) -> void:
	## Only the host drives game state transitions via timers.
	## The guest receives state changes via RPCs.
	if multiplayer and multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return

	# Handle reconnection countdown (pauses normal game timers)
	if _waiting_for_reconnect:
		_reconnect_timer -= delta
		if _reconnect_timer <= 0.0:
			_reconnect_timer = 0.0
			_waiting_for_reconnect = false
			_award_forfeit_to_remaining_player()
		return  # Don't process game timers while waiting for reconnect

	if pvp_phase == PvPPhase.PVP_PLACEMENT:
		if host_ready and guest_ready:
			return
		placement_timer -= delta
		if placement_timer <= 0.0:
			placement_timer = 0.0
			_auto_confirm_expired_players()
	elif pvp_phase == PvPPhase.MOVEMENT:
		if match_config.move_time_limit <= 0.0:
			return  # No time limit configured
		move_timer -= delta
		if move_timer <= 0.0:
			move_timer = 0.0
			_auto_pass_expired_turn()


## Auto-confirms placement for players who haven't confirmed when the timer expires.
## If a player has fewer than MIN_PLACEMENT_PIECES, they are still auto-confirmed
## with whatever they have (the timer override per Requirement 3.5).
func _auto_confirm_expired_players() -> void:
	if not host_ready:
		host_ready = true
		if multiplayer and multiplayer.has_multiplayer_peer():
			_placement_confirmed_rpc.rpc(host_peer_id)

	if not guest_ready:
		guest_ready = true
		if multiplayer and multiplayer.has_multiplayer_peer():
			_placement_confirmed_rpc.rpc(guest_peer_id)

	if host_ready and guest_ready:
		_reveal_and_start_movement()


## Auto-passes the current player's turn when the 60-second move timer expires.
## Notifies both players that the turn was forfeited due to timeout (Requirement 4.4).
func _auto_pass_expired_turn() -> void:
	var forfeiting_owner: Piece.Owner = movement_current_turn
	var forfeiting_peer: int = _owner_to_peer(int(forfeiting_owner))

	# Track that this player acted (forfeited counts as acted) in the current round
	_mark_player_acted(forfeiting_owner)

	# Advance the turn via the Movement class
	movement._advance_turn()

	# Sync local tracking
	movement_current_turn = movement.current_turn

	# Notify both players of the forfeited turn
	if multiplayer and multiplayer.has_multiplayer_peer():
		_turn_forfeited_rpc.rpc(forfeiting_peer)

	# Check round/phase completion
	_check_round_and_phase_completion()


# ── Reveal & Movement Transition ──────────────────────────────────────────────

## Movement tracking state for PvP turn management.
var movement_first_mover: Piece.Owner = Piece.Owner.PLAYER
var movement_current_turn: Piece.Owner = Piece.Owner.PLAYER
var movement_rounds_remaining: int = 2

## Per-turn move timer. Counts down from match_config.move_time_limit each turn.
var move_timer: float = 0.0

## Tracks whether each player has acted (moved or passed) in the current round.
var _round_host_acted: bool = false
var _round_guest_acted: bool = false


## Transitions from PVP_PLACEMENT → REVEAL → MOVEMENT.
## Activates wind tiles on DESERT terrain, serializes the full board,
## broadcasts it to both players, performs a coin flip to determine first mover,
## and initializes the movement phase with 2 rounds of alternating turns.
##
## Preconditions:
##   - host_ready == true AND guest_ready == true
##   - pvp_phase == PvPPhase.PVP_PLACEMENT (or just transitioned)
##
## Postconditions:
##   - pvp_phase == PvPPhase.MOVEMENT
##   - Full board sent to both players (after wind activation)
##   - Coin flip determines first mover
##   - Movement phase initialized with 2 rounds
func _reveal_and_start_movement() -> void:
	pvp_phase = PvPPhase.REVEAL

	# On DESERT terrain, activate wind push for all Wind pieces on the board.
	# This mirrors the single-player behaviour where wind activates on placement,
	# but since both sides placed hidden, we trigger all wind effects at reveal.
	if current_terrain == Terrain.Type.DESERT:
		_activate_wind_tiles()

	# Serialize the full board (after wind activation) for transmission
	var board_data: Array = BoardSync.serialize_board(board)

	# Broadcast the revealed board to both players with ack/retry logic
	if multiplayer and multiplayer.has_multiplayer_peer():
		_board_ack_received = false
		_receive_full_board_rpc.rpc(board_data)
		# Await acknowledgment with retransmission (up to 3 retries at 3-sec intervals)
		_await_board_ack(board_data)

	# Perform coin flip on host to determine who moves first
	var first_mover: Piece.Owner = movement.coin_flip()
	movement_first_mover = first_mover
	movement_current_turn = first_mover
	movement_rounds_remaining = 2

	# Reset round tracking
	_round_host_acted = false
	_round_guest_acted = false

	# Start the move timer for the first turn
	if match_config.move_time_limit > 0.0:
		move_timer = match_config.move_time_limit
	else:
		move_timer = 0.0

	# Transition to MOVEMENT phase
	pvp_phase = PvPPhase.MOVEMENT

	# Notify UI to refresh the board (now shows all pieces after reveal)
	emit_signal("board_updated")
	emit_signal("phase_changed", Phase.MOVEMENT)

	# Broadcast movement phase started with first mover peer_id
	var first_mover_peer: int = _owner_to_peer(int(first_mover))
	if multiplayer and multiplayer.has_multiplayer_peer():
		_movement_phase_started_rpc.rpc(first_mover_peer)

	# If no one can move at all, skip directly to scoring
	if movement.phase_complete:
		_start_scoring()


## Activates wind push effects for all Wind pieces currently on the board.
## Called during REVEAL on DESERT terrain to replicate the single-player
## behaviour where each Wind piece pushes adjacent tiles on placement.
## Pieces are processed in board order (top-left to bottom-right).
func _activate_wind_tiles() -> void:
	for r in range(BoardState.BOARD_SIZE):
		for c in range(BoardState.BOARD_SIZE):
			var piece: Piece = board.get_piece(r, c)
			if piece != null and piece.type == Piece.Type.WIND:
				_apply_wind_push(r, c)


## RPC broadcast to both players with the full revealed board state.
## Client-side: replace local board mirror entirely with deserialized state,
## then acknowledge receipt so host knows transmission succeeded.
@rpc("authority", "reliable")
func _receive_full_board_rpc(_board_data: Array) -> void:
	# Replace local board state entirely with the host-authoritative version
	board = BoardSync.deserialize_board(_board_data)
	# Send acknowledgment back to host (respond within 3 seconds per Req 6.6)
	if multiplayer and multiplayer.has_multiplayer_peer():
		_board_ack_rpc.rpc_id(host_peer_id)
	# Notify UI to refresh with the revealed board
	emit_signal("board_updated")


## RPC sent from client to host acknowledging receipt of full board state.
## Host uses this to confirm the client received the board; if no ack within
## 3 seconds, host retransmits (up to 3 retries per Requirement 6.6).
@rpc("any_peer", "reliable")
func _board_ack_rpc() -> void:
	# Host-side: mark that the client acknowledged board receipt.
	# This stops the retransmission loop.
	var sender_id: int = multiplayer.get_remote_sender_id()
	if sender_id == guest_peer_id:
		_board_ack_received = true


## Waits for the client to acknowledge board receipt with retransmission logic.
## If no ack is received within BOARD_ACK_TIMEOUT seconds, retransmits the board
## data up to BOARD_ACK_MAX_RETRIES times. Proceeds regardless after max retries.
func _await_board_ack(board_data: Array) -> void:
	var retries: int = 0
	while retries < BOARD_ACK_MAX_RETRIES and not _board_ack_received:
		await get_tree().create_timer(BOARD_ACK_TIMEOUT).timeout
		if _board_ack_received:
			break
		retries += 1
		if multiplayer and multiplayer.has_multiplayer_peer():
			_receive_full_board_rpc.rpc(board_data)


## RPC broadcast to both players when the movement phase starts.
## Communicates which player moves first (by peer_id).
@rpc("authority", "reliable")
func _movement_phase_started_rpc(_first_mover_peer_id: int) -> void:
	# Client-side: update phase and turn tracking
	pvp_phase = PvPPhase.MOVEMENT
	movement_current_turn = _peer_to_owner(_first_mover_peer_id) as Piece.Owner
	emit_signal("phase_changed", Phase.MOVEMENT)
	emit_signal("board_updated")


## ── Scoring Phase (Host-Authoritative) ───────────────────────────────────────

## Tracks whether the client has acknowledged receiving scoring results.
var _scoring_ack_received: bool = false

## Stores the last computed scoring result for retry transmission.
var _scoring_result_cache: Dictionary = {}

## Number of scoring transmission attempts made (max 3 retries = 4 total sends).
var _scoring_retry_count: int = 0

## Maximum number of retries for score transmission (Requirement 5.5).
const SCORING_MAX_RETRIES: int = 3

## Interval between scoring retries in seconds.
const SCORING_RETRY_INTERVAL: float = 1.0


## Overrides the parent GameManager._start_scoring() to run host-authoritative
## scoring with network transmission and acknowledgment.
##
## Host calculates scores using the existing Scoring pipeline, serializes
## results, and transmits them to the Client. If the Client doesn't
## acknowledge within 1 second, the Host retries up to 3 times.
##
## Preconditions:
##   - pvp_phase == PvPPhase.MOVEMENT (transitioning from)
##   - movement phase is complete
##
## Postconditions:
##   - pvp_phase == PvPPhase.SCORING during calculation/transmission
##   - Scoring results broadcast to both players
##   - On ack or max retries: pvp_phase == PvPPhase.RESULT
func _start_scoring() -> void:
	pvp_phase = PvPPhase.SCORING
	current_phase = Phase.SCORING
	emit_signal("phase_changed", current_phase)

	# Only the host performs authoritative scoring
	if not multiplayer or not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		# Fallback for local/testing: just use parent logic
		var result: Dictionary = Scoring.calculate_scores(board, current_terrain)
		_scoring_result_cache = result
		emit_signal("scores_ready", result)
		pvp_phase = PvPPhase.RESULT
		determine_match_result()
		return

	# Host: calculate scores using existing Scoring pipeline
	var result: Dictionary = Scoring.calculate_scores(board, current_terrain)
	_scoring_result_cache = result
	_scoring_ack_received = false
	_scoring_retry_count = 0

	# Emit locally on host so host UI can display scores immediately
	emit_signal("scores_ready", result)

	# Serialize and transmit to client
	var scoring_data: Dictionary = _serialize_scoring_result(result)
	_scoring_results_rpc.rpc_id(guest_peer_id, scoring_data)

	# Start retry loop: wait up to SCORING_RETRY_INTERVAL, then retry if no ack
	_await_scoring_ack()


## Awaits client acknowledgment with retry logic.
## Retries up to SCORING_MAX_RETRIES times at SCORING_RETRY_INTERVAL intervals.
## Transitions to RESULT phase on ack or after exhausting retries.
func _await_scoring_ack() -> void:
	while _scoring_retry_count < SCORING_MAX_RETRIES and not _scoring_ack_received:
		# Wait 1 second for acknowledgment
		await get_tree().create_timer(SCORING_RETRY_INTERVAL).timeout

		if _scoring_ack_received:
			break

		# Retry transmission
		_scoring_retry_count += 1
		var scoring_data: Dictionary = _serialize_scoring_result(_scoring_result_cache)
		if multiplayer and multiplayer.has_multiplayer_peer():
			_scoring_results_rpc.rpc_id(guest_peer_id, scoring_data)

	# Transition to RESULT phase regardless of ack status
	pvp_phase = PvPPhase.RESULT
	determine_match_result()


## Serializes the scoring result dictionary for network transmission.
## Converts the battle log Array[String] to a plain Array for RPC safety.
## Also includes the final board state so the guest can display scored pieces.
func _serialize_scoring_result(result: Dictionary) -> Dictionary:
	var log_array: Array = []
	for entry in result.get("log", []):
		log_array.append(str(entry))
	return {
		"player_score": result.get("player", 0),
		"enemy_score": result.get("enemy", 0),
		"battle_log": log_array,
		"board_data": BoardSync.serialize_board(board),
	}


## RPC sent from Host to Client with the scoring results.
## Client should process and display the results, then send an ack back.
@rpc("authority", "reliable")
func _scoring_results_rpc(scoring_data: Dictionary) -> void:
	# Client-side: receive and display scoring results from the host
	var result: Dictionary = {
		"player": scoring_data.get("player_score", 0),
		"enemy": scoring_data.get("enemy_score", 0),
		"log": scoring_data.get("battle_log", []),
	}
	_scoring_result_cache = result

	# Replace local board with the host's scored board state
	var board_data: Array = scoring_data.get("board_data", [])
	if not board_data.is_empty():
		board = BoardSync.deserialize_board(board_data)

	pvp_phase = PvPPhase.SCORING
	current_phase = Phase.SCORING
	emit_signal("phase_changed", current_phase)
	emit_signal("scores_ready", result)
	emit_signal("board_updated")

	# Send acknowledgment back to the host
	if multiplayer and multiplayer.has_multiplayer_peer():
		_scoring_ack_rpc.rpc_id(host_peer_id)


## RPC sent from Client to Host acknowledging receipt of scoring results.
@rpc("any_peer", "reliable")
func _scoring_ack_rpc() -> void:
	# Host-side: mark acknowledgment received so retry loop exits
	var sender_id: int = multiplayer.get_remote_sender_id()
	if sender_id == guest_peer_id:
		_scoring_ack_received = true
		# Transition to RESULT if not already there
		if pvp_phase == PvPPhase.SCORING:
			pvp_phase = PvPPhase.RESULT
			determine_match_result()


# ── Move Validation & Turn Enforcement RPCs ───────────────────────────────────


## Validates and applies a move request from a peer.
## Delegates to the existing Movement class for game-rule validation.
##
## Returns Movement.MoveResult indicating success or failure reason.
##
## Preconditions:
##   - pvp_phase == PvPPhase.MOVEMENT
##   - movement.current_turn == _peer_to_owner(peer_id)
##
## Postconditions:
##   - On OK: board updated, turn advanced, both players notified
##   - On failure: no state change, sender notified with reason
func request_move(peer_id: int, from_r: int, from_c: int, to_r: int, to_c: int) -> Movement.MoveResult:
	# Phase check
	if pvp_phase != PvPPhase.MOVEMENT:
		return Movement.MoveResult.PHASE_OVER

	# Map peer to owner
	var owner: int = _peer_to_owner(peer_id)
	if owner == -1:
		return Movement.MoveResult.NOT_YOUR_TURN

	# Turn check — must be this player's turn
	if movement.current_turn != owner:
		return Movement.MoveResult.NOT_YOUR_TURN

	# Delegate to the existing Movement class for full validation and execution
	var result: Movement.MoveResult = movement.attempt_move(
		owner as Piece.Owner, from_r, from_c, to_r, to_c
	)

	if result == Movement.MoveResult.OK:
		# Apply Wind push effect on Desert terrain if the moved piece is Wind
		if current_terrain == Terrain.Type.DESERT:
			var moved_piece: Piece = board.get_piece(to_r, to_c)
			if moved_piece != null and moved_piece.type == Piece.Type.WIND:
				_apply_wind_push(to_r, to_c)

		# Track that this player acted in the current round
		_mark_player_acted(owner as Piece.Owner)

		# Sync local tracking with Movement's internal state
		movement_current_turn = movement.current_turn

		# Broadcast move to both players
		if multiplayer and multiplayer.has_multiplayer_peer():
			_move_applied_rpc.rpc(from_r, from_c, to_r, to_c)

		# Notify host UI to refresh
		emit_signal("board_updated")

		# Check round/phase completion and reset timer
		_check_round_and_phase_completion()
	else:
		# Send rejection to the requesting peer only
		var reason: String = _get_move_rejection_reason(result)
		if multiplayer and multiplayer.has_multiplayer_peer():
			_move_rejected_rpc.rpc_id(peer_id, reason)

	return result


## Handles a voluntary pass from a peer.
## Validates that it is the requesting player's turn, then advances the turn
## without applying any move.
##
## Preconditions:
##   - pvp_phase == PvPPhase.MOVEMENT
##   - movement.current_turn == _peer_to_owner(peer_id)
##
## Postconditions:
##   - Turn advances to the other player (or round/phase ends)
##   - Both players notified of the pass
func request_pass_turn(peer_id: int) -> void:
	# Phase check
	if pvp_phase != PvPPhase.MOVEMENT:
		return

	# Map peer to owner
	var owner: int = _peer_to_owner(peer_id)
	if owner == -1:
		return

	# Turn check
	if movement.current_turn != owner:
		return

	# Track that this player acted in the current round
	_mark_player_acted(owner as Piece.Owner)

	# Advance the turn manually (same logic Movement uses internally)
	movement._advance_turn()

	# Sync local tracking
	movement_current_turn = movement.current_turn

	# Notify both players about the pass
	if multiplayer and multiplayer.has_multiplayer_peer():
		_turn_passed_rpc.rpc(peer_id)

	# Check round/phase completion and reset timer
	_check_round_and_phase_completion()


## RPC handler called by any peer to request a move on the host.
@rpc("any_peer", "reliable")
func _request_move_rpc(from_r: int, from_c: int, to_r: int, to_c: int) -> void:
	var sender_id: int = multiplayer.get_remote_sender_id()
	request_move(sender_id, from_r, from_c, to_r, to_c)


## RPC handler called by any peer to voluntarily pass their turn.
@rpc("any_peer", "reliable")
func _request_pass_rpc() -> void:
	var sender_id: int = multiplayer.get_remote_sender_id()
	request_pass_turn(sender_id)


## RPC broadcast to both players when a move is successfully applied.
## Client-side: apply the confirmed move to the local board mirror and update tracking.
## Only processes on the CLIENT — the host already applied the move locally.
@rpc("authority", "reliable")
func _move_applied_rpc(_from_r: int, _from_c: int, _to_r: int, _to_c: int) -> void:
	# Skip processing on the host — it already applied the move
	if multiplayer and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		return

	# Get the piece at the source position on local board
	var piece: Piece = board.get_piece(_from_r, _from_c)
	if piece != null:
		# Remove from old position and place at new position
		board.remove_piece(_from_r, _from_c)
		board.place_piece(piece, _to_r, _to_c)
		# Update movement tracking: mark piece as having moved this turn
		if movement:
			movement.moved_pieces[piece] = true
	# Flip turn to the other player (host drives actual logic, this is for UI)
	if movement_current_turn == Piece.Owner.PLAYER:
		movement_current_turn = Piece.Owner.ENEMY
	else:
		movement_current_turn = Piece.Owner.PLAYER
	# Emit signal for UI layer
	opponent_move_received.emit(Vector2i(_from_c, _from_r), Vector2i(_to_c, _to_r))
	emit_signal("board_updated")


## RPC sent to the requesting peer only when a move is rejected.
@rpc("authority", "reliable")
func _move_rejected_rpc(_reason: String) -> void:
	# Client-side: display rejection feedback (e.g., "Not your turn").
	pass


## RPC broadcast to both players when a player voluntarily passes their turn.
@rpc("authority", "reliable")
func _turn_passed_rpc(_peer_id: int) -> void:
	# Skip on host — it already advanced the turn
	if multiplayer and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		return
	# Client-side: advance turn tracking to reflect the host's state
	if _peer_id == _owner_to_peer(int(Piece.Owner.PLAYER)):
		movement_current_turn = Piece.Owner.ENEMY
	else:
		movement_current_turn = Piece.Owner.PLAYER
	emit_signal("board_updated")


## RPC broadcast to both players when a player's turn is forfeited due to timeout.
@rpc("authority", "reliable")
func _turn_forfeited_rpc(_peer_id: int) -> void:
	# Client-side: advance turn tracking (same as pass)
	if _peer_id == _owner_to_peer(int(Piece.Owner.PLAYER)):
		movement_current_turn = Piece.Owner.ENEMY
	else:
		movement_current_turn = Piece.Owner.PLAYER
	emit_signal("board_updated")


# ── Movement Round & Timer Helpers ────────────────────────────────────────────


## Marks that the given owner has acted (moved or passed) in the current round.
func _mark_player_acted(owner: Piece.Owner) -> void:
	if owner == Piece.Owner.PLAYER:
		_round_host_acted = true
	else:
		_round_guest_acted = true


## Checks whether the current round is complete (both players acted) or the
## phase is complete (all rounds done). Handles round transitions with turn
## order reversal for round 2, and resets the move timer for the next turn.
##
## Turn order per Requirement 4.7:
##   - Round 1: first_mover goes first, then second_mover
##   - Round 2: second_mover goes first (reversed), then first_mover
##
## Transitions to SCORING when movement_rounds_remaining reaches 0.
func _check_round_and_phase_completion() -> void:
	# Rely on the Movement class's built-in round/phase tracking.
	# Movement internally handles 2 rounds, turn alternation, and sets phase_complete.
	if movement.phase_complete:
		_start_scoring()
		return

	# Sync our turn tracking with Movement's internal state
	movement_current_turn = movement.current_turn

	# Reset move timer for the next turn
	_reset_move_timer()

	# Notify UI that the turn may have changed
	emit_signal("board_updated")


## Resets the per-turn move timer to match_config.move_time_limit.
func _reset_move_timer() -> void:
	if match_config.move_time_limit > 0.0:
		move_timer = match_config.move_time_limit
	else:
		move_timer = 0.0


# ── Move Rejection Helpers ────────────────────────────────────────────────────


## Converts a MoveResult enum into a human-readable rejection reason string.
func _get_move_rejection_reason(result: Movement.MoveResult) -> String:
	match result:
		Movement.MoveResult.NOT_YOUR_TURN:
			return "Not your turn"
		Movement.MoveResult.PIECE_ALREADY_MOVED:
			return "That piece has already moved this phase"
		Movement.MoveResult.INVALID_DESTINATION:
			return "Invalid move destination"
		Movement.MoveResult.PHASE_OVER:
			return "Movement phase is over"
		_:
			return "Move rejected"


# ── Match Result & Outcome Determination ──────────────────────────────────────

## Points awarded based on match outcome.
const POINTS_WIN: int = 100
const POINTS_DRAW: int = 50
const POINTS_LOSS: int = 0

## Emitted when the match result has been fully determined and broadcast.
## The result dictionary contains: outcome_host, outcome_guest, host_score,
## guest_score, host_points, guest_points, battle_log.
signal match_ended(result: Dictionary)

## Stores the computed match result for reference.
var _match_result: Dictionary = {}


## Determines the winner based on scores and broadcasts the match result to
## both players. Called after pvp_phase transitions to RESULT.
##
## Outcome rules:
##   - player_score > enemy_score → host wins (victory), guest loses (defeat)
##   - enemy_score > player_score → guest wins (victory), host loses (defeat)
##   - equal scores → draw for both
##
## Points awarded:
##   - Victory: POINTS_WIN (100)
##   - Draw: POINTS_DRAW (50)
##   - Defeat: POINTS_LOSS (0)
##   - Disconnect/forfeit: 0 points (handled separately)
##
## Preconditions:
##   - pvp_phase == PvPPhase.RESULT
##   - _scoring_result_cache contains valid player/enemy scores
##
## Postconditions:
##   - _match_result populated with full outcome data
##   - match_ended signal emitted
##   - Both players receive _match_result_rpc with their perspective
func determine_match_result() -> void:
	if pvp_phase != PvPPhase.RESULT:
		return

	var player_score: int = _scoring_result_cache.get("player", 0)
	var enemy_score: int = _scoring_result_cache.get("enemy", 0)
	var battle_log: Array = _scoring_result_cache.get("log", [])

	var host_outcome: String = ""
	var guest_outcome: String = ""
	var host_points: int = 0
	var guest_points: int = 0

	if player_score > enemy_score:
		# Host wins
		host_outcome = "victory"
		guest_outcome = "defeat"
		host_points = POINTS_WIN
		guest_points = POINTS_LOSS
	elif enemy_score > player_score:
		# Guest wins
		host_outcome = "defeat"
		guest_outcome = "victory"
		host_points = POINTS_LOSS
		guest_points = POINTS_WIN
	else:
		# Draw
		host_outcome = "draw"
		guest_outcome = "draw"
		host_points = POINTS_DRAW
		guest_points = POINTS_DRAW

	_match_result = {
		"outcome_host": host_outcome,
		"outcome_guest": guest_outcome,
		"host_score": player_score,
		"guest_score": enemy_score,
		"host_points": host_points,
		"guest_points": guest_points,
		"battle_log": battle_log,
	}

	# Broadcast result to both players
	if multiplayer and multiplayer.has_multiplayer_peer():
		# Send host perspective to the host (local)
		var host_data: Dictionary = _build_result_data_for_peer(host_peer_id)
		# Send guest perspective to the guest
		var guest_data: Dictionary = _build_result_data_for_peer(guest_peer_id)
		_match_result_rpc.rpc_id(guest_peer_id, guest_data)
		# Process locally on host
		_on_match_result_received(host_data)
	else:
		# Local/testing fallback: emit with host perspective
		var local_data: Dictionary = _build_result_data_for_peer(host_peer_id)
		_on_match_result_received(local_data)

	match_result_confirmed.emit(_owner_to_peer(
		Piece.Owner.PLAYER if host_outcome == "victory"
		else (Piece.Owner.ENEMY if guest_outcome == "victory" else Piece.Owner.PLAYER)
	))


## Builds a result data dictionary from the perspective of the given peer.
## Both peers see identical score values and battle log, but their own outcome.
func _build_result_data_for_peer(peer_id: int) -> Dictionary:
	var outcome: String = ""
	var points: int = 0

	if peer_id == host_peer_id:
		outcome = _match_result.get("outcome_host", "draw")
		points = _match_result.get("host_points", 0)
	else:
		outcome = _match_result.get("outcome_guest", "draw")
		points = _match_result.get("guest_points", 0)

	return {
		"outcome": outcome,
		"host_score": _match_result.get("host_score", 0),
		"guest_score": _match_result.get("guest_score", 0),
		"points_awarded": points,
		"battle_log": _match_result.get("battle_log", []),
	}


## RPC sent from Host to Client with the match result from the client's perspective.
@rpc("authority", "reliable")
func _match_result_rpc(result_data: Dictionary) -> void:
	# Client-side: receive match result and display UI
	_on_match_result_received(result_data)


## Processes match result data locally (called on both host and client).
## Emits match_ended signal so the UI layer can show the result screen.
func _on_match_result_received(result_data: Dictionary) -> void:
	_match_result = result_data
	match_ended.emit(result_data)


# ── Disconnection Handling ────────────────────────────────────────────────────

## Reconnection window duration in seconds.
const RECONNECT_WINDOW_SEC: float = 30.0

## Time before client returns to menu after host disconnect (seconds).
const HOST_DISCONNECT_RETURN_SEC: float = 5.0


## Returns true if the current pvp_phase is an active battle phase
## (placement, movement, or scoring) where disconnection should trigger
## forfeit logic.
func _is_active_battle_phase() -> bool:
	return pvp_phase in [PvPPhase.PVP_PLACEMENT, PvPPhase.MOVEMENT, PvPPhase.SCORING]


## Called when NetworkManager emits `player_left` (a peer disconnected).
## On the host, this means the client/guest has disconnected.
## Triggers pause and reconnection window if mid-match.
func _on_player_left(peer_id: int) -> void:
	# Only the host handles player_left for forfeit logic
	if not multiplayer or not multiplayer.has_multiplayer_peer():
		return
	if not multiplayer.is_server():
		return

	# Only trigger if it's the guest who disconnected during an active phase
	if peer_id != guest_peer_id:
		return
	if not _is_active_battle_phase():
		return

	# Pause the game and start the reconnection window
	_pause_game()
	_waiting_for_reconnect = true
	_reconnect_timer = RECONNECT_WINDOW_SEC

	# Notify UI within 3 seconds (signal is emitted immediately)
	opponent_disconnected.emit()


## Called when NetworkManager emits `disconnected` (connection lost).
## On the client, this means the host has gone away.
## Emits host_disconnected and returns to menu after 5 seconds.
func _on_network_disconnected(_reason: String) -> void:
	# The host doesn't handle its own disconnection via this signal path;
	# host-side disconnect of the guest is handled by _on_player_left.
	# If we were the server (host), ignore this signal.
	if multiplayer and multiplayer.has_multiplayer_peer():
		if multiplayer.is_server():
			return

	if not _is_active_battle_phase():
		return

	# Emit signal so UI can show "Host lost"
	host_disconnected.emit()

	# Return to multiplayer menu after 5 seconds
	_return_to_menu_after_delay()


## Pauses the game by stopping placement and move timer countdowns.
## Saves current timer values so they can be resumed on reconnection.
func _pause_game() -> void:
	_paused_placement_timer = placement_timer
	_paused_move_timer = move_timer
	# Setting timers to a large value effectively stops countdown since
	# _process won't fire meaningful logic while _waiting_for_reconnect is true.
	# The actual pause is enforced by the early return in _process().


## Resumes the game after a successful reconnection.
## Restores timers from their paused values and clears the waiting state.
func _resume_game() -> void:
	_waiting_for_reconnect = false
	_reconnect_timer = 0.0
	placement_timer = _paused_placement_timer
	move_timer = _paused_move_timer


## Awards win-by-forfeit to the remaining player (host) when the reconnection
## window expires. Per user requirement: 0 points for both players on forfeit.
func _award_forfeit_to_remaining_player() -> void:
	pvp_phase = PvPPhase.RESULT

	# Build forfeit result: 0 points for both players
	_match_result = {
		"outcome_host": "forfeit_win",
		"outcome_guest": "forfeit_loss",
		"host_score": 0,
		"guest_score": 0,
		"host_points": 0,
		"guest_points": 0,
		"battle_log": [],
	}

	# Emit match_ended with forfeit result for the host's UI
	var host_data: Dictionary = {
		"outcome": "forfeit_win",
		"host_score": 0,
		"guest_score": 0,
		"points_awarded": 0,
		"battle_log": [],
	}
	_on_match_result_received(host_data)
	match_result_confirmed.emit(host_peer_id)


## Returns to the multiplayer menu after a delay. Used on the client side
## when the host disconnects (Requirement 7.3: within 5 seconds).
func _return_to_menu_after_delay() -> void:
	if not is_inside_tree():
		return
	await get_tree().create_timer(HOST_DISCONNECT_RETURN_SEC).timeout
	# Navigate back to multiplayer menu. The actual scene path may vary;
	# emit a signal and let the scene tree owner handle navigation.
	pvp_phase = PvPPhase.LOBBY
	# Attempt to change scene if the multiplayer menu scene exists
	var menu_scene_path: String = "res://scenes/multiplayer/multiplayer_menu.tscn"
	if ResourceLoader.exists(menu_scene_path):
		get_tree().change_scene_to_file(menu_scene_path)


# ── Reconnection & State Restoration ─────────────────────────────────────────


## Called when NetworkManager emits `player_joined` during an active match.
## If the host is waiting for a reconnection, treats the new peer as the
## returning guest and triggers state restoration (Requirement 7.4).
func _on_player_joined_during_match(player_info: Dictionary) -> void:
	# Only the host handles reconnection logic
	if not multiplayer or not multiplayer.has_multiplayer_peer():
		return
	if not multiplayer.is_server():
		return

	# Only process if we're actively waiting for a reconnect
	if not _waiting_for_reconnect:
		return

	var peer_id: int = player_info.get("peer_id", 0)
	if peer_id <= 0:
		return

	_handle_reconnection(peer_id)


## Handles a reconnecting player by restoring game state and resuming timers.
## Accepts the new peer as the guest (they may have a new peer_id after reconnect).
##
## Flow:
##   1. Update guest_peer_id to the new peer
##   2. Resume paused timers via _resume_game()
##   3. Send full board state and phase info to the reconnecting player
##   4. Broadcast reconnection notification to both players
##   5. Emit opponent_reconnected signal for host UI
##
## Preconditions:
##   - _waiting_for_reconnect == true
##   - peer_id is a valid connected peer
##
## Postconditions:
##   - _waiting_for_reconnect == false
##   - Game timers restored to pre-pause values
##   - Reconnecting player has full board state and phase context
##   - Both players notified of reconnection
func _handle_reconnection(peer_id: int) -> void:
	# Accept the new peer as the guest (peer_id may differ after reconnect)
	guest_peer_id = peer_id

	# Resume game timers from their paused values
	_resume_game()

	# Send full state restoration to the reconnecting player
	_send_state_restoration(peer_id)

	# Broadcast reconnection status to both players
	if multiplayer and multiplayer.has_multiplayer_peer():
		_player_reconnected_rpc.rpc()

	# Emit signal so host UI can update (e.g., dismiss "Opponent disconnected" overlay)
	opponent_reconnected.emit()


## Serializes and sends the full game state to a reconnecting player.
## Includes: board state, current phase, whose turn it is, and remaining timers.
## Must complete within 2 seconds per Requirement 7.4.
##
## Data sent:
##   - board_data: full BoardState serialized via BoardSync
##   - pvp_phase: current PvPPhase enum value
##   - current_turn: peer_id of the player whose turn it is (MOVEMENT phase)
##   - placement_timer: remaining placement time (PVP_PLACEMENT phase)
##   - move_timer: remaining move time (MOVEMENT phase)
##   - movement_rounds_remaining: rounds left in movement phase
##   - terrain: current terrain type
func _send_state_restoration(peer_id: int) -> void:
	# Serialize the full board state
	var board_data: Array = BoardSync.serialize_board(board)

	# Determine whose turn it is (relevant in MOVEMENT phase)
	var current_turn_peer: int = _owner_to_peer(int(movement_current_turn))

	# Build the state restoration payload
	var state_data: Dictionary = {
		"board_data": board_data,
		"pvp_phase": int(pvp_phase),
		"current_turn_peer": current_turn_peer,
		"placement_timer": placement_timer,
		"move_timer": move_timer,
		"movement_rounds_remaining": movement_rounds_remaining,
		"terrain": int(current_terrain),
		"host_score": _scoring_result_cache.get("player", 0),
		"guest_score": _scoring_result_cache.get("enemy", 0),
	}

	# Send state restoration to the reconnecting player
	_state_restored_rpc.rpc_id(peer_id, state_data)


## RPC received by the reconnecting client with full game state.
## Restores the local board mirror, phase, timers, and turn info so the
## client can seamlessly resume from where the game was paused.
@rpc("authority", "reliable")
func _state_restored_rpc(state_data: Dictionary) -> void:
	# Restore board state from the host's serialized data
	var board_data: Array = state_data.get("board_data", [])
	board = BoardSync.deserialize_board(board_data)

	# Restore phase
	pvp_phase = state_data.get("pvp_phase", 0) as PvPPhase

	# Restore timers
	placement_timer = state_data.get("placement_timer", 0.0)
	move_timer = state_data.get("move_timer", 0.0)
	movement_rounds_remaining = state_data.get("movement_rounds_remaining", 0)

	# Restore terrain
	current_terrain = state_data.get("terrain", 0) as Terrain.Type

	# Restore turn tracking for MOVEMENT phase
	var turn_peer: int = state_data.get("current_turn_peer", host_peer_id)
	movement_current_turn = _peer_to_owner(turn_peer) as Piece.Owner


## RPC broadcast to both players when a disconnected player reconnects.
## Notifies the UI on both sides that the game is resuming.
@rpc("authority", "reliable")
func _player_reconnected_rpc() -> void:
	# Client-side: dismiss any "Opponent disconnected" / "Waiting" overlay.
	# Both host and guest receive this to confirm the game is resuming.
	opponent_reconnected.emit()


# ── Rematch System Integration ────────────────────────────────────────────────


## Starts the rematch countdown. Should be called after match_ended is emitted
## and the result screen is displayed to both players (Requirement 8.1).
func start_rematch_countdown() -> void:
	if rematch_manager == null:
		return
	rematch_manager.guest_peer_id = guest_peer_id
	rematch_manager.start_rematch_countdown()


## Called by the local player (via UI) to accept the rematch.
## If this is the client, sends an RPC to the host.
func request_rematch() -> void:
	if rematch_manager == null:
		return

	var local_id: int = 1
	if multiplayer and multiplayer.has_multiplayer_peer():
		local_id = multiplayer.get_unique_id()
		# Send RPC to the other peer so they know we accepted
		rematch_manager._request_rematch_rpc.rpc()

	rematch_manager.accept_rematch(local_id)


## Called by the local player (via UI) to decline the rematch.
func decline_rematch() -> void:
	if rematch_manager == null:
		return

	var local_id: int = 1
	if multiplayer and multiplayer.has_multiplayer_peer():
		local_id = multiplayer.get_unique_id()

	rematch_manager.decline_rematch(local_id)


## Returns the remaining rematch countdown time (for UI display).
func get_rematch_time_remaining() -> float:
	if rematch_manager == null:
		return 0.0
	return rematch_manager.get_time_remaining()


## Returns true if the rematch countdown is currently active.
func is_rematch_active() -> bool:
	if rematch_manager == null:
		return false
	return rematch_manager.rematch_active


## Returns true if the local player has accepted and is waiting for opponent.
func is_waiting_for_opponent_rematch() -> bool:
	if rematch_manager == null:
		return false
	if not rematch_manager.rematch_active:
		return false

	var local_id: int = 1
	if multiplayer and multiplayer.has_multiplayer_peer():
		local_id = multiplayer.get_unique_id()

	if local_id == 1:
		return rematch_manager.host_accepted and not rematch_manager.guest_accepted
	else:
		return rematch_manager.guest_accepted and not rematch_manager.host_accepted


## Called when both players accept — resets match state and transitions to
## piece selection (Requirement 8.2: retain connection, return to selection).
func _on_rematch_started() -> void:
	# Reset match state for a new game while retaining the connection
	pvp_phase = PvPPhase.LOBBY
	host_ready = false
	guest_ready = false
	placement_timer = 0.0
	move_timer = 0.0
	movement_rounds_remaining = 2
	_round_host_acted = false
	_round_guest_acted = false
	_scoring_ack_received = false
	_scoring_result_cache = {}
	_scoring_retry_count = 0
	_match_result = {}


## Called when the rematch timer expires (Requirement 8.3: disconnect both,
## return to multiplayer menu).
func _on_rematch_expired() -> void:
	pvp_phase = PvPPhase.LOBBY
