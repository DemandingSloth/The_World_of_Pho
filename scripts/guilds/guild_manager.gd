extends Node

## Autoload: GuildManager
## Client-side layer for the Guilds feature.  All durable state lives in
## Supabase; this node caches what the client needs for the current session
## and surfaces a clean API for the UI screens.
##
## Build-order from the implementation plan:
##   Step 2 — Guild creation / join / leave + roster
##   Step 3 — Mission multiplier + spawn (via MissionBoard hook)
##   Step 4 — Contribution hook (see MissionBoard.gd)
##   Step 5 — Completion RPC + distribution
##   Step 6 — Upgrades screen
##   Step 7 — Linking system + effective-perk resolution
##   Steps 8/9 — Community garden / expedition (future)

## ── Signals ─────────────────────────────────────────────────────

## Emitted whenever the cached guild data changes (join/leave/refresh).
signal guild_data_changed()
## Emitted when an RPC call completes, carrying a user-facing message.
signal operation_done(ok: bool, message: String)

## ── Constants ────────────────────────────────────────────────────

const VALID_SPECIALIZATIONS: Array[String] = ["gardening", "mining", "horse"]
const MIN_CAPACITY := 5
const MAX_CAPACITY := 20

## Grid dimensions for each community-garden level (§6 of the plan).
const GARDEN_GRID_LEVELS: Array[Dictionary] = [
	{"level": 0, "width": 5,  "height": 5},
	{"level": 1, "width": 10, "height": 5},
	{"level": 2, "width": 10, "height": 10},
	{"level": 3, "width": 18, "height": 10},
	{"level": 4, "width": 18, "height": 18},
	{"level": 5, "width": 27, "height": 18},
	{"level": 6, "width": 27, "height": 27},
	{"level": 7, "width": 38, "height": 27},
	{"level": 8, "width": 38, "height": 38},
	{"level": 9, "width": 50, "height": 38},
	{"level": 10,"width": 50, "height": 50},
]

## Cooldown durations in seconds (§9 of the plan).
const COOLDOWN_NORMAL_SEC  := 48 * 3600.0   ## 48 h
const COOLDOWN_LINKED_SEC  := 24 * 3600.0   ## 24 h when switching to a linked guild

## ── Cached state (refreshed on every enter() of a guilds screen) ─

## The guild the local player currently belongs to, or {} if none.
var current_guild: Dictionary = {}

## Active guild missions: Array of mission Dictionaries from the server.
var guild_missions: Array = []

## Guild members: Array of member Dictionaries (user_id, username, role, etc.)
var guild_roster: Array = []

## Guild upgrades: Dictionary of upgrade_key → level.
var guild_upgrades: Dictionary = {}

## Effective perk table returned by get_effective_guild_perks RPC.
var effective_perks: Dictionary = {}

## True while any async RPC is in flight.
var is_loading := false

## Cached local probation info: { perks_active_at: float } or {}
## Populated from the server after join/refresh; used to gate contribution
## hooks (§8/§9 of the plan).
var _local_member_info: Dictionary = {}


## ── Convenience helpers ──────────────────────────────────────────

func is_in_guild() -> bool:
	return current_guild.get("id", "") != ""


## Returns true if the player's probation period has passed and they may
## contribute to guild missions and receive perks (§9).
func perks_active() -> bool:
	if not is_in_guild():
		return false
	var _pat_raw = _local_member_info.get("perks_active_at", null)
	var pat: float = 0.0
	if _pat_raw != null and _pat_raw != "null" and _pat_raw != "":
		pat = float(str(_pat_raw))
	if pat <= 0.0:
		return true  ## first-ever join — no probation
	return TrustedClock.now() >= pat


func guild_id() -> String:
	return str(current_guild.get("id", ""))


func guild_name() -> String:
	return str(current_guild.get("name", ""))


func guild_specialization() -> String:
	return str(current_guild.get("specialization", ""))


func guild_capacity() -> int:
	return int(current_guild.get("capacity", 5))


func guild_member_count() -> int:
	return guild_roster.size()


## Multiplier for guild missions (§3): (capacity + member_count) / 2.
## Returned as a float — caller rounds only after applying to the base target.
func mission_multiplier() -> float:
	var cap := float(guild_capacity())
	var members := float(guild_member_count())
	return ((cap + members) / 2.0)*25


## ── Guild perk multipliers (applied to live gameplay) ────────────
## Each guild upgrade track grants a per-level % bonus. These resolve the
## player's EFFECTIVE perk strength — their own guild's level PLUS any linked
## guild's level (the cross-spec perk, scaled by the link_discount upgrade) —
## and return a ready-to-apply multiplier. All return a neutral 1.0 when not in
## a guild, during the join probation window, or when the track is level 0, so
## callers can multiply unconditionally.
##
## Per-level steps (match the server + guild_detail_screen display):
##   crop_sell_value, gem_sell_value : +5% per level  (increase)
##   growth_time, foundry_time, prospector_cost : -5% per level (reduce)

