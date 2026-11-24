extends Node
## Autoload: MoneyGun
## Client-side cache + RPC wrappers for the Money Gun + Benjamins currency
## (server-authoritative; migrations 053/054). All durable state lives on the
## server (accounts.benjamin_balance / money_gun_owned / money_gun_level /
## money_gun_last_claim_at); this node caches the last-fetched view for the UI.
##
## The server computes accrual from the stored gun level + last-claim clock, so
## the client never reports an amount — it just calls claim_benjamins and the
## server decides what was earned. Upgrades go through upgrade_money_gun so the
## level (which drives the print rate) stays authoritative.
##
## Purchase trust model: the Money Gun costs MONEY_GUN_COST coins, deducted
## LOCALLY (coins are a local currency) only AFTER buy_money_gun records server
## ownership — mirroring the server-authoritative-escrow pattern used by listings.

## ── Signals ─────────────────────────────────────────────────────
signal money_gun_changed()   ## balance / owned / level / accrued changed

## ── Constants ────────────────────────────────────────────────────
## Exorbitant one-per-save coin price (like Tractor/Excavator, far pricier).
const MONEY_GUN_COST := 500_000_000_000   ## 500 billion coins

## Shared secret for the alpha grant cheat (must match
## _benjamin_grant_secret() in migration 054). Alpha-only.
const BENJAMIN_GRANT_SECRET := "sloth-alpha-benjamin-2026"

## ── Cached state (server-authoritative; refreshed via refresh()) ─
var balance: int = 0
var owned: bool = false
var level: int = 0
var rate_per_hour: int = 1
var cap: int = 48
var accrued: int = 0            ## accrued-but-unclaimed, as of last refresh
var last_claim_at: float = 0.0  ## Unix seconds, 0 if never

var is_loading: bool = false


## ── RPC helpers (same shape as guild_stockpile_data.gd) ──────────

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


