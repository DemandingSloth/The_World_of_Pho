extends Node

## Autoload: MarketplaceAccount
## Owns the player's online marketplace identity: a locally-generated device id,
## the server account (id + username + token balance), and the one-time recovery
## code flow.
##
## Identity model (no email/password):
##  * On first online use we generate a random device id, persist it locally,
##    and send a salted HASH of it to register_account. The server creates an
##    account with a unique username + 2000 tokens and returns a recovery code
##    ONCE. That code is the only way to restore the account on another device.
##  * The device id + account handle live in user://marketplace_account.cfg,
##    which is folded into SaveBackup so export/restore carries the identity.
##
## This node stores only NON-sensitive handles locally (device id, account id,
## username, cached balance). The recovery code is never persisted — it is shown
## to the player exactly once and must be written down.

const SAVE_PATH := "user://marketplace_account.cfg"

## Salt mixed into the device id before hashing. Not a secret (the server never
## sees the raw device id anyway); it just makes the hash opaque.
const DEVICE_HASH_SALT := "world_of_pho_market_v1"

signal account_ready(username: String)
signal registration_failed(error: String)
## Emitted when a brand-new account is created and a recovery code must be shown.
signal recovery_code_available(username: String, recovery_code: String)
## Emitted whenever the cached token balance changes (e.g. after reconcile).
signal token_balance_changed(balance: int)

## Emitted when the online username changes (e.g. after a successful rename).
signal username_changed(username: String)

var device_id: String = ""
var account_id: String = ""
var username: String = ""
var token_balance: int = 2000
## One-shot admin override (set by the FreeNameChange cheat): the next rename
## skips the coin cost. Consumed on use; not persisted.
var free_name_change: bool = false
## True once we've registered with the server this session.
var _registered := false


func _ready() -> void:
	_load_local()
	## Auto-show the one-time recovery-code popup whenever a new account is made.
	recovery_code_available.connect(_on_recovery_code_available)
	## Link the in-game name with the online account once every autoload
	## (incl. PlayerData's save) has finished loading.
	call_deferred("sync_identity")


func _on_recovery_code_available(p_username: String, recovery_code: String) -> void:
	var RecoveryPopup := load("res://scripts/marketplace/recovery_code_popup.gd")
	RecoveryPopup.show_code(get_tree(), p_username, recovery_code)


## ── Local persistence ───────────────────────────────────────────

func _load_local() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		device_id = str(cfg.get_value("account", "device_id", ""))
		account_id = str(cfg.get_value("account", "account_id", ""))
		username = str(cfg.get_value("account", "username", ""))
		token_balance = int(cfg.get_value("account", "token_balance", 2000))
	if device_id == "":
		device_id = _generate_device_id()
		_save_local()


func _save_local() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("account", "device_id", device_id)
	cfg.set_value("account", "account_id", account_id)
	cfg.set_value("account", "username", username)
	cfg.set_value("account", "token_balance", token_balance)
	cfg.save(SAVE_PATH)


## Reloads local identity from disk. Called after a SaveBackup restore so a
## restored marketplace_account.cfg takes effect without an app restart.
func reload_local() -> void:
	_load_local()


## A random, stable-per-install device id (UUID-like). Not derived from hardware,
## so it's portable via backup/restore and immune to OS unique-id quirks.
func _generate_device_id() -> String:
	var bytes := PackedByteArray()
	for i in range(16):
		bytes.append(randi() % 256)
	return bytes.hex_encode()


## ── Server registration ─────────────────────────────────────────

## True if we have a server account handle (locally cached).
func has_account() -> bool:
	return account_id != ""


## Salted SHA-256 of the device id — what we send to the server. The raw device
## id never leaves the device.
func _device_hash() -> String:
	return (DEVICE_HASH_SALT + ":" + device_id).sha256_text()


## Changes the online username. The caller is responsible for the coin cost /
## admin override; this only validates format+profanity locally, then asks the
## server (authoritative for uniqueness) to apply it. On success updates the
## cached username. Returns { ok, username } or { ok=false, error }.
func rename(new_username: String) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured."}
	if not has_account():
		return {"ok": false, "error": "Register an online account first."}

	var name := new_username.strip_edges()
	## Reuse the in-game name validation (length, characters, profanity filter).
	var local_err := PlayerData.validate_name(name)
	if local_err != "":
		return {"ok": false, "error": local_err}
	if name == username:
		return {"ok": false, "error": "That's already your name."}

	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/rename_account",
		{"p_device_hash": _device_hash(), "p_new_username": name})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Rename failed."))}
	var data = res.get("data", null)
	if not (data is Dictionary) or data.has("error"):
		return {"ok": false, "error": _friendly_rename_error(data)}

	username = str(data.get("username", name))
	_save_local()
	username_changed.emit(username)
	return {"ok": true, "username": username}


