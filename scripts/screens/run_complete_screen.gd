extends BaseScreen
## Run Complete screen — displayed when the player wins the entire campaign gauntlet.
## Shows a congratulatory title, run summary (wins/losses), coin reward, and a
## "New Campaign" button to return home.
##
## Requirements: 1.2, 1.3, 9.1


@onready var run_complete_title: Label = $VBox/RunCompleteTitle
@onready var run_complete_detail: Label = $VBox/RunCompleteDetail
@onready var new_campaign_btn: Button = $VBox/NewCampaignBtn


func enter(params: Dictionary = {}) -> void:
	new_campaign_btn.pressed.connect(_on_new_campaign_pressed)

	# Build display text from game_manager_ref passed by battle screen
	var detail_text := ""
	var game_manager_ref = params.get("game_manager_ref", null)

	if game_manager_ref != null:
		# Use campaign summary from the game manager
		if game_manager_ref.campaign != null:
			detail_text += game_manager_ref.campaign.get_run_summary()
		if game_manager_ref.last_coin_reward > 0:
			detail_text += "\n\n+%d coins for completing the gauntlet!" % game_manager_ref.last_coin_reward
	else:
		# Fallback: read from PlayerData if no game_manager_ref (e.g. back nav)
		detail_text = "Campaign Complete!"

	detail_text += "\n\nCoins: %s" % PlayerData.format_number(PlayerData.coins)
	run_complete_detail.text = detail_text


func exit() -> void:
	pass


func get_screen_name() -> String:
	return "run_complete"


## ── Private: Button handlers ─────────────────────────────────────


func _on_new_campaign_pressed() -> void:
	_get_navigator().navigate_to("home")
