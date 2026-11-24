extends SceneTree

## Unit tests for the HorseRacing autoload: catalog helpers, pricing, name
## generator, payload parsing, and client-side buy guards (no network). Runs the
## full project so the autoload is available; hits NO server.
##
##   godot --headless --script tests/test_horse_racing_data.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" HorseRacing Data Layer Unit Tests")
	print("========================================\n")

	var hr = root.get_node_or_null("HorseRacing")
	if hr == null:
		printerr("[FAIL] Autoload HorseRacing not found!")
		quit(1)
		return true

	_test_catalog(hr)
	_test_pricing(hr)
	_test_suggestions_deduped(hr)
	_test_npc_names(hr)
	_test_payload_parse(hr)
	_test_views(hr)
	_test_buy_guards(hr)
	_test_sprites(hr)
	_test_training(hr)
	_test_minigame()
	_test_feed(hr)
	_test_races(hr)
	_test_race_result(hr)
	_test_bets(hr)
	_test_cups(hr)
	_test_paddock(hr)
	_test_horseshoes(hr)
	_test_jewelry_horse(hr)

	print("\n----------------------------------------")
	print(" Results: %d passed, %d failed, %d total" % [_passed, _failed, _run])
	print("----------------------------------------\n")
	quit(1 if _failed > 0 else 0)
	return true


func _ok(cond: bool, desc: String) -> void:
	_run += 1
	if cond:
		_passed += 1
		print("  ✓ %s" % desc)
	else:
		_failed += 1
		print("  ✗ FAIL: %s" % desc)


func _eq(actual, expected, desc: String) -> void:
	_ok(actual == expected, "%s  (got %s, expected %s)" % [desc, str(actual), str(expected)])


func _test_catalog(hr) -> void:
	print("Breed catalog:")
	_eq(hr.HORSE_BREEDS.size(), 6, "six breeds")
	_eq(hr.breed_def("arabian").get("endurance"), 10, "arabian endurance 10")
	_eq(hr.breed_stat_total("arabian"), 118, "arabian stat total 118")
	_eq(hr.purchasable_breeds().size(), 3, "three purchasable breeds")
	_ok(not hr.breed_def("unicorn").get("purchasable", false), "unicorn not purchasable")


func _test_pricing(hr) -> void:
	print("Pricing:")
	_eq(hr.buy_price("arabian"), 11800000, "arabian buy price 11.8M")
	## Buyback (migration 071) = half the buy price = stat_total * 50000.
	## Arabian base stat_total 118 -> 118 * 50000 = 5,900,000.
	_eq(hr.sell_price_for(100, 8, 10), 5900000, "arabian sell price (half buy)")


func _test_suggestions_deduped(hr) -> void:
	print("Name suggestions deduped:")
	var sugg = hr.name_suggestions()
	_ok(sugg.size() > 200, "has 200+ suggestions (got %d)" % sugg.size())
	var seen := {}
	var dupes := 0
	for n in sugg:
		if seen.has(n):
			dupes += 1
		seen[n] = true
	_eq(dupes, 0, "no duplicate suggestions")
	_ok(sugg.has("Secretariat"), "includes Secretariat")


func _test_npc_names(hr) -> void:
	print("NPC name generator:")
	_eq(hr.NPC_FIRST_NAMES_MALE.size(), 50, "50 male first names")
	_eq(hr.NPC_FIRST_NAMES_FEMALE.size(), 50, "50 female first names")
	_eq(hr.NPC_LAST_NAMES.size(), 50, "50 last names")
	var nm: String = hr.random_npc_name()
	_ok(nm.length() > 0 and nm.find(" ") > 0, "random npc name is 'First Last' (got %s)" % nm)


func _test_payload_parse(hr) -> void:
	print("apply_payload parses get_horses response:")
	var ok = hr.apply_payload({
		"capacity": 7,
		"horses": [
			{"id": "h1", "name": "Secretariat", "breed": "arabian", "life": 100, "life_cap": 100,
			 "speed": 8, "endurance": 10, "status": "active", "wins": 2, "races_run": 5},
			{"id": "h2", "name": "Old Timer", "breed": "thoroughbred", "life": 0, "life_cap": 80,
			 "speed": 10, "endurance": 6, "status": "retired", "wins": 1, "races_run": 9},
			"garbage",
		],
	})
	_ok(ok, "apply_payload returns true")
	_eq(hr.stable_capacity, 7, "capacity parsed")
	_eq(hr.horses.size(), 2, "two horses (garbage skipped)")
	_eq(hr.horses[0]["name"], "Secretariat", "name parsed")
	_eq(hr.apply_payload("nope"), false, "bad payload -> false")


