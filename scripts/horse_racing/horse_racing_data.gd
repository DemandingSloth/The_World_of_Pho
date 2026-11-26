extends Node
## Autoload: HorseRacing
## Client-side cache + RPC wrappers for the horse-racing feature (migration 065+).
## The SERVER owns horse existence, stats, naming, and stable capacity. COINS are
## a LOCAL currency (PlayerData.coins — no coin column on accounts), so buy/sell
## charge/credit coins LOCALLY only AFTER the server confirms the ownership
## change, mirroring the Money Gun purchase trust model.
##
## Also the single source of truth (client-side) for breed stats, the curated
## horse-name suggestion list, and the NPC name generator pools.

## ── Signals ─────────────────────────────────────────────────────
signal horses_changed()      ## Owned-horse list changed — UI should refresh
signal training_changed()    ## Training availability changed — UI should refresh
signal races_changed()       ## Race schedule / entries changed — UI should refresh
signal paddock_changed()     ## Guild paddock contents changed — UI should refresh

## ── Breed catalog (MUST match server _horse_breed_stats, migration 065) ──────
## life / speed / endurance base stats + whether purchasable with coins.
const HORSE_BREEDS := {
	"thoroughbred": {"name": "Thoroughbred", "life": 80,  "speed": 10, "endurance": 6,  "purchasable": true},
	"arabian":      {"name": "Arabian",      "life": 100, "speed": 8,  "endurance": 10, "purchasable": true},
	"standardbred": {"name": "Standardbred", "life": 90,  "speed": 9,  "endurance": 8,  "purchasable": true},
	"pegasus":      {"name": "Pegasus",      "life": 90,  "speed": 10, "endurance": 6,  "purchasable": false},
	"centaur":      {"name": "Centaur",      "life": 110, "speed": 9,  "endurance": 10, "purchasable": false},
	"unicorn":      {"name": "Unicorn",      "life": 150, "speed": 10, "endurance": 10, "purchasable": false},
}

## Stat caps.
const SPEED_CAP := 500
const ENDURANCE_CAP := 500
const LIFE_CAP_MAX := 500

## ── Training kinds (MUST match server train_horse, migration 067) ────────────
## Each kind is a mini-game trainable once per UTC day per horse. `stat` is the
## horse field it raises; `max_gain` is the per-session ceiling the SERVER
## enforces (the client's mini-game only reports a 0..100 score — the server
## decides the real gain). `ceiling` is the stat's hard cap.
## `ceiling` is the stat's hard cap. The per-session max GAIN is decided by the
## server (_horse_training_session_cap, base 10.00; raised by the horse guild),
## not here. Gain = round(score/10 + 1, 2) where `score` is the game's points.
const TRAINING_KINDS := {
	"sprint": {"name": "Sprint",  "stat": "speed",     "ceiling": SPEED_CAP,
		"icon": "🏃", "blurb": "Raises Speed."},
	"hurdle": {"name": "Hurdles", "stat": "endurance", "ceiling": ENDURANCE_CAP,
		"icon": "🚧", "blurb": "Raises Endurance."},
	"groom":  {"name": "Groom",   "stat": "life_cap",  "ceiling": LIFE_CAP_MAX,
		"icon": "✨", "blurb": "Raises max Life."},
}
## Ordered kind ids for stable UI.
const TRAINING_ORDER: Array[String] = ["sprint", "hurdle", "groom"]

## All three training kinds now enforce a 3-sessions-per-UTC-day limit
## (migration 090). The client pre-checks the training_status cache to
## avoid sending a doomed request; the server is still authoritative.
const TRAINING_CAPPED_KINDS: Array[String] = ["sprint", "hurdle", "groom"]

## ── Horse feed (local stackable consumable; MUST match server 068) ───────────
## Feed restores a horse's current `life` toward its life_cap. It's a LOCAL
## consumable bought with coins into PlayerData's generic item store (keyed by
## FEED_ITEM_ID), exactly like a Marketplace tool — the server does NOT track
## feed quantity. feed() calls the server to raise `life` (authoritative), then
## consumes one feed locally only on success. FEED_RESTORE mirrors the server's
## _horse_feed_restore() (display only — the server decides the real amount).
const FEED_ITEM_ID := "horse_feed"
const FEED_PRICE := 50000       ## coins per feed
const FEED_RESTORE := 25        ## life restored per feed (mirror of server)
const FEED_NAME := "Horse Feed"
const FEED_ICON := "🥕"

## ── Horseshoes (guild-produced ITEM_DEFS; equipped to a horse) ───────────────
## copper → race SPEED boost; iron → race ENDURANCE boost. One equipped per
## horse. The bonus scales with how many of that shoe the player OWNS, using the
## SAME count→level curve as jewelry (JewelryBonus.COUNT_THRESHOLDS, 1%..25%).
## The level is computed client-side and passed to register() so the server can
## bake it into the race-entry snapshot (migration 082).
const HORSESHOE_TYPES := {
	"copper": {"item_id": "copper_horseshoe", "stat": "speed",     "name": "Copper Horseshoe", "icon": "🧲"},
	"iron":   {"item_id": "iron_horseshoe",   "stat": "endurance", "name": "Iron Horseshoe",   "icon": "🔩"},
}

## Horse spritesheet (single sheet, sliced per breed — see horse_cell_region()).
## Path casing MUST match the on-disk folder exactly ("Horse Racing") or it
## fails to load on case-sensitive platforms (Android).
const SPRITE_DIR := "res://Assets/Horse Racing/"
const SPRITESHEET_PATH := "res://Assets/Horse Racing/horse_sprites.png"
## Hurdle runner mini-game art (used by the hurdle training game).
const TRAINING_BG_PATH := "res://Assets/Horse Racing/training_game_background.png"
const HURDLE_PATH := "res://Assets/Horse Racing/hurdle.png"
## Groom (brush-swipe) mini-game art. If brush.png is absent the game draws a
## simple placeholder brush, so it works before the art is added.
const BRUSH_PATH := "res://Assets/Horse Racing/brush.png"
## Pasture scenery backdrop (retired horses graze/walk here).
const PASTURE_BG_PATH := "res://Assets/Backgrounds/nature_5/orig.png"
## Race track background (5 lanes, scrolls during replay).
## IMPORTANT: open the Godot editor once after adding this file so it gets
## imported; until then ResourceLoader.exists() will return false and the
## replay falls back to the training background.
const RACE_BG_PATH := "res://Assets/Horse Racing/race_background.png"


## ── Curated horse-name suggestions (player picker). Deduped at _ready. ───────
const HORSE_NAME_SUGGESTIONS: Array[String] = [
	"Secretariat", "Man o' War", "Citation", "Seattle Slew", "Count Fleet", "Affirmed",
	"American Pharoah", "Justify", "Whirlaway", "Assault", "Gallant Fox", "Omaha",
	"War Admiral", "Kelso", "Dr. Fager", "Forego", "Spectacular Bid", "Native Dancer",
	"Seabiscuit", "Phar Lap", "Frankel", "Black Caviar", "Ruffian", "Zenyatta", "Cigar",
	"Winx", "Flightline", "Curlin", "Arrogate", "Gun Runner", "California Chrome",
	"Rachel Alexandra", "Ghostzapper", "Tiznow", "Goldikova", "Makybe Diva", "Enable",
	"Sea The Stars", "Kauto Star", "Arkle", "Red Rum", "Deep Impact", "Equinox", "Orfevre",
	"Wise Dan", "Skip Away", "John Henry", "Sunday Silence", "Easy Goer", "Alydar",
	"Buckpasser", "Damascus", "Round Table", "Tom Fool", "Swaps", "Nashua", "Bold Ruler",
	"Equipoise", "Challedon", "Stymie", "Coaltown", "Twilight Tear", "Busher", "Gallorette",
	"Armed", "Alsab", "Discovery", "Twenty Grand", "Blue Larkspur", "Top Flight", "Grey Lag",
	"Zev", "Crusader", "Bubbling Over", "Chance Shot", "Reigh Count", "Blue Peter",
	"Cameronian", "Hyperion", "Windsor Lad", "Bahram", "Mahmoud", "Tulyar", "Pinza",
	"Crepello", "Santa Claus", "Nijinsky", "Mill Reef", "Brigadier Gerard", "Grundy",
	"Shergar", "Northern Dancer", "Ribot", "Sea-Bird", "Dahlia", "Allez France",
	"Exterminator", "Granville", "Johnstown", "Bimelech", "Riva Ridge", "Canonero II",
	"Little Current", "Foolish Pleasure", "Bold Forbes", "Seattle Song", "Alysheba",
	"Silver Charm", "Real Quiet", "Charismatic", "Holy Bull", "Personal Ensign",
	"Go for Wand", "Lady's Secret", "Winning Colors", "Genuine Risk", "Susan's Girl",
	"Desert Vixen", "Ta Wee", "Shuvee", "A.P. Indy", "Lure", "Best Pal", "Broad Brush",
	"Precisionist", "Capot", "Hill Prince", "Counterpoint", "One Count", "Native Diver",
	"Ack Ack", "Arts and Letters", "Dust Commander", "Cannonade", "Exceller",
	"Ancient Title", "Devil Diver", "Sword Dancer", "Bald Eagle", "Slew o' Gold",
	"Bates Motel", "Conquistador Cielo", "Lemhi Gold", "Awesome Again", "Alphabet Soup",
	"Wild Rush", "Gentlemen", "Siphon", "Free House", "Cavonnier", "Dubai Millennium",
	"Street Cry", "Barbaro", "Smarty Jones", "Point Given", "Bernardini", "Invasor",
	"Shared Belief", "Beholder", "Rags to Riches", "Songbird", "Monomoy Girl",
	"Midnight Bisou", "Gamine", "Essential Quality", "Knicks Go", "Life Is Good",
	"Epicenter", "Cody's Wish", "White Abarrio", "Mage", "Arcangelo", "Fierceness",
	"Sierra Leone", "Thorpedo Anna", "Sottsass", "St Mark's Basilica", "Baaeed", "Adayar",
	"Hurricane Lane", "Pyledriver", "Mishriff", "Lord Kanaloa", "Almond Eye", "Contrail",
	"Lys Gracieux", "Chrono Genesis", "Gran Alegria", "Usual Suspect", "So You Think",
	"Chautauqua", "Nature Strip", "Verry Elleegant", "Incentivise", "Might and Power",
	"Sunline", "Lonhro", "Takeover Target", "Saintly", "Octagonal", "Speightstown",
	"Lost in the Fog", "Midnight Lute", "Kona Gold", "Cherokee Run", "Housebuster",
	"Rubiano", "Safely Kept", "Groovy", "Eillo", "Smile", "Gulch", "Forty Niner",
	"Risen Star", "Tabasco Cat", "Thunder Gulch", "Grindstone", "Touch Gold",
	"Victory Gallop", "Commendable", "Sarava", "Birdstone", "Afleet Alex", "Jazil",
	"Da' Tara", "Summer Bird", "Drosselmeyer", "Ruler On Ice", "Union Rags",
	"Palace Malice", "Tonalist", "Creator", "Tapwrit", "Sir Winston", "Tiz the Law",
	"Authentic", "Mandaloun", "Rich Strike", "National Treasure", "Seize the Grey",
	"Dornoch", "Desert Orchid", "Best Mate", "Sprinter Sacre", "Altior",
	"Constitution Hill", "Golden Miller", "Crisp",
]

