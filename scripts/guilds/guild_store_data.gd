extends Node
## Autoload: GuildStore
## Client-side cache + RPC wrappers for the Guild Store (migrations 057/058): a
## members-only marketplace for PRODUCED JEWELRY ('item:<id>' keys only), priced
## in marketplace tokens. Sale proceeds are split EVENLY across all current
## members by the server; the sub-member remainder is held in the guild BANK and
## released automatically once it becomes evenly distributable.
##
## Listing trust model (mirrors GuildStockpile.deposit): the client removes the
## jewelry from the player's LOCAL inventory first, then calls list_guild_item;
## on any failure the local removal is refunded. The server holds no per-player
## inventory, so a listing only creates an offer backed by escrow.
##
## Buying debits the buyer's authoritative token_balance server-side and adds
## the item to the buyer's escrow (claimed into local inventory next marketplace
## open) — no local inventory change on buy.

## ── Signals ─────────────────────────────────────────────────────
signal store_changed()      ## In-guild listings or bank changed — UI refresh
signal fronts_changed()     ## Public Guild Fronts browse list changed — UI refresh

## ── Cached state ─────────────────────────────────────────────────
## listings: Array of { id, seller_id, seller_name, item_key, unit_price,
##                      quantity_remaining, mine, created_at }
var listings: Array = []

## Guild bank (undistributed sale-proceeds remainder) + current member count.
var bank_balance: int = 0
var member_count: int = 0

## Public "Guild Fronts" browse cache (migration 059): active listings across
## ALL guilds, buyable by any player. Each entry:
##   { id, guild_id, guild_name, seller_name, item_key, unit_price,
##     quantity_remaining, mine }
var fronts: Array = []

## Guild-owned finished jewelry pool (migration 062): the stock the storefront
## lists FROM. produced jewelry collects here (not personal inventory). Dict:
##   item_key (String) -> quantity (int)
var guild_jewelry: Dictionary = {}

var is_loading: bool = false
var is_loading_fronts: bool = false


## ── RPC helpers (identical shape to the other guild autoloads) ───

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


## ── Convenience ─────────────────────────────────────────────────

func is_empty() -> bool:
	return listings.is_empty()


## Only this player's own active listings.
func my_listings() -> Array:
	var out: Array = []
	for l in listings:
		if l is Dictionary and bool(l.get("mine", false)):
			out.append(l)
	return out


## ── Response parsing (shared by refresh + tests) ─────────────────

## Populates `listings` from a get_guild_store payload. Factored out for tests.
func apply_payload(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	listings.clear()
	var raw = data.get("items", [])
	if raw is Array:
		for e in raw:
			if not e is Dictionary:
				continue
			listings.append({
				"id":                 str(e.get("id", "")),
				"seller_id":          str(e.get("seller_id", "")),
				"seller_name":        str(e.get("seller_name", "")),
				"item_key":           str(e.get("item_key", "")),
				"unit_price":         int(e.get("unit_price", 0)),
				"quantity_remaining": int(e.get("quantity_remaining", 0)),
				"mine":               bool(e.get("mine", false)),
				"created_at":         float(e.get("created_at", 0.0)),
			})
	return true


## Populates bank_balance + member_count from a get_guild_bank payload.
func apply_bank_payload(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	bank_balance = int(data.get("bank_balance", 0))
	member_count = int(data.get("member_count", 0))
	return true


## Populates guild_jewelry from a get_guild_jewelry payload. Factored for tests.
func apply_jewelry_payload(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	guild_jewelry.clear()
	var raw = data.get("items", [])
	if raw is Array:
		for e in raw:
			if not e is Dictionary:
				continue
			var key := str(e.get("item_key", ""))
			if key.is_empty():
				continue
			guild_jewelry[key] = int(e.get("quantity", 0))
	return true


## How many of a jewelry item_key the GUILD pool holds (0 if none).
func guild_jewelry_count(item_key: String) -> int:
	return int(guild_jewelry.get(item_key, 0))


## ── Public API — view ────────────────────────────────────────────

## Fetches the guild's active listings AND the bank balance, then emits
## store_changed. Returns a friendly result dict.
func refresh(guild_id: String) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	is_loading = true
	var res := await _rpc("get_guild_store", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
	})
	if not res.get("ok", false):
		is_loading = false
		return _friendly(res)
	if not apply_payload(res.get("data", {})):
		is_loading = false
		return {"ok": false, "error": "bad_response", "message": "Bad server response."}

	## Bank read (best-effort: a failure here doesn't void the listings view).
	var bres := await _rpc("get_guild_bank", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
	})
	if bres.get("ok", false):
		apply_bank_payload(bres.get("data", {}))

	## Guild jewelry pool (what the Store "List Jewelry" dropdown sells FROM).
	## Best-effort — a failure leaves the last-known pool.
	var jres := await _rpc("get_guild_jewelry", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
	})
	if jres.get("ok", false):
		apply_jewelry_payload(jres.get("data", {}))
	is_loading = false

	store_changed.emit()
	return {"ok": true}


