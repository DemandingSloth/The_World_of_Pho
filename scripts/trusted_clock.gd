extends Node
## Autoload: TrustedClock — the game's single source of "what time is it".
##
## Every timer in the game (orchard, garden, workshop, prospectors, daily
## rewards, ...) reads TrustedClock.now() instead of the phone's clock, so
## changing the phone's date/time can't speed anything up.
##
## How it works:
##   • The clock is ANCHORED to a known time and then advanced with the
##     engine's monotonic tick counter (Time.get_ticks_msec), which does NOT
##     change when the user edits the system date.
##   • Online: the anchor is the SERVER's time (get_server_time, migration 110),
##     re-fetched at startup and every time the app returns to the foreground.
##   • Before the first server answer, the clock stays at the last time we
##     trusted (the persisted high-water mark), so start-up catch-up (offline
##     prospector gems, passive XP, ...) waits until time is verified instead
##     of using a possibly-fake phone date. If the server can't be reached
##     (offline) we fall back to the phone's clock — but never earlier than the
##     high-water mark, so rolling the clock BACK is caught and simply freezes
##     time until real time catches up.
##   • Known gap (accepted): a player who is offline the whole time can still
##     move the date FORWARD. Nothing shared (tokens/market/guilds) is affected
##     because those are server-authoritative.

const SAVE_PATH := "user://trusted_clock.cfg"
## Clock differences under this many seconds are treated as normal drift.
const TOLERANCE_SECS := 120.0
## Give up waiting for the server after this long and use the fallback.
const SYNC_TIMEOUT_SECS := 6.0

## Emitted when the clock gets its first verified (or fallback) time.
signal clock_ready
## Emitted once per detection when the phone's clock looks tampered with
## (rolled back, or far ahead of the server). `ahead_secs` > 0 = phone ahead.
signal clock_tampered(ahead_secs: float)

var _anchor_epoch: float = 0.0
var _anchor_ticks: int = 0
var _high_water: float = 0.0
var _synced: bool = false       ## anchored to server time this session
var _ready_done: bool = false   ## clock_ready has fired
var _syncing: bool = false
var _last_sync_ticks: int = -1_000_000


func _ready() -> void:
	clock_tampered.connect(_on_clock_tampered)
	_load()
	var device := Time.get_unix_time_from_system()
	if _high_water <= 0.0:
		## First run ever: nothing to compare against yet.
		_high_water = device
	if device < _high_water - TOLERANCE_SECS:
		clock_tampered.emit(device - _high_water)
	## Until verified, hold time at the last trusted value.
	_set_anchor(_high_water)

	var t := Timer.new()
	t.wait_time = 30.0
	t.autostart = true
	t.timeout.connect(_persist)
	add_child(t)

	call_deferred("sync_now")


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN:
			## The monotonic counter may not advance while the phone sleeps, so
			## on return: if the phone's clock moved well past ours, take it
			## provisionally (never going backwards) and verify with the server
			## immediately. Otherwise just re-verify now and then.
			if _reanchor_from_device():
				sync_now()
			elif Time.get_ticks_msec() - _last_sync_ticks > 30_000:
				sync_now()
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT, \
		NOTIFICATION_WM_CLOSE_REQUEST:
			_persist()


## The trusted current time, in unix seconds (UTC).
func now() -> float:
	return _anchor_epoch + float(Time.get_ticks_msec() - _anchor_ticks) / 1000.0


## True once anchored to the server's time this session.
func is_synced() -> bool:
	return _synced


## True once the clock has a usable time (server-verified or fallback).
func is_ready() -> bool:
	return _ready_done


## Local-time date/time dictionary (year, month, day, hour, minute, second,
## weekday) for the trusted time — replacement for get_datetime_dict_from_system.
func local_datetime_dict() -> Dictionary:
	var bias_min := int(Time.get_time_zone_from_system().get("bias", 0))
	return Time.get_datetime_dict_from_unix_time(int(now()) + bias_min * 60)


## Fetches the server's time and re-anchors to it. Safe to call often.
func sync_now() -> void:
	if _syncing:
		return
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		_use_fallback()
		return
	_syncing = true
	var timeout := get_tree().create_timer(SYNC_TIMEOUT_SECS)
	timeout.timeout.connect(func():
		if _syncing and not _ready_done:
			_use_fallback())
	var sent_ticks := Time.get_ticks_msec()
	var res: Dictionary = await SupabaseClient.request_json("POST", "/rest/v1/rpc/get_server_time", {})
	_syncing = false
	var data = res.get("data", null)
	if not res.get("ok", false) or not (data is Dictionary) or not data.has("now"):
		if not _ready_done:
			_use_fallback()
		return
	## Compensate for half the round trip.
	var rtt := float(Time.get_ticks_msec() - sent_ticks) / 1000.0
	var server_now := float(data["now"]) + rtt * 0.5
	var device := Time.get_unix_time_from_system()
	if device - server_now > TOLERANCE_SECS:
		clock_tampered.emit(device - server_now)
	_set_anchor(server_now)
	_synced = true
	_last_sync_ticks = Time.get_ticks_msec()
	## Server time is authoritative — it may LOWER a high-water mark that an
	## earlier offline forward-jump inflated.
	_high_water = server_now
	_persist()
	_mark_ready()


## ── Internals ───────────────────────────────────────────────────

var _warned := false

## Tell the player (once per session) that the game ignores their device clock.
func _on_clock_tampered(_ahead_secs: float) -> void:
	if _warned:
		return
	_warned = true
	call_deferred("_show_tamper_notice")


func _show_tamper_notice() -> void:
	if get_node_or_null("/root/GameNotification") != null:
		GameNotification.show_message("⏰ Clock mismatch",
			"Your device's date/time doesn't match the real time. The game uses real time, so changing your clock won't speed anything up.")


func _set_anchor(epoch: float) -> void:
	_anchor_epoch = epoch
	_anchor_ticks = Time.get_ticks_msec()


## Offline fallback: the phone's clock, but never earlier than the high-water
## mark (a rollback freezes time instead of rewinding it).
func _use_fallback() -> void:
	if _synced:
		_mark_ready()
		return
	var device := Time.get_unix_time_from_system()
	if device < _high_water - TOLERANCE_SECS:
		clock_tampered.emit(device - _high_water)
	_set_anchor(maxf(device, now()))
	_mark_ready()


## Returns true if it re-anchored to the phone's clock (a real gap, e.g. the
## phone slept) — the caller must then verify with the server.
func _reanchor_from_device() -> bool:
	var device := Time.get_unix_time_from_system()
	var current := now()
	if device > current + 60.0:
		_set_anchor(device)  ## provisional; the server sync corrects it
		return true
	if device < current - TOLERANCE_SECS:
		clock_tampered.emit(device - current)
	return false


func _mark_ready() -> void:
	if not _ready_done:
		_ready_done = true
		clock_ready.emit()


func _persist() -> void:
	_high_water = maxf(_high_water, now()) if not _synced else now()
	var cfg := ConfigFile.new()
	cfg.set_value("clock", "high_water", _high_water)
	cfg.save(SAVE_PATH)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		_high_water = float(cfg.get_value("clock", "high_water", 0.0))
