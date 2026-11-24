class_name SaveBackup
extends RefCounted

## Backup / restore of all player progress via a copy-paste code.
##
## Bundles every save file into a single versioned JSON blob, Base64-encoded so
## it's a plain-text string the player can copy out (export) and paste back
## (import). No file picker / native plugin required — works on every platform.
##
## Restore is destructive: it overwrites all current save files, then the
## caller must reload the autoloads (see reload_all_autoloads()).

## v2 adds the marketplace account identity so backups carry the online account.
## v3 compresses the JSON before Base64-encoding it (save files are repetitive
## text, so codes shrink dramatically). v2 codes still import.
const BACKUP_VERSION := 3

## Compressed (v3+) codes look like "PHO3:<raw_byte_size>:<base64 gzip bytes>".
## The raw size is needed by FileAccess decompression. Older codes are plain
## Base64 JSON with no prefix.
const COMPRESSED_PREFIX := "PHO3:"
const COMPRESSION_MODE := FileAccess.COMPRESSION_GZIP
## Upper bound on a decompressed backup, to reject garbage sizes safely.
const MAX_RAW_SIZE := 256 * 1024 * 1024

## All save files that make up "progress". Keys are stable identifiers stored
## in the backup; values are the user:// paths.
const SAVE_FILES := {
	"player": "user://player_save.cfg",
	"garden": "user://garden_save.cfg",
	"orchard": "user://orchard_save.cfg",
	## Workshop (Saw + Foundry): in-progress queues, hourglass usage, qty prefs.
	## Prestige LEVELS live in the player save; this is the Workshop's own state.
	"workshop": "user://workshop_save.cfg",
	"missions": "user://missions.cfg",
	"achievements": "user://achievements.cfg",
	## Marketplace online identity (device id + account handle). Folding it into
	## the backup means restoring on a new device re-links the same account.
	"marketplace_account": "user://marketplace_account.cfg",
	## Business District shop deposits/levels + slot assignments.
	"business": "user://business_save.cfg",
	## Personal Deep Mine (grid size, dig state, pending gems, Excavator unlock).
	"deep_mine": "user://deep_mine_save.cfg",
	## Luck level.
	"luck": "user://luck_save.cfg",
	## Which horse-bet / cup-prize payouts were already credited, so a restore
	## can't pay the same winnings twice.
	"horse_bets": "user://horse_bets.cfg",
}

## Files that "Delete All Progress" must NOT touch. The online marketplace
## account (identity, token balance, active listings — all server-side, keyed by
## this local identity file) is intentionally preserved: a local wipe never
## erases online data. Players who want their online account/listings removed
## must contact the developer. These are still included in backup/restore above.
## horse_bets is also kept: it records which server-side bet/cup winnings were
## already credited, so wiping it would pay those winnings out again.
const DELETE_EXEMPT_KEYS := ["marketplace_account", "horse_bets"]


## Produces a Base64 backup code capturing all existing save files.
## Returns "" if nothing could be read.
static func export_code() -> String:
	var files: Dictionary = {}
	for key in SAVE_FILES:
		var path: String = SAVE_FILES[key]
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		files[key] = f.get_as_text()
		f.close()

	if files.is_empty():
		return ""

	var payload := {
		"version": BACKUP_VERSION,
		"created": TrustedClock.now(),
		"files": files,
		"checksum": _checksum(files),
	}
	var raw: PackedByteArray = JSON.stringify(payload).to_utf8_buffer()
	var packed: PackedByteArray = raw.compress(COMPRESSION_MODE)
	return "%s%d:%s" % [COMPRESSED_PREFIX, raw.size(), Marshalls.raw_to_base64(packed)]


## Turns a pasted code back into the JSON text. Handles compressed v3 codes and
## legacy plain-Base64 (v1/v2) codes. Returns "" if it can't be decoded.
static func _decode_to_json(code: String) -> String:
	## Clipboards and chat apps sometimes insert line breaks or spaces.
	var cleaned := code.strip_edges().replace("\n", "").replace("\r", "").replace(" ", "")
	if cleaned.begins_with(COMPRESSED_PREFIX):
		var rest := cleaned.substr(COMPRESSED_PREFIX.length())
		var sep := rest.find(":")
		if sep <= 0:
			return ""
		var size_text := rest.substr(0, sep)
		if not size_text.is_valid_int():
			return ""
		var raw_size := int(size_text)
		if raw_size <= 0 or raw_size > MAX_RAW_SIZE:
			return ""
		var packed: PackedByteArray = Marshalls.base64_to_raw(rest.substr(sep + 1))
		if packed.is_empty():
			return ""
		var raw: PackedByteArray = packed.decompress(raw_size, COMPRESSION_MODE)
		if raw.size() != raw_size:
			return ""
		return raw.get_string_from_utf8()
	## Legacy uncompressed code.
	return Marshalls.base64_to_utf8(cleaned)


