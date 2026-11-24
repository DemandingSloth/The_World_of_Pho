extends Node

## Autoload: SupabaseClient
## Thin networking layer for the online player marketplace. Wraps HTTPRequest
## with a serial request queue, JSON encode/decode, timeout + error handling,
## and an online/offline status signal.
##
## Config (URL + publishable key) comes from SupabaseConfigDefaults, a committed
## script that always ships in exports. Only the client-safe publishable key
## lives there; the secret/service_role key must NEVER be in the client.
##
## Usage:
##   var res := await SupabaseClient.request_json("GET", "/rest/v1/", {})
##   if res.ok: use res.data  else: show res.error
##
## Results are plain Dictionaries: { ok: bool, status: int, data: Variant, error: String }

const REQUEST_TIMEOUT := 15.0  ## seconds per request

## Emitted after any request completes, reflecting reachability. UI can gate the
## online tab on this. true = last request reached the server; false = offline.
signal online_status_changed(online: bool)

var _url: String = ""
var _anon_key: String = ""
var _http: HTTPRequest = null

## Serial queue: only one in-flight request at a time (Supabase calls are cheap
## and this keeps ordering + error handling simple). Each entry is a Dictionary
## describing the request plus a resume Callable.
var _queue: Array = []
var _busy := false

## Cached reachability from the most recent completed request. null = unknown yet.
var _online: Variant = null


func _ready() -> void:
	_load_config()
	_http = HTTPRequest.new()
	_http.timeout = REQUEST_TIMEOUT
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)


## ── Config ──────────────────────────────────────────────────────

func _load_config() -> void:
	## Single source of truth: the committed SupabaseConfigDefaults script, which
	## Godot always packs into every export (unlike a loose .cfg). Only the
	## publishable/anon key lives here — it's client-safe by design; security is
	## enforced server-side by Row Level Security.
	_url = SupabaseConfigDefaults.URL.strip_edges().rstrip("/")
	_anon_key = SupabaseConfigDefaults.ANON_KEY.strip_edges()
	if _url == "" or _anon_key == "":
		push_warning("SupabaseClient: URL/key not set in SupabaseConfigDefaults.")


## True if a URL + key are configured (does not imply reachability).
func is_configured() -> bool:
	return _url != "" and _anon_key != ""


## Last known reachability. Returns false until a request has succeeded at least
## once. Use for gating UI; it reflects the most recent request's outcome.
func is_online() -> bool:
	return _online == true


## Debug-only: short description of what config actually loaded, for diagnosing
## packaging issues on device (e.g. "url=set key=set" vs "url=EMPTY key=EMPTY").
func debug_status() -> String:
	var url_state := "set(%d)" % _url.length() if _url != "" else "EMPTY"
	var key_state := "set(%d)" % _anon_key.length() if _anon_key != "" else "EMPTY"
	return "url=%s key=%s" % [url_state, key_state]


## ── Public API ──────────────────────────────────────────────────

## Lightweight connectivity check. Uses the Auth health endpoint, which accepts
## the publishable/anon key and doesn't require any tables to exist. (The REST
## root /rest/v1/ can reject the newer sb_publishable_ keys, so we avoid it.)
func ping() -> Dictionary:
	return await request_json("GET", "/auth/v1/health", {})


## Performs an async JSON request. `path` is appended to the project URL (start
## with "/"). `body` is JSON-encoded for non-GET requests. `extra_headers` may
## add per-call headers (e.g. Prefer). Returns:
##   { ok: bool, status: int, data: Variant, error: String }
## Await this call. Requests are queued and run one at a time.
func request_json(method: String, path: String, body: Variant = null, extra_headers: Array = []) -> Dictionary:
	if not is_configured():
		return {"ok": false, "status": 0, "data": null,
			"error": "Marketplace not configured (SupabaseConfigDefaults empty)."}

	## Suspend until this request's turn comes up and it completes.
	var entry := {
		"method": method,
		"path": path,
		"body": body,
		"extra_headers": extra_headers,
		"result": {},
		"done": false,
	}
	_queue.append(entry)
	_pump()
	## Busy-wait cooperatively on the SceneTree until this entry finishes.
	while not entry["done"]:
		await get_tree().process_frame
	return entry["result"]


## ── Internal request pump ───────────────────────────────────────

var _active: Dictionary = {}

func _pump() -> void:
	if _busy or _queue.is_empty():
		return
	_busy = true
	_active = _queue.pop_front()

	var headers := PackedStringArray([
		"apikey: %s" % _anon_key,
		"Authorization: Bearer %s" % _anon_key,
		"Content-Type: application/json",
		"Accept: application/json",
	])
	for h in _active.get("extra_headers", []):
		headers.append(str(h))

	var method_enum := _method_enum(str(_active["method"]))
	var body_str := ""
	if _active.get("body") != null:
		body_str = JSON.stringify(_active["body"])

	var full_url: String = _url + str(_active["path"])
	var err := _http.request(full_url, headers, method_enum, body_str)
	if err != OK:
		## Couldn't even start the request (bad URL, busy, etc.).
		_finish_active({
			"ok": false, "status": 0, "data": null,
			"error": "Request could not be started (err %d)." % err,
		}, false)


func _on_request_completed(result: int, status: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _active.is_empty():
		return

	## Transport-level failure (no connection, timeout, DNS, etc.).
	if result != HTTPRequest.RESULT_SUCCESS:
		_finish_active({
			"ok": false, "status": 0, "data": null,
			"error": "Network error (result %d). Check your connection." % result,
		}, false)
		return

	## Parse JSON body (may be empty for some 2xx responses).
	var text := body.get_string_from_utf8()
	var parsed: Variant = null
	if text.strip_edges() != "":
		var json := JSON.new()
		if json.parse(text) == OK:
			parsed = json.data
		else:
			## Reached the server but got non-JSON — still "online".
			_finish_active({
				"ok": false, "status": status, "data": text,
				"error": "Server returned invalid JSON (status %d)." % status,
			}, true)
			return

	var ok := status >= 200 and status < 300
	var error_msg := ""
	if not ok:
		## Supabase errors are usually JSON with a message/hint.
		if parsed is Dictionary:
			error_msg = str(parsed.get("message", parsed.get("error", "Request failed (%d)." % status)))
		else:
			error_msg = "Request failed (status %d)." % status

	_finish_active({
		"ok": ok, "status": status, "data": parsed, "error": error_msg,
	}, true)


## Completes the active request: stores its result, updates online status, frees
## the pump, and starts the next queued request. `reached_server` updates the
## online/offline signal.
func _finish_active(result: Dictionary, reached_server: bool) -> void:
	var entry := _active
	_active = {}
	_busy = false

	if not entry.is_empty():
		entry["result"] = result
		entry["done"] = true

	_set_online(reached_server)

	## Process the next queued request (deferred to avoid deep recursion).
	if not _queue.is_empty():
		call_deferred("_pump")


func _set_online(online: bool) -> void:
	if _online != online:
		_online = online
		online_status_changed.emit(online)


func _method_enum(method: String) -> int:
	match method.to_upper():
		"GET": return HTTPClient.METHOD_GET
		"POST": return HTTPClient.METHOD_POST
		"PUT": return HTTPClient.METHOD_PUT
		"PATCH": return HTTPClient.METHOD_PATCH
		"DELETE": return HTTPClient.METHOD_DELETE
		_: return HTTPClient.METHOD_GET
