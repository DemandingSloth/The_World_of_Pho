extends SceneTree

## Tests for the guild leaderboard (Side-task B): the GuildLeaderboard autoload's
## payload parsing + the new Leaderboard panel nodes/@onready refs in the guild
## detail scene.
##
##   godot --headless --script tests/test_guild_leaderboard.gd

var _done := false
var _run := 0
var _passed := 0
var _failed := 0


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	print("\n========================================")
	print(" Guild Leaderboard Tests")
	print("========================================\n")

	var lb = root.get_node_or_null("GuildLeaderboard")
	if lb == null:
		printerr("[FAIL] GuildLeaderboard autoload not found!")
		quit(1)
		return true

	_test_apply_players(lb)
	_test_apply_guilds(lb)
	_test_bad_payloads(lb)
	_test_scene_nodes()

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


func _test_apply_players(lb) -> void:
	print("apply_players parses the player leaderboard:")
	_ok(lb.apply_players({"players": [
		{"username": "alice", "score": 1500, "guild_name": "Guild A", "is_you": true},
		{"username": "bob", "score": 1200, "guild_name": "Guild B", "is_you": false},
	]}), "apply_players returns true")
	_eq(lb.players.size(), 2, "two players cached")
	_eq(lb.players[0]["username"], "alice", "first player username")
	_eq(lb.players[0]["score"], 1500, "first player score")
	_eq(lb.players[0]["guild_name"], "Guild A", "first player guild")
	_eq(lb.players[0]["is_you"], true, "first player is_you")
	_eq(lb.players[1]["is_you"], false, "second player is_you false")


func _test_apply_guilds(lb) -> void:
	print("apply_guilds parses the guild leaderboard:")
	_ok(lb.apply_guilds({"guilds": [
		{"name": "Guild A", "specialization": "mining", "upgrade_points": 9999, "member_count": 5, "is_yours": true},
	]}), "apply_guilds returns true")
	_eq(lb.guilds.size(), 1, "one guild cached")
	_eq(lb.guilds[0]["name"], "Guild A", "guild name")
	_eq(lb.guilds[0]["upgrade_points"], 9999, "guild points")
	_eq(lb.guilds[0]["member_count"], 5, "guild member_count")
	_eq(lb.guilds[0]["is_yours"], true, "guild is_yours")


func _test_bad_payloads(lb) -> void:
	print("Bad payloads handled:")
	_eq(lb.apply_players("nope"), false, "non-dict players payload -> false")
	_eq(lb.apply_guilds(42), false, "non-dict guilds payload -> false")
	_ok(lb.apply_players({}), "empty players dict -> true (defaults)")
	_eq(lb.players.size(), 0, "empty players dict clears cache")


func _test_scene_nodes() -> void:
	print("Leaderboard panel nodes resolve in the guild detail scene:")
	var scene: PackedScene = load("res://scenes/screens/guild_detail_screen.tscn")
	_ok(scene != null, "guild_detail_screen.tscn loads")
	if scene == null:
		return
	var inst = scene.instantiate()
	root.add_child(inst)
	var base := "MarginContainer/OuterVBox"
	_ok(inst.get_node_or_null("%s/NavRow/LeaderboardNavBtn" % base) != null, "LeaderboardNavBtn exists")
	var panel := "%s/ContentScroll/ContentVBox/LeaderboardPanel" % base
	_ok(inst.get_node_or_null(panel) != null, "LeaderboardPanel exists")
	_ok(inst.get_node_or_null("%s/TabRow/PlayersTabBtn" % panel) != null, "PlayersTabBtn exists")
	_ok(inst.get_node_or_null("%s/TabRow/GuildsTabBtn" % panel) != null, "GuildsTabBtn exists")
	_ok(inst.get_node_or_null("%s/LeaderboardList" % panel) != null, "LeaderboardList exists")
	## @onready refs resolved after add_child.
	_ok(inst._nav_leaderboard != null, "@onready _nav_leaderboard resolved")
	_ok(inst._leaderboard_panel != null, "@onready _leaderboard_panel resolved")
	_ok(inst._lb_list != null, "@onready _lb_list resolved")
	inst.queue_free()
