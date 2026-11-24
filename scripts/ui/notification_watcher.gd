extends Node

## Autoload: NotificationWatcher
## Polls game state on a timer and fires in-app banners (via GameNotification)
## when notable things become ready, honoring the per-category settings on
## PlayerData. In-app only — does not schedule OS/background notifications.
##
## Triggers:
##   - Daily bonus: when the daily bonus becomes claimable.
##   - Garden: when a garden row has >= 3/4 of its columns ready to harvest.
##   - Orchard: when a tree first has fruit ready this cycle, or >10 fruit
##     (first-fruit always fires first, so a single 0 -> ready edge covers both).
##   - Workshop: when the saw first has polished gems ready to collect.
##   - Missions: when a mission slot becomes ready to claim.

const POLL_INTERVAL := 10.0                 ## Seconds between readiness checks
const GARDEN_ROW_READY_FRACTION := 0.75     ## 3/4 of a row's columns ready

const MOTD_TEXT := "Be the good you want to see in the world"

var _daily_notified: bool = false            ## True while the daily banner is "used up"
## Threshold-based alerts: each stays "armed as used" until the ready count
## drops back below the player's chosen threshold, then re-arms.
var _garden_notified: bool = false           ## Garden reached its row threshold
var _orchard_notified: bool = false          ## Orchard reached its tree threshold
var _saw_notified: bool = false              ## Saw reached its item threshold
var _foundry_notified: bool = false          ## Foundry reached its item threshold
## Per-slot flag: true while we've already alerted that this slot's current
## mission is ready to claim. Re-arms when the slot rolls a new mission.
var _mission_slots_notified: Dictionary = {} ## slot (int) -> true (already alerted)

## Message-of-the-day scheduling. Each day we pick a random target time-of-day
## (seconds since local midnight); the banner fires the first poll at/after it.
var _motd_day: int = -1                      ## Day index the target below was chosen for
var _motd_target_seconds: int = 0            ## Seconds-since-midnight to fire at


func _ready() -> void:
	var timer := Timer.new()
	timer.wait_time = POLL_INTERVAL
	timer.autostart = true
	timer.timeout.connect(_check_all)
	add_child(timer)
	## Give autoloads a moment to finish loading their save data.
	_check_all.call_deferred()


func _check_all() -> void:
	_check_message_of_the_day()
	_check_daily_bonus()
	_check_garden()
	_check_orchard()
	_check_saw()
	_check_foundry()
	_check_missions()


## ── Missions ───────────────────────────────────────────────────

## Fires once when a mission slot becomes ready to claim (progress met, not yet
## claimed). Re-arms per slot when that slot rolls a new mission, so each newly
## completed mission alerts once.
func _check_missions() -> void:
	if not PlayerData.is_notification_enabled("missions"):
		return
	if get_node_or_null("/root/MissionBoard") == null:
		return
	var ready_count := 0
	for slot in range(MissionBoard.missions.size()):
		var m = MissionBoard.missions[slot]
		var is_ready := m != null and not bool(m.get("claimed", false)) \
			and int(m.get("progress", 0)) >= int(m.get("required", 1))
		if is_ready:
			if not _mission_slots_notified.get(slot, false):
				_mission_slots_notified[slot] = true
				ready_count += 1
		else:
			## Slot not ready (unclaimed-incomplete, claimed, or rerolled) — re-arm.
			_mission_slots_notified.erase(slot)

	## Condense multiple slots that became ready this poll into one banner.
	if ready_count == 1:
		GameNotification.show_message(
			"📋 Mission Complete",
			"A mission is ready to claim on the Mission Board!",
			"", "mission_board")
	elif ready_count > 1:
		GameNotification.show_message(
			"📋 Missions Complete",
			"%d missions are ready to claim!" % ready_count,
			"", "mission_board")


## ── Workshop saw ───────────────────────────────────────────────

## Fires once when the saw's ready-count reaches the player's chosen threshold
## (10/50/100). Re-arms when the ready count drops back below it (e.g. collected).
func _check_saw() -> void:
	if not PlayerData.is_notification_enabled("workshop"):
		return
	if get_node_or_null("/root/Workshop") == null:
		return
	var threshold: int = maxi(1, PlayerData.get_notification_threshold("workshop"))
	var ready: int = Workshop.get_ready_count()
	if ready >= threshold and not _saw_notified:
		_saw_notified = true
		GameNotification.show_message(
			"🪚 Gems Polished",
			"%d polished gems are ready to collect in the Workshop!" % ready,
			"", "workshop")
	elif ready < threshold:
		_saw_notified = false


## ── Workshop foundry ───────────────────────────────────────────

## Fires once when the foundry's ready bar-count reaches the chosen threshold
## (10/50/100). Re-arms when the ready count drops back below it.
func _check_foundry() -> void:
	if not PlayerData.is_notification_enabled("foundry"):
		return
	if get_node_or_null("/root/Workshop") == null:
		return
	if not Workshop.has_method("get_foundry_ready_count"):
		return
	var threshold: int = maxi(1, PlayerData.get_notification_threshold("foundry"))
	var ready: int = Workshop.get_foundry_ready_count()
	if ready >= threshold and not _foundry_notified:
		_foundry_notified = true
		GameNotification.show_message(
			"🏭 Bars Ready",
			"%d bars are ready to collect in the Workshop!" % ready,
			"", "workshop")
	elif ready < threshold:
		_foundry_notified = false


