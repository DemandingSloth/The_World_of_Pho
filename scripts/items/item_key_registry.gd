class_name ItemKeyRegistry
extends RefCounted

## Canonical string keys for every tradeable item, used by the online player
## marketplace so the server and all clients agree on what is being traded.
##
## Local item identity is mixed: gems/resources/crops/fruit use string ids,
## tiles use the Piece.Type enum (int), and tools use int ids. This registry
## normalizes all of them to a single colon-delimited string form:
##
##   gem:<gem_type>          e.g. "gem:diamond"
##   resource:<id>           e.g. "resource:iron_bar"
##   crop:<id>               e.g. "crop:beans"
##   fruit:<id>              e.g. "fruit:plum"
##   tile:<piece_name>       e.g. "tile:pawn"   (Piece.Type name, lowercased)
##   tool:<slug>             e.g. "tool:scythe"
##   item:<id>               e.g. "item:diamond_ring"  (enhancement items)
##
## Design notes:
## - Keys are STRINGS on purpose so the server never stores engine-specific
##   ints. Tiles key off the Piece.Type *name* (not its int value) so reordering
##   the enum later can't silently remap an existing listing to a different tile.
## - This is a pure static helper (no autoload, no network). It's safe to call
##   from anywhere and has no side effects.

## Category prefixes.
const CAT_GEM := "gem"
const CAT_RESOURCE := "resource"
const CAT_CROP := "crop"
const CAT_FRUIT := "fruit"
const CAT_TILE := "tile"
const CAT_TOOL := "tool"
const CAT_ITEM := "item"
const CAT_SEED := "seed"
const CAT_POLISHED := "polished"
const CAT_PRESENT := "present"
const CAT_SAPLING := "sapling"
const CAT_MATERIAL := "material"   ## rare crafting materials (WonderStone)
const CAT_VESSEL := "vessel"       ## WonderVessels (single-use duplicators)

## Stable per-tool slugs, keyed by PlayerData.ToolType int id. Kept explicit (not
## derived from the display name) so renaming a tool's label never changes its key.
const TOOL_SLUGS := {
	0: "magnifying_glass",  ## MAGNIFYING_GLASS
	1: "scythe",            ## SCYTHE
	2: "tractor",           ## TRACTOR
	3: "shovel",            ## SHOVEL
}


## ── Key builders (local id -> canonical key) ────────────────────

static func gem_key(gem_type: String) -> String:
	return "%s:%s" % [CAT_GEM, gem_type]

## Polished gem (Workshop saw output) — a distinct item from the raw gem.
static func polished_key(gem_type: String) -> String:
	return "%s:%s" % [CAT_POLISHED, gem_type]

## Present (Christmas Conifer output) — 8 variants (0..7). Tradeable so players
## can collect all 8 (each save only produces one variant).
static func present_key(variant: int) -> String:
	return "%s:%d" % [CAT_PRESENT, variant]

static func resource_key(item_id: String) -> String:
	return "%s:%s" % [CAT_RESOURCE, item_id]

static func crop_key(crop_id: String) -> String:
	return "%s:%s" % [CAT_CROP, crop_id]

static func fruit_key(fruit_id: String) -> String:
	return "%s:%s" % [CAT_FRUIT, fruit_id]

## Tiles key off the Piece.Type NAME (lowercased), not the int, for stability.
static func tile_key(piece_type: int) -> String:
	return "%s:%s" % [CAT_TILE, _piece_name(piece_type)]

static func tool_key(tool_id: int) -> String:
	return "%s:%s" % [CAT_TOOL, str(TOOL_SLUGS.get(tool_id, "tool_%d" % tool_id))]

static func item_key(item_id: String) -> String:
	return "%s:%s" % [CAT_ITEM, item_id]

## Seeds key off the GardenData.PlantType enum NAME (lowercased) for stability
## across enum reordering — e.g. seed:beans, seed:squash. This is the SEED, a
## distinct item from the harvested crop (crop:beans).
static func seed_key(plant_type: int) -> String:
	return "%s:%s" % [CAT_SEED, _plant_name(plant_type)]

