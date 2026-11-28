extends Node

## Autoload: LocalNotificationManager
## Wraps the native kyoz/godot-local-notification plugin (Android & iOS).
## Safely no-ops on desktop/editor or when the native plugin is not yet installed.
##
## Usage:
##   LocalNotificationManager.schedule_notification(
##       LocalNotificationManager.ID_GARDEN,
##       "Garden Ready",
##       "Your garden crops are ready to harvest!",
##       300
##   )

const ID_GARDEN := 1001
const ID_ORCHARD := 1002
const ID_WORKSHOP_SAW := 1003
const ID_WORKSHOP_FOUNDRY := 1004
const ID_DAILY_BONUS := 1005

var _plugin: Object = null


func _ready() -> void:
	if Engine.has_singleton("LocalNotification"):
		_plugin = Engine.get_singleton("LocalNotification")
		print("[LocalNotificationManager] Plugin loaded: ", _plugin)
		if not _plugin.isPermissionGranted():
			_plugin.requestPermission()
	else:
		print("[LocalNotificationManager] LocalNotification singleton NOT found")


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_RESUMED:
			cancel_all()
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_CLOSE_REQUEST:
			_schedule_on_background()


## Returns true when the native LocalNotification singleton is loaded (Android/iOS).
func is_available() -> bool:
	return _plugin != null


## Schedules a one-shot local notification after `delay_seconds` (> 0).
func schedule_notification(id: int, title: String, message: String, delay_seconds: int) -> void:
	if _plugin == null or delay_seconds <= 0:
		return
	print("[LocalNotificationManager] Scheduling id=%d in %ds: %s" % [id, delay_seconds, title])
	_plugin.show(title, message, delay_seconds, id)


## Cancels a single scheduled notification by ID.
func cancel_notification(id: int) -> void:
	if _plugin == null:
		return
	_plugin.cancel(id)


## Cancels all scheduled local notifications.
func cancel_all() -> void:
	if _plugin == null:
		return
	for id in [ID_GARDEN, ID_ORCHARD, ID_WORKSHOP_SAW, ID_WORKSHOP_FOUNDRY, ID_DAILY_BONUS, 999]:
		_plugin.cancel(id)


## Called when the app goes to background or closes.
## Schedules OS notifications for Garden, Workshop (Saw & Foundry), etc.
func _schedule_on_background() -> void:
	if _plugin == null:
		return
	cancel_all()

	var now: float = TrustedClock.now()

	## Garden: notify when the earliest growing crop finishes
	if PlayerData.is_notification_enabled("garden") and get_node_or_null("/root/Garden") != null:
		var garden_secs := _get_garden_next_ready_seconds(now)
		if garden_secs > 0:
			schedule_notification(
				ID_GARDEN,
				"🌱 Garden Ready",
				"Your garden crops are ready to harvest!",
				garden_secs
			)

	## Workshop Saw: notify when the next batch finishes (if none ready yet)
	if PlayerData.is_notification_enabled("workshop") and get_node_or_null("/root/Workshop") != null:
		if not Workshop.saw_queue.is_empty() and Workshop.get_ready_count() == 0:
			var saw_secs := int(ceil(Workshop.saw_start + Workshop.get_saw_cut_time() - now))
			if saw_secs > 0:
				schedule_notification(
					ID_WORKSHOP_SAW,
					"🪚 Gems Polished",
					"Polished gems are ready to collect in the Workshop!",
					saw_secs
				)

	## Workshop Foundry: notify when the next batch finishes (if none ready yet)
	if PlayerData.is_notification_enabled("foundry") and get_node_or_null("/root/Workshop") != null:
		if not Workshop.foundry_queue.is_empty() and Workshop.get_foundry_ready_count() == 0:
			var foundry_secs := int(ceil(Workshop.foundry_start + Workshop.get_foundry_smelt_time() - now))
			if foundry_secs > 0:
				schedule_notification(
					ID_WORKSHOP_FOUNDRY,
					"🏭 Bars Ready",
					"Smelted bars are ready to collect in the Workshop!",
					foundry_secs
				)

func _get_garden_next_ready_seconds(now: float) -> int:
	var earliest: float = INF
	for row in Garden.grid:
		if not (row is Array):
			continue
		for cell in row:
			if cell == null or not (cell is Dictionary):
				continue
			var ptype: int = int(cell.get("plant_type", -1))
			if ptype < 0 or ptype >= Garden.PLANT_DEFS.size():
				continue
			var ptime: float = float(cell.get("plant_time", 0.0))
			var harvest_time: float = float(Garden.PLANT_DEFS[ptype].get("harvest_time", 0.0))
			var rem: float = ptime + harvest_time - now
			if rem > 0.0 and rem < earliest:
				earliest = rem
	if earliest == INF:
		return 0
	return int(ceil(earliest))