func _friendly_rename_error(data) -> String:
	var code := ""
	if data is Dictionary and data.has("error"):
		code = str(data["error"])
	return friendly_name_error(code, "Rename failed.")


## Maps a server username error code (migration 099) to a player-facing message.
func friendly_name_error(code: String, fallback: String = "That name isn't allowed.") -> String:
	match code:
		"username_taken":    return "That name is already taken. Try another."
		"account_not_found": return "No online account found."
		"invalid_length":    return "Name must be 2-16 characters."
		"invalid_chars":     return "Name can only contain letters, numbers, and spaces."
		"profanity":         return "That name contains inappropriate language."
		"invalid":           return "That name isn't allowed."
	return fallback


## ── Unified identity (migration 099) ───────────────────────────
## The in-game name and the marketplace account name are the SAME name. The
## server is authoritative for uniqueness; the online name wins on conflict.

## Emitted when the player's local name can't be claimed online (taken by
## someone else, or fails the rules) and they must pick a new one.
signal name_needs_change(reason: String)

var _identity_sync_running := false
var _identity_synced := false  ## true once a sync succeeded this session
## Set when a sync found the local name can't be claimed, so a screen that opens
## AFTER the signal fired can still show the "choose a new name" prompt.
## Cleared by clear_name_change_request() once the player picks a valid name.
var pending_name_change_reason: String = ""


func clear_name_change_request() -> void:
	pending_name_change_reason = ""


## Is `name` acceptable and free? Returns { ok, available, error_code, error }.
## ok=false means the server couldn't be reached (offline / not configured).
func check_username(name: String) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "offline"}
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/check_username",
		{"p_device_hash": _device_hash(), "p_username": name.strip_edges()})
	if not res.get("ok", false):
		return {"ok": false, "error": "offline"}
	var data = res.get("data", null)
	if not (data is Dictionary):
		return {"ok": false, "error": "offline"}
	var code := str(data.get("error", ""))
	return {"ok": true, "available": bool(data.get("available", false)),
		"error_code": code, "error": friendly_name_error(code) if code != "" else ""}


## Creates this device's account with a CHOSEN name (or returns the existing one
## if the device is already registered — then `username` is the online name and
## created=false). Returns { ok, created, username } on success, or
## { ok=false, error, error_code } where error_code is "offline" for network
## problems or a server code (username_taken, profanity, …).
func register_with_name(name: String) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error_code": "offline", "error": "You're offline."}
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/register_account_with_name",
		{"p_device_hash": _device_hash(), "p_username": name.strip_edges()})
	if not res.get("ok", false):
		return {"ok": false, "error_code": "offline", "error": "Couldn't reach the server."}
	var data = res.get("data", null)
	if not (data is Dictionary):
		return {"ok": false, "error_code": "offline", "error": "Unexpected server response."}
	if data.has("error"):
		var code := str(data["error"])
		return {"ok": false, "error_code": code, "error": friendly_name_error(code)}

	account_id = str(data.get("id", account_id))
	username = str(data.get("username", username))
	token_balance = int(data.get("token_balance", token_balance))
	_registered = true
	_save_local()
	account_ready.emit(username)
	username_changed.emit(username)
	var created := bool(data.get("created", false))
	var recovery = data.get("recovery_code", null)
	if created and recovery != null and str(recovery) != "":
		recovery_code_available.emit(username, str(recovery))
	return {"ok": true, "created": created, "username": username}