## Saplings key off the Orchard TREE_DEFS stable string id (e.g. sapling:plum),
## not the TreeType int, so it survives enum reordering. This is the SAPLING
## (a plantable orchard tree), distinct from the fruit it eventually produces.
static func sapling_key(tree_id: String) -> String:
	return "%s:%s" % [CAT_SAPLING, tree_id]

## Rare crafting material, e.g. material:wonderstone.
static func material_key(material_id: String) -> String:
	return "%s:%s" % [CAT_MATERIAL, material_id]

## WonderVessel of a given tier (1..10), e.g. vessel:3.
static func vessel_key(tier: int) -> String:
	return "%s:%d" % [CAT_VESSEL, tier]


## ── Parsing (canonical key -> category + id) ────────────────────

## Splits a key into [category, id]. Returns ["", ""] if malformed.
static func split_key(key: String) -> Array:
	var idx := key.find(":")
	if idx <= 0 or idx >= key.length() - 1:
		return ["", ""]
	return [key.substr(0, idx), key.substr(idx + 1)]

static func category_of(key: String) -> String:
	return split_key(key)[0]

static func id_of(key: String) -> String:
	return split_key(key)[1]


## ── Validation + display ────────────────────────────────────────

## True if `key` names a real, currently tradeable item.
static func is_valid(key: String) -> bool:
	var parts := split_key(key)
	var cat: String = parts[0]
	var id: String = parts[1]
	if cat == "" or id == "":
		return false
	match cat:
		CAT_GEM:
			for def in PlayerData.PROSPECTOR_GEM_ORDER:
				if str(def["gem_type"]) == id:
					return true
			return false
		CAT_RESOURCE:
			return not PlayerData.get_resource_def(id).is_empty()
		CAT_CROP:
			return not PlayerData.get_crop_def(id).is_empty()
		CAT_FRUIT:
			## Fruit entries carry a `fruit_index`; jewelry/other item: entries don't.
			for def in PlayerData.ITEM_DEFS:
				if def.has("fruit_index") and str(def.get("id", "")) == id:
					return true
			return false
		CAT_TILE:
			return _piece_type_from_name(id) != -1
		CAT_TOOL:
			return TOOL_SLUGS.values().has(id)
		CAT_ITEM:
			## Jewelry (diamond_ring + the guild-produced set) and any other
			## non-fruit item: entry. Matches an ITEM_DEFS id that is NOT a fruit.
			for def in PlayerData.ITEM_DEFS:
				if not def.has("fruit_index") and str(def.get("id", "")) == id:
					return true
			return false
		CAT_SEED:
			return _plant_type_from_name(id) != -1
		CAT_POLISHED:
			return PlayerData.POLISHABLE_GEMS.has(id)
		CAT_PRESENT:
			return id.is_valid_int() and int(id) >= 0 and int(id) < PlayerData.PRESENT_COUNT
		CAT_SAPLING:
			return _tree_type_from_id(id) != -1
		CAT_MATERIAL:
			return id == "wonderstone"
		CAT_VESSEL:
			return id.is_valid_int() and int(id) >= 1 and int(id) <= 10
	return false


## True if `key` may be listed/sold on the PLAYER marketplace. Stricter than
## is_valid: excludes unique, non-stackable items that can't be duplicated into
## a buyer's inventory (permanent tools like the Tractor). Anything not
## tradeable must never be listable, buyable, or escrow-claimable.
static func is_tradeable(key: String) -> bool:
	if not is_valid(key):
		return false
	var parts := split_key(key)
	var cat: String = parts[0]
	var id: String = parts[1]
	if cat == CAT_TOOL:
		## Permanent tools (e.g. Tractor) are unique — the player can only ever
		## own one, so they can't be traded on the player market.
		for t in PlayerData.TOOL_DEFS:
			if TOOL_SLUGS.get(int(t["id"]), "") == id:
				return not bool(t.get("permanent", false))
		return false
	return true


