extends Node
## Autoload: GuildGarden
## Client-side cache for the community guild garden.
## All durable state lives in Supabase; this node caches the current
## session's view and provides RPC wrappers for GuildGardenUI to call.
##
## Grid cells are stored as a Dictionary keyed by Vector2i(row, col):
##   { "plant_type": int, "plant_time": float, "planted_by": String }
##
## Silo is stored as a Dictionary: { crop_id (String) -> amount (int) }

## ── Signals ─────────────────────────────────────────────────────
signal garden_updated()   ## Grid or silo changed — UI should refresh

## ── Constants ────────────────────────────────────────────────────
## Base silo capacity per crop (matches server _guild_silo_capacity).
const SILO_BASE_CAPACITY    := 100
const SILO_CAPACITY_PER_LVL := 50

## Harvest times in seconds — mirrors GardenData.PLANT_DEFS order.
const HARVEST_TIMES: Array[float] = [
    300.0,    ## Beans
    600.0,    ## Cucumbers
    1200.0,   ## Peppers
    2400.0,   ## Squash
    4800.0,   ## Grapes
    7200.0,   ## Sunflower
    10800.0,  ## Cauliflower
    16200.0,  ## Pineapple
    21600.0,  ## Watermelon
]

## crop_id string for each plant_type index — mirrors PlayerData.CROP_DEFS.
const CROP_IDS: Array[String] = [
    "beans", "cucumbers", "peppers", "squash", "grapes",
    "sunflower", "cauliflower", "pineapple", "watermelon",
]

## ── Cached state ─────────────────────────────────────────────────
## Dictionary: Vector2i(row,col) → { plant_type, plant_time, planted_by }
var grid: Dictionary = {}

## Dictionary: crop_id → amount
var silo: Dictionary = {}

## Per-crop silo capacity (same value for all crops; set by server response).
var silo_capacity: int = SILO_BASE_CAPACITY

## True while an RPC is in flight.
var is_loading: bool = false

## In-flight operations per cell: Vector2i(row, col) → { "action": "plant"|"harvest", ... }
var _pending_cells: Dictionary = {}


## ── Convenience ─────────────────────────────────────────────────

func get_cell(row: int, col: int) -> Dictionary:
    return grid.get(Vector2i(row, col), {})


func is_occupied(row: int, col: int) -> bool:
    return grid.has(Vector2i(row, col))


func is_cell_pending(row: int, col: int) -> bool:
    return _pending_cells.has(Vector2i(row, col))


func get_growth_progress(row: int, col: int) -> float:
    var cell := get_cell(row, col)
    if cell.is_empty():
        return -1.0
    var elapsed: float = TrustedClock.now() - float(cell["plant_time"])
    var harvest_time: float = HARVEST_TIMES[int(cell["plant_type"])]
    if harvest_time <= 0.0:
        return -1.0
    return clampf(elapsed / harvest_time, 0.0, 1.0)


func is_harvestable(row: int, col: int) -> bool:
    return get_growth_progress(row, col) >= 1.0


func get_growth_frame(row: int, col: int) -> int:
    var p := get_growth_progress(row, col)
    if p < 0.0:
        return -1
    return mini(int(p * 4), 3)


func get_silo_amount(crop_id: String) -> int:
    return silo.get(crop_id, 0)


func silo_capacity_for(crop_id: String) -> int:
    return silo_capacity  ## Same cap for all crop types.


func crop_id_for_plant_type(plant_type: int) -> String:
    if plant_type >= 0 and plant_type < CROP_IDS.size():
        return CROP_IDS[plant_type]
    return ""


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

## Fetches the full guild garden state from the server.
## Populates grid, silo, and silo_capacity, then emits garden_updated.
func refresh(guild_id: String) -> Dictionary:
    if guild_id.is_empty():
        return {"ok": false, "error": "no_guild"}
    is_loading = true
    var res := await _rpc("get_guild_garden", {
        "p_device_hash": _device_hash(),
        "p_guild_id":    guild_id,
    })
    is_loading = false
    if not res.get("ok", false):
        return res

    var data = res.get("data", {})
    if not data is Dictionary:
        return {"ok": false, "error": "bad_response"}

    ## Preserve pending plants so a background refresh doesn't overwrite them.
    var pending_plants: Dictionary = {}
    for pos in _pending_cells:
        if _pending_cells[pos].get("action") == "plant" and grid.has(pos):
            pending_plants[pos] = grid[pos]

    ## Parse grid cells.
    grid.clear()
    var raw_grid = data.get("grid", [])
    if raw_grid is Array:
        for entry in raw_grid:
            if not entry is Dictionary:
                continue
            var r := int(entry.get("row", 0))
            var c := int(entry.get("col", 0))
            var pos := Vector2i(r, c)
            if _pending_cells.has(pos) and _pending_cells[pos].get("action") == "harvest":
                continue
            grid[pos] = {
                "plant_type": int(entry.get("plant_type", 0)),
                "plant_time": float(str(entry.get("plant_time", 0))),
                "planted_by": str(entry.get("planted_by", "")),
            }

    ## Re-apply pending plants that server response hasn't included yet.
    for pos in pending_plants:
        if not grid.has(pos):
            grid[pos] = pending_plants[pos]

    ## Parse silo.
    silo.clear()
    var raw_silo = data.get("silo", [])
    if raw_silo is Array:
        for entry in raw_silo:
            if not entry is Dictionary:
                continue
            silo[str(entry.get("crop_id", ""))] = int(entry.get("amount", 0))

    silo_capacity = int(data.get("silo_capacity", SILO_BASE_CAPACITY))

    garden_updated.emit()
    return {"ok": true}