## ── NPC name generator pools (option A: first + last). Provided verbatim. ────
const NPC_FIRST_NAMES_MALE: Array[String] = [
	"James", "Michael", "John", "Robert", "David", "William", "Richard", "Joseph", "Thomas",
	"Christopher", "Charles", "Daniel", "Matthew", "Anthony", "Mark", "Steven", "Andrew",
	"Tucker", "Joshua", "Paul", "Kevin", "Kenneth", "Brian", "Timothy", "Ronald", "Jason",
	"George", "Edward", "Jeffrey", "Jacob", "Ryan", "Nicholas", "Gary", "Eric", "Jonathan",
	"Stephen", "Larry", "Justin", "Benjamin", "Scott", "Brandon", "Samuel", "Alexander",
	"Gregory", "Patrick", "Jack", "Frank", "Raymond", "Dennis", "Aaron",
]
const NPC_FIRST_NAMES_FEMALE: Array[String] = [
	"Mary", "Patricia", "Jennifer", "Linda", "Elizabeth", "Barbara", "Susan", "Jessica",
	"Karen", "Sarah", "Lisa", "Nancy", "Sandra", "Ashley", "Emily", "Kimberly", "Michelle",
	"Donna", "Margaret", "Carol", "Betty", "Amanda", "Melissa", "Deborah", "Stephanie",
	"Rebecca", "Sharon", "Cynthia", "Laura", "Amy", "Kathleen", "Angela", "Emma", "Shirley",
	"Dorothy", "Brenda", "Nicole", "Pamela", "Samantha", "Anna", "Olivia", "Katherine",
	"Christine", "Debra", "Rachel", "Maria", "Carolyn", "Janet", "Heather", "Diane",
]
const NPC_LAST_NAMES: Array[String] = [
	"Smith", "Johnson", "Williams", "Brown", "Jones", "Miller", "Davis", "Garcia",
	"Rodriguez", "Wilson", "Martinez", "Anderson", "Taylor", "Thomas", "Hernandez", "Moore",
	"Martin", "Jackson", "Thompson", "White", "Lopez", "Lee", "Gonzalez", "Harris", "Clark",
	"Lewis", "Robinson", "Walker", "Perez", "Hall", "Young", "Allen", "Sanchez", "Wright",
	"King", "Scott", "Green", "Baker", "Adams", "Nelson", "Hill", "Ramirez", "Campbell",
	"Mitchell", "Roberts", "Carter", "Phillips", "Evans", "Turner", "Torres",
]

## ── Cached state ─────────────────────────────────────────────────
## horses: Array of { id, name, breed, life, life_cap, speed, endurance, status,
##                    wins, races_run }
var horses: Array = []
var stable_capacity: int = 5

## Per-horse training availability for today: { horse_id -> { sprint, hurdle,
## groom : bool } } where true means "available to train now". Populated by
## refresh_training(); absent horse_id -> assume all available.
var training_status: Dictionary = {}

## Unix time (secs) of the next UTC midnight, when the 3/day training counters
## reset (from the server; 0 = unknown).
var training_resets_at: float = 0.0

## Cached race schedule (open + closed races not yet resolved). Each entry:
## { id, name, kind, status, field_size, opens_at, closes_at,
##   entries:[{ lane, is_npc, display_name, breed, speed, endurance, life,
##              horse_id, mine }] }. Populated by refresh_races().
var races: Array = []

## Field size (lanes per race) — mirrors server _race_field_size().
const RACE_FIELD_SIZE := 8

## ── Cups (MUST match server _race_cup_tiers, migration 077) ──────────────────
## Recurring cup races gated by a horse's STAT-TOTAL (= current life+speed+
## endurance). A horse is LOCKED TO ITS HIGHEST eligible tier. Top-3 finishers
## win COIN prizes (1st = first_prize, 2nd = 50%, 3rd = 25%); the winner also
## gets a mythical foal of the tier's breed IF the stable has room. Coins are a
## LOCAL currency, so prizes are credited client-side (claim_cup_prizes), once
## each. Band is [min_total, max_total] (max_total 0 = open-ended top tier).
const CUP_TIERS := {
	1: {"name": "Little Cup", "min_total": 125, "max_total": 229, "prize_breed": "unicorn", "first_prize": 1000000,   "icon": "🥉"},
	2: {"name": "Rodeo Cup",  "min_total": 230, "max_total": 349, "prize_breed": "centaur", "first_prize": 10000000,  "icon": "🥈"},
	3: {"name": "Derby Cup",  "min_total": 350, "max_total": 0,   "prize_breed": "pegasus", "first_prize": 100000000, "icon": "🥇"},
}
## Field size for cups (vs RACE_FIELD_SIZE for regular) — mirrors server.
const CUP_FIELD_SIZE := 5

var is_loading: bool = false

## Deduped suggestion list (built at _ready from HORSE_NAME_SUGGESTIONS).
var _suggestions: Array[String] = []


func _ready() -> void:
	## Dedupe the curated suggestions (the source list has a couple of repeats).
	var seen := {}
	for n in HORSE_NAME_SUGGESTIONS:
		if not seen.has(n):
			seen[n] = true
			_suggestions.append(n)


## ── RPC helpers (same shape as the guild/money-gun autoloads) ────

func _rpc(fn: String, body: Variant = null) -> Dictionary:
	if get_node_or_null("/root/SupabaseClient") == null:
		return {"ok": false, "error": "offline"}
	if not SupabaseClient.is_configured():
		return {"ok": false, "error": "offline"}
	var res := await SupabaseClient.request_json("POST", "/rest/v1/rpc/%s" % fn, body)
	if not res.get("ok", false):
		return res
	var data = res.get("data", null)
	if data is Dictionary and data.has("error"):
		return {"ok": false, "error": str(data["error"])}
	return {"ok": true, "data": data}


func _device_hash() -> String:
	return MarketplaceAccount._device_hash()


## ── Catalog convenience ──────────────────────────────────────────

func breed_def(breed: String) -> Dictionary:
	return HORSE_BREEDS.get(breed, {})


func breed_stat_total(breed: String) -> int:
	var d := breed_def(breed)
	if d.is_empty():
		return 0
	return int(d.get("life", 0)) + int(d.get("speed", 0)) + int(d.get("endurance", 0))


## Coin price to buy a breed = stat_total * 100000.
func buy_price(breed: String) -> int:
	return breed_stat_total(breed) * 100000


## Coin price a horse sells back for = HALF the current buy price = stat_total *
## 50000 (migration 071). Stats are fractional; the server rounds the stat total
## to an int, so this display estimate rounds the same way to stay consistent.
func sell_price_for(life: float, speed: float, endurance: float) -> int:
	var total := int(round(life + speed + endurance))
	return total * 50000


