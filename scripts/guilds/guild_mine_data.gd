extends Node
## Autoload: GuildMine
## Client-side cache for the community guild Deep Mine + Warehouse.
## All durable state lives in Supabase; this node caches the current session's
## view and provides RPC wrappers for GuildMineUI to call.
##
## The mine is a fixed 10x10 grid stacked into up to 11 layers. How deep the
## guild can dig is gated by the 'mine_depth' guild upgrade (max_layers, from
## the server). Tapping a tile:
##   • with pending treasure -> COLLECTS it into the warehouse (no shovel)
##   • otherwise -> DIGS the next layer (consumes one of YOUR shovels, validated
##     client-side like the garden's seed spend). The server rolls the treasure.
##
## Grid cells are cached as a Dictionary keyed by Vector2i(row, col):
##   { "depth": int, "pending": String }  (pending = canonical item key or "")
##
## Warehouse is cached as a Dictionary: { item_key (String) -> amount (int) }

## ── Signals ─────────────────────────────────────────────────────
signal mine_updated()   ## Grid or warehouse changed — UI should refresh

## ── Constants ────────────────────────────────────────────────────
const GRID_ROWS := 10
const GRID_COLS := 10

## ── Cached state ─────────────────────────────────────────────────
## Dictionary: Vector2i(row,col) → { depth: int, pending: String }
var grid: Dictionary = {}

## Dictionary: item_key → amount
var warehouse: Dictionary = {}

var grid_rows: int = GRID_ROWS
var grid_cols: int = GRID_COLS
var max_layers: int = 1
var warehouse_capacity: int = 500

## True while a full refresh RPC is in flight.
var is_loading: bool = false

## In-flight dig/pickup per cell: Vector2i(row, col) → true
var _pending_cells: Dictionary = {}


## ── Convenience ─────────────────────────────────────────────────

func get_cell(row: int, col: int) -> Dictionary:
	return grid.get(Vector2i(row, col), {"depth": 0, "pending": ""})


func get_depth(row: int, col: int) -> int:
	return int(get_cell(row, col).get("depth", 0))


func get_pending(row: int, col: int) -> String:
	return str(get_cell(row, col).get("pending", ""))


func has_pending(row: int, col: int) -> bool:
	return not get_pending(row, col).is_empty()


func is_fully_dug(row: int, col: int) -> bool:
	return get_depth(row, col) >= max_layers and not has_pending(row, col)


func is_cell_pending(row: int, col: int) -> bool:
	return _pending_cells.has(Vector2i(row, col))


func get_warehouse_amount(item_key: String) -> int:
	return int(warehouse.get(item_key, 0))


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


## ── Public API ───────────────────────────────────────────────────

## Fetches the full guild mine state from the server. Populates grid, warehouse,
## max_layers and capacity, then emits mine_updated.
func refresh(guild_id: String) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild"}
	is_loading = true
	var res := await _rpc("get_guild_mine", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
	})
	is_loading = false
	if not res.get("ok", false):
		return _friendly(res)

	var data = res.get("data", {})
	if not data is Dictionary:
		return {"ok": false, "error": "bad_response"}

	grid_rows = int(data.get("grid_rows", GRID_ROWS))
	grid_cols = int(data.get("grid_cols", GRID_COLS))
	max_layers = int(data.get("max_layers", 1))
	warehouse_capacity = int(data.get("warehouse_capacity", 500))

	## Parse grid cells. Preserve cells with an in-flight dig/pickup so a
	## background refresh doesn't clobber an optimistic update mid-request.
	var preserved: Dictionary = {}
	for pos in _pending_cells:
		if grid.has(pos):
			preserved[pos] = grid[pos]

	grid.clear()
	var raw_cells = data.get("cells", [])
	if raw_cells is Array:
		for entry in raw_cells:
			if not entry is Dictionary:
				continue
			var r := int(entry.get("row", 0))
			var c := int(entry.get("col", 0))
			grid[Vector2i(r, c)] = {
				"depth":   int(entry.get("depth", 0)),
				"pending": str(entry.get("pending", "")),
			}

	for pos in preserved:
		grid[pos] = preserved[pos]

	## Parse warehouse.
	warehouse.clear()
	var raw_wh = data.get("warehouse", [])
	if raw_wh is Array:
		for entry in raw_wh:
			if not entry is Dictionary:
				continue
			warehouse[str(entry.get("item_key", ""))] = int(entry.get("amount", 0))

	mine_updated.emit()
	return {"ok": true}