## Effective level for a perk key = own level + linked level × link strength.
## effective_perks holds the player's own upgrades plus the linked guild's under
## a 'linked_' prefix (see server _guild_effective_perks). The linked
## contribution is scaled by this guild's link_discount track (+5% strength/lvl).
func _effective_perk_level(key: String) -> float:
	if not is_in_guild() or not perks_active():
		return 0.0
	var own := float(int(effective_perks.get(key, guild_upgrades.get(key, 0))))
	var linked := float(int(effective_perks.get("linked_" + key, 0)))
	if linked > 0.0:
		var discount_lvl := float(int(effective_perks.get("link_discount",
			guild_upgrades.get("link_discount", 0))))
		linked *= (1.0 + discount_lvl * 0.05)
	return own + linked


## Increase multiplier: 1.0 + level × step%. (crop/gem sell value.)
func _perk_increase_mult(key: String, step_pct: float) -> float:
	return 1.0 + _effective_perk_level(key) * (step_pct / 100.0)


## Reduction multiplier: 1.0 − level × step%, floored at 0.5 so it can't invert.
## (growth_time, foundry_time, prospector_cost — lower is faster/cheaper.)
func _perk_reduce_mult(key: String, step_pct: float) -> float:
	return maxf(1.0 - _effective_perk_level(key) * (step_pct / 100.0), 0.5)


## Crop sell-value multiplier from the guild 'crop_sell_value' track (+5%/lvl).
func crop_sell_perk_mult() -> float:
	return _perk_increase_mult("crop_sell_value", 5.0)

## Gem (and polished gem) sell-value multiplier from 'gem_sell_value' (+5%/lvl).
func gem_sell_perk_mult() -> float:
	return _perk_increase_mult("gem_sell_value", 5.0)

## Crop growth-time multiplier from 'growth_time' (−5%/lvl; lower = faster).
func growth_time_perk_mult() -> float:
	return _perk_reduce_mult("growth_time", 5.0)

## Foundry smelt-time multiplier from 'foundry_time' (−5%/lvl; lower = faster).
func foundry_time_perk_mult() -> float:
	return _perk_reduce_mult("foundry_time", 5.0)

## Prospector hire-cost multiplier from 'prospector_cost' (−5%/lvl; lower = cheaper).
func prospector_cost_perk_mult() -> float:
	return _perk_reduce_mult("prospector_cost", 5.0)


## ── Public API — data fetching ───────────────────────────────────

## Fetches all guild data for the current player: guild info, roster, missions,
## upgrades, and effective perks.  Populates all cached fields above.
## Returns { ok, error }.
func refresh_all() -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	is_loading = true
	guild_data_changed.emit()

	var res := await _rpc("get_player_guild_summary", {
		"p_device_hash": _device_hash(),
	})
	is_loading = false

	if not res.get("ok", false):
		guild_data_changed.emit()
		return res

	var data = res.get("data", {})
	if not data is Dictionary:
		guild_data_changed.emit()
		return {"ok": false, "error": "Unexpected server response."}

	current_guild     = _dict(data.get("guild", {}))
	guild_roster      = _array(data.get("roster", []))
	guild_missions    = _array(data.get("missions", []))
	guild_upgrades    = _dict(data.get("upgrades", {}))
	effective_perks   = _dict(data.get("effective_perks", {}))
	_local_member_info = _dict(data.get("member_info", {}))

	# Keep PlayerData's local cache in sync with server truth.
	PlayerData.guild_id   = str(current_guild.get("id",   ""))
	PlayerData.guild_role = str(_local_member_info.get("role", ""))
	PlayerData.save_data()

	guild_data_changed.emit()

	## Grant XP for any guild-mission token rewards received since last check.
	await claim_guild_reward_xp()
	return {"ok": true}


## Awards local XP for guild-mission TOKEN rewards received since the last check.
## Guild missions pay marketplace tokens on completion; this grants the matching
## XP at the game's standard rate: XP = tokens × 5. (Tokens are ~1/10 of coin
## value, and normal XP is ~1/2 coin value, so ×5 keeps guild XP in line.)
## Idempotent via PlayerData.guild_reward_xp_watermark — each token reward is
## only ever counted once. Safe to call freely (on refresh / after a deposit).
const GUILD_REWARD_XP_PER_TOKEN := 5

