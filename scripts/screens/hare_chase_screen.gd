extends BaseScreen
## Hare chase mini game screen. Shown when a hare steals ready crops
## (Garden.pending_heist). Win = crops returned to inventory; lose or abandon =
## crops are gone. Leaving by any other route keeps the heist pending, so this
## screen reopens the next time the garden is visited.

var _field: HareChaseField = null
var _hint_label: Label = null
var _modal: Control = null
var _finished: bool = false


func get_screen_name() -> String:
	return "hare_chase"


func show_top_bar() -> bool:
	return true


func get_background_override() -> String:
	return "res://Assets/Backgrounds/Summer1.png"


## Cuts start at the field's side walls, right by the screen edges, so the
## edge-swipe back gesture would fire on every horizontal stroke. Disable it.
func allows_edge_swipe_back() -> bool:
	return false


func enter(_params: Dictionary = {}) -> void:
	if not Garden.has_pending_heist():
		## Nothing to chase (already resolved) — go straight back to the garden.
		_get_navigator().navigate_to("garden")
		return
	_build_ui()
	_show_intro()


func exit() -> void:
	_close_modal()
	for child in get_children():
		child.queue_free()
	_field = null
	_hint_label = null


## ── UI ──────────────────────────────────────────────────────────

func _build_ui() -> void:
	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	add_child(margin)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var title: Label = Label.new()
	title.text = "🐇 Hare Heist"
	title.add_theme_font_size_override("font_size", 14)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_hint_label = Label.new()
	_hint_label.text = ""
	_hint_label.add_theme_font_size_override("font_size", 11)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.custom_minimum_size = Vector2(0, 28)
	vbox.add_child(_hint_label)

	_field = HareChaseField.new()
	_field.name = "HareField"
	_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_field.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_field.custom_minimum_size = Vector2(240, 240)
	_field.caught.connect(_on_caught)
	_field.hare_trapped.connect(_on_trapped)
	_field.hint.connect(_on_field_hint)
	vbox.add_child(_field)

	var abandon_btn: Button = Button.new()
	abandon_btn.text = "Abandon crops"
	abandon_btn.custom_minimum_size = Vector2(200, 44)
	abandon_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	abandon_btn.add_theme_font_size_override("font_size", 12)
	abandon_btn.pressed.connect(_on_abandon_pressed)
	vbox.add_child(abandon_btn)


func _on_field_hint(text: String) -> void:
	if _hint_label != null and is_instance_valid(_hint_label):
		_hint_label.text = text


## ── Modals (custom overlays; dialogs clip on mobile) ────────────

## Shows a centered card with a title, body text and buttons.
## buttons: Array of { "text": String, "action": Callable }.
func _show_modal(title_text: String, body_text: String, buttons: Array) -> void:
	_close_modal()
	_modal = Control.new()
	_modal.set_anchors_preset(Control.PRESET_FULL_RECT)
	_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_modal)

	var dim: ColorRect = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_modal.add_child(dim)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_modal.add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	center.add_child(panel)

	var pad: MarginContainer = MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 16)
	pad.add_theme_constant_override("margin_right", 16)
	pad.add_theme_constant_override("margin_top", 14)
	pad.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(pad)

	var box: VBoxContainer = VBoxContainer.new()
	box.custom_minimum_size = Vector2(280, 0)
	box.add_theme_constant_override("separation", 10)
	pad.add_child(box)

	var t: Label = Label.new()
	t.text = title_text
	t.add_theme_font_size_override("font_size", 14)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(t)

	var body: Label = Label.new()
	body.text = body_text
	body.add_theme_font_size_override("font_size", 11)
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(body)

	for b in buttons:
		var btn: Button = Button.new()
		btn.text = str(b["text"])
		btn.custom_minimum_size = Vector2(0, 44)
		btn.add_theme_font_size_override("font_size", 12)
		btn.pressed.connect(b["action"])
		box.add_child(btn)

	if _field != null and is_instance_valid(_field):
		_field.paused = true


func _close_modal() -> void:
	if _modal != null and is_instance_valid(_modal):
		_modal.queue_free()
	_modal = null
	if _field != null and is_instance_valid(_field):
		_field.paused = false


## ── Flow ────────────────────────────────────────────────────────

func _show_intro() -> void:
	var text: String = "A hare snuck into your garden and made off with:\n%s\n\n" \
		+ "Draw lines from edge to edge to wall off sections. The side without " \
		+ "the crate gets closed, so don't trap the hare outside! Herd it into " \
		+ "the crate through its left or right side to get your crops back."
	_show_modal("Thief!", text % Garden.heist_summary_text(), [
		{"text": "Chase!", "action": _on_chase_pressed},
		{"text": "Abandon crops", "action": _on_abandon_pressed},
	])


func _on_chase_pressed() -> void:
	_close_modal()
	## Wait a frame so the field has its final laid-out size.
	await get_tree().process_frame
	if _field != null and is_instance_valid(_field):
		_field.start_game()
		_on_field_hint("Drag a line from one edge to another.")


func _on_abandon_pressed() -> void:
	if _finished:
		return
	var text: String = "You'll lose the stolen crops for good:\n%s" % Garden.heist_summary_text()
	_show_modal("Abandon crops?", text, [
		{"text": "Yes, abandon them", "action": _confirm_abandon},
		{"text": "Keep chasing", "action": _cancel_abandon},
	])


func _cancel_abandon() -> void:
	## Back to the intro if the game has not started yet, otherwise resume.
	_close_modal()
	if _field != null and is_instance_valid(_field) and not _field.is_active() \
			and not _field.is_finished():
		_show_intro()


func _confirm_abandon() -> void:
	if _finished:
		return
	_finished = true
	Garden.resolve_heist_loss()
	_close_modal()
	_get_navigator().navigate_to("garden")


func _on_caught() -> void:
	if _finished:
		return
	_finished = true
	var returned: Dictionary = Garden.resolve_heist_win()
	var parts: PackedStringArray = []
	var keys: Array = returned.keys()
	keys.sort()
	for pt in keys:
		var def: Dictionary = Garden.get_plant_def(int(pt))
		parts.append("%d %s" % [int(returned[pt]), str(def.get("name", "crop"))])
	_show_modal("Caught the hare!",
		"Your crops were returned to your inventory:\n%s" % ", ".join(parts), [
			{"text": "Back to garden", "action": _go_to_garden},
		])


func _on_trapped() -> void:
	if _finished:
		return
	_finished = true
	var lost: String = Garden.heist_summary_text()
	Garden.resolve_heist_loss()
	_show_modal("The hare is gone",
		"It got walled off and your crops are lost:\n%s" % lost, [
			{"text": "Back to garden", "action": _go_to_garden},
		])


func _go_to_garden() -> void:
	_close_modal()
	_get_navigator().navigate_to("garden")