func _test_views(hr) -> void:
	print("Active/retired views:")
	hr.apply_payload({
		"capacity": 5,
		"horses": [
			{"id": "a", "status": "active", "breed": "arabian", "life": 100, "life_cap": 100, "speed": 8, "endurance": 10},
			{"id": "b", "status": "active", "breed": "arabian", "life": 50, "life_cap": 100, "speed": 8, "endurance": 10},
			{"id": "c", "status": "retired", "breed": "arabian", "life": 0, "life_cap": 100, "speed": 8, "endurance": 10},
		],
	})
	_eq(hr.active_count(), 2, "two active")
	_eq(hr.retired_horses().size(), 1, "one retired")
	_eq(hr.has_stable_room(), true, "room for more (2 < 5)")


func _test_buy_guards(hr) -> void:
	print("buy client-side guards (no network):")
	## Mythical breed rejected before any network.
	var r = await hr.buy("unicorn", "Sparkle")
	_eq(r.get("error"), "not_purchasable", "unicorn -> not_purchasable")
	## Fill the cache to capacity so stable_full triggers client-side.
	hr.apply_payload({
		"capacity": 2,
		"horses": [
			{"id": "a", "status": "active", "breed": "arabian", "life": 1, "life_cap": 1, "speed": 1, "endurance": 1},
			{"id": "b", "status": "active", "breed": "arabian", "life": 1, "life_cap": 1, "speed": 1, "endurance": 1},
		],
	})
	r = await hr.buy("thoroughbred", "Filler")
	_eq(r.get("error"), "stable_full", "full stable -> stable_full")


func _test_sprites(hr) -> void:
	print("Breed spritesheet slicing:")
	## The sheet exists and each breed yields an AtlasTexture at the right region.
	for i in range(hr._SHEET_BREED_ORDER.size()):
		var breed: String = hr._SHEET_BREED_ORDER[i]
		var tex = hr.breed_texture(breed)
		_ok(tex is AtlasTexture, "%s -> AtlasTexture" % breed)
		if tex is AtlasTexture:
			var r: Rect2 = tex.region
			_eq(int(r.position.x), i * 210 + 70, "%s region x" % breed)
			_eq(int(r.size.x), 70, "%s region 70px wide" % breed)
	## Unknown breed -> null (no crash).
	_ok(hr.breed_texture("dragon") == null, "unknown breed -> null")

	## Run frames: 3 columns per breed (x = base + col*70), cycles modulo 3.
	for i in range(hr._SHEET_BREED_ORDER.size()):
		var rbreed: String = hr._SHEET_BREED_ORDER[i]
		for col in range(3):
			var rt = hr.breed_run_frame(rbreed, col)
			_ok(rt is AtlasTexture, "%s run frame %d -> AtlasTexture" % [rbreed, col])
			if rt is AtlasTexture:
				_eq(int(rt.region.position.x), i * 210 + col * 70,
					"%s run frame %d region x" % [rbreed, col])
	## frame wraps modulo 3 (frame 3 == frame 0).
	var f0 = hr.breed_run_frame("arabian", 0)
	var f3 = hr.breed_run_frame("arabian", 3)
	if f0 is AtlasTexture and f3 is AtlasTexture:
		_eq(int(f3.region.position.x), int(f0.region.position.x), "run frame wraps mod 3")
	_ok(hr.breed_run_frame("dragon", 0) == null, "unknown breed run frame -> null")


func _test_training(hr) -> void:
	print("Training catalog + availability (no network):")
	## Catalog shape matches the server kinds.
	_eq(hr.TRAINING_KINDS.size(), 3, "three training kinds")
	_eq(hr.TRAINING_ORDER, ["sprint", "hurdle", "groom"], "kind order")
	_eq(hr.training_def("sprint").get("stat"), "speed", "sprint -> speed")
	_eq(hr.training_def("hurdle").get("stat"), "endurance", "hurdle -> endurance")
	_eq(hr.training_def("groom").get("stat"), "life_cap", "groom -> life_cap")
	_eq(hr.training_def("sprint").get("ceiling"), 100, "sprint ceiling 100")
	_eq(hr.training_def("groom").get("ceiling"), 200, "groom ceiling 200")
	_ok(hr.training_def("yoga").is_empty(), "unknown kind -> {}")

	## Seed a horse at a known state + a training-status cache.
	hr.apply_payload({
		"capacity": 5,
		"horses": [
			{"id": "t1", "status": "active", "breed": "thoroughbred",
			 "life": 80, "life_cap": 80, "speed": 100, "endurance": 6},
		],
	})
	## horse_by_id finds it.
	_eq(hr.horse_by_id("t1").get("name", "?"), "", "horse_by_id returns the row")
	_ok(hr.horse_by_id("nope").is_empty(), "horse_by_id unknown -> {}")

	## speed is at ceiling (100) -> sprint not trainable regardless of cooldown.
	hr.training_status = {"t1": {"sprint": true, "hurdle": true, "groom": true}}
	_eq(hr.can_train("t1", "sprint"), false, "at-ceiling speed -> can't sprint")
	_eq(hr.can_train("t1", "hurdle"), true, "endurance below cap -> can hurdle")

	## Cooldown only applies to CAPPED kinds (groom); sprint/hurdle are uncapped
	## for testing, so a "false" cache entry does NOT block them.
	hr.training_status = {"t1": {"sprint": false, "hurdle": false, "groom": false}}
	_eq(hr.can_train("t1", "hurdle"), true, "hurdle uncapped -> trainable despite cache")
	_eq(hr.can_train("t1", "groom"), false, "groom cooldown -> can't groom")

	## Unknown horse with no status -> assume available (below cap).
	hr.apply_payload({"capacity": 5, "horses": []})
	hr.training_status = {}
	_eq(hr.can_train("ghost", "sprint"), true, "no cache -> assume available")

	## Invalid kind rejected locally by train() before any network.
	var r = await hr.train("ghost", "yoga", 100)
	_eq(r.get("error"), "invalid_kind", "train invalid kind -> invalid_kind")