func claim_guild_reward_xp() -> void:
	if not _check_configured():
		return
	var res := await _rpc("claim_guild_reward_xp", {
		"p_device_hash": _device_hash(),
		"p_since_epoch": PlayerData.guild_reward_xp_watermark,
	})
	if not res.get("ok", false):
		return
	var data = res.get("data", {})
	if not data is Dictionary:
		return
	var first_claim := PlayerData.guild_reward_xp_watermark <= 0.0

	if first_claim:
		## First-ever claim: anchor the watermark to the server's CURRENT time so
		## we don't retroactively grant XP for a pre-feature player's historical
		## guild rewards. Rewards earned after now will award XP on later claims.
		var server_now := float(data.get("server_now", 0.0))
		PlayerData.guild_reward_xp_watermark = maxf(server_now, 1.0)
		PlayerData.save_data()
		return

	var tokens := int(data.get("tokens_since", 0))
	var latest := float(data.get("latest_epoch", PlayerData.guild_reward_xp_watermark))
	if latest > PlayerData.guild_reward_xp_watermark:
		PlayerData.guild_reward_xp_watermark = latest

	if tokens > 0:
		## award_xp applies the Scholar prestige multiplier, matching all other
		## XP sources, saves, and emits data_changed.
		PlayerData.award_xp(tokens * GUILD_REWARD_XP_PER_TOKEN)
	else:
		PlayerData.save_data()


## Fetches only guild missions (lighter than refresh_all).
func refresh_missions() -> Dictionary:
	if not is_in_guild():
		return {"ok": false, "error": "Not in a guild."}
	var res := await _rpc("get_guild_missions", {
		"p_device_hash": _device_hash(),
		"p_guild_id": guild_id(),
	})
	if res.get("ok", false):
		var d = res.get("data", {})
		if d is Dictionary:
			guild_missions = _array(d.get("missions", []))
			guild_data_changed.emit()
	return res


## Rerolls a single active guild mission by its server UUID.
## Deducts coins and consumes one daily reroll from the shared PlayerData
## allowance (same pool as the solo mission board).
## Returns { ok } or { ok=false, error }.
## Rerolls a guild mission. LEADER-ONLY, priced in the guild's shared UPGRADE
## POINTS on a tiered curve (migration 066): first 3/day free, then 1 pt each
## for the next 3, 2 pt for the next 3, etc; resets daily. No longer uses coins
## or the solo mission-board allowance. The server is authoritative on the cost
## and point balance. Returns { ok, cost, next_cost, points_remaining,
## rerolls_used } or { ok=false, error }.
func reroll_guild_mission(p_mission_id: String) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	if not is_in_guild():
		return {"ok": false, "error": "Not in a guild."}
	if p_mission_id.is_empty():
		return {"ok": false, "error": "Invalid mission id."}
	if PlayerData.guild_role != "leader":
		return {"ok": false, "error": "Only the guild leader can reroll missions."}

	var res := await _rpc("reroll_guild_mission", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id(),
		"p_mission_id":  p_mission_id,
	})
	## Reflect the authoritative upgrade_points balance in the cache on success.
	if res.get("ok", false):
		var data = res.get("data", {})
		if data is Dictionary and data.has("points_remaining"):
			current_guild["upgrade_points"] = int(data.get("points_remaining", current_guild.get("upgrade_points", 0)))
	return _unwrap(res, "reroll_guild_mission")


## Reads the next reroll's upgrade-point cost + free-rerolls-remaining without
## doing a reroll (migration 066). Returns { ok, rerolls_used, next_cost,
## free_remaining, upgrade_points, is_leader } or { ok=false, error }.
func guild_reroll_status() -> Dictionary:
	if not _check_configured() or not is_in_guild():
		return {"ok": false, "error": "Not in a guild."}
	var res := await _rpc("get_guild_reroll_status", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id(),
	})
	return _unwrap(res, "get_guild_reroll_status")


## Spawns a new mission into an empty difficulty slot (leader only).
## `p_difficulty` must be "easy", "medium", or "hard".
## The slot must have no currently active mission — the server enforces this.
## Returns { ok } or { ok=false, error }.
func spawn_guild_mission(p_difficulty: String) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	if not is_in_guild():
		return {"ok": false, "error": "Not in a guild."}
	if PlayerData.guild_role != "leader":
		return {"ok": false, "error": "Only the guild leader can spawn missions."}
	if p_difficulty not in ["easy", "medium", "hard"]:
		return {"ok": false, "error": "Invalid difficulty."}

	var res := await _rpc("spawn_guild_mission", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id(),
		"p_difficulty":  p_difficulty,
	})
	return _unwrap(res, "spawn_guild_mission")


## ── Public API — guild lifecycle ────────────────────────────────

## Returns the current guild creation cost in coins.
## Cost = 1,000,000,000 × (1 + 0.1 × existing_guild_count).
## Returns { ok, cost: int, guild_count: int } or { ok=false, error }.
func get_guild_creation_cost() -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required.", "cost": 0, "guild_count": 0}
	var res := await _rpc("get_guild_creation_cost", null)
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Failed to fetch cost.")), "cost": 0, "guild_count": 0}
	var d = res.get("data", {})
	if not d is Dictionary:
		return {"ok": false, "error": "Unexpected response.", "cost": 0, "guild_count": 0}
	return {
		"ok":          true,
		"cost":        int(d.get("cost", 1000000000)),
		"guild_count": int(d.get("guild_count", 0)),
	}