## SHA-256 hex digest of the files payload, used to detect a corrupted or
## truncated backup code on import.
static func _checksum(files: Dictionary) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	## Hash the file contents in a stable key order so the digest is reproducible.
	var keys := files.keys()
	keys.sort()
	for key in keys:
		ctx.update(str(key).to_utf8_buffer())
		ctx.update(str(files[key]).to_utf8_buffer())
	return ctx.finish().hex_encode()


## Restores save files from a backup code. Returns "" on success, or a
## human-readable error message on failure. On success the files are written
## but NOT yet loaded — call reload_all_autoloads() afterward.
static func import_code(code: String) -> String:
	var trimmed := code.strip_edges()
	if trimmed.is_empty():
		return "Paste a backup code first."

	var json_text := _decode_to_json(trimmed)
	if json_text == "":
		return "Invalid backup code (could not decode). Make sure the whole code was pasted."

	var parsed = JSON.parse_string(json_text)
	if not (parsed is Dictionary):
		return "Invalid backup code (bad format)."

	var payload: Dictionary = parsed
	var version := int(payload.get("version", 0))
	if version <= 0 or version > BACKUP_VERSION:
		return "Unsupported backup version (%d)." % version

	var files = payload.get("files", null)
	if not (files is Dictionary) or (files as Dictionary).is_empty():
		return "Backup contains no save data."

	## Verify integrity: the embedded checksum must match the files payload.
	var expected := str(payload.get("checksum", ""))
	if expected == "":
		return "Backup code is missing its integrity checksum."
	if _checksum(files) != expected:
		return "Backup code is corrupted (checksum mismatch)."

	## Only accept known keys; ignore anything unexpected.
	var to_write: Dictionary = {}
	for key in files:
		if SAVE_FILES.has(key) and files[key] is String:
			to_write[key] = files[key]

	if to_write.is_empty():
		return "Backup contains no recognizable save data."

	## Write each recognized file. Player save is required to be present.
	if not to_write.has("player"):
		return "Backup is missing the main player save."

	for key in to_write:
		var path: String = SAVE_FILES[key]
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return "Could not write save file: %s" % path
		f.store_string(to_write[key])
		f.close()

	return ""


## Deletes ALL progress by overwriting every save file with a blank template,
## then reloading the autoloads. Each autoload's load_data() reads the empty
## (but valid) ConfigFile and falls back to its defaults, giving a clean slate.
## This avoids file-deletion quirks and guarantees in-memory state is reset.
## Irreversible unless the player has a backup code.
static func delete_all_progress() -> void:
	## Overwrite each save with an empty ConfigFile — EXCEPT the online account
	## identity, which is preserved so a local wipe never touches online data
	## (tokens, listings, account). Includes the Workshop (saw/foundry) save.
	for key in SAVE_FILES:
		if DELETE_EXEMPT_KEYS.has(key):
			continue
		var path: String = SAVE_FILES[key]
		var blank := ConfigFile.new()
		blank.save(path)
	## Clear the transient Android quick-resume state so a stale session can't
	## repopulate anything on the next launch.
	var quick := "user://quick_save.cfg"
	var blank_quick := ConfigFile.new()
	blank_quick.save(quick)
	## Reload local autoloads from the blanked saves. The marketplace account is
	## intentionally left alone (its file was not touched, and we don't reload it)
	## so the player's online identity/tokens/listings remain intact.
	reload_all_autoloads(false)


## Reloads every local-progress autoload from the freshly written save files so
## the running game reflects restored/reset progress without an app restart.
## reload_marketplace: reload the online account identity too. Restore passes
## true (the backup may re-link a different account); delete passes false so the
## online account is never touched by a local wipe.
static func reload_all_autoloads(reload_marketplace: bool = true) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := tree.root if tree else null
	if root == null:
		return
	for name in ["PlayerData", "Garden", "Orchard", "Workshop", "MissionBoard",
			"Achievements", "BusinessDistrict", "DeepMine", "Luck"]:
		var node := root.get_node_or_null(name)
		if node != null and node.has_method("load_data"):
			node.load_data()
	## Horse-bet payout ledger (separate loader; clear first so a restore
	## replaces rather than merges it).
	var horses := root.get_node_or_null("HorseRacing")
	if horses != null and horses.has_method("_load_applied_bets"):
		horses._applied_bet_ids.clear()
		if "_applied_prize_ids" in horses:
			horses._applied_prize_ids.clear()
		horses._load_applied_bets()
	## Marketplace identity uses reload_local() (not load_data()). Only reload it
	## when explicitly requested (restore) — never on a delete wipe.
	if reload_marketplace:
		var market := root.get_node_or_null("MarketplaceAccount")
		if market != null and market.has_method("reload_local"):
			market.reload_local()