## Reconciles the local name with the online account. Safe to call often (it is
## guarded and runs at most once successfully per session). Backwards-compatible
## path for existing players:
##   • has an online account → local name := online name if they differ.
##   • no online account     → register using the local name; if that name is
##     taken / not allowed, emit name_needs_change so the UI asks for a new one.
##   • offline               → do nothing; it retries on the next call.
func sync_identity() -> void:
	if _identity_synced or _identity_sync_running:
		return
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return
	if get_node_or_null("/root/PlayerData") == null or not PlayerData.has_set_name:
		return  ## first-run name prompt handles brand-new players
	_identity_sync_running = true

	if has_account():
		var rec: Dictionary = await reconcile()
		if rec.get("ok", false):
			_identity_synced = true
			if username != "" and username != PlayerData.player_name:
				PlayerData.adopt_online_name(username)
			## Keep server-enforced horse prestige (training cap, stable size) current.
			PlayerData.sync_horse_prestige()
	else:
		var reg: Dictionary = await register_with_name(PlayerData.player_name)
		if reg.get("ok", false):
			_identity_synced = true
			if username != "" and username != PlayerData.player_name:
				PlayerData.adopt_online_name(username)
		elif str(reg.get("error_code", "")) != "offline":
			## Name is taken or no longer allowed — the player must choose again.
			pending_name_change_reason = str(reg.get("error", "Please choose a new name."))
			name_needs_change.emit(pending_name_change_reason)

	_identity_sync_running = false


## Registers (or re-fetches) this device's account with the server. Safe to call
## repeatedly; the server returns the existing account without a new recovery
## code if already registered. Emits account_ready on success, and additionally
## recovery_code_available when a brand-new account was just created.
func register() -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null:
		registration_failed.emit("SupabaseClient not available.")
		return {"ok": false, "error": "SupabaseClient not available."}
	if not SupabaseClient.is_configured():
		registration_failed.emit("Marketplace not configured.")
		return {"ok": false, "error": "Marketplace not configured."}

	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/register_account",
		{"p_device_hash": _device_hash()})

	if not res.get("ok", false):
		registration_failed.emit(str(res.get("error", "Registration failed.")))
		return {"ok": false, "error": str(res.get("error", "Registration failed."))}

	## RPC returns the function's JSON result directly as `data`.
	var data = res.get("data", null)
	if not (data is Dictionary):
		registration_failed.emit("Unexpected server response.")
		return {"ok": false, "error": "Unexpected server response."}

	if data.has("error"):
		registration_failed.emit(str(data["error"]))
		return {"ok": false, "error": str(data["error"])}

	account_id = str(data.get("id", account_id))
	username = str(data.get("username", username))
	token_balance = int(data.get("token_balance", token_balance))
	_registered = true
	_save_local()

	account_ready.emit(username)

	## Brand-new account: surface the one-time recovery code so the UI can force
	## the player to write it down.
	var recovery = data.get("recovery_code", null)
	if bool(data.get("created", false)) and recovery != null and str(recovery) != "":
		recovery_code_available.emit(username, str(recovery))

	return {"ok": true, "created": bool(data.get("created", false)),
		"username": username, "recovery_code": recovery}


## Fetches the authoritative token balance from the server and updates the local
## cache. The balance is DISPLAY-ONLY from the server; never mutated locally.
## Returns { ok, balance } or { ok=false, error }. If we don't yet have an
## account handle, this is a no-op error (register first).
func reconcile() -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured."}
	if device_id == "":
		return {"ok": false, "error": "No device id."}

	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/reconcile_account",
		{"p_device_hash": _device_hash()})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Reconcile failed."))}
	var data = res.get("data", null)
	if not (data is Dictionary) or data.has("error"):
		var msg := "Account not found."
		if data is Dictionary and data.has("error"):
			msg = str(data["error"])
		return {"ok": false, "error": msg}

	account_id = str(data.get("id", account_id))
	username = str(data.get("username", username))
	var new_balance := int(data.get("token_balance", token_balance))
	if new_balance != token_balance:
		token_balance = new_balance
		token_balance_changed.emit(token_balance)
	else:
		token_balance = new_balance
	_save_local()
	return {"ok": true, "balance": token_balance}


## Creates a marketplace listing on the server. Does NOT touch local inventory —
## the caller deducts locally only AFTER this returns ok (server-authoritative
## escrow). Returns { ok, listing_id } or { ok=false, error }.
func list_item(item_key: String, quantity: int, unit_price: int, daily_limit: int = 0) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured."}
	if not has_account():
		return {"ok": false, "error": "Not registered."}
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/list_item",
		{
			"p_device_hash": _device_hash(),
			"p_item_key": item_key,
			"p_quantity": quantity,
			"p_unit_price": unit_price,
			"p_daily_limit": daily_limit,
		})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Listing failed."))}
	var data = res.get("data", null)
	if not (data is Dictionary) or data.has("error"):
		var msg := "Listing failed."
		if data is Dictionary and data.has("error"):
			var code := str(data["error"])
			match code:
				"item_not_tradeable": msg = "That item can't be sold on the market."
				_: msg = code
		return {"ok": false, "error": msg}
	return {"ok": true, "listing_id": str(data.get("listing_id", ""))}