## Purchasable breed ids, in catalog order.
func purchasable_breeds() -> Array[String]:
	var out: Array[String] = []
	for k in HORSE_BREEDS:
		if bool(HORSE_BREEDS[k].get("purchasable", false)):
			out.append(k)
	return out


## Deduped suggestion list for the name picker.
func name_suggestions() -> Array[String]:
	return _suggestions


## Training-kind definition, or {} for an unknown kind.
func training_def(kind: String) -> Dictionary:
	return TRAINING_KINDS.get(kind, {})


## True if `kind` can be trained on this horse today (not on cooldown and not
## already at the kind's ceiling). Unknown horse -> assume available.
func can_train(horse_id: String, kind: String) -> bool:
	var d := training_def(kind)
	if d.is_empty():
		return false
	## At ceiling?
	var h := horse_by_id(horse_id)
	if not h.is_empty():
		var stat := str(d.get("stat", ""))
		if float(h.get(stat, 0)) >= float(d.get("ceiling", 0)):
			return false
	## Session limit (all three kinds are capped at 3/day). The remaining count
	## is the source of truth so the button and the "n/3 left" text never disagree.
	return training_sessions_remaining(horse_id, kind) > 0


## How many training sessions are left today for a given kind (0–3).
func training_sessions_remaining(horse_id: String, kind: String) -> int:
	var row = training_status.get(horse_id, {})
	if row is Dictionary:
		var key := kind + "_remaining"
		if row.has(key):
			return int(row[key])
	return 3  ## assume max when status not yet loaded


## The cached horse row for an id, or {} if we don't have it.
func horse_by_id(horse_id: String) -> Dictionary:
	for h in horses:
		if str(h.get("id", "")) == horse_id:
			return h
	return {}


## A random "First Last" NPC name.
func random_npc_name() -> String:
	var firsts: Array[String] = []
	firsts.append_array(NPC_FIRST_NAMES_MALE)
	firsts.append_array(NPC_FIRST_NAMES_FEMALE)
	var first := firsts[randi() % firsts.size()] if firsts.size() > 0 else "Racer"
	var last := NPC_LAST_NAMES[randi() % NPC_LAST_NAMES.size()] if NPC_LAST_NAMES.size() > 0 else ""
	return ("%s %s" % [first, last]).strip_edges()


## ── Spritesheet slicing ──────────────────────────────────────────
## Single sheet: 1260x285, laid out as 6 breeds across x 4 rows. Each breed
## occupies a 210px-wide column-group (3 anim columns of 70px). Rows are facing
## directions; row 1 (y~76) is the side profile — the natural racing pose.
## Breed order IN THE SHEET (left->right): arabian, thoroughbred, standardbred,
## unicorn, centaur, pegasus.
const _SHEET_BREED_ORDER: Array[String] = [
	"arabian", "thoroughbred", "standardbred", "unicorn", "centaur", "pegasus",
]
const _SHEET_BREED_PITCH := 210   ## px per breed column-group (3 x 70)
const _SHEET_CELL := 70           ## px cell pitch (w and nominal h)
const _SHEET_PROFILE_ROW_Y := 76  ## top of the side-profile row (row 1)
const _SHEET_MID_COL_X := 70      ## middle anim column within a breed group

var _sheet_tex: Texture2D = null


func _sheet() -> Texture2D:
	if _sheet_tex == null and ResourceLoader.exists(SPRITESHEET_PATH):
		_sheet_tex = load(SPRITESHEET_PATH) as Texture2D
	return _sheet_tex


## A still side-profile frame for a breed as an AtlasTexture, or null if the
## sheet isn't present / the breed is unknown.
func breed_texture(breed: String) -> Texture2D:
	var sheet := _sheet()
	if sheet == null:
		return null
	var idx := _SHEET_BREED_ORDER.find(breed)
	if idx < 0:
		return null
	var at := AtlasTexture.new()
	at.atlas = sheet
	at.region = Rect2(
		idx * _SHEET_BREED_PITCH + _SHEET_MID_COL_X,
		_SHEET_PROFILE_ROW_Y,
		_SHEET_CELL, _SHEET_CELL)
	return at


## A side-profile RUN frame for a breed. The profile row has 3 anim columns per
## breed (x = 0,70,140 within the 210px breed group); cycling them animates a
## running gait. `frame` is taken modulo 3. Returns an AtlasTexture or null.
func breed_run_frame(breed: String, frame: int) -> Texture2D:
	var sheet := _sheet()
	if sheet == null:
		return null
	var idx := _SHEET_BREED_ORDER.find(breed)
	if idx < 0:
		return null
	var col := posmod(frame, 3)
	var at := AtlasTexture.new()
	at.atlas = sheet
	at.region = Rect2(
		idx * _SHEET_BREED_PITCH + col * _SHEET_CELL,
		_SHEET_PROFILE_ROW_Y,
		_SHEET_CELL, _SHEET_CELL)
	return at


## ── Response parsing (shared by refresh + tests) ─────────────────

