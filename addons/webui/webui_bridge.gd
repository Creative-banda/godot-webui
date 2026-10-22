class_name WebUIBridge
extends RefCounted
## Wire protocol between the page and GDScript. Pure functions, no platform code.
##
## Page -> Godot messages are JSON objects:
##   {"t":"ready"}                                         bridge handshake, sent once per page load
##   {"t":"event","name":"jump","payload":{...}}           application event
## Godot -> page messages are (name, payload-as-JSON) pairs handled by native code.

const MAX_MESSAGE_CHARS := 64 * 1024
const MAX_NAME_LENGTH := 64

static var _name_regex: RegEx = null


static func is_valid_name(event_name: Variant) -> bool:
	if typeof(event_name) != TYPE_STRING or event_name.is_empty() or event_name.length() > MAX_NAME_LENGTH:
		return false
	if _name_regex == null:
		_name_regex = RegEx.create_from_string("^[A-Za-z][A-Za-z0-9_.:-]*$")
	return _name_regex.search(event_name) != null


## Returns {"ok": true, "type": "ready"|"event", "name": String, "payload": Dictionary}
## or {"ok": false, "error": String}.
static func parse_incoming(raw: String) -> Dictionary:
	if raw.length() > MAX_MESSAGE_CHARS:
		return _fail("message exceeds %d characters" % MAX_MESSAGE_CHARS)
	var json := JSON.new()
	if json.parse(raw) != OK:
		return _fail("invalid JSON: %s" % json.get_error_message())
	var data: Variant = json.data
	if typeof(data) != TYPE_DICTIONARY:
		return _fail("message must be a JSON object")
	var kind: Variant = data.get("t")
	if kind == "ready":
		return {"ok": true, "type": "ready", "name": "", "payload": {}}
	if kind != "event":
		return _fail("unknown message type '%s'" % str(kind))
	var event_name: Variant = data.get("name")
	if not is_valid_name(event_name):
		return _fail("invalid event name '%s'" % str(event_name))
	var payload: Variant = data.get("payload", {})
	if typeof(payload) != TYPE_DICTIONARY:
		return _fail("payload of '%s' must be an object" % event_name)
	return {"ok": true, "type": "event", "name": event_name, "payload": payload}


## Returns the JSON text for a Godot -> page payload, or "" if it cannot be encoded.
static func encode_payload(payload: Variant) -> String:
	if typeof(payload) != TYPE_DICTIONARY and typeof(payload) != TYPE_ARRAY:
		return ""
	var text := JSON.stringify(payload)
	return text if text.length() <= MAX_MESSAGE_CHARS else ""


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "error": reason}