## Re-prices ALL of the caller's active listings for `item_key` to the given
## price + daily limit, merging them into one. Used by the Sell tab's "list all
## at the new price" option. Returns { ok, listing_id, quantity } or
## { ok=false, error }.
func reprice(item_key: String, unit_price: int, daily_limit: int = 0) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured."}
	if not has_account():
		return {"ok": false, "error": "Not registered."}
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/reprice_listings",
		{
			"p_device_hash": _device_hash(),
			"p_item_key": item_key,
			"p_unit_price": unit_price,
			"p_daily_limit": daily_limit,
		})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Reprice failed."))}
	var data = res.get("data", null)
	if not (data is Dictionary) or data.has("error"):
		return {"ok": false, "error": str(data.get("error", "Reprice failed.")) if data is Dictionary else "Reprice failed."}
	return {"ok": true, "listing_id": str(data.get("listing_id", "")), "quantity": int(data.get("quantity", 0))}


## Fetches an existing active listing for `item_key` owned by the caller (the
## first/oldest), so the Sell tab can pre-fill price/limit. Returns
## { ok, listing } where listing is {} if none. Reads from get_my_listings.
func get_my_listing_for(item_key: String) -> Dictionary:
	var res: Dictionary = await get_my_listings()
	if not res.get("ok", false):
		return {"ok": false, "listing": {}}
	for l in res.get("listings", []):
		if l is Dictionary and str(l.get("item_key", "")) == item_key:
			return {"ok": true, "listing": l}
	return {"ok": true, "listing": {}}


## Buys `quantity` from a listing. On success the server has moved the items
## into our escrow and debited our tokens; this then claims the escrow into the
## local inventory. Returns { ok, spent, claimed: Array } or { ok=false, error }.
func buy(listing_id: String, quantity: int) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured."}
	if not has_account():
		return {"ok": false, "error": "Not registered."}
	if quantity < 1:
		return {"ok": false, "error": "Quantity must be at least 1."}

	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/buy_listing",
		{"p_device_hash": _device_hash(), "p_listing_id": listing_id, "p_quantity": quantity})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Purchase failed."))}
	var data = res.get("data", null)
	if not (data is Dictionary) or data.has("error"):
		return {"ok": false, "error": _friendly_buy_error(data)}

	## Update the cached token balance from the server's authoritative value.
	if data.has("new_balance"):
		var nb := int(data["new_balance"])
		if nb != token_balance:
			token_balance = nb
			token_balance_changed.emit(token_balance)
		_save_local()

	## Claim the just-purchased items out of escrow into local inventory.
	var claim := await claim_escrow()
	return {"ok": true, "spent": int(data.get("spent", 0)), "claimed": claim.get("items", [])}


## Translates a buy_listing error code into a player-friendly message.
func _friendly_buy_error(data) -> String:
	var code := ""
	if data is Dictionary and data.has("error"):
		code = str(data["error"])
	match code:
		"insufficient_tokens": return "Not enough marketplace tokens."
		"insufficient_stock":  return "Not enough of that item left."
		"daily_limit_exceeded": return "You've hit the daily buy limit for this listing."
		"cannot_buy_own":      return "You can't buy your own listing."
		"listing_not_active":  return "That listing is no longer available."
		"listing_not_found":   return "That listing no longer exists."
		"": return "Purchase failed."
		_: return "Purchase failed (%s)." % code


