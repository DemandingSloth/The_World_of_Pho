extends SceneTree

## Unit tests for GuildStore.apply_payload / apply_bank_payload (the pure
## response-parsing paths) and its convenience getters. Runs with the full
## project so the GuildStore autoload is available, but hits NO network — the
## parse functions are fed mocked get_guild_store / get_guild_bank payloads.
##
##   godot --headless --script tests/test_guild_store_data.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" GuildStore Data Layer Unit Tests")
	print("========================================\n")

	var gs = root.get_node_or_null("GuildStore")
	if gs == null:
		printerr("[FAIL] Autoload GuildStore not found!")
		quit(1)
		return true

	_test_parse_well_formed(gs)
	_test_fields(gs)
	_test_mine_filter(gs)
	_test_bank_parse(gs)
	_test_bad_payload(gs)
	_test_skips_malformed_entries(gs)
	_test_list_guards(gs)
	_test_buy_cancel_guards(gs)
	_test_fronts_parse(gs)
	_test_front_buy_guard(gs)
	_test_guild_jewelry_pool(gs)

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


func _sample_payload() -> Dictionary:
	return {
		"now": 1700000000.0,
		"items": [
			{
				"id": "aaaa", "seller_id": "s1", "seller_name": "Alice",
				"item_key": "item:ruby_ring", "unit_price": 500,
				"quantity_remaining": 3, "mine": true, "created_at": 1699999000.0,
			},
			{
				"id": "bbbb", "seller_id": "s2", "seller_name": "Bob",
				"item_key": "item:gold_ring", "unit_price": 200,
				"quantity_remaining": 1, "mine": false, "created_at": 1699998000.0,
			},
		],
	}


func _test_parse_well_formed(gs) -> void:
	print("apply_payload parses a well-formed response:")
	_ok(gs.apply_payload(_sample_payload()), "apply_payload returns true")
	_eq(gs.listings.size(), 2, "two listings cached")
	_eq(gs.is_empty(), false, "is_empty false when listings present")


func _test_fields(gs) -> void:
	print("Listing fields parsed correctly:")
	gs.apply_payload(_sample_payload())
	var first = gs.listings[0]
	_eq(first["id"], "aaaa", "id parsed")
	_eq(first["seller_name"], "Alice", "seller_name parsed")
	_eq(first["item_key"], "item:ruby_ring", "item_key parsed")
	_eq(first["unit_price"], 500, "unit_price parsed")
	_eq(first["quantity_remaining"], 3, "quantity_remaining parsed")
	_eq(first["mine"], true, "mine flag parsed")


func _test_mine_filter(gs) -> void:
	print("my_listings filters to the player's own listings:")
	gs.apply_payload(_sample_payload())
	var mine = gs.my_listings()
	_eq(mine.size(), 1, "exactly one mine listing")
	_eq(mine[0]["item_key"], "item:ruby_ring", "the ruby_ring is mine")


func _test_bank_parse(gs) -> void:
	print("apply_bank_payload parses bank balance + member count:")
	_ok(gs.apply_bank_payload({"bank_balance": 7, "member_count": 3}), "apply_bank_payload true")
	_eq(gs.bank_balance, 7, "bank_balance == 7")
	_eq(gs.member_count, 3, "member_count == 3")
	## Defaults when missing.
	gs.apply_bank_payload({})
	_eq(gs.bank_balance, 0, "bank_balance defaults to 0")
	_eq(gs.member_count, 0, "member_count defaults to 0")


func _test_bad_payload(gs) -> void:
	print("Bad payloads rejected gracefully:")
	_eq(gs.apply_payload("not a dict"), false, "string payload -> false")
	_eq(gs.apply_payload(42), false, "int payload -> false")
	_eq(gs.apply_bank_payload("nope"), false, "bank string payload -> false")
	_ok(gs.apply_payload({}), "empty dict -> true (defaults)")
	_eq(gs.listings.size(), 0, "empty dict clears listings")


func _test_skips_malformed_entries(gs) -> void:
	print("Malformed listing entries are skipped:")
	gs.apply_payload({
		"items": [
			{"id": "ok", "item_key": "item:emerald_necklace", "unit_price": 100, "quantity_remaining": 2},
			"garbage",          ## not a dict -> skipped
			42,                 ## not a dict -> skipped
		],
	})
	_eq(gs.listings.size(), 1, "only the valid entry kept")
	_eq(gs.listings[0]["item_key"], "item:emerald_necklace", "valid entry item_key correct")