## Category-aware search keywords for a key, so a text filter can match by
## category name as well as the item's own name. Rules the player expects:
##   "seed"/"seeds"     -> all seeds
##   "polished"         -> polished gems only
##   "gem"/"gems"       -> both raw AND polished gems
##   "tool"/"tools"     -> all tools
## etc. Returns the category keyword list for the key (lowercased).
static func search_keywords(key: String) -> PackedStringArray:
	var cat := category_of(key)
	var words: PackedStringArray = []
	match cat:
		CAT_GEM:
			words.append_array(["gem", "gems"])
		CAT_POLISHED:
			## Polished gems answer to "polished" AND to "gem"/"gems".
			words.append_array(["polished", "gem", "gems"])
		CAT_SEED:
			words.append_array(["seed", "seeds"])
		CAT_TOOL:
			words.append_array(["tool", "tools"])
		CAT_CROP:
			words.append_array(["crop", "crops", "vegetable", "vegetables"])
		CAT_RESOURCE:
			words.append_array(["resource", "resources", "ore", "ores", "ingot", "bar", "material"])
		CAT_FRUIT:
			words.append_array(["fruit", "fruits"])
		CAT_TILE:
			words.append_array(["tile", "tiles", "piece", "pieces"])
		CAT_ITEM:
			words.append_array(["item", "items"])
		CAT_SAPLING:
			words.append_array(["sapling", "saplings", "tree", "trees"])
		CAT_MATERIAL:
			words.append_array(["material", "wonderstone", "stone", "wonder"])
		CAT_VESSEL:
			words.append_array(["vessel", "wondervessel", "wonder", "duplicate"])
	return words


## True if `key` matches a search query. Empty query matches everything. Matches
## the item's display name OR any of its category keywords (see search_keywords).
static func matches_search(key: String, query: String) -> bool:
	var q := query.strip_edges().to_lower()
	if q == "":
		return true
	var haystack := display_name(key).to_lower()
	for kw in search_keywords(key):
		haystack += " " + kw
	return haystack.find(q) != -1


## Human-readable display name for a key (e.g. "gem:diamond" -> "Diamond"),
## reusing existing definitions where possible. Falls back to a prettified id.
static func display_name(key: String) -> String:
	var parts := split_key(key)
	var cat: String = parts[0]
	var id: String = parts[1]
	match cat:
		CAT_GEM:
			return id.replace("_", " ").capitalize()
		CAT_RESOURCE:
			var rdef := PlayerData.get_resource_def(id)
			return str(rdef.get("name", _prettify(id))) if not rdef.is_empty() else _prettify(id)
		CAT_CROP:
			var cdef := PlayerData.get_crop_def(id)
			return str(cdef.get("name", _prettify(id))) if not cdef.is_empty() else _prettify(id)
		CAT_FRUIT:
			for def in PlayerData.ITEM_DEFS:
				if def.has("fruit_index") and str(def.get("id", "")) == id:
					return str(def.get("name", _prettify(id)))
			return _prettify(id)
		CAT_TILE:
			var pt := _piece_type_from_name(id)
			if pt != -1 and Engine.get_main_loop() != null:
				var root := (Engine.get_main_loop() as SceneTree).root
				var reg := root.get_node_or_null("PieceRegistry") if root != null else null
				if reg != null and reg.has_method("get_def"):
					var pdef = reg.get_def(pt)
					if pdef != null and pdef.display_name != "":
						return pdef.display_name
			return _prettify(id)
		CAT_TOOL:
			for t in PlayerData.TOOL_DEFS:
				if TOOL_SLUGS.get(int(t["id"]), "") == id:
					return str(t.get("name", _prettify(id)))
			return _prettify(id)
		CAT_ITEM:
			for def in PlayerData.ITEM_DEFS:
				if not def.has("fruit_index") and str(def.get("id", "")) == id:
					return str(def.get("name", _prettify(id)))
			return _prettify(id)
		CAT_SEED:
			## e.g. "Bean Seed", "Squash Seed" — so buyers know it's the seed,
			## not the harvested vegetable.
			return "%s Seed" % _seed_base_name(id)
		CAT_POLISHED:
			## e.g. "Polished Diamond" — distinct from the raw "Diamond".
			return "Polished %s" % id.replace("_", " ").capitalize()
		CAT_PRESENT:
			## All 8 variants share the name "Present"; the art differs.
			return "Present"
		CAT_SAPLING:
			## e.g. "Plum Sapling" — the plantable tree, not its fruit.
			var tdef := _tree_def_for_id(id)
			if not tdef.is_empty():
				return "%s Sapling" % str(tdef.get("fruit_name", _prettify(id)))
			return "%s Sapling" % _prettify(id)
		CAT_MATERIAL:
			return "WonderStone" if id == "wonderstone" else _prettify(id)
		CAT_VESSEL:
			return "WonderVessel (Tier %s)" % id if id.is_valid_int() else "WonderVessel"
	return _prettify(id)


