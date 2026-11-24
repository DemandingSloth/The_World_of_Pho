extends Node
## Autoload: GuildProduction
## Client-side cache + RPC wrappers for the Guild Production Facility
## (migration 055). Members enqueue a jewelry recipe (by recipe_id); the server
## consumes stockpile inputs and schedules the craft. Finished crafts are
## collected into the collecting member's escrow.
##
## Recipe authority: the client only ever passes a recipe_id — the server owns
## the inputs + craft time (guild_production_recipes). The client reads recipe
## display info from PlayerData.ITEM_DEFS.
##
## Timing: the server sends finish_at AND its own `now` as unix epochs. We store
## a server-time offset so countdowns are correct even if the device clock is
## skewed. remaining_seconds(finish_at) uses that offset.

## ── Signals ─────────────────────────────────────────────────────
signal production_changed()

## Seconds shaved per Benjamin when rushing a craft. MUST mirror the server's
## _rush_seconds_per_benjamin() (migration 060) — used only for the client-side
## cost preview; the server is authoritative on what's actually charged.
const RUSH_SECONDS_PER_BENJAMIN := 600


## Benjamins needed to fully finish a craft with `remaining_sec` left (ceil).
func rush_cost_for(remaining_sec: float) -> int:
	if remaining_sec <= 0.0:
		return 0
	return int(ceil(remaining_sec / float(RUSH_SECONDS_PER_BENJAMIN)))

## ── Cached state ─────────────────────────────────────────────────
## items: Array of { id, recipe_id, output_item_key, quantity, enqueued_at, finish_at, ready }
var items: Array = []
var capacity: int = 3
var parallel: int = 1
## Max items per slot (from 'production_batch_size' upgrade, migration 093).
var batch_size: int = 1

## server_now (epoch) at last refresh, and the local clock at that moment, so we
## can project the server's "now" forward for live countdowns.
var _server_now: float = 0.0
var _local_at_refresh: float = 0.0

var is_loading := false


## ── RPC helpers ─────────────────────────────────────────────────

func _rpc(fn: String, body: Variant = null) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null:
		return {"ok": false, "error": "offline"}
	if not SupabaseClient.is_configured():
		return {"ok": false, "error": "offline"}
	var res := await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/%s" % fn, body)
	if not res.get("ok", false):
		return res
	var data = res.get("data", null)
	if data is Dictionary and data.has("error"):
		return {"ok": false, "error": str(data["error"])}
	return {"ok": true, "data": data}


func _device_hash() -> String:
	return MarketplaceAccount._device_hash()


## Parses a get_guild_production payload into the cache. Factored out for tests.
func apply_payload(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	capacity = int(data.get("capacity", capacity))
	parallel = int(data.get("parallel", parallel))
	batch_size = int(data.get("batch_size", batch_size))
	_server_now = float(data.get("now", 0.0))
	_local_at_refresh = TrustedClock.now()

	items.clear()
	var raw = data.get("items", [])
	if raw is Array:
		for e in raw:
			if e is Dictionary:
				items.append({
					"id":              str(e.get("id", "")),
					"recipe_id":       str(e.get("recipe_id", "")),
					"output_item_key": str(e.get("output_item_key", "")),
					"quantity":        int(e.get("quantity", 1)),
					"enqueued_at":     float(e.get("enqueued_at", 0.0)),
					"finish_at":       float(e.get("finish_at", 0.0)),
					"ready":           bool(e.get("ready", false)),
				})
	return true


## Seconds remaining until a finish_at epoch, using the server-time offset so a
## skewed device clock doesn't distort the countdown. 0 when ready.
func remaining_seconds(finish_at: float) -> float:
	var projected_server_now := _server_now + (TrustedClock.now() - _local_at_refresh)
	return maxf(finish_at - projected_server_now, 0.0)


## How many crafts are currently finished (ready to collect), by live countdown.
func ready_count() -> int:
	var n := 0
	for it in items:
		if remaining_seconds(float(it.get("finish_at", 0.0))) <= 0.0:
			n += 1
	return n


func is_full() -> bool:
	return items.size() >= capacity


## ── Public API ───────────────────────────────────────────────────

func refresh(guild_id: String) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	is_loading = true
	var res := await _rpc("get_guild_production", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
	})
	is_loading = false
	if not res.get("ok", false):
		return _friendly(res)
	if not apply_payload(res.get("data", {})):
		return {"ok": false, "error": "bad_response", "message": "Bad server response."}
	production_changed.emit()
	return {"ok": true}


## Enqueues a recipe (by id) with an optional batch quantity.
## The server consumes qty × recipe inputs and produces qty items.
func enqueue(guild_id: String, recipe_id: String, qty: int = 1) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	var res := await _rpc("enqueue_production", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
		"p_recipe_id":   recipe_id,
		"p_qty":         maxi(1, qty),
	})
	if res.get("ok", false):
		await refresh(guild_id)
		if get_node_or_null("/root/GuildStockpile") != null:
			await GuildStockpile.refresh(guild_id)
	return _friendly(res)


## Collects every finished craft into the caller's escrow.
func collect(guild_id: String) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	var res := await _rpc("collect_production", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
	})
	if res.get("ok", false):
		await refresh(guild_id)
	return _friendly(res)


## Spends `benjamins` of the caller's Benjamins to shave time off an active
## craft (migration 060). The server charges only what's needed to finish the
## craft (overshoot-protected). On success refreshes the queue AND the MoneyGun
## balance so the Benjamin wallet stays current. Returns the friendly result
## (incl. spent, seconds_removed, finish_at, ready, balance on ok).
func rush(guild_id: String, queue_id: String, benjamins: int) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	if benjamins <= 0:
		return {"ok": false, "error": "invalid_amount", "message": "Enter a valid amount."}
	var res := await _rpc("rush_production", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
		"p_queue_id":    queue_id,
		"p_benjamins":   benjamins,
	})
	if res.get("ok", false):
		## Reflect the authoritative Benjamin balance locally if MoneyGun exposes
		## it, then refresh the queue to pull the new finish_at.
		var data = res.get("data", {})
		if data is Dictionary and data.has("balance") and get_node_or_null("/root/MoneyGun") != null:
			MoneyGun.balance = int(data.get("balance", MoneyGun.balance))
			MoneyGun.money_gun_changed.emit()
		await refresh(guild_id)
	return _friendly(res)


## ── Private ──────────────────────────────────────────────────────

func _friendly(res: Dictionary) -> Dictionary:
	if res.get("ok", false):
		var data = res.get("data", null)
		if data is Dictionary:
			var out := {"ok": true}
			out.merge(data)
			return out
		return {"ok": true}
	var code := str(res.get("error", "unknown"))
	var msg: String
	match code:
		"account_not_found":   msg = "Online account required."
		"not_in_guild":        msg = "You are not in a guild."
		"invalid_recipe":      msg = "Unknown recipe."
		"wrong_guild_spec":    msg = "Your guild's specialization can't craft that."
		"stockpile_locked":    msg = "The stockpile is locked."
		"facility_full":       msg = "The production facility is full."
		"insufficient_stock":  msg = "Not enough materials in the stockpile."
		"invalid_amount":      msg = "Enter a valid amount."
		"craft_not_found":     msg = "That craft is gone."
		"craft_not_active":    msg = "That craft is no longer active."
		"wrong_guild":         msg = "That craft belongs to another guild."
		"already_ready":       msg = "That craft is already finished."
		"insufficient_benjamins": msg = "You don't have enough Benjamins."
		"offline":             msg = "No connection."
		_:                     msg = "Error: %s" % code
	return {"ok": false, "error": code, "message": msg}