## Creates a new guild.  `p_name` = display name; `p_spec` = "gardening"|"mining".
## All guilds start at the default capacity of 5 and grow via the capacity upgrade.
## Deducts the creation cost from PlayerData.coins on success.
## Returns { ok, guild } or { ok=false, error }.
func create_guild(p_name: String, p_spec: String) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	if is_in_guild():
		return {"ok": false, "error": "You're already in a guild. Leave first."}
	p_name = p_name.strip_edges()
	if p_name.length() < 3 or p_name.length() > 32:
		return {"ok": false, "error": "Guild name must be 3–32 characters."}
	if p_spec not in VALID_SPECIALIZATIONS:
		return {"ok": false, "error": "Invalid specialization."}

	# Fetch current cost (re-queried here so the cost is always fresh at submit time).
	var cost_res := await get_guild_creation_cost()
	if not cost_res.get("ok", false):
		return {"ok": false, "error": cost_res.get("error", "Could not verify creation cost.")}
	var cost: int = cost_res.get("cost", 0)
	if PlayerData.coins < cost:
		return {"ok": false, "error": "Not enough coins. Need %s." % PlayerData.format_number(cost)}

	var res := await _rpc("create_guild", {
		"p_device_hash":    _device_hash(),
		"p_name":           p_name,
		"p_specialization": p_spec,
	})
	if res.get("ok", false):
		PlayerData.coins -= cost
		PlayerData.save_data()
		await refresh_all()
	return _unwrap(res, "create_guild")


## Joins an existing guild by its UUID.
## Returns { ok } or { ok=false, error }.
func join_guild(p_guild_id: String) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	if is_in_guild():
		return {"ok": false, "error": "Leave your current guild before joining another."}

	var res := await _rpc("join_guild", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    p_guild_id,
	})
	if res.get("ok", false):
		await refresh_all()
	return _unwrap(res, "join_guild")


## Leaves the current guild.
## Returns { ok } or { ok=false, error }.
func leave_guild() -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	if not is_in_guild():
		return {"ok": false, "error": "You're not in a guild."}

	var res := await _rpc("leave_guild", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id(),
	})
	if res.get("ok", false):
		current_guild = {}
		guild_roster = []
		guild_missions = []
		guild_upgrades = {}
		effective_perks = {}
		_local_member_info = {}
		PlayerData.guild_id   = ""
		PlayerData.guild_role = ""
		PlayerData.save_data()
		guild_data_changed.emit()
	return _unwrap(res, "leave_guild")


## Disbands (permanently shuts down) the current guild. LEADER ONLY — deletes
## the guild and all of its data server-side (cascade also severs every link
## Transfers guild leadership to another active member. Leader-only.
## The caller becomes a regular member; p_new_leader_id gets the leader role.
## On success refreshes the guild summary so PlayerData.guild_role updates.
## Returns { ok, new_leader_id, new_leader_username } or { ok=false, error }.
func transfer_leadership(p_new_leader_id: String) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	if not is_in_guild():
		return {"ok": false, "error": "You're not in a guild."}
	if PlayerData.guild_role != "leader":
		return {"ok": false, "error": "Only the guild leader can transfer leadership."}

	var res := await _rpc("transfer_leadership", {
		"p_device_hash":   _device_hash(),
		"p_guild_id":      guild_id(),
		"p_new_leader_id": p_new_leader_id,
	})
	if res.get("ok", false):
		## Refresh so the caller's role flips to 'member' locally.
		await refresh_all()
	return _unwrap(res, "transfer_leadership")


## with other guilds). Clears all local guild state on success, same as leaving.
## Returns { ok } or { ok=false, error }.
func disband_guild() -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	if not is_in_guild():
		return {"ok": false, "error": "You're not in a guild."}

	var res := await _rpc("disband_guild", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id(),
	})
	if res.get("ok", false):
		current_guild = {}
		guild_roster = []
		guild_missions = []
		guild_upgrades = {}
		effective_perks = {}
		_local_member_info = {}
		PlayerData.guild_id   = ""
		PlayerData.guild_role = ""
		PlayerData.save_data()
		guild_data_changed.emit()
	return _unwrap(res, "disband_guild")


## ── Guild sales (migration 103) ─────────────────────────────────