## ── Public API — list (any member) ───────────────────────────────

## Lists `quantity` of a guild item at `unit_price` tokens each. The server
## routes to the right pool: jewelry (item:*) from guild_jewelry_inventory,
## stockpile items (resource/gem/polished/crop/fruit) from guild_stockpile
## (available = amount - reserved only). Returns { ok, listing_id } or
## { ok=false }.
func list_item(guild_id: String, item_key: String, quantity: int, unit_price: int) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	if item_key.is_empty():
		return {"ok": false, "error": "not_jewelry", "message": "Pick an item to list."}
	if quantity <= 0:
		return {"ok": false, "error": "invalid_quantity", "message": "Enter a valid quantity."}
	if unit_price <= 0:
		return {"ok": false, "error": "invalid_price", "message": "Enter a valid price."}
	## Stock check is done server-side (it knows which pool to draw from and
	## enforces available = amount − reserved for stockpile items).

	var res := await _rpc("list_guild_item", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
		"p_item_key":    item_key,
		"p_quantity":    quantity,
		"p_unit_price":  unit_price,
	})

	if res.get("ok", false):
		await refresh(guild_id)

	return _friendly(res)


## Buys `quantity` from a listing. Tokens are debited server-side; the item lands
## in the buyer's escrow. Returns { ok, spent, new_balance, shared, banked, ... }.
func buy(guild_id: String, listing_id: String, quantity: int) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	if quantity <= 0:
		return {"ok": false, "error": "invalid_quantity", "message": "Enter a valid quantity."}
	var res := await _rpc("buy_guild_item", {
		"p_device_hash":  _device_hash(),
		"p_guild_id":     guild_id,
		"p_listing_id":   listing_id,
		"p_quantity":     quantity,
	})
	if res.get("ok", false):
		## Reflect the authoritative token balance locally (same pattern as the
		## marketplace buy/claim handlers: set token_balance + emit the signal so
		## any open token label updates immediately).
		var data = res.get("data", {})
		if data is Dictionary and data.has("new_balance") and get_node_or_null("/root/MarketplaceAccount") != null:
			var nb := int(data.get("new_balance", MarketplaceAccount.token_balance))
			if nb != MarketplaceAccount.token_balance:
				MarketplaceAccount.token_balance = nb
				MarketplaceAccount.token_balance_changed.emit(nb)
		## Pull the just-bought item out of escrow into local inventory NOW, so it
		## appears immediately (not on the next marketplace open). Mirrors
		## MarketplaceAccount.buy(), which claims escrow right after a purchase.
		await _claim_escrow_now()
		await refresh(guild_id)
	return _friendly(res)


## Cancels the caller's own active listing; the unsold remainder returns to the
## seller's escrow. Returns { ok, returned_qty, item_key } or { ok=false, ... }.
func cancel(guild_id: String, listing_id: String) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	var res := await _rpc("cancel_guild_listing", {
		"p_device_hash": _device_hash(),
		"p_listing_id":  listing_id,
	})
	if res.get("ok", false):
		await refresh(guild_id)
	return _friendly(res)


## ── Public API — bank ────────────────────────────────────────────

## Refreshes just the bank balance + member count.
func refresh_bank(guild_id: String) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	var res := await _rpc("get_guild_bank", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
	})
	if res.get("ok", false):
		apply_bank_payload(res.get("data", {}))
		store_changed.emit()
	return _friendly(res)


## Leader-only. Flushes the bank: distributes the evenly-divisible portion to all
## members, leaving the sub-member remainder. Returns { ok, distributed,
## bank_balance } or { ok=false, ... }.
func distribute_bank(guild_id: String) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	var res := await _rpc("distribute_guild_bank", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
	})
	if res.get("ok", false):
		var data = res.get("data", {})
		if data is Dictionary:
			bank_balance = int(data.get("bank_balance", bank_balance))
		store_changed.emit()
	return _friendly(res)