## Applies an immediate local plant: consumes seed and sets cell in grid.
## Returns true on success, false if cell occupied, pending, or out of seeds.
func plant_optimistic(row: int, col: int, plant_type: int) -> bool:
    var pos := Vector2i(row, col)
    if is_occupied(row, col) or is_cell_pending(row, col):
        return false
    if Garden.get_seed_count(plant_type) <= 0:
        return false

    ## Deduct seed locally
    Garden.seeds[plant_type] = Garden.seeds.get(plant_type, 0) - 1
    Garden.save_data()

    ## Store in grid immediately
    grid[pos] = {
        "plant_type": plant_type,
        "plant_time": TrustedClock.now(),
        "planted_by": "You",
    }
    _pending_cells[pos] = {
        "action": "plant",
        "plant_type": plant_type,
    }
    return true


## Sends the plant RPC to server in the background and resolves the pending cell.
## On error, rolls back the local cell and refunds the seed.
func commit_plant(guild_id: String, row: int, col: int, plant_type: int) -> Dictionary:
    var pos := Vector2i(row, col)
    if guild_id.is_empty():
        _pending_cells.erase(pos)
        grid.erase(pos)
        Garden.seeds[plant_type] = Garden.seeds.get(plant_type, 0) + 1
        Garden.save_data()
        return {"ok": false, "error": "no_guild", "message": "No guild specified."}

    var res := await _rpc("plant_guild_garden", {
        "p_device_hash": _device_hash(),
        "p_guild_id":    guild_id,
        "p_row":         row,
        "p_col":         col,
        "p_plant_type":  plant_type,
    })

    _pending_cells.erase(pos)

    if res.get("ok", false):
        return _friendly(res)
    else:
        ## Rollback on error
        grid.erase(pos)
        Garden.seeds[plant_type] = Garden.seeds.get(plant_type, 0) + 1
        Garden.save_data()
        return _friendly(res)


## Backwards-compatible plant method: applies optimistic update immediately, then commits.
func plant(guild_id: String, row: int, col: int, plant_type: int) -> Dictionary:
    if guild_id.is_empty():
        return {"ok": false, "error": "no_guild"}

    if is_occupied(row, col):
        return {"ok": false, "error": "cell_occupied", "message": "That plot is already planted."}
    if is_cell_pending(row, col):
        return {"ok": false, "error": "cell_busy", "message": "Plot is currently busy."}
    if Garden.get_seed_count(plant_type) <= 0:
        return {"ok": false, "error": "no_seeds", "message": "You don't have that seed."}

    var success := plant_optimistic(row, col, plant_type)
    if not success:
        return {"ok": false, "error": "plant_failed", "message": "Could not plant."}

    return await commit_plant(guild_id, row, col, plant_type)


## ── Batch plant (migration 095) ─────────────────────────────────
## Optimistically marks a list of cells as pending-plant and deducts seeds
## locally for each one that is available. Returns the list of cells that
## were successfully claimed locally (skips occupied / pending / no-seed).
## The caller fires batch_plant() with this list immediately after.
func batch_plant_optimistic(cells: Array) -> Array:
    var claimed: Array = []
    for item in cells:
        var r := int(item.get("row", -1))
        var c := int(item.get("col", -1))
        var pt := int(item.get("plant_type", -1))
        if r < 0 or c < 0 or pt < 0:
            continue
        var ok := plant_optimistic(r, c, pt)
        if ok:
            claimed.append({"row": r, "col": c, "plant_type": pt})
    return claimed