func _test_minigame() -> void:
	print("TrainingMinigame instantiation:")
	## Load by path (avoids depending on the global class_name cache in tests).
	var script = load("res://scripts/horse_racing/training_minigame.gd")
	_ok(script != null, "mini-game script loads")
	if script == null:
		return
	var game = script.new()
	_ok(game != null, "mini-game instantiates")
	_ok(game.has_signal("finished"), "has finished(score) signal")
	_ok(game.has_method("setup"), "has setup()")
	_ok(game.has_method("set_breed"), "groom has set_breed()")
	game.setup("Groom", "Brush!", Color(0.85, 0.6, 1.0))
	game.free()

	## The hurdle runner mini-game (dino-jump style) + its run-frame helper.
	print("HurdleMinigame + run frames:")
	var hscript = load("res://scripts/horse_racing/hurdle_minigame.gd")
	_ok(hscript != null, "hurdle mini-game script loads")
	if hscript != null:
		var hg = hscript.new()
		_ok(hg != null, "hurdle mini-game instantiates")
		_ok(hg.has_signal("finished"), "hurdle has finished(score) signal")
		_ok(hg.has_method("setup"), "hurdle has setup(breed, blurb)")
		hg.setup("thoroughbred", "Jump!")
		hg.free()

	## The sprint traffic-light mini-game.
	print("SprintMinigame:")
	var sscript = load("res://scripts/horse_racing/sprint_minigame.gd")
	_ok(sscript != null, "sprint mini-game script loads")
	if sscript != null:
		var sg = sscript.new()
		_ok(sg != null, "sprint mini-game instantiates")
		_ok(sg.has_signal("finished"), "sprint has finished(score) signal")
		_ok(sg.has_method("setup"), "sprint has setup(breed, blurb)")
		sg.setup("arabian", "Go!")
		sg.free()


func _test_feed(hr) -> void:
	print("Horse feed (local consumable, no network):")
	## Access PlayerData via the root node (the global identifier isn't bound in
	## a bare --script SceneTree run — same reason we fetch `hr` from root).
	var pd = root.get_node_or_null("PlayerData")
	if pd == null:
		_ok(false, "autoload PlayerData not found")
		return

	## Feed catalog constants.
	_eq(hr.FEED_ITEM_ID, "horse_feed", "feed item id")
	_ok(hr.FEED_PRICE > 0, "feed has a positive price")
	_ok(hr.FEED_RESTORE > 0, "feed restores a positive amount")

	## Start from a clean feed count.
	var start: int = hr.feed_count()
	pd.consume_fruit(hr.FEED_ITEM_ID, start)  ## zero it out
	_eq(hr.feed_count(), 0, "feed count starts at 0")

	## buy_feed with no coins -> insufficient_coins (and no feed added).
	var saved_coins: int = pd.coins
	pd.coins = 0
	var r = hr.buy_feed(1)
	_eq(r.get("error"), "insufficient_coins", "buy_feed broke -> insufficient_coins")
	_eq(hr.feed_count(), 0, "no feed added when broke")

	## buy_feed with coins -> deducts and adds.
	pd.coins = hr.FEED_PRICE * 3
	r = hr.buy_feed(2)
	_ok(r.get("ok", false), "buy_feed ok")
	_eq(hr.feed_count(), 2, "two feeds owned")
	_eq(pd.coins, hr.FEED_PRICE, "coins deducted for 2 feeds")

	## buy_feed bad qty.
	r = hr.buy_feed(0)
	_eq(r.get("error"), "bad_qty", "buy_feed 0 -> bad_qty")

	## feed() local guards: full horse -> already_full (no network).
	hr.apply_payload({"capacity": 5, "horses": [
		{"id": "f1", "status": "active", "breed": "arabian",
		 "life": 100, "life_cap": 100, "speed": 8, "endurance": 10},
	]})
	r = await hr.feed("f1")
	_eq(r.get("error"), "already_full", "feed full horse -> already_full")
	_eq(hr.feed_count(), 2, "feed not consumed on full")

	## feed() with no feed owned -> no_feed (even if horse needs it).
	hr.apply_payload({"capacity": 5, "horses": [
		{"id": "f2", "status": "active", "breed": "arabian",
		 "life": 10, "life_cap": 100, "speed": 8, "endurance": 10},
	]})
	pd.consume_fruit(hr.FEED_ITEM_ID, hr.feed_count())  ## zero feeds
	r = await hr.feed("f2")
	_eq(r.get("error"), "no_feed", "feed with none owned -> no_feed")

	## Restore coins for a tidy environment.
	pd.coins = saved_coins