func _test_list_guards(gs) -> void:
	print("list_item client-side guards (no network):")
	## no_guild
	var r = await gs.list_item("", "item:ruby_ring", 1, 100)
	_eq(r.get("error"), "no_guild", "empty guild -> no_guild")
	## not_jewelry (raw resource key rejected before any network)
	r = await gs.list_item("g1", "gem:gold", 1, 100)
	_eq(r.get("error"), "not_jewelry", "gem key -> not_jewelry")
	## not_jewelry (bare 'item:' with no id)
	r = await gs.list_item("g1", "item:", 1, 100)
	_eq(r.get("error"), "not_jewelry", "bare item: -> not_jewelry")
	## invalid_quantity
	r = await gs.list_item("g1", "item:ruby_ring", 0, 100)
	_eq(r.get("error"), "invalid_quantity", "zero qty -> invalid_quantity")
	## invalid_price
	r = await gs.list_item("g1", "item:ruby_ring", 1, 0)
	_eq(r.get("error"), "invalid_price", "zero price -> invalid_price")


func _test_buy_cancel_guards(gs) -> void:
	print("buy / cancel client-side guards (no network):")
	var r = await gs.buy("", "lid", 1)
	_eq(r.get("error"), "no_guild", "buy empty guild -> no_guild")
	r = await gs.buy("g1", "lid", 0)
	_eq(r.get("error"), "invalid_quantity", "buy zero qty -> invalid_quantity")
	r = await gs.cancel("", "lid")
	_eq(r.get("error"), "no_guild", "cancel empty guild -> no_guild")
	r = await gs.distribute_bank("")
	_eq(r.get("error"), "no_guild", "distribute empty guild -> no_guild")


func _test_fronts_parse(gs) -> void:
	print("apply_fronts_payload parses public Guild Fronts listings:")
	var ok = gs.apply_fronts_payload({
		"now": 1700000000.0,
		"items": [
			{
				"id": "f1", "guild_id": "g1", "guild_name": "Iron Co",
				"seller_name": "Smith", "item_key": "item:gold_ring",
				"unit_price": 300, "quantity_remaining": 4, "mine": false,
			},
			{
				"id": "f2", "guild_id": "g1", "guild_name": "Iron Co",
				"seller_name": "You", "item_key": "item:ruby_ring",
				"unit_price": 900, "quantity_remaining": 1, "mine": true,
			},
			"garbage",   ## skipped
		],
	})
	_ok(ok, "apply_fronts_payload returns true")
	_eq(gs.fronts.size(), 2, "two fronts cached (garbage skipped)")
	_eq(gs.fronts[0]["guild_name"], "Iron Co", "guild_name parsed")
	_eq(gs.fronts[0]["item_key"], "item:gold_ring", "item_key parsed")
	_eq(gs.fronts[1]["mine"], true, "mine flag parsed on own listing")
	_eq(gs.apply_fronts_payload("nope"), false, "bad fronts payload -> false")


func _test_front_buy_guard(gs) -> void:
	print("buy_front client-side guard (no network):")
	var r = await gs.buy_front("some_listing", 0)
	_eq(r.get("error"), "invalid_quantity", "buy_front zero qty -> invalid_quantity")


func _test_guild_jewelry_pool(gs) -> void:
	print("Guild jewelry pool parse + list guard (migration 062):")
	var ok = gs.apply_jewelry_payload({
		"items": [
			{"item_key": "item:ruby_ring", "quantity": 3},
			{"item_key": "item:gold_ring", "quantity": 0},   ## kept, reads as 0
			"garbage",                                        ## skipped
		],
	})
	_ok(ok, "apply_jewelry_payload returns true")
	_eq(gs.guild_jewelry_count("item:ruby_ring"), 3, "pool ruby_ring == 3")
	_eq(gs.guild_jewelry_count("item:emerald_necklace"), 0, "unknown key -> 0")
	_eq(gs.apply_jewelry_payload("nope"), false, "bad jewelry payload -> false")

	## list_item now checks the GUILD pool (not personal inventory). With 3
	## ruby_rings pooled, listing 1 passes the local guard (then hits network,
	## which returns offline in the test harness — error != insufficient_jewelry).
	gs.apply_jewelry_payload({"items": [{"item_key": "item:ruby_ring", "quantity": 3}]})
	var r = await gs.list_item("g1", "item:ruby_ring", 5, 100)
	_eq(r.get("error"), "insufficient_jewelry", "list over pool -> insufficient_jewelry")
