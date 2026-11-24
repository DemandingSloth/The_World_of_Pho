class_name MultiplayerMenuUI
extends MarginContainer

## Multiplayer menu screen — allows the player to host or join a game.
## Connects to NetworkManager (autoload) for creating/joining servers.
## On successful connection, transitions to the lobby screen scene.

# ── Node references ───────────────────────────────────────────────────────────

@onready var title_label       : Label      = $VBox/TitleLabel
@onready var host_btn          : Button     = $VBox/HostBtn
@onready var join_btn          : Button     = $VBox/JoinBtn
@onready var back_btn          : Button     = $VBox/BackBtn

## Host panel
@onready var host_panel        : VBoxContainer = $VBox/HostPanel
@onready var host_port_input   : LineEdit      = $VBox/HostPanel/HostPortInput
@onready var host_confirm_btn  : Button        = $VBox/HostPanel/HostBtnRow/HostConfirmBtn
@onready var host_cancel_btn   : Button        = $VBox/HostPanel/HostBtnRow/HostCancelBtn

## Join panel
@onready var join_panel        : VBoxContainer = $VBox/JoinPanel
@onready var join_ip_input     : LineEdit      = $VBox/JoinPanel/JoinIpInput
@onready var join_port_input   : LineEdit      = $VBox/JoinPanel/JoinPortInput
@onready var join_confirm_btn  : Button        = $VBox/JoinPanel/JoinBtnRow/JoinConfirmBtn
@onready var join_cancel_btn   : Button        = $VBox/JoinPanel/JoinBtnRow/JoinCancelBtn

## Status / error display
@onready var error_label       : Label      = $VBox/ErrorLabel
@onready var status_label      : Label      = $VBox/StatusLabel

# ── Constants ─────────────────────────────────────────────────────────────────

const DEFAULT_PORT := "7000"
const DEFAULT_IP := "127.0.0.1"
const LOBBY_SCENE_PATH := "res://scenes/multiplayer/lobby_screen.tscn"

# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	## Ensure any previous connection is fully closed before showing menu
	## (handles cases where player returns to menu without proper disconnect)
	if NetworkManager.state != NetworkManager.ConnectionState.DISCONNECTED:
		NetworkManager.disconnect_from_match()

	## Button connections
	host_btn.pressed.connect(_on_host_pressed)
	join_btn.pressed.connect(_on_join_pressed)
	back_btn.pressed.connect(_on_back_pressed)
	host_confirm_btn.pressed.connect(_on_host_confirm)
	host_cancel_btn.pressed.connect(_on_host_cancel)
	join_confirm_btn.pressed.connect(_on_join_confirm)
	join_cancel_btn.pressed.connect(_on_join_cancel)

	## NetworkManager signal connections
	NetworkManager.connection_established.connect(_on_connection_established)
	NetworkManager.connection_failed.connect(_on_connection_failed)

	## Initial state — show main buttons, hide panels
	_show_main_menu()


func _exit_tree() -> void:
	## Disconnect signals to prevent errors if NetworkManager persists
	if NetworkManager.connection_established.is_connected(_on_connection_established):
		NetworkManager.connection_established.disconnect(_on_connection_established)
	if NetworkManager.connection_failed.is_connected(_on_connection_failed):
		NetworkManager.connection_failed.disconnect(_on_connection_failed)


# ── UI State Management ───────────────────────────────────────────────────────


func _show_main_menu() -> void:
	host_btn.visible = true
	join_btn.visible = true
	back_btn.visible = false
	host_panel.visible = false
	join_panel.visible = false
	error_label.text = ""
	status_label.text = ""
	_set_buttons_enabled(true)


func _show_host_panel() -> void:
	host_btn.visible = false
	join_btn.visible = false
	back_btn.visible = false
	host_panel.visible = true
	join_panel.visible = false
	host_port_input.text = DEFAULT_PORT
	error_label.text = ""
	status_label.text = ""


func _show_join_panel() -> void:
	host_btn.visible = false
	join_btn.visible = false
	back_btn.visible = false
	host_panel.visible = false
	join_panel.visible = true
	join_ip_input.text = DEFAULT_IP
	join_port_input.text = DEFAULT_PORT
	error_label.text = ""
	status_label.text = ""


func _set_buttons_enabled(enabled: bool) -> void:
	host_btn.disabled = not enabled
	join_btn.disabled = not enabled
	back_btn.disabled = not enabled
	host_confirm_btn.disabled = not enabled
	join_confirm_btn.disabled = not enabled


# ── Button Handlers ───────────────────────────────────────────────────────────


func _on_host_pressed() -> void:
	_show_host_panel()


func _on_join_pressed() -> void:
	_show_join_panel()


func _on_back_pressed() -> void:
	## Return to main menu scene
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _on_host_cancel() -> void:
	_show_main_menu()


func _on_join_cancel() -> void:
	_show_main_menu()


func _on_host_confirm() -> void:
	error_label.text = ""

	var port := _parse_port(host_port_input.text)
	if port < 0:
		error_label.text = "Invalid port. Must be a number between 1024 and 65535."
		return

	_set_buttons_enabled(false)
	status_label.text = "Creating server..."

	var err := NetworkManager.create_server(port)
	if err != OK:
		_set_buttons_enabled(true)
		status_label.text = ""
		match err:
			ERR_ALREADY_IN_USE:
				error_label.text = "Already connected. Disconnect first."
			ERR_CANT_CREATE:
				error_label.text = "Failed to bind port %d. It may be in use." % port
			_:
				error_label.text = "Failed to create server: %s" % error_string(err)


func _on_join_confirm() -> void:
	error_label.text = ""

	var address := join_ip_input.text.strip_edges()
	if address.is_empty():
		error_label.text = "Please enter a valid IP address."
		return

	var port := _parse_port(join_port_input.text)
	if port < 0:
		error_label.text = "Invalid port. Must be a number between 1024 and 65535."
		return

	_set_buttons_enabled(false)
	status_label.text = "Connecting to %s:%d..." % [address, port]

	var err := NetworkManager.join_server(address, port)
	if err != OK:
		_set_buttons_enabled(true)
		status_label.text = ""
		match err:
			ERR_ALREADY_IN_USE:
				error_label.text = "Already connected. Disconnect first."
			ERR_INVALID_PARAMETER:
				error_label.text = "Invalid address or port."
			ERR_CANT_CREATE:
				error_label.text = "Failed to initiate connection."
			_:
				error_label.text = "Connection failed: %s" % error_string(err)


# ── NetworkManager Signal Handlers ────────────────────────────────────────────


func _on_connection_established(_peer_id: int) -> void:
	status_label.text = "Connected!"
	## Transition to lobby screen
	get_tree().change_scene_to_file(LOBBY_SCENE_PATH)


func _on_connection_failed(reason: String) -> void:
	_set_buttons_enabled(true)
	status_label.text = ""
	error_label.text = "Connection failed: %s" % reason


# ── Helpers ───────────────────────────────────────────────────────────────────


## Parses a port string and returns the port number, or -1 if invalid.
func _parse_port(text: String) -> int:
	var stripped := text.strip_edges()
	if not stripped.is_valid_int():
		return -1
	var port := stripped.to_int()
	if port < NetworkManager.MIN_PORT or port > NetworkManager.MAX_PORT:
		return -1
	return port