func _test_races(hr) -> void:
	print("Race schedule parsing + views (no network):")
	## RACE_FIELD_SIZE constant mirrors the server.
	_eq(hr.RACE_FIELD_SIZE, 8, "race field size 8")

	## Parse a get_races payload: one open race (1 real + 1 npc), one closed.
	var payload := {
		"now": "2026-01-01T00:00:00Z",
		"races": [
			{
				"id": "r1", "name": "Daily Dash", "kind": "regular", "status": "open",
				"field_size": 8, "opens_at": "a", "closes_at": "b",
				"entries": [
					{"lane": 0, "is_npc": false, "display_name": "Alpha", "breed": "arabian",
					 "speed": 12.5, "endurance": 10.0, "life": 80.0, "horse_id": "h1", "mine": true},
					{"lane": 1, "is_npc": true, "display_name": "Dusty Runner", "breed": "thoroughbred",
					 "speed": 20.0, "endurance": 18.0, "life": 60.0, "horse_id": null, "mine": false},
				],
			},
			{
				"id": "r2", "name": "Second", "kind": "regular", "status": "betting",
				"field_size": 8, "opens_at": "a", "closes_at": "b", "bet_closes_at": "c",
				"entries": [
					{"lane": 0, "is_npc": false, "display_name": "Zeta", "breed": "arabian",
					 "speed": 30.0, "endurance": 25.0, "life": 90.0, "odds": 2.50,
					 "horse_id": "h9", "mine": false},
				],
			},
			"garbage",
		],
	}
	hr.races = hr._parse_races(payload)
	_eq(hr.races.size(), 2, "two races parsed (garbage skipped)")
	_eq(hr.races[0]["id"], "r1", "first race id")
	_eq(hr.races[0]["entries"].size(), 2, "first race has 2 entries")
	_eq(hr.races[0]["entries"][0]["mine"], true, "entry 0 is mine")
	_eq(hr.races[0]["entries"][0]["speed"], 12.5, "entry stats parsed as float")
	_eq(hr.races[0]["entries"][1]["horse_id"], "", "npc entry horse_id -> empty string")
	_eq(hr.races[0]["entries"][1]["is_npc"], true, "npc flagged")

	## Views.
	_eq(hr.open_races().size(), 1, "one open race")
	_eq(hr.betting_races().size(), 1, "one betting race")
	## Betting race parsed odds + bet_closes_at + mine_in_race.
	_eq(hr.races[1]["status"], "betting", "r2 is betting")
	_eq(hr.races[1]["entries"][0]["odds"], 2.5, "betting entry odds parsed")
	_eq(hr.races[1]["bet_closes_at"], "c", "bet_closes_at parsed")

	## horse_in_any_race.
	_eq(hr.horse_in_any_race("h1"), true, "h1 is in a race")
	_eq(hr.horse_in_any_race("nope"), false, "unknown horse not in a race")

	## Bad payload -> empty.
	_eq(hr._parse_races("nope").size(), 0, "bad races payload -> empty")


func _test_race_result(hr) -> void:
	print("Race result (replay + placements) parsing (no network):")
	## Replay parse: 2 lanes, 3 segments, an order.
	var replay := {
		"segments": 3,
		"lanes": [
			{"lane": 0, "display_name": "Hero", "breed": "arabian", "is_npc": false,
			 "horse_id": "h1", "total": 42.5, "samples": [10.0, 25.5, 42.5]},
			{"lane": 1, "display_name": "Dusty Runner", "breed": "thoroughbred", "is_npc": true,
			 "horse_id": null, "total": 40.0, "samples": [12.0, 28.0, 40.0]},
		],
		"order": [0, 1],
	}
	var p = hr._parse_replay(replay)
	_eq(int(p.get("segments", 0)), 3, "replay segments parsed")
	_eq(p.get("lanes", []).size(), 2, "replay 2 lanes")
	_eq(p["lanes"][0]["samples"].size(), 3, "lane 0 has 3 samples")
	_eq(p["lanes"][0]["samples"][2], 42.5, "lane 0 final sample float")
	_eq(p["lanes"][1]["horse_id"], "", "npc lane horse_id -> empty")
	_eq(p.get("order", []), [0, 1], "order parsed")
	_eq(hr._parse_replay(null).size(), 0, "null replay -> {}")

	## Placements parse.
	var places = hr._parse_placements([
		{"lane": 0, "finish_place": 1, "display_name": "Hero", "breed": "arabian",
		 "is_npc": false, "horse_id": "h1", "mine": true},
		{"lane": 1, "finish_place": 2, "display_name": "Dusty Runner", "breed": "thoroughbred",
		 "is_npc": true, "horse_id": null, "mine": false},
		"garbage",
	])
	_eq(places.size(), 2, "two placements (garbage skipped)")
	_eq(places[0]["finish_place"], 1, "first placement is 1st")
	_eq(places[0]["mine"], true, "first placement is mine")
	_eq(places[1]["horse_id"], "", "npc placement horse_id -> empty")