## ── Public API — Guild Fronts (public marketplace, migration 059) ─────────────

## Parses a get_guild_fronts payload into `fronts`. Factored out for tests.
func apply_fronts_payload(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	fronts.clear()
	var raw = data.get("items", [])
	if raw is Array:
		for e in raw:
			if not e is Dictionary:
				continue
			fronts.append({
				"id":                 str(e.get("id", "")),
				"guild_id":           str(e.get("guild_id", "")),
				"guild_name":         str(e.get("guild_name", "")),
				"seller_name":        str(e.get("seller_name", "")),
				"item_key":           str(e.get("item_key", "")),
				"unit_price":         int(e.get("unit_price", 0)),
				"quantity_remaining": int(e.get("quantity_remaining", 0)),
				"mine":               bool(e.get("mine", false)),
			})
	return true


## Fetches the public Guild Fronts listings (any player, no guild needed).
func refresh_fronts(limit: int = 50, offset: int = 0) -> Dictionary:
	is_loading_fronts = true
	var res := await _rpc("get_guild_fronts", {
		"p_device_hash": _device_hash(),
		"p_limit":       limit,
		"p_offset":      offset,
	})
	is_loading_fronts = false
	if not res.get("ok", false):
		return _friendly(res)
	if not apply_fronts_payload(res.get("data", {})):
		return {"ok": false, "error": "bad_response", "message": "Bad server response."}
	fronts_changed.emit()
	return {"ok": true}


## Buys `quantity` from a public guild-front listing. Any player may call this;
## the proceeds go to the listing's guild bank. Tokens debited server-side; the
## item lands in the buyer's escrow. Returns { ok, spent, new_balance, ... }.
func buy_front(listing_id: String, quantity: int = 1) -> Dictionary:
	if quantity <= 0:
		return {"ok": false, "error": "invalid_quantity", "message": "Enter a valid quantity."}
	var res := await _rpc("buy_guild_front_item", {
		"p_device_hash": _device_hash(),
		"p_listing_id":  listing_id,
		"p_quantity":    quantity,
	})
	if res.get("ok", false):
		## Reflect the authoritative token balance locally + emit the signal.
		var data = res.get("data", {})
		if data is Dictionary and data.has("new_balance") and get_node_or_null("/root/MarketplaceAccount") != null:
			var nb := int(data.get("new_balance", MarketplaceAccount.token_balance))
			if nb != MarketplaceAccount.token_balance:
				MarketplaceAccount.token_balance = nb
				MarketplaceAccount.token_balance_changed.emit(nb)
		## Claim the item out of escrow into local inventory immediately.
		await _claim_escrow_now()
		await refresh_fronts()
	return _friendly(res)


## ── Private ──────────────────────────────────────────────────────

## Claims any server escrow into local inventory right now (so a storefront
## purchase lands immediately instead of waiting for the next marketplace open).
## Safe no-op if the marketplace account isn't available.
func _claim_escrow_now() -> void:
	if get_node_or_null("/root/MarketplaceAccount") == null:
		return
	if not MarketplaceAccount.has_method("claim_escrow"):
		return
	await MarketplaceAccount.claim_escrow()


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
		"not_jewelry":         msg = "Only produced jewelry can be sold here."
		"invalid_quantity":    msg = "Enter a valid quantity."
		"invalid_price":       msg = "Enter a valid price."
		"insufficient_items":  msg = "You don't have that many."
		"insufficient_jewelry": msg = "The guild doesn't have that many to list."
		"insufficient_stock":  msg = "Not enough available stock (some may be reserved)."
		"price_below_minimum": msg = "Price is below the minimum (sell value − 1)."
		"not_allowed":         msg = "Only the lister or the guild leader can do that."
		"listing_not_found":   msg = "That listing is gone."
		"listing_not_active":  msg = "That listing is no longer available."
		"wrong_guild":         msg = "That listing belongs to another guild."
		"cannot_buy_own":      msg = "You can't buy your own listing."
		"insufficient_stock":  msg = "Not enough in stock."
		"insufficient_tokens": msg = "You don't have enough tokens."
		"not_your_listing":    msg = "That isn't your listing."
		"not_leader":          msg = "Only the guild leader can do that."
		"offline":             msg = "No connection."
		_:                     msg = "Error: %s" % code
	return {"ok": false, "error": code, "message": msg}
