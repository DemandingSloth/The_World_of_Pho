extends SceneTree

## Verifies the backup code formats WITHOUT touching any save files:
##   * legacy v2 codes (plain Base64 JSON) still decode
##   * new v3 codes (PHO3: + gzip) decode back to the identical payload
##   * whitespace/line breaks inserted by clipboards are tolerated
##   * truncated / garbage codes are rejected
##
##   godot --headless --script tests/test_save_backup_codes.gd

var _run := 0
var _passed := 0
var _failed := 0
var _done := false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	print("\n=== Save backup code tests ===\n")

	var files := {
		"player": "[player]\ncoins=12345\ninventory=[{\"type\": 0, \"direction\": 0}, {\"type\": 0, \"direction\": 0}]\n",
		"garden": "[garden]\nrows=5\ncols=5\n",
	}
	var payload := {
		"version": 2,
		"created": 0.0,
		"files": files,
		"checksum": SaveBackup._checksum(files),
	}
	var json := JSON.stringify(payload)

	## Legacy v2: plain Base64 of the JSON (exactly what old builds exported).
	var legacy := Marshalls.utf8_to_base64(json)
	_ok(SaveBackup._decode_to_json(legacy) == json, "legacy v2 code decodes")
	_ok(_checksum_ok(SaveBackup._decode_to_json(legacy)), "legacy v2 checksum still matches")

	## New v3: compressed.
	var raw := json.to_utf8_buffer()
	var v3 := "%s%d:%s" % [SaveBackup.COMPRESSED_PREFIX, raw.size(),
		Marshalls.raw_to_base64(raw.compress(SaveBackup.COMPRESSION_MODE))]
	_ok(v3.begins_with("PHO3:"), "new code has the PHO3 prefix")
	_ok(SaveBackup._decode_to_json(v3) == json, "new v3 code decodes to the same payload")

	## Whitespace from clipboards / chat apps.
	var spaced := v3.substr(0, 20) + "\n " + v3.substr(20, 30) + "\r\n" + v3.substr(50)
	_ok(SaveBackup._decode_to_json(spaced) == json, "v3 code with line breaks/spaces decodes")
	var legacy_spaced := legacy.substr(0, 15) + "\n" + legacy.substr(15)
	_ok(SaveBackup._decode_to_json(legacy_spaced) == json, "legacy code with a line break decodes")

	## Real export round-trip (reads current saves; writes nothing).
	var exported := SaveBackup.export_code()
	if exported != "":
		_ok(exported.begins_with("PHO3:"), "export_code produces a compressed code")
		var back := SaveBackup._decode_to_json(exported)
		_ok(_checksum_ok(back), "exported code decodes with a valid checksum")
		print("  (export size: %d chars)" % exported.length())

	## Bad input.
	_ok(SaveBackup._decode_to_json(v3.substr(0, v3.length() / 2)) == "", "truncated v3 code rejected")
	_ok(SaveBackup._decode_to_json("PHO3:abc:xyz") == "", "garbage v3 code rejected")

	print("\n Results: %d passed, %d failed, %d total\n" % [_passed, _failed, _run])
	quit(1 if _failed > 0 else 0)
	return true


func _checksum_ok(json_text: String) -> bool:
	var parsed = JSON.parse_string(json_text)
	if not (parsed is Dictionary):
		return false
	var f = parsed.get("files", null)
	if not (f is Dictionary):
		return false
	return SaveBackup._checksum(f) == str(parsed.get("checksum", ""))


func _ok(cond: bool, desc: String) -> void:
	_run += 1
	if cond:
		_passed += 1
		print("  ✓ %s" % desc)
	else:
		_failed += 1
		print("  ✗ FAIL: %s" % desc)