## Leader-only: what this guild can be listed for. Returns
## { ok, levels, points, score, floor, min_score, others, eligible, reason }.
func get_guild_sale_quote() -> Dictionary:
	if not _check_configured() or not is_in_guild():
		return {"ok": false, "error": "You're not in a guild."}
	var res := await _rpc("get_guild_sale_quote", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id(),
	})
	if not res.get("ok", false):
		return _unwrap(res, "get_guild_sale_quote")
	var d = res.get("data", {})
	var out := {"ok": true}
	if d is Dictionary:
		out.merge(d)
	return out


## Lists the current guild for sale at `price` tokens. On success the leader is
## removed from the guild, so local guild state is cleared (same as leaving).
func list_guild_for_sale(price: int) -> Dictionary:
	if not _check_configured() or not is_in_guild():
		return {"ok": false, "error": "You're not in a guild."}
	var res := await _rpc("list_guild_for_sale", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id(),
		"p_price":       price,
	})
	if res.get("ok", false):
		_clear_local_guild()
	return _unwrap(res, "list_guild_for_sale")


## Sells the current guild to the game (migration 106) for its floor price,
## paid instantly. The game re-lists it at floor + 5%. The leader leaves the
## guild, so local guild state is cleared. Returns
## { ok, paid, new_balance, relisted_price, evicted_guild } or { ok=false, error }.
func sell_guild_to_game() -> Dictionary:
	if not _check_configured() or not is_in_guild():
		return {"ok": false, "error": "You're not in a guild."}
	var res := await _rpc("sell_guild_to_game", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id(),
	})
	if res.get("ok", false):
		_apply_new_token_balance(res)
		_clear_local_guild()
		var out := {"ok": true}
		var d = res.get("data", {})
		if d is Dictionary:
			out.merge(d)
		return out
	return _unwrap(res, "sell_guild_to_game")


## Public browse: { ok, items:[...], my_listing: Dictionary (empty if none) }.
func get_guild_sales() -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required.", "items": [], "my_listing": {}}
	var res := await _rpc("get_guild_sales", {"p_device_hash": _device_hash()})
	if not res.get("ok", false):
		var u := _unwrap(res, "get_guild_sales")
		u["items"] = []
		u["my_listing"] = {}
		return u
	var d = res.get("data", {})
	if not d is Dictionary:
		d = {}
	return {"ok": true, "items": _array(d.get("items", [])),
		"my_listing": _dict(d.get("my_listing", {}))}


## Buys a listed guild; the buyer becomes its leader. Updates the cached token
## balance and refreshes guild state.
func buy_guild(listing_id: String) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	var res := await _rpc("buy_guild", {
		"p_device_hash": _device_hash(),
		"p_listing_id":  listing_id,
	})
	if res.get("ok", false):
		_apply_new_token_balance(res)
		await refresh_all()
		var out := {"ok": true}
		var d = res.get("data", {})
		if d is Dictionary:
			out.merge(d)
		return out
	return _unwrap(res, "buy_guild")


## Seller pays the reclaim fee and moves back into their listed guild.
func reclaim_guild() -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	var res := await _rpc("reclaim_guild", {"p_device_hash": _device_hash()})
	if res.get("ok", false):
		_apply_new_token_balance(res)
		await refresh_all()
		var out := {"ok": true}
		var d = res.get("data", {})
		if d is Dictionary:
			out.merge(d)
		return out
	return _unwrap(res, "reclaim_guild")


func _apply_new_token_balance(res: Dictionary) -> void:
	var d = res.get("data", {})
	if d is Dictionary and d.has("new_balance") and get_node_or_null("/root/MarketplaceAccount") != null:
		var nb := int(d["new_balance"])
		if nb != MarketplaceAccount.token_balance:
			MarketplaceAccount.token_balance = nb
			MarketplaceAccount.token_balance_changed.emit(nb)


func _clear_local_guild() -> void:
	current_guild = {}
	guild_roster = []
	guild_missions = []
	guild_upgrades = {}
	effective_perks = {}
	_local_member_info = {}
	PlayerData.guild_id   = ""
	PlayerData.guild_role = ""
	PlayerData.save_data()
	guild_data_changed.emit()


## Kicks a member from the guild (leader only).
func kick_member(p_user_id: String) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	var res := await _rpc("kick_guild_member", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id(),
		"p_target_id":   p_user_id,
	})
	if res.get("ok", false):
		await refresh_all()
	return _unwrap(res, "kick_guild_member")


## Searches for guilds by partial name.  Returns { ok, guilds: Array }.
func search_guilds(query: String, spec_filter: String = "") -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required.", "guilds": []}
	var body := {
		"p_device_hash": _device_hash(),
		"p_query":       query.strip_edges(),
	}
	if spec_filter != "":
		body["p_specialization"] = spec_filter
	var res := await _rpc("search_guilds", body)
	if res.get("ok", false):
		var d = res.get("data", {})
		var guilds = d.get("guilds", []) if d is Dictionary else []
		return {"ok": true, "guilds": _array(guilds)}
	return {"ok": false, "error": str(res.get("error", "Search failed.")), "guilds": []}