## Sends one batch_plant_guild_garden RPC for all cells in `cells`
## (Array of {"row","col","plant_type"}). On partial failure the server
## returns which cells were skipped; those are rolled back locally.
## On full failure every cell is rolled back. Emits garden_updated once.
func batch_plant(guild_id: String, cells: Array) -> Dictionary:
    if guild_id.is_empty() or cells.is_empty():
        ## Rollback all
        for item in cells:
            var pos := Vector2i(int(item.get("row", 0)), int(item.get("col", 0)))
            var pt := int(item.get("plant_type", 0))
            grid.erase(pos)
            _pending_cells.erase(pos)
            Garden.seeds[pt] = Garden.seeds.get(pt, 0) + 1
        Garden.save_data()
        return {"ok": false, "error": "no_guild"}

    ## Build the jsonb-compatible array for the RPC.
    var rpc_cells: Array = []
    for item in cells:
        rpc_cells.append({
            "row":        int(item.get("row", 0)),
            "col":        int(item.get("col", 0)),
            "plant_type": int(item.get("plant_type", 0)),
        })

    var res := await _rpc("batch_plant_guild_garden", {
        "p_device_hash": _device_hash(),
        "p_guild_id":    guild_id,
        "p_cells":       rpc_cells,
    })

    ## Build a fast lookup of what the server actually planted.
    var planted_set: Dictionary = {}
    if res.get("ok", false):
        var data = res.get("data", {})
        if data is Dictionary:
            var planted = data.get("planted", [])
            if planted is Array:
                for p in planted:
                    if p is Dictionary:
                        planted_set[Vector2i(int(p.get("row", 0)), int(p.get("col", 0)))] = true

    ## Clear pending flags; rollback any cell the server skipped / errored.
    var rolled_back := 0
    for item in cells:
        var pos := Vector2i(int(item.get("row", 0)), int(item.get("col", 0)))
        var pt := int(item.get("plant_type", 0))
        _pending_cells.erase(pos)
        var server_accepted: bool = res.get("ok", false) and planted_set.has(pos)
        if not server_accepted:
            grid.erase(pos)
            Garden.seeds[pt] = Garden.seeds.get(pt, 0) + 1
            rolled_back += 1

    if rolled_back > 0:
        Garden.save_data()

    garden_updated.emit()
    return _friendly(res)


## Harvests a cell. On success updates local grid and silo, emits garden_updated.
## Returns { ok, crop_id, went_to_mission, went_to_silo } or { ok=false, error }.
func harvest(guild_id: String, row: int, col: int) -> Dictionary:
    if guild_id.is_empty():
        return {"ok": false, "error": "no_guild"}

    var pos := Vector2i(row, col)
    var cell := get_cell(row, col)
    if cell.is_empty():
        return {"ok": false, "error": "cell_empty"}
    if not is_harvestable(row, col):
        return {"ok": false, "error": "not_harvestable"}
    if is_cell_pending(row, col):
        return {"ok": false, "error": "cell_busy", "message": "Harvest in progress."}

    _pending_cells[pos] = { "action": "harvest" }

    var res := await _rpc("harvest_guild_garden", {
        "p_device_hash": _device_hash(),
        "p_guild_id":    guild_id,
        "p_row":         row,
        "p_col":         col,
    })

    _pending_cells.erase(pos)

    if res.get("ok", false):
        ## Update local cache optimistically.
        grid.erase(pos)
        var data = res.get("data", {})
        if data is Dictionary:
            var crop_id: String = str(data.get("crop_id", ""))
            var to_silo: bool   = bool(data.get("went_to_silo", false))
            if to_silo and not crop_id.is_empty():
                silo[crop_id] = silo.get(crop_id, 0) + 1
        garden_updated.emit()

    return _friendly(res)


## Deposits `amount` of a crop from the silo directly into the active mission.
## Returns { ok, deposited } or { ok=false, error }.
func deposit_silo(guild_id: String, crop_id: String, amount: int) -> Dictionary:
    if guild_id.is_empty():
        return {"ok": false, "error": "no_guild"}
    if amount <= 0:
        return {"ok": false, "error": "invalid_amount"}
    if get_silo_amount(crop_id) < amount:
        return {"ok": false, "error": "silo_insufficient"}

    ## Optimistic local deduct.
    silo[crop_id] = maxi(silo.get(crop_id, 0) - amount, 0)
    if silo[crop_id] == 0:
        silo.erase(crop_id)

    var res := await _rpc("deposit_silo_to_mission", {
        "p_device_hash": _device_hash(),
        "p_guild_id":    guild_id,
        "p_crop_id":     crop_id,
        "p_amount":      amount,
    })

    if res.get("ok", false):
        garden_updated.emit()
        ## Also refresh missions so progress bars update.
        if GuildManager.is_in_guild():
            GuildManager.refresh_missions()
    else:
        ## Refund on failure.
        silo[crop_id] = silo.get(crop_id, 0) + amount

    return _friendly(res)


## ── Private ──────────────────────────────────────────────────────

func _friendly(res: Dictionary) -> Dictionary:
    if res.get("ok", false):
        ## Unwrap the data dict into the top level for convenient access.
        var data = res.get("data", null)
        if data is Dictionary:
            var out := {"ok": true}
            out.merge(data)
            return out
        return {"ok": true}
    var code := str(res.get("error", "unknown"))
    var msg: String
    match code:
        "account_not_found":    msg = "Online account required."
        "not_in_guild":         msg = "You are not in a guild."
        "not_gardening_guild":  msg = "Only gardening guilds have a community garden."
        "cell_occupied":        msg = "That plot is already planted."
        "cell_empty":           msg = "No plant in that plot."
        "not_harvestable":      msg = "That plant isn't ready yet."
        "cell_out_of_bounds":   msg = "That cell is outside the garden."
        "no_seeds":             msg = "You don't have that seed."
        "silo_full":            msg = "The guild silo is full."
        "silo_empty":           msg = "The silo has no stock of that crop."
        "silo_insufficient":    msg = "Not enough in the silo."
        "offline":              msg = "No connection."
        _:                      msg = "Error: %s" % code
    return {"ok": false, "error": code, "message": msg}