func apply_payload(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	stable_capacity = int(data.get("capacity", stable_capacity))
	horses.clear()
	var raw = data.get("horses", [])
	if raw is Array:
		for e in raw:
			if not e is Dictionary:
				continue
			horses.append({
				"id":        str(e.get("id", "")),
				"name":      str(e.get("name", "")),
				"breed":     str(e.get("breed", "")),
				## Stats are NUMERIC(5,2) server-side — parse as float.
				"life":      float(e.get("life", 0)),
				"life_cap":  float(e.get("life_cap", 0)),
				"speed":     float(e.get("speed", 0)),
				"endurance": float(e.get("endurance", 0)),
				"status":    str(e.get("status", "active")),
				"wins":      int(e.get("wins", 0)),
				"races_run": int(e.get("races_run", 0)),
				## Equipped horseshoe: "" | "copper" | "iron" (migration 082).
				"horseshoe": str(e.get("horseshoe", "")),
			})
	return true


## ── Convenience views ────────────────────────────────────────────

func active_horses() -> Array:
	return horses.filter(func(h): return str(h.get("status", "")) == "active")


func retired_horses() -> Array:
	return horses.filter(func(h): return str(h.get("status", "")) == "retired")


func active_count() -> int:
	return active_horses().size()


func has_stable_room() -> bool:
	return active_count() < stable_capacity


## ── Public API ───────────────────────────────────────────────────

func refresh() -> Dictionary:
	is_loading = true
	var res := await _rpc("get_horses", {"p_device_hash": _device_hash()})
	is_loading = false
	if not res.get("ok", false):
		return _friendly(res)
	if not apply_payload(res.get("data", {})):
		return {"ok": false, "error": "bad_response", "message": "Bad server response."}
	horses_changed.emit()
	return {"ok": true}


## Buys a purchasable breed and names it. Coins are a LOCAL currency, so we
## verify + deduct them locally ONLY AFTER the server records the horse (the
## RPC echoes `price`). Name is validated via PlayerData.validate_name for
## free-text; curated suggestions are pre-vetted (caller may pass is_suggestion).
func buy(breed: String, horse_name: String, is_suggestion: bool = false) -> Dictionary:
	var d := breed_def(breed)
	if d.is_empty() or not bool(d.get("purchasable", false)):
		return {"ok": false, "error": "not_purchasable", "message": "That breed can't be bought."}
	if not has_stable_room():
		return {"ok": false, "error": "stable_full", "message": "Your stable is full (%d)." % stable_capacity}

	var clean := horse_name.strip_edges()
	if is_suggestion:
		## Curated name: only guard length (char rules bypassed — pre-vetted).
		if clean.length() < 1 or clean.length() > 24:
			return {"ok": false, "error": "invalid_name", "message": "Pick a valid name."}
	else:
		var err := PlayerData.validate_name(clean)
		if err != "":
			return {"ok": false, "error": "invalid_name", "message": err}

	var price := buy_price(breed)
	if PlayerData.coins < price:
		return {"ok": false, "error": "insufficient_coins",
			"message": "That horse costs %s coins." % PlayerData.format_number(price)}

	var res := await _rpc("buy_horse", {
		"p_device_hash": _device_hash(),
		"p_breed":       breed,
		"p_name":        clean,
	})
	if not res.get("ok", false):
		return _friendly(res)

	## Server recorded the horse — charge the local coins now.
	var data = res.get("data", {})
	var charged := int(data.get("price", price)) if data is Dictionary else price
	PlayerData.coins -= charged
	PlayerData.save_data()
	PlayerData.data_changed.emit()

	await refresh()
	return _friendly(res)


## Renames one of the player's horses (migration 112). Free. Same rules as
## naming at purchase: 1..24 characters, profanity-filtered. Curated
## suggestions skip the character check (they're pre-vetted).
func rename_horse(horse_id: String, new_name: String, is_suggestion: bool = false) -> Dictionary:
	var clean := new_name.strip_edges()
	if clean.length() < 1 or clean.length() > 24:
		return {"ok": false, "error": "invalid_name", "message": "Names must be 1-24 characters."}
	if not is_suggestion and not PlayerData.is_name_clean(clean):
		return {"ok": false, "error": "invalid_name", "message": "That name contains inappropriate language."}
	var res := await _rpc("rename_horse", {
		"p_device_hash": _device_hash(),
		"p_horse_id":    horse_id,
		"p_name":        clean,
	})
	if not res.get("ok", false):
		return _friendly(res)
	await refresh()
	return _friendly(res)


## Sells a horse back to the game for coins (credited locally on success).
func sell(horse_id: String) -> Dictionary:
	var res := await _rpc("sell_horse", {
		"p_device_hash": _device_hash(),
		"p_horse_id":    horse_id,
	})
	if not res.get("ok", false):
		return _friendly(res)
	var data = res.get("data", {})
	var price := int(data.get("price", 0)) if data is Dictionary else 0
	if price > 0:
		PlayerData.coins += price
		PlayerData.save_data()
		PlayerData.data_changed.emit()
	await refresh()
	var out := _friendly(res)
	out["price"] = price
	return out


## ── Horse marketplace (player-to-player, TOKENS) ─────────────────
## Horses sell to other players for marketplace TOKENS (server currency), unlike
## the coin buyback. Suggested price = coin buyback / 10 = stat_total*5000 tokens
## (seller may set any price). A listed horse can't race or be paddocked, and
## retired horses can't be listed. Buyer needs stable room.

## Cached active horse-market listings + the caller's token balance.
var horse_market: Array = []
var horse_market_balance: int = 0


## Suggested token price for a horse (base stats). = round(stat_total)*5000.
func horse_market_suggested_price(h: Dictionary) -> int:
	var total := int(round(float(h.get("life", 0)) + float(h.get("speed", 0)) + float(h.get("endurance", 0))))
	return maxi(1, total * 5000)


## Refreshes the horse marketplace (active listings + token balance).
func refresh_horse_market() -> Dictionary:
	var res := await _rpc("get_horse_market", {"p_device_hash": _device_hash()})
	if not res.get("ok", false):
		return _friendly(res)
	var data = res.get("data", {})
	horse_market_balance = int(data.get("balance", 0)) if data is Dictionary else 0
	horse_market = _parse_horse_market(data.get("listings", []) if data is Dictionary else [])
	return {"ok": true}


func _parse_horse_market(raw: Variant) -> Array:
	var out: Array = []
	if not raw is Array:
		return out
	for l in raw:
		if not l is Dictionary:
			continue
		out.append({
			"listing_id":  str(l.get("listing_id", "")),
			"horse_id":    str(l.get("horse_id", "")),
			"price":       int(l.get("price", 0)),
			"seller_id":   str(l.get("seller_id", "")),
			"seller_name": str(l.get("seller_name", "")),
			"mine":        bool(l.get("mine", false)),
			"name":        str(l.get("name", "")),
			"breed":       str(l.get("breed", "")),
			"speed":       float(l.get("speed", 0)),
			"endurance":   float(l.get("endurance", 0)),
			"life":        float(l.get("life", 0)),
			"life_cap":    float(l.get("life_cap", 0)),
			"wins":        int(l.get("wins", 0)),
			"races_run":   int(l.get("races_run", 0)),
		})
	return out


## Lists one of the caller's active horses for sale at `price` tokens.
func list_horse(horse_id: String, price: int) -> Dictionary:
	if price < 1:
		return {"ok": false, "error": "bad_price", "message": "Enter a price."}
	var res := await _rpc("list_horse", {
		"p_device_hash": _device_hash(), "p_horse_id": horse_id, "p_price": price,
	})
	if not res.get("ok", false):
		return _friendly(res)
	await refresh()
	await refresh_horse_market()
	return _friendly(res)


## Cancels the caller's own active listing (horse was never transferred).
func cancel_horse_listing(listing_id: String) -> Dictionary:
	var res := await _rpc("cancel_horse_listing", {
		"p_device_hash": _device_hash(), "p_listing_id": listing_id,
	})
	if not res.get("ok", false):
		return _friendly(res)
	await refresh()
	await refresh_horse_market()
	return _friendly(res)


## Buys a listed horse (tokens debited server-side; ownership transfers).
## After the server confirms, the sold listing is dropped from the local market
## right away and the stable is re-fetched (retried once) until the bought horse
## actually appears — so the UI can never keep showing a stale market/stable.
## The result carries `in_stable` (bool) so the caller can report accurately.
func buy_horse_listing(listing_id: String) -> Dictionary:
	var res := await _rpc("buy_horse_listing", {
		"p_device_hash": _device_hash(), "p_listing_id": listing_id,
	})
	if not res.get("ok", false):
		return _friendly(res)
	var out := _friendly(res)
	var horse_id := str(out.get("horse_id", ""))

	## The listing is sold — remove it locally even if the re-fetch fails.
	horse_market = horse_market.filter(func(l): return str(l.get("listing_id", "")) != listing_id)
	if out.has("new_balance"):
		horse_market_balance = int(out["new_balance"])

	## Pull the stable; retry once if the horse isn't there yet.
	var in_stable := false
	for attempt in range(2):
		var r := await refresh()
		if r.get("ok", false) and _owns_horse(horse_id):
			in_stable = true
			break
		await get_tree().create_timer(1.0).timeout
	await refresh_horse_market()
	out["in_stable"] = in_stable
	return out


## True if a horse with this id is in the locally cached stable.
func _owns_horse(horse_id: String) -> bool:
	if horse_id == "":
		return false
	for h in horses:
		if h is Dictionary and str(h.get("id", "")) == horse_id:
			return true
	return false


## Refreshes the per-horse training availability for today (UTC). Safe to call
## alongside refresh(); updates training_status + emits training_changed.
func refresh_training() -> Dictionary:
	var res := await _rpc("get_training_status", {"p_device_hash": _device_hash()})
	if not res.get("ok", false):
		return _friendly(res)
	var data = res.get("data", {})
	training_status.clear()
	if data is Dictionary:
		training_resets_at = float(data.get("resets_at", training_resets_at))
		var rows = data.get("horses", [])
		if rows is Array:
			for e in rows:
				if not e is Dictionary:
					continue
				var hid := str(e.get("horse_id", ""))
				if hid == "":
					continue
				training_status[hid] = {
					"sprint": bool(e.get("sprint", true)),
					"hurdle": bool(e.get("hurdle", true)),
					"groom":  bool(e.get("groom",  true)),
					## Remaining session counts (0–3) from migration 090.
					"sprint_remaining": int(e.get("sprint_remaining", 3)),
					"hurdle_remaining": int(e.get("hurdle_remaining", 3)),
					"groom_remaining":  int(e.get("groom_remaining",  3)),
				}
	training_changed.emit()
	return {"ok": true}


## Trains a horse in `kind` (sprint/hurdle/groom), reporting the mini-game
## `score` (0..100). The SERVER decides the real stat gain + enforces the
## once-per-day cooldown and ceilings — we only report the score. On success the
## horse list + training status are refreshed. Returns the _friendly() result,
## with { stat, gain } merged in from the server on success.
func train(horse_id: String, kind: String, score: int) -> Dictionary:
	var d := training_def(kind)
	if d.is_empty():
		return {"ok": false, "error": "invalid_kind", "message": "Unknown training."}
	## Local pre-checks for a nicer message (server is still authoritative).
	if not can_train(horse_id, kind):
		var h := horse_by_id(horse_id)
		if not h.is_empty() and float(h.get(str(d.get("stat", "")), 0)) >= float(d.get("ceiling", 0)):
			return {"ok": false, "error": "at_ceiling",
				"message": "%s is already maxed." % str(d.get("name", kind))}
		return {"ok": false, "error": "already_trained",
			"message": "Already did %s today. Try again tomorrow." % str(d.get("name", kind))}

	## Push current horseshoe/prestige levels first: the server raises this
	## session's cap from them (migration 111), and shoe counts can change.
	await PlayerData.sync_horse_prestige(false)

	## Score is an integer point count (sprint green sections / hurdles cleared /
	## groom center-hits). It can exceed 100; the server floors at 0 and caps the
	## resulting gain, so we only guard against negatives here.
	var res := await _rpc("train_horse", {
		"p_device_hash": _device_hash(),
		"p_horse_id":    horse_id,
		"p_kind":        kind,
		"p_score":       maxi(score, 0),
		## Equipped-jewelry training boost for this kind (violet=sprint,
		## blue=hurdle, black=groom). Applied server-side AFTER the session cap,
		## so it can push the gain above the base cap. 1.0 if nothing equipped.
		"p_train_mult":  _training_mult(kind),
	})
	## Apply the server's authoritative remaining count immediately, so the
	## popup can't show a stale "n/3 left" while the refreshes below run.
	_apply_remaining_from(res, horse_id, kind)
	if not res.get("ok", false):
		return _friendly(res)

	await refresh()
	await refresh_training()
	return _friendly(res)


## Updates the cached remaining count for one horse+kind from a train reply
## (success carries `remaining`; already_trained means 0 left). Emits
## training_changed so open UI refreshes right away.
func _apply_remaining_from(res: Dictionary, horse_id: String, kind: String) -> void:
	var data = res.get("data", {})
	var rem := -1
	if res.get("ok", false) and data is Dictionary and data.has("remaining"):
		rem = int(data["remaining"])
	elif str(res.get("error", "")) == "already_trained":
		rem = 0
	if rem < 0:
		return
	if data is Dictionary and data.has("resets_at"):
		training_resets_at = float(data["resets_at"])
	var row: Dictionary = training_status.get(horse_id, {})
	row[kind + "_remaining"] = rem
	row[kind] = rem > 0
	training_status[horse_id] = row
	training_changed.emit()


## "resets in 3h 12m" for the daily training counters (UTC midnight), or "".
func training_reset_text() -> String:
	var at := training_resets_at
	if at <= 0.0:
		## Fallback: compute the next UTC midnight locally.
		var now_u := int(TrustedClock.now())
		at = float((now_u / 86400 + 1) * 86400)
	var secs := int(at - TrustedClock.now())
	if secs <= 0:
		return "resets now"
	var h := secs / 3600
	var m := (secs % 3600) / 60
	return "resets in %dh %dm" % [h, m] if h > 0 else "resets in %dm" % maxi(m, 1)


## The equipped-jewelry training multiplier for a kind (>= 1.0), via JewelryBonus.
func _training_mult(kind: String) -> float:
	var mult := 1.0
	if get_node_or_null("/root/JewelryBonus") != null:
		mult = JewelryBonus.horse_training_multiplier(kind)
	## Recipe boosts: Tropical Oat & Fruit Mash ("Equestrian Spark") boosts
	## Speed/Endurance training (sprint/hurdle); Coconut Water Hydration
	## ("Grooming Bliss") boosts groom (life/vitality recovery).
	if get_node_or_null("/root/PlayerData") != null:
		if (kind == "sprint" or kind == "hurdle") and PlayerData.boost_active("equestrian_spark"):
			mult *= 1.0 + PlayerData.boost_value("equestrian_spark")
		elif kind == "groom" and PlayerData.boost_active("grooming_bliss"):
			mult *= 1.0 + PlayerData.boost_value("grooming_bliss")
	return mult


## ── Horse feed ───────────────────────────────────────────────────

## How many feeds the player currently owns (local inventory).
func feed_count() -> int:
	return PlayerData.get_item_count(FEED_ITEM_ID)


## Buys `qty` feeds for coins (fully local, like a Marketplace tool). Returns
## { ok, bought, spent } | { ok:false, error, message }.
func buy_feed(qty: int = 1) -> Dictionary:
	var n := maxi(qty, 0)
	if n <= 0:
		return {"ok": false, "error": "bad_qty", "message": "Pick a quantity."}
	var cost := FEED_PRICE * n
	if PlayerData.coins < cost:
		return {"ok": false, "error": "insufficient_coins",
			"message": "That costs %s coins." % PlayerData.format_number(cost)}
	PlayerData.coins -= cost
	PlayerData.add_item(FEED_ITEM_ID, n)  ## add_item saves + emits data_changed
	return {"ok": true, "bought": n, "spent": cost}


## Feeds a horse: raises its `life` toward life_cap (server-authoritative), then
## consumes ONE feed locally on success. Requires a feed in inventory. Returns
## the _friendly() result with { restored, life, life_cap } merged on success.
func feed(horse_id: String) -> Dictionary:
	if feed_count() <= 0:
		return {"ok": false, "error": "no_feed", "message": "You have no feed."}
	## Local pre-check for a nicer message (server is still authoritative).
	var h := horse_by_id(horse_id)
	if not h.is_empty() and float(h.get("life", 0)) >= float(h.get("life_cap", 0)):
		return {"ok": false, "error": "already_full", "message": "That horse is already full."}

	var res := await _rpc("feed_horse", {
		"p_device_hash": _device_hash(),
		"p_horse_id":    horse_id,
	})
	if not res.get("ok", false):
		return _friendly(res)

	## Server raised life — consume one feed locally now.
	PlayerData.consume_fruit(FEED_ITEM_ID, 1)  ## saves + emits data_changed
	await refresh()
	return _friendly(res)


## ── Races ────────────────────────────────────────────────────────

## Refreshes the race schedule (the server lazily advances it first — closing
## expired races, backfilling NPCs, keeping an open race available). Fills the
## `races` cache + emits races_changed. Returns { ok } | { ok:false, error }.
func refresh_races() -> Dictionary:
	var res := await _rpc("get_races", {"p_device_hash": _device_hash()})
	if not res.get("ok", false):
		return _friendly(res)
	var data = res.get("data", {})
	## Capture the server clock so countdowns are correct even if the device
	## clock is skewed: offset = server_now - local_now (seconds).
	if data is Dictionary and data.has("now"):
		var srv := _iso_to_unix(str(data.get("now", "")))
		if srv > 0.0:
			_race_time_offset = srv - TrustedClock.now()
	races = _parse_races(data)
	races_changed.emit()
	return {"ok": true}


## ── Race countdown helpers ───────────────────────────────────────

## Server-time offset (server_now - local_now), set on each refresh_races.
var _race_time_offset: float = 0.0


## Parse an ISO-8601 timestamp (e.g. "2026-01-01T00:00:00Z" or "...+00") to Unix
## seconds, or 0.0 if blank/unparseable. Godot ignores the trailing 'Z'.
func _iso_to_unix(iso: String) -> float:
	if iso.strip_edges() == "":
		return 0.0
	return float(Time.get_unix_time_from_datetime_string(iso))


## Seconds from NOW (server-adjusted) until an ISO timestamp. Negative if past.
func seconds_until(iso: String) -> float:
	var target := _iso_to_unix(iso)
	if target <= 0.0:
		return 0.0
	return target - (TrustedClock.now() + _race_time_offset)


## A short "Hh Mm" / "Mm Ss" countdown for `secs` (<=0 -> "any moment").
func format_countdown(secs: float) -> String:
	var s := int(max(0.0, secs))
	if s <= 0:
		return "any moment"
	var h := s / 3600
	var m := (s % 3600) / 60
	var sec := s % 60
	if h > 0:
		return "%dh %dm" % [h, m]
	if m > 0:
		return "%dm %ds" % [m, sec]
	return "%ds" % sec


## Recently-RESOLVED races the caller was in (entered a horse OR bet), within
## the 12h replay window — so the Races tab can show results + a Watch button
## even if the player didn't bet. Returns { ok, races:[{id,name,kind,run_at,
## has_replay,mine_entered,mine_bet,winner:{display_name,breed,is_npc,mine}}] }.
func recent_results() -> Dictionary:
	var res := await _rpc("get_recent_results", {"p_device_hash": _device_hash()})
	if not res.get("ok", false):
		return _friendly(res)
	var data = res.get("data", {})
	return {"ok": true, "races": _parse_recent_results(data.get("races", []) if data is Dictionary else [])}


func _parse_recent_results(raw: Variant) -> Array:
	var out: Array = []
	if not raw is Array:
		return out
	for r in raw:
		if not r is Dictionary:
			continue
		var w = r.get("winner", {})
		var winner := {}
		if w is Dictionary:
			winner = {
				"display_name": str(w.get("display_name", "")),
				"breed":        str(w.get("breed", "")),
				"is_npc":       bool(w.get("is_npc", false)),
				"mine":         bool(w.get("mine", false)),
			}
		out.append({
			"id":            str(r.get("id", "")),
			"name":          str(r.get("name", "")),
			"kind":          str(r.get("kind", "regular")),
			"run_at":        str(r.get("run_at", "")),
			"has_replay":    bool(r.get("has_replay", false)),
			"mine_entered":  bool(r.get("mine_entered", false)),
			"mine_bet":      bool(r.get("mine_bet", false)),
			"winner":        winner,
		})
	return out


## Registers an ACTIVE horse into an OPEN race. If the horse wears a horseshoe,
## the owner's current count-derived bonus LEVEL (0..10) is passed so the server
## bakes the race-stat bonus into the entry snapshot. On success the schedule is
## refreshed. Returns the _friendly() result (with lane/race_id merged on ok).
func register(race_id: String, horse_id: String) -> Dictionary:
	var h := horse_by_id(horse_id)
	var shoe := str(h.get("horseshoe", "")) if not h.is_empty() else ""
	var lvl := horseshoe_level(shoe) if shoe != "" else 0
	## Equipped-jewelry horse buffs (apply to all horses while equipped):
	## emerald = across-the-board, pink = life_cap. Levels resolved client-side.
	var em_lvl := 0
	var pk_lvl := 0
	if get_node_or_null("/root/JewelryBonus") != null:
		em_lvl = JewelryBonus.horse_stat_level()
		pk_lvl = JewelryBonus.horse_life_cap_level()
	var res := await _rpc("register_horse", {
		"p_device_hash":     _device_hash(),
		"p_race_id":         race_id,
		"p_horse_id":        horse_id,
		"p_horseshoe_level": lvl,
		"p_emerald_level":   em_lvl,
		"p_pink_level":      pk_lvl,
	})
	if not res.get("ok", false):
		return _friendly(res)
	await refresh_races()
	return _friendly(res)


## ── Present horse grants (Task 11d) ──────────────────────────────
## Horses are entries in the SAME uniform present-drop pool as every tradeable
## item (equal 1-in-N chance each). The present code adds one pool entry per
## breed as a pseudo-key "horse:<breed>" and routes those to grant_horse. ALL
## breeds are droppable — the purchasable three AND the mythical pegasus/centaur/
## unicorn (presents are the non-cup way to get the mythical ones).

## Every breed, as present-pool pseudo-keys "horse:<breed>" (one entry each, so
## uniform odds with the item keys). Order = HORSE_BREEDS catalog order.
func present_horse_pool_keys() -> Array:
	var out: Array = []
	for b in HORSE_BREEDS:
		out.append("horse:%s" % b)
	return out


## Grants a horse of `breed` for free (room-gated, server-side). Used by present
## drops. Returns _friendly() result (with horse merged on ok). On stable_full
## the caller should re-roll so the present isn't wasted.
func grant_horse(breed: String, horse_name: String = "") -> Dictionary:
	var res := await _rpc("grant_horse", {
		"p_device_hash": _device_hash(),
		"p_breed":       breed,
		"p_name":        horse_name,
	})
	if not res.get("ok", false):
		return _friendly(res)
	await refresh()
	return _friendly(res)


## ── Horseshoes ───────────────────────────────────────────────────

## Horseshoe-type definition ("copper"/"iron"), or {} if unknown.
func horseshoe_def(hs_type: String) -> Dictionary:
	return HORSESHOE_TYPES.get(hs_type, {})


## The ITEM_DEFS id for a horseshoe type, or "".
func horseshoe_item_id(hs_type: String) -> String:
	return str(horseshoe_def(hs_type).get("item_id", ""))


## How many of a horseshoe type the player owns (local jewelry inventory).
func horseshoe_count(hs_type: String) -> int:
	var iid := horseshoe_item_id(hs_type)
	if iid == "":
		return 0
	return PlayerData.get_jewelry_count(iid)


## The owned-count bonus LEVEL (0..10) for a horseshoe type, via the shared
## JewelryBonus count→level curve (so horseshoes scale exactly like jewelry).
func horseshoe_level(hs_type: String) -> int:
	var n := horseshoe_count(hs_type)
	if n <= 0:
		return 0
	if get_node_or_null("/root/JewelryBonus") != null:
		return JewelryBonus.level_for_count(n)
	## Fallback curve (mirror of COUNT_THRESHOLDS) if the autoload isn't present.
	var thresholds := [1, 10, 100, 1000, 5000, 20000, 75000, 200000, 500000, 1000000]
	var lvl := 0
	for i in range(thresholds.size()):
		if n >= int(thresholds[i]):
			lvl = i + 1
		else:
			break
	return lvl


## Equips (or clears) a horse's horseshoe. hs_type "" clears it; "copper"/"iron"
## require owning at least one of that shoe. Returns _friendly() result.
func equip_horseshoe(horse_id: String, hs_type: String) -> Dictionary:
	if hs_type != "" and not HORSESHOE_TYPES.has(hs_type):
		return {"ok": false, "error": "bad_horseshoe", "message": "Unknown horseshoe."}
	if hs_type != "" and horseshoe_count(hs_type) <= 0:
		return {"ok": false, "error": "no_horseshoe",
			"message": "You don't own a %s." % str(horseshoe_def(hs_type).get("name", "horseshoe"))}
	var res := await _rpc("equip_horseshoe", {
		"p_device_hash": _device_hash(),
		"p_horse_id":    horse_id,
		"p_type":        hs_type,
	})
	if not res.get("ok", false):
		return _friendly(res)
	await refresh()
	return _friendly(res)


## Convenience views over the cached races.
func open_races() -> Array:
	return races.filter(func(r): return str(r.get("status", "")) == "open")


## Races in the betting window (field locked, odds published, 3h to bet).
func betting_races() -> Array:
	return races.filter(func(r): return str(r.get("status", "")) == "betting")


## ── Cups ─────────────────────────────────────────────────────────

## Cup-tier definition by tier int, or {} for an unknown tier.
func cup_tier_def(tier: int) -> Dictionary:
	return CUP_TIERS.get(tier, {})


## A horse's current stat-total (life + speed + endurance) — the cup gate.
## Uses BASE stats (equipped-jewelry buffs don't change cup tier).
func horse_stat_total(horse_id: String) -> float:
	var h := horse_by_id(horse_id)
	if h.is_empty():
		return 0.0
	return float(h.get("life", 0)) + float(h.get("speed", 0)) + float(h.get("endurance", 0))


## ── Effective stats (base × equipped-jewelry buffs) ──────────────
## Equipped emerald raises speed/endurance/life across the board; equipped pink
## raises life_cap (≤200). These apply to ALL the player's horses while equipped
## (base stats are never mutated). Used for DISPLAY + baked into the race
## snapshot server-side at registration (so races honor the same numbers).

func _emerald_mult() -> float:
	if get_node_or_null("/root/JewelryBonus") != null:
		return JewelryBonus.horse_stat_multiplier()
	return 1.0


func _pink_mult() -> float:
	if get_node_or_null("/root/JewelryBonus") != null:
		return JewelryBonus.horse_life_cap_multiplier()
	return 1.0


## Effective stats dict {speed, endurance, life, life_cap} for a horse row,
## applying the live equipped-jewelry buffs + clamping to hard ceilings. Pass a
## cached horse row (from horses/horse_by_id).
func effective_stats(h: Dictionary) -> Dictionary:
	var em := _emerald_mult()
	var pk := _pink_mult()
	var life_cap: float = minf(float(LIFE_CAP_MAX), float(h.get("life_cap", 0)) * pk)
	var life: float = minf(life_cap, float(h.get("life", 0)) * em)
	return {
		"speed":     minf(float(SPEED_CAP), float(h.get("speed", 0)) * em),
		"endurance": minf(float(ENDURANCE_CAP), float(h.get("endurance", 0)) * em),
		"life":      life,
		"life_cap":  life_cap,
	}


## True if any equipped jewelry is currently buffing horse stats (for UI hints).
func has_jewelry_horse_buff() -> bool:
	return _emerald_mult() > 1.0 or _pink_mult() > 1.0


## The HIGHEST cup tier a stat-total qualifies for, or 0 if below the lowest cup.
## Mirrors the server's _race_cup_tier_for — a horse is locked to this tier.
func cup_tier_for_total(total: float) -> int:
	var best := 0
	for tier in CUP_TIERS:
		if total >= float(CUP_TIERS[tier].get("min_total", 0)):
			best = maxi(best, int(tier))
	return best


## The cup tier a given horse is locked to (0 = ineligible for any cup).
func horse_cup_tier(horse_id: String) -> int:
	return cup_tier_for_total(horse_stat_total(horse_id))


## True if a horse's HIGHEST eligible tier is exactly `tier` (so it may enter it).
func horse_qualifies_for_cup(horse_id: String, tier: int) -> bool:
	return horse_cup_tier(horse_id) == tier


## Coin prize for a finishing place in a tier (1st=first, 2nd=50%, 3rd=25%, else 0).
func cup_prize_for_place(tier: int, place: int) -> int:
	var d := cup_tier_def(tier)
	if d.is_empty():
		return 0
	var first := int(d.get("first_prize", 0))
	match place:
		1: return first
		2: return int(first / 2)
		3: return int(first / 4)
		_: return 0


## Is this active horse already entered in any (open/closed) cached race?
func horse_in_any_race(horse_id: String) -> bool:
	for r in races:
		for e in r.get("entries", []):
			if str(e.get("horse_id", "")) == horse_id:
				return true
	return false


## ── Betting ──────────────────────────────────────────────────────

## Places a WIN bet on `lane` of a betting-window race. `currency` is "coins"
## (local) or "tokens" (server). Coins are debited locally AFTER the server
## records the bet (money-gun trust model); tokens are debited server-side.
## Returns _friendly() result (with lane/odds/stake/currency merged on ok).
##   client-side guards: bad_currency, bad_stake, insufficient_coins
func place_bet(race_id: String, lane: int, currency: String, stake: int) -> Dictionary:
	if currency != "coins" and currency != "tokens":
		return {"ok": false, "error": "bad_currency", "message": "Pick a currency."}
	if stake <= 0:
		return {"ok": false, "error": "bad_stake", "message": "Enter a stake."}
	if currency == "coins" and PlayerData.coins < stake:
		return {"ok": false, "error": "insufficient_coins",
			"message": "Not enough coins for that bet."}

	var res := await _rpc("place_bet", {
		"p_device_hash": _device_hash(),
		"p_race_id":     race_id,
		"p_lane":        lane,
		"p_currency":    currency,
		"p_stake":       stake,
	})
	if not res.get("ok", false):
		return _friendly(res)

	## Server recorded the bet — debit local coins now (tokens handled server-side).
	if currency == "coins":
		PlayerData.coins -= stake
		PlayerData.save_data()
		PlayerData.data_changed.emit()
	await refresh_races()
	return _friendly(res)


## The caller's bets (optionally just for one race). Also credits any newly
## SETTLED, WON, COIN bets locally (exactly once — applied ids are persisted),
## so a coin win lands even if the player wasn't watching when the race ran.
## Returns { ok, bets:[{id,race_id,lane,currency,stake,odds,settled,won,payout,
##           race_status}], credited } | _friendly error.
func my_bets(race_id: String = "") -> Dictionary:
	var body := {"p_device_hash": _device_hash()}
	if race_id != "":
		body["p_race_id"] = race_id
	var res := await _rpc("get_my_bets", body)
	if not res.get("ok", false):
		return _friendly(res)
	var data = res.get("data", {})
	var bets := _parse_bets(data.get("bets", []) if data is Dictionary else [])
	var credited := _apply_coin_payouts(bets)
	return {"ok": true, "bets": bets, "credited": credited}


## ── Guild paddock (shared training) ──────────────────────────────

## Cached paddock horses (for the caller's horse guild). Each entry:
## { horse_id, name, breed, speed, endurance, life, life_cap, owner_id, mine,
##   can_sprint, can_hurdle, can_groom }. Populated by refresh_paddock().
var paddock: Array = []


## Refreshes the caller's horse-guild paddock. Returns { ok } | { ok:false, error }.
## not_horse_guild is normal for non-horse-guild players (paddock stays empty).
func refresh_paddock() -> Dictionary:
	var res := await _rpc("get_guild_paddock", {"p_device_hash": _device_hash()})
	if not res.get("ok", false):
		paddock = []
		paddock_changed.emit()
		return _friendly(res)
	var data = res.get("data", {})
	paddock = _parse_paddock(data.get("horses", []) if data is Dictionary else [])
	paddock_changed.emit()
	return {"ok": true}


func _parse_paddock(raw: Variant) -> Array:
	var out: Array = []
	if not raw is Array:
		return out
	for h in raw:
		if not h is Dictionary:
			continue
		out.append({
			"horse_id":   str(h.get("horse_id", "")),
			"name":       str(h.get("name", "")),
			"breed":      str(h.get("breed", "")),
			"speed":      float(h.get("speed", 0)),
			"endurance":  float(h.get("endurance", 0)),
			"life":       float(h.get("life", 0)),
			"life_cap":   float(h.get("life_cap", 0)),
			"owner_id":   str(h.get("owner_id", "")),
			"mine":       bool(h.get("mine", false)),
			"can_sprint": bool(h.get("can_sprint", true)),
			"can_hurdle": bool(h.get("can_hurdle", true)),
			"can_groom":  bool(h.get("can_groom", true)),
		})
	return out


## Deposits one of the caller's active horses into the guild paddock.
func deposit_to_paddock(horse_id: String) -> Dictionary:
	var res := await _rpc("deposit_to_paddock", {
		"p_device_hash": _device_hash(), "p_horse_id": horse_id,
	})
	if not res.get("ok", false):
		return _friendly(res)
	await refresh_paddock()
	await refresh()  ## stable list may change (horse now in the paddock)
	return _friendly(res)


## Withdraws one of the caller's horses from the paddock.
func withdraw_from_paddock(horse_id: String) -> Dictionary:
	var res := await _rpc("withdraw_from_paddock", {
		"p_device_hash": _device_hash(), "p_horse_id": horse_id,
	})
	if not res.get("ok", false):
		return _friendly(res)
	await refresh_paddock()
	return _friendly(res)


## Trains a paddocked horse (gain lands on the owner). Mirrors train() but routes
## through train_paddock_horse. Per-trainer daily cooldown is server-enforced.
func train_paddock(horse_id: String, kind: String, score: int) -> Dictionary:
	var d := training_def(kind)
	if d.is_empty():
		return {"ok": false, "error": "invalid_kind", "message": "Unknown training."}
	## Keep our own shoe/prestige levels current (used when WE own the horse;
	## a guildmate's horse uses the levels its owner last reported).
	await PlayerData.sync_horse_prestige(false)
	var res := await _rpc("train_paddock_horse", {
		"p_device_hash": _device_hash(),
		"p_horse_id":    horse_id,
		"p_kind":        kind,
		"p_score":       maxi(score, 0),
	})
	## The paddock now shares the horse's 3/day counter (migration 101), so a
	## paddock session also uses up one of the owner's Stable sessions.
	_apply_remaining_from(res, horse_id, kind)
	if not res.get("ok", false):
		return _friendly(res)
	await refresh()            ## the owner's horse (possibly ours) changed
	await refresh_paddock()
	await refresh_training()
	return _friendly(res)


## ── Private: bets ────────────────────────────────────────────────

var _applied_bet_ids: Dictionary = {}          ## bet_id -> true (coin payouts applied)
const _BETS_SAVE_PATH := "user://horse_bets.cfg"


func _parse_bets(raw: Variant) -> Array:
	var out: Array = []
	if not raw is Array:
		return out
	for b in raw:
		if not b is Dictionary:
			continue
		out.append({
			"id":          str(b.get("id", "")),
			"race_id":     str(b.get("race_id", "")),
			"lane":        int(b.get("lane", 0)),
			"currency":    str(b.get("currency", "coins")),
			"stake":       int(b.get("stake", 0)),
			"odds":        float(b.get("odds", 0)),
			"settled":     bool(b.get("settled", false)),
			"won":         bool(b.get("won", false)),
			"payout":      int(b.get("payout", 0)),
			"race_status": str(b.get("race_status", "")),
			"race_name":   str(b.get("race_name", "")) if b.get("race_name") != null else "",
			"placed_at":   float(b.get("placed_at", 0.0)) if b.get("placed_at") != null else 0.0,
			"resolved_at": float(b.get("resolved_at", 0.0)) if b.get("resolved_at") != null else 0.0,
		})
	return out


## Credits settled+won COIN bets not yet applied (tokens are credited server-
## side). Returns total coins credited this call. Idempotent via a persisted
## applied-id set, so each coin win pays out exactly once.
func _apply_coin_payouts(bets: Array) -> int:
	if _applied_bet_ids.is_empty():
		_load_applied_bets()
	var credited := 0
	var dirty := false
	for b in bets:
		var bid := str(b.get("id", ""))
		if bid == "" or _applied_bet_ids.has(bid):
			continue
		if bool(b.get("settled", false)) and bool(b.get("won", false)) \
				and str(b.get("currency", "")) == "coins" and int(b.get("payout", 0)) > 0:
			PlayerData.coins += int(b["payout"])
			credited += int(b["payout"])
			_applied_bet_ids[bid] = true
			dirty = true
	if dirty:
		_save_applied_bets()
		PlayerData.save_data()
		PlayerData.data_changed.emit()
	return credited


func _load_applied_bets() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_BETS_SAVE_PATH) == OK:
		for k in cfg.get_section_keys("applied"):
			_applied_bet_ids[k] = true
		if cfg.has_section("cup_prizes"):
			for k in cfg.get_section_keys("cup_prizes"):
				_applied_prize_ids[k] = true