## Populates the cache from a get_benjamin_balance / claim / upgrade payload.
## Factored out so it can be unit-tested headlessly. Returns true if applied.
func apply_payload(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	if data.has("balance"):
		balance = int(data.get("balance", balance))
	if data.has("owned"):
		owned = bool(data.get("owned", owned))
	if data.has("level"):
		level = int(data.get("level", level))
	if data.has("rate_per_hour"):
		rate_per_hour = int(data.get("rate_per_hour", rate_per_hour))
	if data.has("cap"):
		cap = int(data.get("cap", cap))
	if data.has("accrued"):
		accrued = int(data.get("accrued", accrued))
	if data.has("last_claim_at"):
		var lc = data.get("last_claim_at", null)
		last_claim_at = float(lc) if lc != null else 0.0
	## Mirror ownership into PlayerData for synchronous UI gating (e.g. the
	## prestige row visibility), without PlayerData needing to call the server.
	if get_node_or_null("/root/PlayerData") != null:
		PlayerData.money_gun_owned = owned
		PlayerData.money_gun_level = level
	return true


## ── Public API ───────────────────────────────────────────────────

## Fetches the full Benjamin/gun state from the server. Returns friendly dict.
func refresh() -> Dictionary:
	is_loading = true
	var res := await _rpc("get_benjamin_balance", {"p_device_hash": _device_hash()})
	is_loading = false
	if not res.get("ok", false):
		return _friendly(res)
	apply_payload(res.get("data", {}))
	money_gun_changed.emit()
	return {"ok": true}


## Claims accrued Benjamins (server computes the amount). Returns { ok, claimed,
## balance } or a friendly error.
func claim() -> Dictionary:
	var res := await _rpc("claim_benjamins", {"p_device_hash": _device_hash()})
	if res.get("ok", false):
		var data = res.get("data", {})
		if data is Dictionary:
			balance = int(data.get("balance", balance))
			accrued = 0
			## Server reset the clock on a non-zero claim.
			if int(data.get("claimed", 0)) > 0:
				last_claim_at = TrustedClock.now()
		money_gun_changed.emit()
	return _friendly(res)


## Buys the Money Gun. Records server ownership FIRST, then deducts the coin
## cost locally. Refuses if already owned or the player can't afford it.
## Returns { ok } or { ok=false, error, message }.
func buy() -> Dictionary:
	if owned or PlayerData.money_gun_owned:
		return {"ok": false, "error": "already_owned", "message": "You already own the Money Gun."}
	if PlayerData.coins < MONEY_GUN_COST:
		return {"ok": false, "error": "insufficient_coins",
			"message": "The Money Gun costs %s coins." % PlayerData.format_number(MONEY_GUN_COST)}

	var res := await _rpc("buy_money_gun", {"p_device_hash": _device_hash()})
	if not res.get("ok", false):
		return _friendly(res)

	## Server recorded ownership — now charge the local coins.
	PlayerData.coins -= MONEY_GUN_COST
	PlayerData.money_gun_owned = true
	PlayerData.money_gun_level = 0
	PlayerData.save_data()
	PlayerData.data_changed.emit()

	owned = true
	level = 0
	await refresh()
	return {"ok": true}


## Upgrades the gun one level (server-authoritative). The XP cost is charged by
## the caller (prestige screen) BEFORE calling this. Returns friendly dict with
## { ok, level } on success.
func upgrade() -> Dictionary:
	var res := await _rpc("upgrade_money_gun", {"p_device_hash": _device_hash()})
	if res.get("ok", false):
		var data = res.get("data", {})
		if data is Dictionary:
			level = int(data.get("level", level + 1))
			balance = int(data.get("balance", balance))
			if get_node_or_null("/root/PlayerData") != null:
				PlayerData.money_gun_level = level
		await refresh()
	return _friendly(res)


## ── Cheat helpers (fire-and-forget; called from PlayerData cheats) ──
## These are async; the sync cheat Callables call them without awaiting and a
## notification reports the outcome (same pattern as _run_marketplace_register).

func cheat_grant_gun() -> void:
	var res := await _rpc("buy_money_gun", {"p_device_hash": _device_hash()})
	if res.get("ok", false):
		PlayerData.money_gun_owned = true
		PlayerData.money_gun_level = 0
		PlayerData.save_data()
		PlayerData.data_changed.emit()
		await refresh()
		_notify("Money Gun 🔫", "The Money Gun is yours — start printing!")
	else:
		var f := _friendly(res)
		if str(f.get("error", "")) == "already_owned":
			_notify("Money Gun", "You already own the Money Gun.")
		else:
			_notify("Money Gun ❌", str(f.get("message", "Could not grant the gun.")))


func cheat_grant_benjamins(amount: int) -> void:
	var res := await _rpc("grant_benjamins", {
		"p_device_hash": _device_hash(),
		"p_amount":      amount,
		"p_secret":      BENJAMIN_GRANT_SECRET,
	})
	if res.get("ok", false):
		var data = res.get("data", {})
		if data is Dictionary:
			balance = int(data.get("balance", balance))
		money_gun_changed.emit()
		_notify("Benjamins 💵", "Granted %d Benjamins." % amount)
	else:
		_notify("Benjamins ❌", str(_friendly(res).get("message", "Could not grant Benjamins.")))


## ── Private ──────────────────────────────────────────────────────

func _notify(title: String, msg: String) -> void:
	if get_node_or_null("/root/GameNotification") != null:
		GameNotification.show_message(title, msg)


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
		"account_not_found":  msg = "Online account required."
		"no_money_gun":       msg = "You don't own the Money Gun."
		"already_owned":      msg = "You already own the Money Gun."
		"max_level":          msg = "The Money Gun is already at max level."
		"insufficient_coins": msg = "Not enough coins."
		"bad_secret":         msg = "Grant refused."
		"invalid_amount":     msg = "Invalid amount."
		"offline":            msg = "No connection."
		_:                    msg = "Error: %s" % code
	return {"ok": false, "error": code, "message": msg}