## Taps a tile. If it has pending treasure, collects it (no shovel). Otherwise
## digs the next layer, consuming one of the player's shovels locally first
## (rolled back on server failure). Returns a friendly result dict.
func dig(guild_id: String, row: int, col: int) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}

	var pos := Vector2i(row, col)
	if is_cell_pending(row, col):
		return {"ok": false, "error": "cell_busy", "message": "That tile is busy."}

	var picking_up := has_pending(row, col)

	## Fresh dig needs a shovel (pickup is free). Validate + consume locally,
	## same trust model as the garden's seed spend.
	var consumed := false
	if not picking_up:
		if get_depth(row, col) >= max_layers:
			return {"ok": false, "error": "fully_dug", "message": "That tile is fully dug."}
		if PlayerData.get_tool_count(PlayerData.ToolType.SHOVEL) <= 0:
			return {"ok": false, "error": "no_shovel", "message": "No shovels! Buy some at the Marketplace."}
		if not PlayerData.consume_tool(PlayerData.ToolType.SHOVEL):
			return {"ok": false, "error": "no_shovel", "message": "No shovels left."}
		consumed = true

	_pending_cells[pos] = true

	## A fresh dig drills through the player's personal multi-layer allowance
	## (solo-mine "mine_multi_layer" prestige), stopping at the first treasure.
	## Pickups ignore it (depth 1). The server clamps this to the guild's
	## unlocked max_layers.
	var dig_depth := 1
	if not picking_up and get_node_or_null("/root/DeepMine") != null:
		dig_depth = maxi(DeepMine.get_dig_depth_per_action(), 1)

	var res := await _rpc("dig_guild_mine", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
		"p_row":         row,
		"p_col":         col,
		"p_dig_depth":   dig_depth,
	})

	_pending_cells.erase(pos)

	if res.get("ok", false):
		var data = res.get("data", {})
		if data is Dictionary:
			var action := str(data.get("action", ""))
			if action == "pickup":
				## Treasure collected into the warehouse (if it had room).
				var item_key := str(data.get("treasure", ""))
				var stored := bool(data.get("stored", true))
				grid[pos] = {"depth": get_depth(row, col), "pending": ""}
				if stored and not item_key.is_empty():
					warehouse[item_key] = get_warehouse_amount(item_key) + 1
			elif action == "dig":
				var new_depth := int(data.get("depth", get_depth(row, col) + 1))
				var treasure := str(data.get("treasure", ""))
				grid[pos] = {"depth": new_depth, "pending": treasure}
		mine_updated.emit()
	else:
		## Rollback exactly the one shovel consume_tool() took (add_tool() would
		## refund a whole purchase's worth of uses, so restore the dict directly).
		if consumed:
			var sid := PlayerData.ToolType.SHOVEL
			PlayerData.tools[sid] = PlayerData.tools.get(sid, 0) + 1
			PlayerData.save_data()
			PlayerData.data_changed.emit()

	return _friendly(res)


## Excavator sweep (migration 102): clears up to `row_count` rows starting at
## `start_row` in ONE server call, no shovels. Tiles with unbanked treasure are
## skipped; found treasure is held pending (bank it by tapping). Updates the
## cache for every dug tile and emits mine_updated once.
## Returns { ok, rows_cleared, tiles, dug:[...], found:{item_key:n} } or { ok=false }.
func excavate(guild_id: String, start_row: int, row_count: int) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	var dig_depth := 1
	if get_node_or_null("/root/DeepMine") != null:
		dig_depth = maxi(DeepMine.get_dig_depth_per_action(), 1)

	var res := await _rpc("excavate_guild_mine", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
		"p_start_row":   start_row,
		"p_row_count":   maxi(row_count, 1),
		"p_dig_depth":   dig_depth,
	})
	var out := _friendly(res)
	if not res.get("ok", false):
		return out

	var found: Dictionary = {}
	var data = res.get("data", {})
	if data is Dictionary:
		var dug = data.get("dug", [])
		if dug is Array:
			for d in dug:
				if not d is Dictionary:
					continue
				var pos := Vector2i(int(d.get("row", 0)), int(d.get("col", 0)))
				var treasure := str(d.get("treasure", ""))
				grid[pos] = {"depth": int(d.get("depth", 0)), "pending": treasure}
				if not treasure.is_empty():
					found[treasure] = int(found.get(treasure, 0)) + 1
	out["found"] = found
	mine_updated.emit()
	return out


## Spends `amount` of a warehouse item on an active guild mission that wants it.
## The amount counts as the GUILD's share (split evenly in the reward), not any
## one player's. Optimistically deducts local warehouse stock; refunds on error.
## Returns { ok, deposited } or { ok=false, error, message }.
func deposit_warehouse(guild_id: String, item_key: String, amount: int) -> Dictionary:
	if guild_id.is_empty():
		return {"ok": false, "error": "no_guild", "message": "No guild specified."}
	if amount <= 0:
		return {"ok": false, "error": "invalid_amount", "message": "Nothing to deposit."}
	if get_warehouse_amount(item_key) < amount:
		return {"ok": false, "error": "warehouse_empty", "message": "Not enough in the warehouse."}

	## Optimistic local deduct.
	warehouse[item_key] = maxi(get_warehouse_amount(item_key) - amount, 0)
	if warehouse[item_key] == 0:
		warehouse.erase(item_key)

	var res := await _rpc("deposit_warehouse_to_mission", {
		"p_device_hash": _device_hash(),
		"p_guild_id":    guild_id,
		"p_item_key":    item_key,
		"p_amount":      amount,
	})

	if res.get("ok", false):
		mine_updated.emit()
		## Mission progress bars live on the guild detail screen — refresh them.
		if GuildManager.is_in_guild():
			GuildManager.refresh_missions()
	else:
		## Refund the optimistic deduct on failure.
		warehouse[item_key] = get_warehouse_amount(item_key) + amount
		mine_updated.emit()

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
		"not_mining_guild":    msg = "Only mining guilds have a community mine."
		"cell_out_of_bounds":  msg = "That tile is outside the mine."
		"fully_dug":           msg = "That tile is already fully dug."
		"no_shovel":           msg = "No shovels! Buy some at the Marketplace."
		"cell_busy":           msg = "That tile is busy."
		"warehouse_empty":     msg = "Not enough in the warehouse."
		"no_matching_mission": msg = "No active mission wants that item."
		"invalid_item":        msg = "That item can't be deposited."
		"invalid_amount":      msg = "Nothing to deposit."
		"offline":             msg = "No connection."
		_:                     msg = "Error: %s" % code
	return {"ok": false, "error": code, "message": msg}