## Resolves a canonical item key to its display Texture2D (icon), centralizing
## the per-category sprite lookups the shop screens each did ad-hoc. Returns
## null if unavailable (caller should fall back to a placeholder). Safe to call
## from the online marketplace, which only knows keys.
static func get_texture(key: String) -> Texture2D:
	var parts := split_key(key)
	var cat: String = parts[0]
	var id: String = parts[1]
	match cat:
		CAT_GEM:
			return _safe_load("res://Assets/GoldPanning/Gemstones/%s.png" % id)
		CAT_POLISHED:
			return _safe_load("res://Assets/GoldPanning/Gemstones/%s_polished.png" % id)
		CAT_CROP:
			var cdef := PlayerData.get_crop_def(id)
			return _safe_load(str(cdef.get("sprite", ""))) if not cdef.is_empty() else null
		CAT_SEED:
			## Seed art is a 4-frame strip; use the first frame.
			var g = _garden()
			if g != null:
				var pt := _plant_type_from_name(id)
				if pt >= 0 and pt < g.PLANT_DEFS.size():
					return _first_frame(str(g.PLANT_DEFS[pt].get("sprite", "")), 4)
			return null
		CAT_RESOURCE:
			var rdef := PlayerData.get_resource_def(id)
			var sprite_id := str(rdef.get("ore_sprite", id)) if not rdef.is_empty() else id
			return OreSprites.get_item_texture(sprite_id)
		CAT_FRUIT:
			for def in PlayerData.ITEM_DEFS:
				if def.has("fruit_index") and str(def.get("id", "")) == id:
					var orch = _autoload("Orchard")
					if orch != null and orch.has_method("get_fruit_texture"):
						return orch.get_fruit_texture(int(def.get("fruit_index", 0)))
					return null
			return null
		CAT_TILE:
			var pt := _piece_type_from_name(id)
			if pt != -1:
				var ps = _autoload("PieceSprites")
				if ps != null and ps.has_method("get_icon"):
					## PieceRegistry def carries the sprite_index used by PieceSprites.
					var reg = _autoload("PieceRegistry")
					if reg != null and reg.has_method("get_def"):
						var pdef = reg.get_def(pt)
						if pdef != null:
							return ps.get_icon(pdef.sprite_index)
			return null
		CAT_TOOL:
			for t in PlayerData.TOOL_DEFS:
				if TOOL_SLUGS.get(int(t["id"]), "") == id:
					return _safe_load(str(t.get("sprite", "")))
			return null
		CAT_ITEM:
			for def in PlayerData.ITEM_DEFS:
				if not def.has("fruit_index") and str(def.get("id", "")) == id:
					return _safe_load(str(def.get("sprite", "")))
			return null
		CAT_PRESENT:
			if id.is_valid_int():
				return PlayerData.get_present_texture(int(id))
			return null
		CAT_SAPLING:
			var tt := _tree_type_from_id(id)
			if tt != -1:
				var orch = _autoload("Orchard")
				if orch != null and orch.has_method("get_tree_texture"):
					## Stage 1 = the young "sapling" frame (a recognizable icon).
					return orch.get_tree_texture(tt, 1)
			return null
		CAT_MATERIAL:
			if id == "wonderstone":
				return _safe_load("res://Assets/WonderStone.png")
			return null
		CAT_VESSEL:
			## WonderVessels.png is a horizontal strip of 10 (tiers 1..10).
			if id.is_valid_int():
				return _nth_frame("res://Assets/WonderVessels.png", 10, int(id) - 1)
			return null
	return null


