extends Node
## Autoload: GuildStockpile
## Client-side cache + RPC wrappers for the dedicated Guild Stockpile (the
## production-input store, migration 052). All durable state lives in Supabase;
## this node caches the current session's view for GuildStockpileUI.
##
## Access model (enforced server-side):
##   • Any active member may DEPOSIT and VIEW.
##   • Only the guild LEADER may lock withdrawals, reserve stock, or withdraw.
##
## Deposit trust model (mirrors mission deposits / guild_mine_data.deposit):
## the client removes the item from the player's LOCAL inventory first (via
## PlayerData.market_remove_owned with the canonical key), then calls
## deposit_to_stockpile. On any failure the local removal is refunded. The
## server holds no per-player inventory, so a deposit only ADDS shared stock.
##
## Stockpile is cached as a Dictionary: item_key (String) -> { amount, reserved }.

## ── Signals ─────────────────────────────────────────────────────
signal stockpile_changed()   ## Items / lock / capacity changed — UI should refresh

## ── Cached state ─────────────────────────────────────────────────
## Dictionary: item_key -> { "amount": int, "reserved": int }
var items: Dictionary = {}

## True when the leader has locked withdrawals.
var locked: bool = false

## Per-item-key capacity (50,000 + stockpile_capacity level * 45,000).
var capacity: int = 50000

## True while a full refresh RPC is in flight.
var is_loading: bool = false


## ── Convenience ─────────────────────────────────────────────────

func get_amount(item_key: String) -> int:
	var e = items.get(item_key, null)
	return int(e.get("amount", 0)) if e is Dictionary else 0


func get_reserved(item_key: String) -> int:
	var e = items.get(item_key, null)
	return int(e.get("reserved", 0)) if e is Dictionary else 0


## Withdrawable / spendable amount = amount - reserved (never below 0).
func get_available(item_key: String) -> int:
	return maxi(get_amount(item_key) - get_reserved(item_key), 0)


func item_keys() -> Array:
	return items.keys()


func is_empty() -> bool:
	return items.is_empty()


## ── RPC helpers (identical shape to guild_mine_data.gd) ──────────

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


## ── Response parsing (shared by refresh + tests) ─────────────────

## Populates the cache from a get_guild_stockpile payload Dictionary. Kept
## separate from refresh() so it can be unit-tested headlessly without a live
## server. Returns true on a well-formed payload.
func apply_payload(data: Variant) -> bool:
	if not data is Dictionary:
		return false

	items.clear()
	var raw = data.get("items", [])
	if raw is Array:
		for entry in raw:
			if not entry is Dictionary:
				continue
			var key := str(entry.get("item_key", ""))
			if key.is_empty():
				continue
			items[key] = {
				"amount":   int(entry.get("amount", 0)),
				"reserved": int(entry.get("reserved", 0)),
			}

	locked = bool(data.get("locked", false))
	capacity = int(data.get("capacity", capacity))
	return true


## ── Public API — view ────────────────────────────────────────────

## Fetches the full stockpile from the server, populates the cache, emits
## stockpile_changed. Returns a friendly result dict.
func refresh(guild_id: String) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	is_loading = true
	var res := await _rpc("get_guild_stockpile", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
	})
	is_loading = false
	if not res.get("ok", false):
		return _friendly(res)

	if not apply_payload(res.get("data", {})):
		return {"ok": false, "error": "bad_response", "message": "Bad server response."}

	stockpile_changed.emit()
	return {"ok": true}


## ── Public API — deposit (any member) ────────────────────────────

## Deposits `amount` of a canonical `item_key` into the shared stockpile. Removes
## the item from the player's LOCAL inventory first (refunded on failure). On a
## partial store (capacity hit) the un-stored remainder is refunded locally too.
## Returns { ok, deposited } or { ok=false, error, message }.
func deposit(guild_id: String, item_key: String, amount: int) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	if amount <= 0:
		return {"ok": false, "error": "invalid_amount", "message": "Nothing to deposit."}
	if PlayerData.market_count_owned(item_key) < amount:
		return {"ok": false, "error": "insufficient_items", "message": "You don't have that many."}

	## Remove locally first so the player can't deposit more than they own even
	## if the network call is slow (same trust model as mission deposits).
	if not PlayerData.market_remove_owned(item_key, amount):
		return {"ok": false, "error": "insufficient_items", "message": "You don't have that many."}

	var res := await _rpc("deposit_to_stockpile", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
		"p_item_key":    item_key,
		"p_amount":      amount,
	})

	if res.get("ok", false):
		var data = res.get("data", {})
		var deposited := amount
		if data is Dictionary:
			deposited = int(data.get("deposited", amount))
			## Reflect the authoritative stored total in the cache.
			items[item_key] = {
				"amount":   int(data.get("amount", get_amount(item_key) + deposited)),
				"reserved": get_reserved(item_key),
			}
		## Refund any remainder the stockpile couldn't hold (capacity clamp).
		var unstored := amount - deposited
		if unstored > 0:
			PlayerData.market_add_owned(item_key, unstored)
		stockpile_changed.emit()
	else:
		## Full refund on failure.
		PlayerData.market_add_owned(item_key, amount)

	return _friendly(res)


## ── Public API — leader management ───────────────────────────────

## Leader-only. Sets the ABSOLUTE reserved amount for an item key (server clamps
## to <= amount on hand).
func reserve(guild_id: String, item_key: String, reserved_amount: int) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	if reserved_amount < 0:
		return {"ok": false, "error": "invalid_amount", "message": "Invalid reserve amount."}
	var res := await _rpc("reserve_stockpile", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
		"p_item_key":    item_key,
		"p_amount":      reserved_amount,
	})
	if res.get("ok", false):
		var data = res.get("data", {})
		if data is Dictionary and items.has(item_key):
			items[item_key]["reserved"] = int(data.get("reserved", reserved_amount))
		stockpile_changed.emit()
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
		"account_not_found":     msg = "Online account required."
		"not_in_guild":          msg = "You are not in a guild."
		"guild_not_found":       msg = "Guild not found."
		"not_leader":            msg = "Only the guild leader can do that."
		"invalid_item":          msg = "That item can't go in the stockpile."
		"invalid_amount":        msg = "Enter a valid amount."
		"insufficient_items":    msg = "You don't have that many."
		"stockpile_full":        msg = "The stockpile is full for that item."
		"offline":               msg = "No connection."
		_:                       msg = "Error: %s" % code
	return {"ok": false, "error": code, "message": msg}