func _test_bets(hr) -> void:
	print("Bets parsing + coin payout crediting (no network):")
	var pd = root.get_node_or_null("PlayerData")
	if pd == null:
		_ok(false, "autoload PlayerData not found")
		return

	## _parse_bets shape.
	var bets = hr._parse_bets([
		{"id": "b1", "race_id": "r1", "lane": 2, "currency": "coins", "stake": 1000,
		 "odds": 2.5, "settled": true, "won": true, "payout": 2500, "race_status": "resolved"},
		{"id": "b2", "race_id": "r1", "lane": 3, "currency": "coins", "stake": 500,
		 "odds": 4.0, "settled": true, "won": false, "payout": 0, "race_status": "resolved"},
		{"id": "b3", "race_id": "r2", "lane": 1, "currency": "tokens", "stake": 100,
		 "odds": 3.0, "settled": true, "won": true, "payout": 300, "race_status": "resolved"},
		"garbage",
	])
	_eq(bets.size(), 3, "three bets parsed (garbage skipped)")
	_eq(bets[0]["payout"], 2500, "bet payout parsed")
	_eq(bets[0]["odds"], 2.5, "bet odds parsed")

	## Coin payout crediting: only the settled+won+coins bet credits; applied once.
	## Clear any persisted applied-id file so the test starts clean.
	DirAccess.remove_absolute("user://horse_bets.cfg")
	hr._applied_bet_ids = {}   ## reset in-memory (test isolation)
	var start: int = pd.coins
	var credited: int = hr._apply_coin_payouts(bets)
	_eq(credited, 2500, "credits only the won coin bet (b1)")
	_eq(pd.coins, start + 2500, "coins increased by payout")
	## Re-applying does nothing (idempotent via applied-id set).
	var credited2: int = hr._apply_coin_payouts(bets)
	_eq(credited2, 0, "re-apply credits nothing (idempotent)")
	_eq(pd.coins, start + 2500, "coins unchanged on re-apply")

	## place_bet client guards (no network).
	var r = await hr.place_bet("r1", 0, "gold", 100)
	_eq(r.get("error"), "bad_currency", "place_bet bad currency")
	r = await hr.place_bet("r1", 0, "coins", 0)
	_eq(r.get("error"), "bad_stake", "place_bet bad stake")
	pd.coins = 50
	r = await hr.place_bet("r1", 0, "coins", 100)
	_eq(r.get("error"), "insufficient_coins", "place_bet broke -> insufficient_coins")
	pd.coins = start   ## restore