## Loads a texture path, returning null on empty/missing rather than erroring.
static func _safe_load(path: String) -> Texture2D:
	if path == "" or not ResourceLoader.exists(path):
		return null
	var res = load(path)
	return res as Texture2D

## Returns the first horizontal frame of a `frames`-frame sprite strip as an
## AtlasTexture, or the whole texture if it can't be sliced.
static func _first_frame(path: String, frames: int) -> Texture2D:
	var tex := _safe_load(path)
	if tex == null:
		return null
	if frames <= 1:
		return tex
	var fw: float = float(tex.get_width()) / float(frames)
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = Rect2(0, 0, fw, tex.get_height())
	return atlas

## Returns the `index`-th horizontal frame of a `frames`-frame strip as an
## AtlasTexture (0-based). Clamps index; returns the whole texture if unsliceable.
static func _nth_frame(path: String, frames: int, index: int) -> Texture2D:
	var tex := _safe_load(path)
	if tex == null:
		return null
	if frames <= 1:
		return tex
	index = clampi(index, 0, frames - 1)
	var fw: float = float(tex.get_width()) / float(frames)
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = Rect2(index * fw, 0, fw, tex.get_height())
	return atlas

## Fetches an autoload node by name via the scene tree root, or null.
static func _autoload(node_name: String):
	if Engine.get_main_loop() == null:
		return null
	var root := (Engine.get_main_loop() as SceneTree).root
	if root == null:
		return null
	return root.get_node_or_null(node_name)


## Returns every valid tradeable key the game currently defines. Useful for
## tests and for building server-side item catalogs.
static func all_keys() -> Array[String]:
	var keys: Array[String] = []
	for def in PlayerData.PROSPECTOR_GEM_ORDER:
		keys.append(gem_key(str(def["gem_type"])))
	## Polished gems (Workshop saw output) — one per polishable gem type.
	for gem_type in PlayerData.POLISHABLE_GEMS:
		keys.append(polished_key(str(gem_type)))
	for rdef in PlayerData.RESOURCE_DEFS:
		keys.append(resource_key(str(rdef["id"])))
	for cdef in PlayerData.CROP_DEFS:
		keys.append(crop_key(str(cdef["id"])))
	## Fruit = ITEM_DEFS entries with a fruit_index; jewelry/other = without.
	for def in PlayerData.ITEM_DEFS:
		if def.has("fruit_index"):
			keys.append(fruit_key(str(def["id"])))
	for pt in _all_piece_types():
		keys.append(tile_key(pt))
	for tdef in PlayerData.TOOL_DEFS:
		keys.append(tool_key(int(tdef["id"])))
	## Jewelry (diamond_ring + the guild-produced set) and any other item: entry.
	for def in PlayerData.ITEM_DEFS:
		if not def.has("fruit_index"):
			keys.append(item_key(str(def["id"])))
	## Seeds (distinct from crops). One key per GardenData.PlantType.
	var pcount := _plant_type_count()
	for pt in range(pcount):
		keys.append(seed_key(pt))
	## Presents (Christmas Conifer output) — 8 tradeable variants.
	for v in range(PlayerData.PRESENT_COUNT):
		keys.append(present_key(v))
	## Saplings (plantable orchard trees). One key per Orchard TREE_DEFS entry.
	var orch = _autoload("Orchard")
	if orch != null:
		for tdef in orch.TREE_DEFS:
			keys.append(sapling_key(str(tdef["id"])))
	## WonderStone (rare material) + the 10 WonderVessel tiers.
	keys.append(material_key("wonderstone"))
	for tier in range(1, 11):
		keys.append(vessel_key(tier))
	return keys