## Returns the most active joinable (non-full) guilds, best-first, for the
## "recommended guilds" list shown when the player isn't in a guild. Activity is
## scored server-side (recent completed missions, members, upgrade points).
## `spec_filter` optionally restricts to "gardening"/"mining". Returns
## { ok, guilds: Array } with the same per-guild shape as search_guilds (plus
## recent_completions / activity_score).
func get_top_active_guilds(spec_filter: String = "", limit: int = 10) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required.", "guilds": []}
	var body := {
		"p_device_hash": _device_hash(),
		"p_limit":       limit,
	}
	if spec_filter != "":
		body["p_specialization"] = spec_filter
	var res := await _rpc("get_top_active_guilds", body)
	if res.get("ok", false):
		var d = res.get("data", {})
		var guilds = d.get("guilds", []) if d is Dictionary else []
		return {"ok": true, "guilds": _array(guilds)}
	return {"ok": false, "error": str(res.get("error", "Could not load recommendations.")), "guilds": []}


## ── Public API — missions ────────────────────────────────────────

## Accepts a guild mission on behalf of the player.
func accept_guild_mission(mission_id: String) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	var res := await _rpc("accept_guild_mission", {
		"p_device_hash": _device_hash(),
		"p_mission_id":  mission_id,
	})
	if res.get("ok", false):
		await refresh_missions()
	return _unwrap(res, "accept_guild_mission")


## Records the local player's contribution to an active guild mission.
## Called by MissionBoard's on_* hook (§8 of the plan).
## `base_key` matches base_mission_key in guild_missions.
## `amount` is the increment (same unit as the solo mission progress).
func record_contribution(base_key: String, amount: int) -> void:
	if amount <= 0 or not is_in_guild() or not perks_active():
		return
	## Fire-and-forget: we don't block gameplay on this.
	_rpc("record_guild_contribution", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id(),
		"p_base_key":    base_key,
		"p_amount":      amount,
	})


## Deposits harvested crops or orchard fruit into an active guild deposit mission.
## `mission_key` is the mission's base_mission_key, e.g. "deposit_beans" or "deposit_fruit".
## `item_id` is the specific crop or fruit id being deposited (e.g. "apple" for "deposit_fruit").
## If omitted, it is inferred from mission_key (e.g. "deposit_beans" -> "beans").
## Consumes `qty` from PlayerData, records contribution, and refreshes the mission list.
## Refunds items on failure.
func deposit_crops_for_mission(mission_key: String, qty: int, item_id: String = "") -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "online_required"}
	if not is_in_guild():
		return {"ok": false, "error": "not_in_guild"}
	if not perks_active():
		return {"ok": false, "error": "perks_inactive"}
	if qty <= 0:
		return {"ok": false, "error": "invalid_amount"}

	## Derive the item_id from the mission key if not explicitly provided
	if item_id.is_empty():
		item_id = mission_key.trim_prefix("deposit_")

	## Validate item against mission type
	if mission_key == "deposit_fruit":
		if not PlayerData.is_orchard_fruit(item_id):
			return {"ok": false, "error": "invalid_fruit"}
	elif mission_key == "deposit_produce":
		if not PlayerData.is_produce(item_id):
			return {"ok": false, "error": "invalid_produce"}
	else:
		if PlayerData.get_crop_or_fruit_def(item_id).is_empty():
			return {"ok": false, "error": "invalid_crop"}

	if PlayerData.get_crop_or_fruit_count(item_id) < qty:
		return {"ok": false, "error": "insufficient_crops"}

	## Consume first so the player can't deposit more than they own
	## even if the network call is slow.
	if not PlayerData.consume_crop_or_fruit(item_id, qty):
		return {"ok": false, "error": "insufficient_crops"}

	## Canonical key so the server can refund the exact item on reroll/expire
	## (crops vs orchard fruit live in different stores).
	var item_key := ItemKeyRegistry.fruit_key(item_id) if PlayerData.is_orchard_fruit(item_id) \
			else ItemKeyRegistry.crop_key(item_id)

	var res := await _rpc("record_guild_contribution", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id(),
		"p_base_key":    mission_key,
		"p_amount":      qty,
		"p_item_key":    item_key,
	})

	if res.get("ok", false):
		## Refresh so the progress bar updates immediately.
		await refresh_missions()
		## A deposit may have COMPLETED the mission (crediting tokens) — grant
		## the matching XP now.
		await claim_guild_reward_xp()
	else:
		## Refund items on failure.
		PlayerData.add_crop_or_fruit(item_id, qty)

	return _unwrap(res, "record_guild_contribution")


## ── Mining guild deposits (gems / polished gems / ores) ──────────
## Mining guilds ask for gems and ores the way gardening guilds ask for produce.
## Items live in different local stores, so we route through the marketplace item
## vocabulary (PlayerData.market_* with canonical keys) which already knows how
## to count / remove / add gems, polished gems, and resources.