func _save_applied_bets() -> void:
	var cfg := ConfigFile.new()
	for k in _applied_bet_ids.keys():
		cfg.set_value("applied", str(k), true)
	for k in _applied_prize_ids.keys():
		cfg.set_value("cup_prizes", str(k), true)
	cfg.save(_BETS_SAVE_PATH)


## ── Cup prizes ───────────────────────────────────────────────────

var _applied_prize_ids: Dictionary = {}        ## entry_id -> true (cup coin prize applied)


## Fetches the caller's unclaimed cup COIN prizes and credits them locally,
## exactly once each (persisted by entry id). The server records the prize on the
## winning entry (prize_coins); the breed foal is granted server-side if the
## stable had room. Returns { ok, credited, prizes:[{entry_id,race_name,tier,
## finish_place,prize_coins}] } | _friendly error.
func claim_cup_prizes() -> Dictionary:
	var res := await _rpc("get_my_cup_prizes", {"p_device_hash": _device_hash()})
	if not res.get("ok", false):
		return _friendly(res)
	var data = res.get("data", {})
	var raw = data.get("prizes", []) if data is Dictionary else []
	var prizes: Array = []
	if raw is Array:
		for p in raw:
			if not p is Dictionary:
				continue
			prizes.append({
				"entry_id":     str(p.get("entry_id", "")),
				"race_name":    str(p.get("race_name", "")),
				"tier":         int(p.get("tier", 0)),
				"finish_place": int(p.get("finish_place", 0)),
				"prize_coins":  int(p.get("prize_coins", 0)),
			})
	var credited := _apply_cup_prizes(prizes)
	return {"ok": true, "credited": credited, "prizes": prizes}