## Claims all server-side escrow into the local inventory. The server deletes the
## escrow and returns what was claimed; we add each to PlayerData. Returns
## { ok, items: Array } (items = [{item_key, quantity}, ...]).
func claim_escrow() -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured.", "items": []}
	if not has_account():
		return {"ok": false, "error": "Not registered.", "items": []}
	## Tell the server which item keys THIS build understands, so it only hands
	## back items we can actually add. Unknown-to-us items stay in escrow for a
	## future updated build — never dropped. (Forward-compatible across APKs.)
	var supported := ItemKeyRegistry.all_keys()
	## Capacity gating: pass free space for each CAPPED pool so the server only
	## hands back what we can hold and LEAVES the rest in escrow (claim it later
	## after freeing space). Tiles share the inventory slot pool; seeds+saplings
	## share the garden seed pool. This also closes the list→buy→cancel dupe:
	## once a store is full you can't pull replacements. Uncapped pools send -1.
	var tile_space := PlayerData.market_storage_space_for("tile:pawn")  ## any tile key
	var seed_space := PlayerData.market_storage_space_for("seed:beans")  ## any seed/sapling key
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/claim_escrow",
		{
			"p_device_hash": _device_hash(),
			"p_supported_keys": supported,
			## -1 (uncapped sentinel) -> null so the server treats the pool as
			## unlimited; otherwise the concrete free-slot count.
			"p_tile_space": null if tile_space < 0 else tile_space,
			"p_seed_space": null if seed_space < 0 else seed_space,
		})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Claim failed.")), "items": []}
	var data = res.get("data", null)
	if not (data is Dictionary) or not data.has("items"):
		return {"ok": true, "items": []}
	var items = data.get("items", [])
	var unrecognized: Array = []
	if items is Array:
		for it in items:
			if it is Dictionary:
				var key := str(it.get("item_key", ""))
				var qty := int(it.get("quantity", 0))
				if key != "" and qty > 0:
					## If this client doesn't recognize the item key (e.g. a newer
					## item bought on an out-of-date build), market_add_owned returns
					## false. Flag it rather than silently dropping it, so the loss
					## is visible instead of mysterious.
					if not PlayerData.market_add_owned(key, qty):
						unrecognized.append({"item_key": key, "quantity": qty})
	if not unrecognized.is_empty():
		push_warning("claim_escrow: %d escrow item(s) not recognized by this build (update the app): %s"
			% [unrecognized.size(), str(unrecognized)])
		if get_node_or_null("/root/GameNotification") != null:
			GameNotification.show_message("Update needed",
				"Some purchased items couldn't be added — update the app to receive them.")
	return {"ok": true, "items": items if items is Array else [], "unrecognized": unrecognized}


## Read-only peek at the caller's escrow (held items awaiting claim). Does NOT
## remove anything — used to show "Held items" so nothing is ever invisible.
## Returns { ok, items: [{item_key, quantity}, ...] } or { ok=false, error }.
func get_escrow() -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured.", "items": []}
	if not has_account():
		return {"ok": false, "error": "Not registered.", "items": []}
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/get_escrow", {"p_device_hash": _device_hash()})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Could not read held items.")), "items": []}
	var data = res.get("data", null)
	if not (data is Dictionary) or not data.has("items"):
		return {"ok": true, "items": []}
	var items = data.get("items", [])
	return {"ok": true, "items": items if items is Array else []}


## Full listing flow: verify the player owns enough locally, create the listing
## on the server, and ONLY on success deduct the items from the local save
## (server-authoritative escrow — no dupe/loss window). Returns
## { ok, listing_id } or { ok=false, error }.
func list_and_deduct(item_key: String, quantity: int, unit_price: int, daily_limit: int = 0) -> Dictionary:
	if quantity < 1:
		return {"ok": false, "error": "Quantity must be at least 1."}
	if unit_price < 1:
		return {"ok": false, "error": "Price must be at least 1 token."}
	if PlayerData.market_count_owned(item_key) < quantity:
		return {"ok": false, "error": "You don't own that many."}

	## Server first. If it fails, local inventory is untouched.
	var res: Dictionary = await list_item(item_key, quantity, unit_price, daily_limit)
	if not res.get("ok", false):
		return res

	## Server confirmed the listing → now remove the items locally.
	if not PlayerData.market_remove_owned(item_key, quantity):
		## Extremely unlikely (we checked ownership above), but surface it.
		return {"ok": false, "error": "Listed, but local deduction failed — reconcile needed.",
			"listing_id": res.get("listing_id", "")}
	return {"ok": true, "listing_id": res.get("listing_id", "")}


