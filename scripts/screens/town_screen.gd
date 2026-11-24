class_name TownScreen
extends BaseScreen
## Town screen with navigation buttons to marketplace, mines, garden, school, and games.
## Requirements: 1.2, 1.3, 1.5, 1.6


@onready var mines_btn: Button = $CenterWrapper/MarginContainer/TownVBox/MinesBtn
@onready var garden_btn: Button = $CenterWrapper/MarginContainer/TownVBox/GardenBtn
@onready var school_btn: Button = $CenterWrapper/MarginContainer/TownVBox/SchoolBtn
@onready var games_btn: Button = $CenterWrapper/MarginContainer/TownVBox/GamesBtn
@onready var back_btn: Button = $CenterWrapper/MarginContainer/TownVBox/BackBtn
@onready var mission_btn: Button = $CenterWrapper/MarginContainer/TownVBox/MissionBtn
@onready var prestige_btn: Button = $CenterWrapper/MarginContainer/TownVBox/PrestigeBtn
@onready var business_district_btn: Button = $CenterWrapper/MarginContainer/TownVBox/BusinessDistrictBtn
@onready var equestrian_btn: Button = $CenterWrapper/MarginContainer/TownVBox/EquestrianBtn


@onready var margin_container: MarginContainer = $CenterWrapper/MarginContainer


func _ready() -> void:
	mines_btn.pressed.connect(_on_mines_pressed)
	garden_btn.pressed.connect(_on_garden_pressed)
	school_btn.pressed.connect(_on_school_pressed)
	games_btn.pressed.connect(_on_games_pressed)
	back_btn.pressed.connect(_on_back_pressed)
	mission_btn.pressed.connect(_on_mission_pressed)
	prestige_btn.pressed.connect(_on_prestige_pressed)
	business_district_btn.pressed.connect(_on_business_district_pressed)
	equestrian_btn.pressed.connect(_on_equestrian_pressed)
	## Money Gun + Jewelry (equipment) now live on the Inventory screen.
	_apply_level_locks()
	_clamp_width()
	get_viewport().size_changed.connect(_clamp_width)


func _clamp_width() -> void:
	const MAX_W := 400.0
	var vp_w: float = get_viewport_rect().size.x
	var target_w: float = min(vp_w - 24.0, MAX_W)
	margin_container.custom_minimum_size.x = target_w
	margin_container.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	margin_container.set_deferred("size", Vector2(target_w, margin_container.size.y))


func _apply_level_locks() -> void:
	var lvl: int = PlayerData.level
	garden_btn.disabled = lvl < 1
	garden_btn.text = "Garden" if lvl >= 1 else "🔒 Garden — Lv.1"
	games_btn.disabled = lvl < 4
	games_btn.text = "Games" if lvl >= 4 else "🔒 Games — Lv.4"
	business_district_btn.disabled = lvl < 25
	business_district_btn.text = "🏢 Business District" if lvl >= 25 else "🔒 Business District — Lv.25"


func get_screen_name() -> String:
	return "town"


func _on_mines_pressed() -> void:
	_get_navigator().navigate_to("mining")


func _on_garden_pressed() -> void:
	_get_navigator().navigate_to("garden")


func _on_school_pressed() -> void:
	_get_navigator().navigate_to("school")


func _on_games_pressed() -> void:
	_get_navigator().navigate_to("games")


func _on_back_pressed() -> void:
	_get_navigator().navigate_back()


func _on_mission_pressed() -> void:
	_get_navigator().navigate_to("mission_board")


func _on_prestige_pressed() -> void:
	_get_navigator().navigate_to("prestige")


func _on_business_district_pressed() -> void:
	_get_navigator().navigate_to("business_district")


func _on_equestrian_pressed() -> void:
	_get_navigator().navigate_to("equestrian")



	## ── Close Button ────────────────────────────────────────────────
	#var close_btn := Button.new()
	#close_btn.text = "Close"
	#close_btn.add_theme_font_size_override("font_size", 12)
	#close_btn.custom_minimum_size.y = 36
	#close_btn.pressed.connect(func(): popup.queue_free())
	#vbox.add_child(close_btn)
##
	#popup.close_requested.connect(func(): popup.queue_free())
#
	#add_child(popup)
	#popup.popup_centered()