## Credits unclaimed cup coin prizes locally, once each (persisted applied-id
## set shared with the bets cfg). Returns total coins credited this call.
func _apply_cup_prizes(prizes: Array) -> int:
	if _applied_bet_ids.is_empty() and _applied_prize_ids.is_empty():
		_load_applied_bets()
	var credited := 0
	var dirty := false
	for p in prizes:
		var pid := str(p.get("entry_id", ""))
		var amt := int(p.get("prize_coins", 0))
		if pid == "" or amt <= 0 or _applied_prize_ids.has(pid):
			continue
		## Sweet Banana Crisp recipe boost ("Jockey's Luck"): +value prize money
		## for the next few races (count-limited). Consume one use per prize paid.
		if get_node_or_null("/root/PlayerData") != null and PlayerData.boost_active("jockeys_luck"):
			amt = int(round(amt * (1.0 + PlayerData.boost_value("jockeys_luck"))))
			PlayerData.consume_boost_use("jockeys_luck")
		PlayerData.coins += amt
		credited += amt
		_applied_prize_ids[pid] = true
		dirty = true
	if dirty:
		_save_applied_bets()
		PlayerData.save_data()
		PlayerData.data_changed.emit()
	return credited


## Fetches a resolved race's result for playback (Task 8). Returns:
##   { ok, status, run_at, has_replay, replay:{segments, lanes[], order[]}|{},
##     placements:[{lane, finish_place, display_name, breed, is_npc, horse_id,
##                  mine}] }
## or _friendly() error. `replay` is {} once the 12h window has elapsed server-
## side (has_replay=false) — the UI should fall back to showing placements only.
func race_result(race_id: String) -> Dictionary:
	var res := await _rpc("get_race_result", {
		"p_device_hash": _device_hash(),
		"p_race_id":     race_id,
	})
	if not res.get("ok", false):
		return _friendly(res)
	var data = res.get("data", {})
	var out := {
		"ok": true,
		"status": str(data.get("status", "")) if data is Dictionary else "",
		"run_at": str(data.get("run_at", "")) if data is Dictionary else "",
		"has_replay": bool(data.get("has_replay", false)) if data is Dictionary else false,
		"replay": _parse_replay(data.get("replay", null)) if data is Dictionary else {},
		"placements": _parse_placements(data.get("placements", [])) if data is Dictionary else [],
	}
	return out