## Cancels one of the caller's listings. Returns { ok, returned_qty, item_key }
## or { ok=false, error }. The returned quantity lands in server escrow (claim
## it back into local inventory via reconcile in a later step).
func cancel_listing(listing_id: String) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured."}
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/cancel_listing",
		{"p_device_hash": _device_hash(), "p_listing_id": listing_id})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Cancel failed."))}
	var data = res.get("data", null)
	if not (data is Dictionary) or data.has("error"):
		var msg := "Cancel failed."
		if data is Dictionary and data.has("error"):
			msg = str(data["error"])
		return {"ok": false, "error": msg}
	return {"ok": true, "returned_qty": int(data.get("returned_qty", 0)),
		"item_key": str(data.get("item_key", ""))}


## Partially cancels a listing: pulls back only `max_return` units (= the
## player's free local space) into escrow and leaves the rest as an ACTIVE
## listing so nothing is hidden — the player can always see the remainder in
## "My Listings". Pass max_return = -1 for an uncapped full cancel. Returns
## { ok, returned_qty, remaining_qty, item_key, cancelled } or { ok=false, error }.
func cancel_listing_partial(listing_id: String, max_return: int) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured."}
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/cancel_listing_partial",
		{
			"p_device_hash": _device_hash(),
			"p_listing_id": listing_id,
			## -1 (uncapped sentinel) -> null so the server returns everything.
			"p_max_return": null if max_return < 0 else max_return,
		})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Cancel failed."))}
	var data = res.get("data", null)
	if not (data is Dictionary) or data.has("error"):
		var msg := "Cancel failed."
		if data is Dictionary and data.has("error"):
			msg = str(data["error"])
		return {"ok": false, "error": msg}
	return {"ok": true,
		"returned_qty": int(data.get("returned_qty", 0)),
		"remaining_qty": int(data.get("remaining_qty", 0)),
		"item_key": str(data.get("item_key", "")),
		"cancelled": bool(data.get("cancelled", true))}


## Fetches active listings from OTHER sellers (excludes the caller's own), newest
## first. Returns { ok, listings: Array } or { ok=false, error }.
func get_listings() -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured.", "listings": []}
	## Exclude our own listings so Browse only shows what we can buy.
	var exclude := _device_hash() if has_account() else ""
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/get_listings", {"p_exclude_device_hash": exclude})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Could not load listings.")), "listings": []}
	var data = res.get("data", null)
	return {"ok": true, "listings": _filter_known_listings(data)}


## Fetches the caller's own active listings. Returns { ok, listings: Array }.
func get_my_listings() -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured.", "listings": []}
	if not has_account():
		return {"ok": false, "error": "Not registered.", "listings": []}
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/get_my_listings", {"p_device_hash": _device_hash()})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Could not load your listings.")), "listings": []}
	var data = res.get("data", null)
	return {"ok": true, "listings": _filter_known_listings(data)}


## Drops any listing whose item_key this BUILD doesn't recognize, so a player
## only ever sees (and can buy) items their APK understands. Newer items listed
## by updated clients are simply invisible here — no error, no interaction — and
## become visible after the player updates. Forward-compatible across versions.
func _filter_known_listings(data) -> Array:
	var out: Array = []
	if data is Array:
		for l in data:
			if l is Dictionary and ItemKeyRegistry.is_valid(str(l.get("item_key", ""))):
				out.append(l)
	return out


## Fetches the daily price history for an item over the last `days` days.
## Returns { ok, points: Array } where each point is a Dictionary with keys
## day, avg_price, min_price, max_price, last_price, volume (oldest -> newest).
func get_price_history(item_key: String, days: int = 30) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured.", "points": []}
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/get_price_history",
		{"p_item_key": item_key, "p_days": days})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Could not load price history.")), "points": []}
	var data = res.get("data", null)
	return {"ok": true, "points": data if data is Array else []}


## Fetches active missions WITH the caller's live progress + claimed flag.
## Returns { ok, missions: Array } where each mission has progress/target/claimed.
func get_mission_status() -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured.", "missions": []}
	var hash := _device_hash() if has_account() else ""
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/get_mission_status", {"p_device_hash": hash})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Could not load missions.")), "missions": []}
	var data = res.get("data", null)
	return {"ok": true, "missions": data if data is Array else []}


