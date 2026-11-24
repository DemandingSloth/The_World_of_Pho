class_name ConnectionIndicator
extends CanvasLayer

## Persistent connection quality overlay for multiplayer sessions.
## Displays latency and connection state (green/yellow/red) in the top-right corner.
## Add this scene as a child of any multiplayer scene (lobby, game, result).

# ── Constants ─────────────────────────────────────────────────────────────────

const LATENCY_GOOD_THRESHOLD_MS := 200
const LATENCY_DEGRADED_THRESHOLD_MS := 1000
const UPDATE_INTERVAL_SEC := 1.0

const COLOR_CONNECTED := Color(0.2, 0.9, 0.2)     # Green
const COLOR_DEGRADED := Color(0.95, 0.85, 0.1)     # Yellow
const COLOR_DISCONNECTED := Color(0.95, 0.2, 0.2)  # Red

# ── Node References ───────────────────────────────────────────────────────────

@onready var status_icon: Label = $PanelContainer/MarginContainer/HBox/StatusIcon
@onready var latency_label: Label = $PanelContainer/MarginContainer/HBox/LatencyLabel
@onready var status_label: Label = $PanelContainer/MarginContainer/HBox/StatusLabel

# ── State ─────────────────────────────────────────────────────────────────────

var _update_timer: Timer = null


# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	# Set canvas layer high so it renders above game UI.
	layer = 100

	# Create a timer for periodic latency checks (every 1 second).
	_update_timer = Timer.new()
	_update_timer.wait_time = UPDATE_INTERVAL_SEC
	_update_timer.one_shot = false
	_update_timer.timeout.connect(_update_connection_state)
	add_child(_update_timer)
	_update_timer.start()

	# Perform initial update immediately.
	_update_connection_state()


# ── Private ───────────────────────────────────────────────────────────────────


## Reads latency from NetworkManager and updates the indicator display.
func _update_connection_state() -> void:
	var latency_ms := NetworkManager.get_latency_ms()
	var net_state := NetworkManager.state

	# Determine connection quality based on latency thresholds.
	if net_state == NetworkManager.ConnectionState.DISCONNECTED:
		_set_disconnected()
	elif latency_ms >= LATENCY_DEGRADED_THRESHOLD_MS:
		_set_disconnected()
	elif latency_ms >= LATENCY_GOOD_THRESHOLD_MS:
		_set_degraded(latency_ms)
	else:
		_set_connected(latency_ms)


## Green state — latency below 200ms.
func _set_connected(latency_ms: int) -> void:
	status_icon.text = "●"
	status_icon.add_theme_color_override("font_color", COLOR_CONNECTED)
	latency_label.text = "%dms" % latency_ms
	latency_label.add_theme_color_override("font_color", COLOR_CONNECTED)
	status_label.text = "Connected"
	status_label.add_theme_color_override("font_color", COLOR_CONNECTED)


## Yellow state — latency between 200ms and 1000ms.
func _set_degraded(latency_ms: int) -> void:
	status_icon.text = "●"
	status_icon.add_theme_color_override("font_color", COLOR_DEGRADED)
	latency_label.text = "%dms" % latency_ms
	latency_label.add_theme_color_override("font_color", COLOR_DEGRADED)
	status_label.text = "Degraded"
	status_label.add_theme_color_override("font_color", COLOR_DEGRADED)


## Red state — latency exceeds 1000ms or NetworkManager reports disconnected.
func _set_disconnected() -> void:
	status_icon.text = "●"
	status_icon.add_theme_color_override("font_color", COLOR_DISCONNECTED)
	latency_label.text = "---"
	latency_label.add_theme_color_override("font_color", COLOR_DISCONNECTED)
	status_label.text = "Disconnected"
	status_label.add_theme_color_override("font_color", COLOR_DISCONNECTED)