## Parses the stored replay json ({segments, lanes[], order[]}) defensively.
func _parse_replay(raw: Variant) -> Dictionary:
	if not raw is Dictionary:
		return {}
	var lanes: Array = []
	var rl = raw.get("lanes", [])
	if rl is Array:
		for l in rl:
			if not l is Dictionary:
				continue
			var samples: Array = []
			var rs = l.get("samples", [])
			if rs is Array:
				for v in rs:
					samples.append(float(v))
			lanes.append({
				"lane":         int(l.get("lane", 0)),
				"display_name": str(l.get("display_name", "")),
				"breed":        str(l.get("breed", "")),
				"is_npc":       bool(l.get("is_npc", false)),
				"horse_id":     str(l.get("horse_id", "")) if l.get("horse_id", null) != null else "",
				"total":        float(l.get("total", 0)),
				"samples":      samples,
			})
	var order: Array = []
	var ro = raw.get("order", [])
	if ro is Array:
		for o in ro:
			order.append(int(o))
	return {"segments": int(raw.get("segments", 0)), "lanes": lanes, "order": order}


## Parses the placements array defensively.
func _parse_placements(raw: Variant) -> Array:
	var out: Array = []
	if not raw is Array:
		return out
	for p in raw:
		if not p is Dictionary:
			continue
		out.append({
			"lane":         int(p.get("lane", 0)),
			"finish_place": int(p.get("finish_place", 0)),
			"display_name": str(p.get("display_name", "")),
			"breed":        str(p.get("breed", "")),
			"is_npc":       bool(p.get("is_npc", false)),
			"horse_id":     str(p.get("horse_id", "")) if p.get("horse_id", null) != null else "",
			"mine":         bool(p.get("mine", false)),
		})
	return out