## Maps a mining deposit mission key + chosen item id to a canonical market key
## ("gem:diamond", "polished:ruby", "resource:iron_bar"), or "" if the item isn't
## valid for that mission category. Generic buckets (deposit_gems/polished/ores)
## accept any item id of that category; specific keys pin the exact item.
func _mining_deposit_market_key(mission_key: String, item_id: String) -> String:
	match mission_key:
		"deposit_gems":
			return "gem:%s" % item_id if _is_unpolished_gem(item_id) else ""
		"deposit_polished":
			return "polished:%s" % item_id if _is_polished_gem(item_id) else ""
		"deposit_ores":
			return "resource:%s" % item_id if _is_mining_resource(item_id) else ""
		_:
			if mission_key.begins_with("deposit_polished_"):
				var pid := mission_key.trim_prefix("deposit_polished_")
				return "polished:%s" % pid if pid == item_id and _is_polished_gem(pid) else ""
			if mission_key.begins_with("deposit_gem_"):
				var gid := mission_key.trim_prefix("deposit_gem_")
				return "gem:%s" % gid if gid == item_id and _is_unpolished_gem(gid) else ""
			if mission_key.begins_with("deposit_ore_"):
				var oid := mission_key.trim_prefix("deposit_ore_")
				return "resource:%s" % oid if oid == item_id and _is_mining_resource(oid) else ""
	return ""


func _is_unpolished_gem(item_id: String) -> bool:
	for def in PlayerData.PROSPECTOR_GEM_ORDER:
		if str(def.get("gem_type", "")) == item_id:
			return true
	return false


func _is_polished_gem(item_id: String) -> bool:
	return PlayerData.POLISHABLE_GEMS.has(item_id)


func _is_mining_resource(item_id: String) -> bool:
	## Only ores/bars/ingots (value_group 'gem'); excludes wood/sticks.
	var def := PlayerData.get_resource_def(item_id)
	return not def.is_empty() and str(def.get("value_group", "")) == "gem"


## Deposits `qty` of a gem/polished/ore item into a mining guild deposit mission.
## `mission_key` is the mission's base_mission_key (e.g. "deposit_ore_iron_bar"
## or a generic "deposit_gems"); `item_id` is the chosen item (e.g. "iron_bar").
## Consumes locally first, records the contribution, and refunds on failure —
## same shape as deposit_crops_for_mission but for mining stores.
func deposit_mining_for_mission(mission_key: String, qty: int, item_id: String) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "online_required"}
	if not is_in_guild():
		return {"ok": false, "error": "not_in_guild"}
	if not perks_active():
		return {"ok": false, "error": "perks_inactive"}
	if qty <= 0:
		return {"ok": false, "error": "invalid_amount"}

	var market_key := _mining_deposit_market_key(mission_key, item_id)
	if market_key == "":
		return {"ok": false, "error": "invalid_item"}

	if PlayerData.market_count_owned(market_key) < qty:
		return {"ok": false, "error": "insufficient_items"}

	## Consume first so the player can't deposit more than they own even if the
	## network call is slow.
	if not PlayerData.market_remove_owned(market_key, qty):
		return {"ok": false, "error": "insufficient_items"}

	var res := await _rpc("record_guild_contribution", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id(),
		"p_base_key":    mission_key,
		"p_amount":      qty,
		## market_key is already canonical (gem:/polished:/resource:) — the
		## server escrows exactly this back to the owner on reroll/expire.
		"p_item_key":    market_key,
	})

	if res.get("ok", false):
		await refresh_missions()
		## A deposit may have COMPLETED the mission (crediting tokens) — grant
		## the matching XP now.
		await claim_guild_reward_xp()
	else:
		## Refund on failure.
		PlayerData.market_add_owned(market_key, qty)

	return _unwrap(res, "record_guild_contribution")


## ── Public API — upgrades ────────────────────────────────────────

## Spends the guild's upgrade_points on one level of an upgrade track.
## Leader only.  Returns { ok } or { ok=false, error }.
func purchase_upgrade(upgrade_key: String) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	var res := await _rpc("purchase_guild_upgrade", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id(),
		"p_upgrade_key": upgrade_key,
	})
	if res.get("ok", false):
		await refresh_all()
	return _unwrap(res, "purchase_guild_upgrade")


## ── Public API — linking ─────────────────────────────────────────

## Sends a link request from this guild to `target_guild_id`.
func request_link(target_guild_id: String) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	var res := await _rpc("request_guild_link", {
		"p_device_hash":    _device_hash(),
		"p_guild_id":       guild_id(),
		"p_target_guild_id": target_guild_id,
	})
	if res.get("ok", false):
		await refresh_all()
	return _unwrap(res, "request_guild_link")


