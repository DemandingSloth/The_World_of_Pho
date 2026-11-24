extends BaseScreen
## Money Gun screen — buy the gun (500B coins, one per save) and claim the
## Benjamins it prints over time. All gun/Benjamin state is server-authoritative
## (via the MoneyGun autoload); this screen just displays it and triggers
## buy/claim. Upgrades live in the Prestige screen (shown once owned).

## Sprites. The gun MAY be animated later — kept as a single Texture2D load so a
## future swap to an AnimatedSprite is a localized change.
const GUN_SPRITE_PATH := "res://Assets/benjamin_gun.png"
const BENJAMIN_SPRITE_PATH := "res://Assets/Benjamins.png"

var _balance_label: Label = null
var _accrued_label: Label = null
var _rate_label: Label = null
var _status_label: Label = null
var _claim_btn: Button = null
var _buy_btn: Button = null


func get_screen_name() -> String:
	return "money_gun"


func enter(_params: Dictionary = {}) -> void:
	_build_ui()
	if not MoneyGun.money_gun_changed.is_connected(_on_money_gun_changed):
		MoneyGun.money_gun_changed.connect(_on_money_gun_changed)
	## Pull the authoritative state (this also surfaces accrued-but-unclaimed).
	await MoneyGun.refresh()
	_refresh()


func exit() -> void:
	if MoneyGun.money_gun_changed.is_connected(_on_money_gun_changed):
		MoneyGun.money_gun_changed.disconnect(_on_money_gun_changed)
	for child in get_children():
		child.queue_free()
	_balance_label = null
	_accrued_label = null
	_rate_label = null
	_status_label = null
	_claim_btn = null
	_buy_btn = null


func _on_money_gun_changed() -> void:
	_refresh()


# ── UI build ──────────────────────────────────────────────────────

func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.12, 0.9)
	style.corner_radius_top_left = 6; style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6; style.corner_radius_bottom_right = 6
	style.content_margin_left = 10; style.content_margin_right = 10
	style.content_margin_top = 8; style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	## Back button
	var back_btn := Button.new()
	back_btn.text = "< Back"
	back_btn.custom_minimum_size = Vector2(200, 44)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back_btn.add_theme_font_size_override("font_size", 13)
	back_btn.pressed.connect(_on_back_pressed)
	vbox.add_child(back_btn)

	## Title
	var title := Label.new()
	title.text = "The Money Gun"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.5, 0.85, 0.4))
	vbox.add_child(title)

	## Gun sprite
	var gun_tex := _load_tex(GUN_SPRITE_PATH)
	if gun_tex != null:
		var gun := TextureRect.new()
		gun.texture = gun_tex
		gun.custom_minimum_size = Vector2(0, 120)
		gun.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		gun.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		vbox.add_child(gun)

	## Balance row (Benjamins icon + amount)
	var bal_row := HBoxContainer.new()
	bal_row.alignment = BoxContainer.ALIGNMENT_CENTER
	bal_row.add_theme_constant_override("separation", 6)
	vbox.add_child(bal_row)
	var benj_tex := _load_tex(BENJAMIN_SPRITE_PATH)
	if benj_tex != null:
		var benj_icon := TextureRect.new()
		benj_icon.texture = benj_tex
		benj_icon.custom_minimum_size = Vector2(28, 28)
		benj_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		bal_row.add_child(benj_icon)
	_balance_label = Label.new()
	_balance_label.add_theme_font_size_override("font_size", 18)
	_balance_label.add_theme_color_override("font_color", Color(0.6, 0.9, 0.5))
	bal_row.add_child(_balance_label)

	## Rate + accrued
	_rate_label = Label.new()
	_rate_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rate_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_rate_label)

	_accrued_label = Label.new()
	_accrued_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_accrued_label.add_theme_font_size_override("font_size", 13)
	_accrued_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	vbox.add_child(_accrued_label)

	## Claim button
	_claim_btn = Button.new()
	_claim_btn.text = "Claim Benjamins"
	_claim_btn.custom_minimum_size = Vector2(220, 48)
	_claim_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_claim_btn.add_theme_font_size_override("font_size", 14)
	_claim_btn.pressed.connect(_on_claim_pressed)
	vbox.add_child(_claim_btn)

	## Buy button (shown only when not owned)
	_buy_btn = Button.new()
	_buy_btn.custom_minimum_size = Vector2(260, 52)
	_buy_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_buy_btn.add_theme_font_size_override("font_size", 13)
	_buy_btn.pressed.connect(_on_buy_pressed)
	vbox.add_child(_buy_btn)

	## Status + upgrade hint
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 11)
	vbox.add_child(_status_label)


# ── Refresh from MoneyGun cache ───────────────────────────────────

func _refresh() -> void:
	if _balance_label == null:
		return  ## UI torn down

	_balance_label.text = PlayerData.format_number(MoneyGun.balance)

	if MoneyGun.owned:
		_rate_label.text = "Printing %s Benjamin(s)/hour (max %s stored)" % [
			PlayerData.format_number(MoneyGun.rate_per_hour),
			PlayerData.format_number(MoneyGun.cap)]
		if MoneyGun.accrued > 0:
			_accrued_label.text = "💵 %s ready to claim" % PlayerData.format_number(MoneyGun.accrued)
			_accrued_label.visible = true
		else:
			_accrued_label.text = "Nothing to claim yet — come back later."
			_accrued_label.visible = true
		_claim_btn.visible = true
		_claim_btn.disabled = MoneyGun.accrued <= 0
		_buy_btn.visible = false
		_status_label.text = "Upgrade the print rate in the Prestige screen."
	else:
		_rate_label.text = ""
		_accrued_label.visible = false
		_claim_btn.visible = false
		_buy_btn.visible = true
		_buy_btn.text = "Buy — %s coins" % PlayerData.format_number(MoneyGun.MONEY_GUN_COST)
		var can_afford := PlayerData.coins >= MoneyGun.MONEY_GUN_COST
		_buy_btn.disabled = not can_afford
		_status_label.text = "A gun that prints its own untradeable currency. One per save." \
			if can_afford else "You can't afford the Money Gun yet."


# ── Actions ───────────────────────────────────────────────────────

func _on_claim_pressed() -> void:
	_claim_btn.disabled = true
	var res := await MoneyGun.claim()
	if res.get("ok", false):
		var claimed := int(res.get("claimed", 0))
		if claimed > 0:
			GameNotification.show_message("💵 Claimed", "Collected %s Benjamins." % PlayerData.format_number(claimed))
		else:
			GameNotification.show_message("Money Gun", "Nothing to claim yet.")
	else:
		GameNotification.show_message("Claim Failed", str(res.get("message", "Could not claim.")))
	_refresh()


func _on_buy_pressed() -> void:
	_buy_btn.disabled = true
	_buy_btn.text = "Purchasing…"
	var res := await MoneyGun.buy()
	if res.get("ok", false):
		GameNotification.show_message("Money Gun 🔫", "The Money Gun is yours — it's printing now!")
	else:
		GameNotification.show_message("Purchase Failed", str(res.get("message", "Could not buy the Money Gun.")))
	_refresh()


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


# ── Helpers ───────────────────────────────────────────────────────

func _load_tex(path: String) -> Texture2D:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D
