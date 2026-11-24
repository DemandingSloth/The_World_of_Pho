extends Node
## Autoload: GuildLeaderboard
## Client-side cache + RPC wrappers for the guild leaderboards (migration 056):
##   Players — top 25 by TOTAL lifetime_upgrade_points across all memberships,
##             shown with their current/most-recent guild name.
##   Guilds  — top 10 by guilds.upgrade_points.
## Read-only; mirrors the guild_stockpile_data.gd autoload shape.

## ── Signals ─────────────────────────────────────────────────────
signal leaderboard_changed()

## ── Cached state ─────────────────────────────────────────────────
## players: Array of { username, score, guild_name, is_you }
var players: Array = []
## guilds: Array of { name, specialization, upgrade_points, member_count, is_yours }
var guilds: Array = []

var is_loading := false


## ── RPC helpers (same shape as the other guild autoloads) ────────

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


## Parses a get_player_leaderboard payload into `players`. Factored out for tests.
func apply_players(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	players.clear()
	var raw = data.get("players", [])
	if raw is Array:
		for e in raw:
			if e is Dictionary:
				players.append({
					"username":   str(e.get("username", "")),
					"score":      int(e.get("score", 0)),
					"guild_name": str(e.get("guild_name", "")),
					"is_you":     bool(e.get("is_you", false)),
				})
	return true


## Parses a get_guild_leaderboard payload into `guilds`. Factored out for tests.
func apply_guilds(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	guilds.clear()
	var raw = data.get("guilds", [])
	if raw is Array:
		for e in raw:
			if e is Dictionary:
				guilds.append({
					"name":               str(e.get("name", "")),
					"specialization":     str(e.get("specialization", "")),
					"upgrade_points":     int(e.get("upgrade_points", 0)),
					## Guild score = points available × upgrades purchased (migration 087).
					"upgrades_purchased": int(e.get("upgrades_purchased", 0)),
					"score":              int(e.get("score", 0)),
					"member_count":       int(e.get("member_count", 0)),
					"is_yours":           bool(e.get("is_yours", false)),
				})
	return true


## ── Public API ───────────────────────────────────────────────────

## Fetches both leaderboards, populates the caches, emits leaderboard_changed.
func refresh() -> Dictionary:
	is_loading = true
	var pr := await _rpc("get_player_leaderboard", {"p_device_hash": _device_hash(), "p_limit": 25})
	var gr := await _rpc("get_guild_leaderboard", {"p_device_hash": _device_hash(), "p_limit": 10})
	is_loading = false

	if not pr.get("ok", false):
		return _friendly(pr)
	if not gr.get("ok", false):
		return _friendly(gr)

	apply_players(pr.get("data", {}))
	apply_guilds(gr.get("data", {}))
	leaderboard_changed.emit()
	return {"ok": true}


## ── Private ──────────────────────────────────────────────────────

func _friendly(res: Dictionary) -> Dictionary:
	if res.get("ok", false):
		return {"ok": true}
	var code := str(res.get("error", "unknown"))
	var msg: String
	match code:
		"account_not_found": msg = "Online account required."
		"not_in_guild":      msg = "You are not in a guild."
		"offline":           msg = "No connection."
		_:                   msg = "Error: %s" % code
	return {"ok": false, "error": code, "message": msg}