## ── Message of the Day ─────────────────────────────────────────

## Fires the inspirational banner once per day at a random time. If the app
## isn't open when the target time passes, it shows the next time the app is
## open that day. Persisted so it fires only once per calendar day.
func _check_message_of_the_day() -> void:
	var today := int(TrustedClock.now() / 86400.0)

	## Already shown today? Nothing to do.
	if PlayerData.motd_last_shown_day == today:
		return

	## Choose a fresh random target time for this day (once per day).
	if _motd_day != today:
		_motd_day = today
		_motd_target_seconds = randi() % 86400  ## Any second of the day

	## Seconds elapsed since local midnight.
	var t := TrustedClock.local_datetime_dict()
	var now_seconds: int = int(t["hour"]) * 3600 + int(t["minute"]) * 60 + int(t["second"])

	if now_seconds >= _motd_target_seconds:
		PlayerData.motd_last_shown_day = today
		PlayerData.save_data()
		GameNotification.show_message("💚 Daily Message", _daily_message())


## Picks the day's uplifting message. The Valentine's Valor shop (Business
## District) unlocks extra messages (one per level); when active, draw from that
## pool. Otherwise use the default message of the day.
func _daily_message() -> String:
	if get_node_or_null("/root/BusinessDistrict") != null:
		var msgs: Array = BusinessDistrict.active_valentine_messages()
		if not msgs.is_empty():
			return str(msgs[randi() % msgs.size()])
	return MOTD_TEXT


## ── Daily bonus ────────────────────────────────────────────────

func _check_daily_bonus() -> void:
	if not PlayerData.is_notification_enabled("daily_bonus"):
		return
	var claimable: bool = PlayerData.can_claim_daily()
	if claimable and not _daily_notified:
		_daily_notified = true
		GameNotification.show_message(
			"🎁 Daily Bonus Ready",
			"Claim your daily reward on the home screen!",
			"", "home")
	elif not claimable:
		## Reset once claimed / no longer available, so it can fire again tomorrow.
		_daily_notified = false


## ── Garden ─────────────────────────────────────────────────────

func _check_garden() -> void:
	if not PlayerData.is_notification_enabled("garden"):
		return
	var garden := get_node_or_null("/root/Garden")
	if garden == null:
		return

	## Threshold is a row count; 0 means "the whole garden" (all current rows).
	## Checked for each owned garden (Garden 1 and, if bought, Garden 2) no
	## matter which one is being viewed.
	var threshold: int = PlayerData.get_notification_threshold("garden")
	var gardens: Array = garden.get_owned_gardens()
	var ready_names: Array = []
	var ready_rows_total := 0
	for g in gardens:
		var rows: int = int(g["rows"])
		var cols: int = int(g["cols"])
		var cells: Array = g["grid"]
		## A row is "ready" when >= 3/4 of its columns are harvestable.
		var needed: int = int(ceil(cols * GARDEN_ROW_READY_FRACTION))
		var ready_rows := 0
		for r in range(mini(rows, cells.size())):
			var planted := 0
			var ready := 0
			for c in range(mini(cols, cells[r].size())):
				var cell = cells[r][c]
				if cell != null:
					planted += 1
					if garden.is_cell_harvestable(cell):
						ready += 1
			if planted > 0 and ready >= needed:
				ready_rows += 1
		var target: int = rows if threshold <= 0 else mini(threshold, rows)
		target = maxi(1, target)
		if ready_rows >= target:
			ready_names.append("Garden %d" % (int(g["index"]) + 1))
			ready_rows_total += ready_rows

	if not ready_names.is_empty() and not _garden_notified:
		_garden_notified = true
		## Only name the garden when the player owns more than one.
		var where: String = "Your whole garden" if gardens.size() <= 1 else " & ".join(ready_names)
		if threshold <= 0:
			GameNotification.show_message(
				"🌾 Garden Ready",
				"%s %s ready to harvest!" % [where, "are" if ready_names.size() > 1 else "is"],
				"", "garden")
		else:
			var suffix: String = "" if gardens.size() <= 1 else " in " + " & ".join(ready_names)
			GameNotification.show_message(
				"🌾 Garden Ready",
				"%d rows are ready to harvest%s!" % [ready_rows_total, suffix],
				"", "garden")
	elif ready_names.is_empty():
		_garden_notified = false


## ── Orchard ────────────────────────────────────────────────────

func _check_orchard() -> void:
	if not PlayerData.is_notification_enabled("orchard"):
		return
	var orchard := get_node_or_null("/root/Orchard")
	if orchard == null:
		return

	## Count how many trees currently have fruit ready to pick.
	var ready_trees := 0
	for r in range(orchard.orchard_rows):
		for c in range(orchard.orchard_cols):
			if orchard.get_available_fruit(r, c) >= 1:
				ready_trees += 1

	## Threshold is a tree count (10/50/100). Fire once when reached; re-arm below.
	var threshold: int = maxi(1, PlayerData.get_notification_threshold("orchard"))
	if ready_trees >= threshold and not _orchard_notified:
		_orchard_notified = true
		GameNotification.show_message(
			"🍎 Orchard Harvest",
			"%d trees are ready to pick!" % ready_trees,
			"", "orchard")
	elif ready_trees < threshold:
		_orchard_notified = false