## ── Internal: Piece.Type name <-> int ───────────────────────────

## Lowercased enum name for a Piece.Type int (e.g. PAWN -> "pawn").
static func _piece_name(piece_type: int) -> String:
	var names := Piece.Type.keys()
	if piece_type >= 0 and piece_type < names.size():
		return str(names[piece_type]).to_lower()
	return "tile_%d" % piece_type

## Piece.Type int for a lowercased enum name, or -1 if unknown.
static func _piece_type_from_name(name: String) -> int:
	var names := Piece.Type.keys()
	for i in range(names.size()):
		if str(names[i]).to_lower() == name:
			return i
	return -1

## All Piece.Type int values.
static func _all_piece_types() -> Array:
	var out: Array = []
	for v in Piece.Type.values():
		out.append(v)
	return out


## Prettifies a raw id for display (e.g. "iron_bar" -> "Iron Bar").
static func _prettify(id: String) -> String:
	return id.replace("_", " ").capitalize()


## ── Internal: seeds (GardenData.PlantType name <-> int) ─────────

## Reaches the Garden autoload node (Garden has no class_name, so it's only
## available as a runtime autoload). Returns null if unavailable.
static func _garden():
	if Engine.get_main_loop() == null:
		return null
	var root := (Engine.get_main_loop() as SceneTree).root
	if root == null:
		return null
	return root.get_node_or_null("Garden")

## Lowercased PlantType enum name for a plant_type int (e.g. BEANS -> "beans").
static func _plant_name(plant_type: int) -> String:
	var g = _garden()
	if g != null:
		var names = g.PlantType.keys()
		if plant_type >= 0 and plant_type < names.size():
			return str(names[plant_type]).to_lower()
	return "plant_%d" % plant_type

## PlantType int for a lowercased enum name, or -1 if unknown.
static func _plant_type_from_name(name: String) -> int:
	var g = _garden()
	if g != null:
		var names = g.PlantType.keys()
		for i in range(names.size()):
			if str(names[i]).to_lower() == name:
				return i
	return -1

## ── Internal: saplings (Orchard TREE_DEFS id <-> TreeType int) ──

## Orchard TREE_DEFS entry for a stable tree id (e.g. "plum"), or {} if unknown.
static func _tree_def_for_id(tree_id: String) -> Dictionary:
	var orch = _autoload("Orchard")
	if orch != null:
		for tdef in orch.TREE_DEFS:
			if str(tdef.get("id", "")) == tree_id:
				return tdef
	return {}

## TreeType int for a stable tree id (index into TREE_DEFS), or -1 if unknown.
static func _tree_type_from_id(tree_id: String) -> int:
	var orch = _autoload("Orchard")
	if orch != null:
		for i in range(orch.TREE_DEFS.size()):
			if str(orch.TREE_DEFS[i].get("id", "")) == tree_id:
				return i
	return -1


## Number of defined plant types (seeds), or 0 if Garden unavailable.
static func _plant_type_count() -> int:
	var g = _garden()
	if g != null:
		return g.PlantType.size()
	return 0

## Human base name for a seed id, singularized so it reads "Bean Seed" rather
## than "Beans Seed". Uses the plant's display name from PLANT_DEFS when
## available, else prettifies the id. Only strips a simple trailing "s"
## (Beans->Bean, Grapes->Grape); leaves "Squash", "Cauliflower" etc. intact.
static func _seed_base_name(id: String) -> String:
	var base := _prettify(id)
	var g = _garden()
	if g != null:
		var pt := _plant_type_from_name(id)
		if pt >= 0 and pt < g.PLANT_DEFS.size():
			base = str(g.PLANT_DEFS[pt].get("name", base))
	## Light singularization: drop a lone trailing "s" (not "ss").
	if base.length() >= 2 and base.ends_with("s") and not base.ends_with("ss"):
		base = base.substr(0, base.length() - 1)
	return base