## ── Private ──────────────────────────────────────────────────────

## Parses a get_races payload into the `races` cache shape (defensive).
func _parse_races(data: Variant) -> Array:
	var out: Array = []
	if not data is Dictionary:
		return out
	var raw = data.get("races", [])
	if not raw is Array:
		return out
	for r in raw:
		if not r is Dictionary:
			continue
		var entries: Array = []
		var raw_entries = r.get("entries", [])
		if raw_entries is Array:
			for e in raw_entries:
				if not e is Dictionary:
					continue
				entries.append({
					"lane":          int(e.get("lane", 0)),
					"is_npc":        bool(e.get("is_npc", false)),
					"display_name":  str(e.get("display_name", "")),
					"breed":         str(e.get("breed", "")),
					"speed":         float(e.get("speed", 0)),
					"endurance":     float(e.get("endurance", 0)),
					"life":          float(e.get("life", 0)),
					"odds":          float(e.get("odds", 0)) if e.get("odds", null) != null else 0.0,
					"horse_id":      str(e.get("horse_id", "")) if e.get("horse_id", null) != null else "",
					"pairing_bonus": bool(e.get("pairing_bonus", false)),
					"mine":          bool(e.get("mine", false)),
				})
		out.append({
			"id":            str(r.get("id", "")),
			"name":          str(r.get("name", "")),
			"kind":          str(r.get("kind", "regular")),
			"status":        str(r.get("status", "open")),
			## Cup fields (migration 077): null/0 for regular races.
			"tier":          int(r.get("tier", 0)) if r.get("tier", null) != null else 0,
			"prize_breed":   str(r.get("prize_breed", "")) if r.get("prize_breed", null) != null else "",
			"min_total":     int(r.get("min_total", 0)) if r.get("min_total", null) != null else 0,
			"max_total":     int(r.get("max_total", 0)) if r.get("max_total", null) != null else 0,
			"first_prize":   int(r.get("first_prize", 0)) if r.get("first_prize", null) != null else 0,
			"field_size":    int(r.get("field_size", RACE_FIELD_SIZE)),
			"opens_at":      str(r.get("opens_at", "")),
			"closes_at":     str(r.get("closes_at", "")),
			"bet_closes_at": str(r.get("bet_closes_at", "")) if r.get("bet_closes_at", null) != null else "",
			"mine_in_race":  bool(r.get("mine_in_race", false)),
			"entries":       entries,
		})
	return out

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
		"invalid_breed":       msg = "Unknown breed."
		"not_purchasable":     msg = "That breed can't be bought."
		"stable_full":         msg = "Your stable is full."
		"invalid_name":        msg = "That name isn't allowed."
		"horse_not_found":     msg = "That horse is gone."
		"not_your_horse":      msg = "That isn't your horse."
		"horse_retired":       msg = "Retired horses can't train."
		"invalid_kind":        msg = "Unknown training."
		"already_trained":     msg = "Already trained that today."
		"at_ceiling":          msg = "That stat is already maxed."
		"already_full":        msg = "That horse is already full."
		"no_feed":             msg = "You have no feed."
		"race_not_found":      msg = "That race is gone."
		"race_closed":         msg = "Registration has closed for that race."
		"race_full":           msg = "That race is full."
		"already_entered":     msg = "That horse is already in this race."
		"horse_in_race":       msg = "That horse is already entered in a race."
		"cup_tier_mismatch":   msg = "That horse belongs in a different cup tier."
		"not_horse_guild":     msg = "Join a horse-racing guild to use the paddock."
		"not_paddocked":       msg = "That horse isn't in the paddock."
		"already_paddocked":   msg = "That horse is already in the paddock."
		"not_same_guild":      msg = "That horse is in another guild's paddock."
		"bad_horseshoe":       msg = "Unknown horseshoe type."
		"no_horseshoe":        msg = "You don't own that horseshoe."
		"bad_price":           msg = "Enter a valid price."
		"already_listed":      msg = "That horse is already listed."
		"horse_in_paddock":    msg = "That horse is in a guild paddock right now, so it can't be listed or bought."
		"horse_listed":        msg = "That horse is listed for sale — unlist it first."
		"listing_not_found":   msg = "That listing is gone."
		"listing_not_active":  msg = "That listing is no longer available."
		"not_your_listing":    msg = "That isn't your listing."
		"cannot_buy_own":      msg = "You can't buy your own horse."
		"horse_gone":          msg = "That horse is no longer available."
		"not_resolved":        msg = "That race hasn't finished yet."
		"not_betting":         msg = "Betting is closed for that race."
		"bad_lane":            msg = "Pick a horse to bet on."
		"bad_stake":           msg = "Enter a valid stake."
		"bad_currency":        msg = "Pick a currency."
		"own_race":            msg = "You can't bet on a race your horse is in."
		"insufficient_tokens": msg = "Not enough tokens."
		"insufficient_coins":  msg = "Not enough coins."
		"offline":             msg = "No connection."
		_:                     msg = "Error: %s" % code
	return {"ok": false, "error": code, "message": msg}