## Claims a completed mission's reward. The server re-verifies eligibility.
## On success updates the cached token balance. Returns { ok, reward } or
## { ok=false, error }.
func claim_mission(mission_id: String) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Marketplace not configured."}
	if not has_account():
		return {"ok": false, "error": "Not registered."}
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/claim_mission",
		{"p_device_hash": _device_hash(), "p_mission_id": mission_id})
	if not res.get("ok", false):
		return {"ok": false, "error": str(res.get("error", "Claim failed."))}
	var data = res.get("data", null)
	if not (data is Dictionary) or data.has("error"):
		return {"ok": false, "error": _friendly_mission_error(data)}
	if data.has("new_balance"):
		var nb := int(data["new_balance"])
		if nb != token_balance:
			token_balance = nb
			token_balance_changed.emit(token_balance)
		_save_local()
	return {"ok": true, "reward": int(data.get("reward", 0)),
		"base_reward": int(data.get("base_reward", 0)),
		"bonus": int(data.get("bonus", 0))}


## Opens/extends the server-side Trader's Tongue window (migration 104): online
## mission rewards are doubled until it ends. 1 hour per recipe, max 24h ahead.
## Returns { ok, boost_until (unix secs), seconds_left } or { ok=false, error }.
func activate_mission_boost(recipes: int = 1) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Connect to the internet to use this recipe."}
	if not has_account():
		return {"ok": false, "error": "Your online account isn't set up yet."}
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/activate_mission_boost",
		{"p_device_hash": _device_hash(), "p_recipes": recipes})
	if not res.get("ok", false):
		return {"ok": false, "error": "Couldn't reach the server — recipe not used."}
	var data = res.get("data", null)
	if not (data is Dictionary) or data.has("error"):
		return {"ok": false, "error": "Couldn't activate the boost — recipe not used."}
	return {"ok": true, "boost_until": float(data.get("boost_until", 0.0)),
		"seconds_left": int(data.get("seconds_left", 0))}


func _friendly_mission_error(data) -> String:
	var code := ""
	if data is Dictionary and data.has("error"):
		code = str(data["error"])
	match code:
		"already_claimed":   return "You already claimed this mission."
		"not_eligible":      return "Not finished yet."
		"daily_cap_reached": return "Daily token cap reached — come back tomorrow."
		"mission_inactive":  return "This mission has expired."
		"mission_expired":   return "This mission expired — a new set is on the way."
		"mission_not_found": return "That mission is no longer available."
		_: return "Claim failed."


## Restores an online account onto THIS device using its recovery code
## (migration 105). The server links the account to this device's hash; any
## account previously on this device is unlinked (kept, not deleted). On
## success the in-game name becomes the restored account's name.
## Returns { ok, username, token_balance } or { ok=false, error }.
func restore_from_code(recovery_code: String) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null or not SupabaseClient.is_configured():
		return {"ok": false, "error": "Connect to the internet to restore your account."}
	var code := recovery_code.strip_edges().replace(" ", "")
	if code.length() < 4:
		return {"ok": false, "error": "Enter your full recovery code."}
	var res: Dictionary = await SupabaseClient.request_json(
		"POST", "/rest/v1/rpc/restore_account_to_device",
		{"p_recovery_code": code, "p_device_hash": _device_hash()})
	if not res.get("ok", false):
		return {"ok": false, "error": "Couldn't reach the server. Try again."}
	var data = res.get("data", null)
	if not (data is Dictionary) or data.has("error"):
		var err_code := str(data.get("error", "")) if data is Dictionary else ""
		match err_code:
			"not_found", "invalid_recovery_code":
				return {"ok": false, "error": "That recovery code doesn't match any account. Check it and try again (it's case-sensitive)."}
		return {"ok": false, "error": "Restore failed. Try again."}

	account_id = str(data.get("id", ""))
	username = str(data.get("username", ""))
	var nb := int(data.get("token_balance", token_balance))
	_registered = true
	_identity_synced = true
	pending_name_change_reason = ""
	if nb != token_balance:
		token_balance = nb
		token_balance_changed.emit(token_balance)
	_save_local()
	if get_node_or_null("/root/PlayerData") != null and username != "":
		PlayerData.adopt_online_name(username)
	account_ready.emit(username)
	username_changed.emit(username)
	## Guild membership belongs to the account — reload it for the restored one.
	if get_node_or_null("/root/GuildManager") != null and GuildManager.has_method("refresh_all"):
		GuildManager.refresh_all()
	return {"ok": true, "username": username, "token_balance": token_balance}