func _test_cups(hr) -> void:
	print("Cups: tiers, locking, prizes, prize crediting (no network):")
	var pd = root.get_node_or_null("PlayerData")
	if pd == null:
		_ok(false, "autoload PlayerData not found")
		return

	## Tier catalog shape + values.
	_eq(hr.CUP_TIERS.size(), 3, "three cup tiers")
	_eq(hr.CUP_FIELD_SIZE, 5, "cup field size 5")
	_eq(int(hr.CUP_TIERS[1]["first_prize"]), 1000000, "little cup first prize 1M")
	_eq(int(hr.CUP_TIERS[3]["first_prize"]), 100000000, "derby cup first prize 100M")
	_eq(str(hr.CUP_TIERS[1]["prize_breed"]), "unicorn", "little cup breed unicorn")
	_eq(str(hr.CUP_TIERS[3]["prize_breed"]), "pegasus", "derby cup breed pegasus")

	## Highest-tier mapping (a horse is locked to its highest band).
	_eq(hr.cup_tier_for_total(100), 0, "<125 -> no cup")
	_eq(hr.cup_tier_for_total(125), 1, "125 -> tier 1")
	_eq(hr.cup_tier_for_total(229), 1, "229 -> tier 1")
	_eq(hr.cup_tier_for_total(230), 2, "230 -> tier 2")
	_eq(hr.cup_tier_for_total(349), 2, "349 -> tier 2")
	_eq(hr.cup_tier_for_total(350), 3, "350 -> tier 3")
	_eq(hr.cup_tier_for_total(999), 3, "999 -> tier 3")

	## Prize split: 1st=first, 2nd=50%, 3rd=25%, else 0.
	_eq(hr.cup_prize_for_place(1, 1), 1000000, "tier1 1st = 1M")
	_eq(hr.cup_prize_for_place(1, 2), 500000, "tier1 2nd = 500k")
	_eq(hr.cup_prize_for_place(1, 3), 250000, "tier1 3rd = 250k")
	_eq(hr.cup_prize_for_place(1, 4), 0, "tier1 4th = 0")
	_eq(hr.cup_prize_for_place(2, 1), 10000000, "tier2 1st = 10M")

	## horse_cup_tier / horse_qualifies_for_cup use the cached horse row.
	hr.apply_payload({
		"capacity": 5,
		"horses": [
			## total 160 -> tier 1
			{"id": "cup_h1", "name": "Mid", "breed": "standardbred",
			 "life": 90, "life_cap": 90, "speed": 40, "endurance": 30,
			 "status": "active", "wins": 0, "races_run": 0},
			## total 400 -> tier 3
			{"id": "cup_h3", "name": "Beast", "breed": "standardbred",
			 "life": 200, "life_cap": 200, "speed": 100, "endurance": 100,
			 "status": "active", "wins": 0, "races_run": 0},
		],
	})
	_eq(hr.horse_stat_total("cup_h1"), 160.0, "cup_h1 stat total 160")
	_eq(hr.horse_cup_tier("cup_h1"), 1, "cup_h1 locked to tier 1")
	_eq(hr.horse_cup_tier("cup_h3"), 3, "cup_h3 locked to tier 3")
	_eq(hr.horse_qualifies_for_cup("cup_h3", 1), false, "cup_h3 can't enter tier 1 (over-qualified)")
	_eq(hr.horse_qualifies_for_cup("cup_h3", 3), true, "cup_h3 can enter tier 3")

	## _parse_races surfaces cup fields.
	var races = hr._parse_races({
		"now": "t",
		"races": [{
			"id": "cup1", "name": "Little Cup", "kind": "cup", "status": "open",
			"tier": 1, "prize_breed": "unicorn", "min_total": 125, "max_total": 229,
			"first_prize": 1000000, "field_size": 5, "opens_at": "a", "closes_at": "b",
			"entries": [],
		}],
	})
	_eq(races.size(), 1, "one cup parsed")
	_eq(races[0]["kind"], "cup", "kind cup")
	_eq(races[0]["tier"], 1, "tier 1 parsed")
	_eq(races[0]["prize_breed"], "unicorn", "prize breed parsed")
	_eq(races[0]["min_total"], 125, "min_total parsed")
	_eq(races[0]["max_total"], 229, "max_total parsed")
	_eq(races[0]["first_prize"], 1000000, "first_prize parsed")
	_eq(races[0]["field_size"], 5, "cup field_size parsed")

	## Cup coin-prize crediting (local, once each).
	DirAccess.remove_absolute("user://horse_bets.cfg")
	hr._applied_bet_ids = {}
	hr._applied_prize_ids = {}
	var start: int = pd.coins
	var credited: int = hr._apply_cup_prizes([
		{"entry_id": "e1", "race_name": "Little Cup", "tier": 1, "finish_place": 1, "prize_coins": 1000000},
		{"entry_id": "e2", "race_name": "Little Cup", "tier": 1, "finish_place": 2, "prize_coins": 500000},
		{"entry_id": "e3", "race_name": "Little Cup", "tier": 1, "finish_place": 4, "prize_coins": 0},
	])
	_eq(credited, 1500000, "credits both prized entries (1M + 500k)")
	_eq(pd.coins, start + 1500000, "coins increased by cup prizes")
	var credited2: int = hr._apply_cup_prizes([
		{"entry_id": "e1", "race_name": "Little Cup", "tier": 1, "finish_place": 1, "prize_coins": 1000000},
	])
	_eq(credited2, 0, "re-apply cup prize credits nothing (idempotent)")
	_eq(pd.coins, start + 1500000, "coins unchanged on cup re-apply")
	pd.coins = start   ## restore