## Accepts a pending link request from `requesting_guild_id`.
func accept_link(requesting_guild_id: String) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	var res := await _rpc("accept_guild_link", {
		"p_device_hash":       _device_hash(),
		"p_guild_id":          guild_id(),
		"p_requesting_guild_id": requesting_guild_id,
	})
	if res.get("ok", false):
		await refresh_all()
	return _unwrap(res, "accept_guild_link")


## Removes an active link.
func remove_link(linked_guild_id: String) -> Dictionary:
	if not _check_configured():
		return {"ok": false, "error": "Online account required."}
	var res := await _rpc("remove_guild_link", {
		"p_device_hash":    _device_hash(),
		"p_guild_id":       guild_id(),
		"p_linked_guild_id": linked_guild_id,
	})
	if res.get("ok", false):
		await refresh_all()
	return _unwrap(res, "remove_guild_link")


## ── Contribution hook helpers ────────────────────────────────────

## Returns the base_mission_key string for a given MissionBoard.MissionType int.
## Used by MissionBoard to map a solo-mission event to a guild mission type.
## Keys must match what the server stores in guild_missions.base_mission_key.
static func mission_type_to_base_key(mission_type: int) -> String:
	## Mirror of MissionBoard.MissionType enum values → server key strings.
	match mission_type:
		0:  return "gems"
		1:  return "crops"
		2:  return "expeditions"
		3:  return "deep_mine"
		4:  return "polish"
		5:  return "smelt"
		6:  return "fruit"
		7:  return "chop"
		8:  return "sell_polished"
		9:  return "sell_bars"
		10: return "game_easy"
		11: return "game_medium"
		12: return "game_hard"
		13: return "game_brutal"
		14: return "beat_wolves"
		15: return "beat_bears"
		16: return "beat_npcs"
		17: return "win_terrain"
		18: return "prospectors"
		19: return "deposit"
	return ""


## Called by the Supabase SQL function after a guild mission completes to
## trigger a local cache refresh (via GameNotification + refresh_all).
## In practice the client polls on screen entry; this is a best-effort signal.
func notify_mission_completed(mission_id: String) -> void:
	GameNotification.show_message("Guild Mission Complete!",
		"Your guild finished a mission — check the Guilds screen for rewards.")
	refresh_missions()


## ── Private: RPC helpers ─────────────────────────────────────────

func _rpc(fn: String, body: Variant = null) -> Dictionary:
	if not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured."}
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


func _check_configured() -> bool:
	if get_node_or_null("/root/SupabaseClient") == null:
		return false
	if not SupabaseClient.is_configured():
		return false
	if not MarketplaceAccount.has_account():
		return false
	return true


## Extracts the canonical error from a server response and maps known codes to
## user-friendly strings.
func _unwrap(res: Dictionary, _fn: String) -> Dictionary:
	if res.get("ok", false):
		return res
	var code := str(res.get("error", ""))
	var friendly := _friendly_error(code)
	return {"ok": false, "error": friendly}


func _friendly_error(code: String) -> String:
	match code:
		"guild_name_taken":       return "That guild name is already taken."
		"already_in_guild":       return "You're already in a guild."
		"guild_full":             return "That guild is full."
		"not_guild_leader":       return "Only the guild leader can do that."
		"guild_not_found":        return "Guild not found."
		"member_not_found":       return "Member not found."
		"link_already_exists":    return "A link between those guilds already exists."
		"link_same_specialization": return "You can only link guilds with different specializations."
		"upgrade_max_level":      return "That upgrade is already at max level."
		"insufficient_points":    return "Not enough upgrade points."
		"probation_active":       return "You're still in the join cooldown period."
		"not_leader":             return "Only the guild leader can do that."
		"guild_not_empty":        return "Everyone else must leave the guild before you can sell it."
		"score_too_low":          return "Your guild needs a score (upgrades × points) of at least 50 to be sold."
		"price_below_floor":      return "That price is below the guild's minimum price."
		"already_listed":         return "This guild is already for sale."
		"has_guild_for_sale":     return "You have a guild for sale. Reclaim it, or wait for it to sell."
		"guild_for_sale":         return "That guild is for sale and can't be joined."
		"listing_not_found":      return "That guild is no longer for sale."
		"cannot_buy_own":         return "That's your guild — use Reclaim instead."
		"insufficient_tokens":    return "Not enough marketplace tokens."
		"no_listing":             return "You don't have a guild for sale."
		"leave_current_guild":    return "Leave your current guild first, then reclaim."
		"exchange_unavailable":   return "The Guild Exchange isn't available right now."
		"":                       return "Operation failed."
		_:                        return code


## Safe cast helpers to avoid type errors on null server data.
func _dict(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}


func _array(v: Variant) -> Array:
	return v if v is Array else []
