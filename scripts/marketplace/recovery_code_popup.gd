extends AcceptDialog

## One-time recovery-code popup for a newly created marketplace account.
##
## Shows the account username, the recovery code in a copyable read-only field,
## and a large, bold, RED warning that the code is unrecoverable if lost — the
## developer cannot retrieve it. The player must acknowledge before closing.
##
## Usage:
##   RecoveryCodePopup.show_code(scene_tree, username, recovery_code)

const _WARN_COLOR := Color(1.0, 0.15, 0.15)  ## bold red

static func show_code(scene_tree: SceneTree, username: String, recovery_code: String) -> void:
	if scene_tree == null or scene_tree.root == null:
		return
	var popup := (load("res://scripts/marketplace/recovery_code_popup.gd") as GDScript).new() as AcceptDialog
	popup._setup(username, recovery_code)
	scene_tree.root.add_child(popup)
	popup.popup_centered()


func _setup(username: String, recovery_code: String) -> void:
	title = "Marketplace Account Created"
	ok_button_text = "I've saved it — close"
	unresizable = false
	min_size = Vector2(420, 340)
	## Block closing via the X / Esc so the warning can't be dismissed by accident;
	## only the acknowledged OK button closes it.
	dialog_hide_on_ok = true
	get_ok_button().custom_minimum_size = Vector2(0, 48)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.custom_minimum_size = Vector2(400, 0)
	add_child(vbox)

	var welcome := Label.new()
	welcome.text = "Welcome, %s!" % username
	welcome.add_theme_font_size_override("font_size", 16)
	welcome.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(welcome)

	## ── The big red warning ──────────────────────────────────────
	var warn := Label.new()
	warn.text = "⚠ WRITE THIS DOWN NOW ⚠"
	warn.add_theme_font_size_override("font_size", 26)
	warn.add_theme_color_override("font_color", _WARN_COLOR)
	warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(warn)

	var warn2 := Label.new()
	warn2.text = "Save this recovery code somewhere safe.\nIf you lose it, it CANNOT be recovered.\nThe developer CANNOT retrieve it for you.\nThere is NO getting it back."
	warn2.add_theme_font_size_override("font_size", 15)
	warn2.add_theme_color_override("font_color", _WARN_COLOR)
	warn2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warn2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(warn2)

	## ── The code itself (read-only, selectable, with a Copy button) ──
	var code_label := Label.new()
	code_label.text = "Your recovery code:"
	code_label.add_theme_font_size_override("font_size", 12)
	code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(code_label)

	var code_field := LineEdit.new()
	code_field.text = recovery_code
	code_field.editable = false
	code_field.selecting_enabled = true
	code_field.alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_field.add_theme_font_size_override("font_size", 20)
	code_field.custom_minimum_size = Vector2(0, 44)
	vbox.add_child(code_field)

	var copy_btn := Button.new()
	copy_btn.text = "📋 Copy to clipboard"
	copy_btn.custom_minimum_size = Vector2(0, 40)
	copy_btn.pressed.connect(func():
		DisplayServer.clipboard_set(recovery_code)
		copy_btn.text = "✅ Copied — now paste it somewhere safe")
	vbox.add_child(copy_btn)

	## Free the popup once dismissed.
	confirmed.connect(queue_free)
	canceled.connect(queue_free)