func _test_paddock(hr) -> void:
	print("Guild paddock parse + pairing-bonus parse (no network):")

	## _parse_paddock shape (garbage skipped, availability flags).
	var pad = hr._parse_paddock([
		{"horse_id": "p1", "name": "Dobbin", "breed": "standardbred",
		 "speed": 20.0, "endurance": 15.0, "life": 80.0, "life_cap": 90.0,
		 "owner_id": "acc1", "mine": true,
		 "can_sprint": false, "can_hurdle": true, "can_groom": true},
		"garbage",
	])
	_eq(pad.size(), 1, "one paddock horse (garbage skipped)")
	_eq(pad[0]["horse_id"], "p1", "paddock horse_id parsed")
	_eq(pad[0]["speed"], 20.0, "paddock speed float")
	_eq(pad[0]["mine"], true, "paddock mine flag")
	_eq(pad[0]["can_sprint"], false, "paddock can_sprint false")
	_eq(pad[0]["can_hurdle"], true, "paddock can_hurdle true")
	_eq(hr._parse_paddock("nope").size(), 0, "bad paddock payload -> empty")

	## _parse_races carries the pairing_bonus flag.
	var races = hr._parse_races({
		"now": "t",
		"races": [{
			"id": "pr", "name": "PairRace", "kind": "regular", "status": "betting",
			"field_size": 8, "opens_at": "a", "closes_at": "b", "bet_closes_at": "c",
			"entries": [
				{"lane": 0, "is_npc": false, "display_name": "Ay", "breed": "standardbred",
				 "speed": 31.5, "endurance": 31.5, "life": 90.0, "odds": 2.0,
				 "horse_id": "h1", "pairing_bonus": true, "mine": true},
				{"lane": 1, "is_npc": true, "display_name": "NPC", "breed": "arabian",
				 "speed": 20.0, "endurance": 18.0, "life": 60.0, "odds": 5.0,
				 "horse_id": null, "pairing_bonus": false, "mine": false},
			],
		}],
	})
	_eq(races[0]["entries"][0]["pairing_bonus"], true, "paired entry flagged")
	_eq(races[0]["entries"][1]["pairing_bonus"], false, "npc entry not paired")


func _test_horseshoes(hr) -> void:
	print("Horseshoes: defs, counts, level curve, horse parse (no network):")
	var pd = root.get_node_or_null("PlayerData")
	if pd == null:
		_ok(false, "autoload PlayerData not found")
		return

	## Type catalog.
	_eq(hr.HORSESHOE_TYPES.size(), 2, "two horseshoe types")
	_eq(hr.horseshoe_item_id("copper"), "copper_horseshoe", "copper item id")
	_eq(hr.horseshoe_item_id("iron"), "iron_horseshoe", "iron item id")
	_eq(str(hr.horseshoe_def("copper").get("stat", "")), "speed", "copper -> speed")
	_eq(str(hr.horseshoe_def("iron").get("stat", "")), "endurance", "iron -> endurance")
	_eq(hr.horseshoe_item_id("bogus"), "", "unknown type -> empty id")

	## ITEM_DEFS registration: horseshoes are jewelry (for the produce/sell loop)
	## but NOT ring/necklace slot, and ARE flagged as horseshoes.
	_eq(pd.is_jewelry_id("copper_horseshoe"), true, "copper is jewelry id")
	_eq(pd.is_horseshoe_id("copper_horseshoe"), true, "copper is horseshoe id")
	_eq(pd.is_horseshoe_id("gold_ring"), false, "gold_ring is not a horseshoe")
	_eq(pd.jewelry_slot_type("copper_horseshoe"), "horse", "copper slot type horse")
	_eq(pd.horseshoe_ids().size(), 2, "two horseshoe ids")

	## Owned-count -> level curve (via HorseRacing, which uses JewelryBonus).
	## Clear then grant counts and check the level thresholds (1, 10, 100 -> 1,2,3).
	pd.jewelry["copper_horseshoe"] = 0
	_eq(hr.horseshoe_level("copper"), 0, "0 owned -> level 0")
	pd.jewelry["copper_horseshoe"] = 1
	_eq(hr.horseshoe_level("copper"), 1, "1 owned -> level 1")
	pd.jewelry["copper_horseshoe"] = 10
	_eq(hr.horseshoe_level("copper"), 2, "10 owned -> level 2")
	pd.jewelry["copper_horseshoe"] = 100
	_eq(hr.horseshoe_level("copper"), 3, "100 owned -> level 3")
	pd.jewelry.erase("copper_horseshoe")

	## apply_payload parses the horseshoe field on a horse row.
	hr.apply_payload({
		"capacity": 5,
		"horses": [
			{"id": "hs1", "name": "Shod", "breed": "standardbred",
			 "life": 90, "life_cap": 90, "speed": 20, "endurance": 20,
			 "status": "active", "wins": 0, "races_run": 0, "horseshoe": "copper"},
		],
	})
	_eq(str(hr.horse_by_id("hs1").get("horseshoe", "")), "copper", "horse horseshoe parsed")


func _test_jewelry_horse(hr) -> void:
	print("Jewelry horse effects (effective stats + training mult, no network):")
	var pd = root.get_node_or_null("PlayerData")
	var jb = root.get_node_or_null("JewelryBonus")
	if pd == null or jb == null:
		_ok(false, "autoload PlayerData/JewelryBonus not found")
		return

	## Clean slate: clear equip slots + relevant counts.
	pd.equipped_ring = ""
	pd.equipped_necklace = ""
	pd.equipped_misc = ""
	pd.jewelry.erase("emerald_necklace")
	pd.jewelry.erase("pink_stone_necklace")
	pd.jewelry.erase("violet_stone_ring")

	## No jewelry -> multipliers are 1.0 and effective == base.
	_eq(jb.horse_stat_multiplier(), 1.0, "no emerald -> 1.0 stat mult")
	_eq(jb.horse_life_cap_multiplier(), 1.0, "no pink -> 1.0 cap mult")
	_eq(hr.has_jewelry_horse_buff(), false, "no buff flagged")
	## life 80 with cap 120 leaves headroom so the emerald life boost (×1.25=100)
	## isn't clipped by the cap; speed/endurance have ceiling headroom too.
	var base := {"speed": 40.0, "endurance": 40.0, "life": 80.0, "life_cap": 120.0}
	var eff0 = hr.effective_stats(base)
	_eq(eff0["speed"], 40.0, "unbuffed effective speed == base")

	## Equip an emerald at a level-10 count (1,000,000) -> +25% across the board.
	pd.jewelry["emerald_necklace"] = 1000000
	pd.equipped_necklace = "emerald_necklace"
	jb.bonuses_changed.emit()
	_eq(jb.horse_stat_multiplier(), 1.25, "emerald lvl10 -> 1.25 stat mult")
	_eq(jb.horse_stat_level(), 10, "emerald horse level 10")
	var eff1 = hr.effective_stats(base)
	_eq(eff1["speed"], 50.0, "emerald effective speed 40->50")
	_eq(eff1["endurance"], 50.0, "emerald effective endurance 40->50")
	_eq(eff1["life"], 100.0, "emerald effective life 80->100")
	_eq(hr.has_jewelry_horse_buff(), true, "buff flagged when emerald equipped")

	## Ceiling clamp: a near-max base can't exceed the hard ceilings.
	var hi := {"speed": 95.0, "endurance": 95.0, "life": 150.0, "life_cap": 190.0}
	var effhi = hr.effective_stats(hi)
	_eq(effhi["speed"], 100.0, "effective speed clamps to 100")
	_eq(effhi["endurance"], 100.0, "effective endurance clamps to 100")

	## Equip a pink at level-10 count in the ring slot -> life_cap +25% (<=200).
	pd.jewelry["pink_stone_necklace"] = 1000000
	pd.equipped_ring = "pink_stone_necklace"
	jb.bonuses_changed.emit()
	_eq(jb.horse_life_cap_multiplier(), 1.25, "pink lvl10 -> 1.25 cap mult")
	var eff2 = hr.effective_stats(base)
	_eq(eff2["life_cap"], 150.0, "pink effective life_cap 120->150")

	## Training multiplier: violet (sprint) at level 10 -> 1.25; others 1.0.
	pd.jewelry["violet_stone_ring"] = 1000000
	pd.equipped_misc = "violet_stone_ring"
	jb.bonuses_changed.emit()
	_eq(jb.horse_training_multiplier("sprint"), 1.25, "violet -> sprint mult 1.25")
	_eq(jb.horse_training_multiplier("hurdle"), 1.0, "no blue -> hurdle mult 1.0")
	_eq(hr._training_mult("sprint"), 1.25, "HorseRacing training mult passes through")

	## Present horse pool: one "horse:<breed>" entry per breed (uniform odds).
	var hp = hr.present_horse_pool_keys()
	_eq(hp.size(), hr.HORSE_BREEDS.size(), "present horse pool has one key per breed")
	_eq(hp.has("horse:unicorn"), true, "present pool includes mythical unicorn")
	_eq(hp.has("horse:thoroughbred"), true, "present pool includes thoroughbred")

	## Horse-market suggested price = round(stat_total)*5000.
	var mh := {"life": 90.0, "speed": 9.0, "endurance": 8.0}
	_eq(hr.horse_market_suggested_price(mh), 535000, "market suggested price 535000")

	## _parse_horse_market shape (garbage skipped).
	var ml = hr._parse_horse_market([
		{"listing_id": "L1", "horse_id": "H1", "price": 250000, "seller_id": "S1",
		 "seller_name": "Alice", "mine": false, "name": "Zippy", "breed": "arabian",
		 "speed": 12.0, "endurance": 10.0, "life": 80.0, "life_cap": 100.0,
		 "wins": 2, "races_run": 5},
		"garbage",
	])
	_eq(ml.size(), 1, "one market listing (garbage skipped)")
	_eq(ml[0]["price"], 250000, "market listing price parsed")
	_eq(ml[0]["mine"], false, "market listing mine flag")
	_eq(ml[0]["name"], "Zippy", "market listing name parsed")
	_eq(hr._parse_horse_market("nope").size(), 0, "bad market payload -> empty")

	## Cleanup so later tests / app state start clean.
	pd.equipped_ring = ""
	pd.equipped_necklace = ""
	pd.equipped_misc = ""
	pd.jewelry.erase("emerald_necklace")
	pd.jewelry.erase("pink_stone_necklace")
	pd.jewelry.erase("violet_stone_ring")
	jb.bonuses_changed.emit()
