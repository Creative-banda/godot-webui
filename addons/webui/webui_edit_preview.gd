class_name WebUIEditPreview
extends Node
## Runs one UI page in the desktop development preview with the visual editor's edit mode injected
## (web/edit_mode.js), and relays edit-mode messages to and from the Godot editor.
##
## The editor starts this scene as its own program (see WebUIEditLink) and says which page to open by
## writing TARGET_FILE ({"ui_dir": "res://ui", "page": "menu.html"}) first. It is a development aid
## like the rest of the desktop preview: Android never sees edit mode, because the script is injected
## only into the preview's staged copy.
##
## Messages are dictionaries with an "op", one JSON object per line over a TCP connection to the
## editor (the port comes from the command line, see WebUIEditLink):
##   page -> editor   the page's edit-mode messages (selected, cleared, apply_result, ready) and
##                    {"op": "preview_opened", "ui_dir", "page"} / {"op": "preview_error", ...}
##   editor -> page   "config", "apply", "add_rule", "remove_rule", "apply_text", "apply_attr", "select", "enable"
##   editor -> here   "sample" (the sample game state to show the page), "page" {"page"} (show another page
##                    of the same folder), "hold" (pause hot reload),
##                    "synced" (the page already shows the files just written: resume hot reload
##                    without reloading), "reload" (re-stage and reload)
## The page side uses the normal bridge event "webui_edit", so nothing in the addon's public API
## changes. When the editor goes away the preview closes itself.

const EDIT_SCRIPT := "res://addons/webui/web/edit_mode.js"
const TARGET_FILE := "user://webui_edit_target.json"
const EVENT := "webui_edit"
const PORT_ARG := "--webui-edit-port"
## Commands for the page edit mode; the others are handled here, on the desktop backend.
const PAGE_OPS := ["config", "apply", "add_rule", "remove_rule", "apply_text", "apply_attr", "select", "enable"]
const BACKEND_OPS := ["hold", "synced", "reload"]
const MAX_OUTBOX := 64

## Everything the page's edit mode reports (selected, cleared, apply_result, ready).
signal edit_message(payload: Dictionary)

## Set false before adding the node to the tree to open a page yourself with open() (tests).
var auto_open := true

var ui: GodotWebUI

var _client: StreamPeerTCP
var _was_connected := false
var _buffer := ""
var _outbox: Array = []
var _sample := {}   # {"states": {name: {...}}, "events": [{"name", "payload"}]} shown to the page in place of a game


func _ready() -> void:
	# The preview is a window beside the editor: keep it above the editor while you work in the dock,
	# so clicking there does not bury the page you are editing.
	get_window().always_on_top = true
	_connect_to_editor()
	if auto_open:
		var target := read_target()
		if target.is_empty():
			push_error("WebUI edit preview: no target. Write %s first ({\"ui_dir\": ..., \"page\": ...})." % TARGET_FILE)
			return
		open(target.ui_dir, target.page)


## Opens `page` of `ui_dir` with edit mode. Returns false (and reports through push_error) on failure.
func open(ui_dir: String, page: String) -> bool:
	if ui != null:
		push_error("WebUI edit preview: already open.")
		return false
	ui = GodotWebUI.new()
	# Hot reload stays on so files edited elsewhere show up; the editor pauses it around its own saves.
	ui.desktop_preview_inject_scripts = PackedStringArray([EDIT_SCRIPT])
	add_child(ui)
	ui.error.connect(func(code: String, text: String) -> void:
		push_error("WebUI edit preview %s: %s" % [code, text])
		_to_editor({"op": "preview_error", "code": code, "text": text}))
	ui.on(EVENT, _on_page_message)
	ui.page_ready.connect(_push_sample)  # on every load, so a reloaded page gets its sample state again
	if not ui.start(ui_dir, page):
		return false
	_to_editor({"op": "preview_opened", "ui_dir": ui_dir, "page": page})
	return true


## Sends an edit-mode command to the page ({"op": "apply" | "select" | "enable", ...}).
func send_edit(payload: Dictionary) -> void:
	if ui != null and ui.is_started() and typeof(payload.get("op")) == TYPE_STRING and payload.op in PAGE_OPS:
		ui.emit_event(EVENT, payload)


## Gives the page the sample state in place of the game's: set_state for each state, emit_event for each
## event, exactly as GDScript would. Names and payloads were checked by the editor; GodotWebUI checks again.
func _push_sample() -> void:
	if ui == null or not ui.is_started():
		return
	var states: Variant = _sample.get("states", {})
	if typeof(states) == TYPE_DICTIONARY:
		for state_name: String in states:
			if typeof(states[state_name]) == TYPE_DICTIONARY:
				ui.set_state(state_name, states[state_name])
	var events: Variant = _sample.get("events", [])
	if typeof(events) == TYPE_ARRAY:
		for event: Variant in events:
			if typeof(event) == TYPE_DICTIONARY and typeof(event.get("name")) == TYPE_STRING:
				ui.emit_event(event.name, event.get("payload", {}) if typeof(event.get("payload", {})) == TYPE_DICTIONARY else {})


## hold / synced / reload on the desktop backend (see the header).
func backend_op(op: String) -> void:
	var backend: Variant = ui._backend if ui != null else null
	if not backend is WebUIBackendDesktop:
		return
	match op:
		"hold":
			backend.hold_reload(true)
		"synced":
			backend.sync_baseline()
			backend.hold_reload(false)
		"reload":
			backend.hold_reload(false)
			backend.reload_now()


## {"ui_dir", "page"} from TARGET_FILE, or {} when it is missing or malformed.
static func read_target() -> Dictionary:
	if not FileAccess.file_exists(TARGET_FILE):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(TARGET_FILE))
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("ui_dir")) != TYPE_STRING or typeof(data.get("page")) != TYPE_STRING:
		return {}
	return data


static func write_target(ui_dir: String, page: String) -> Error:
	var file := FileAccess.open(TARGET_FILE, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({"ui_dir": ui_dir, "page": page}))
	return OK


func _on_page_message(payload: Dictionary) -> void:
	if typeof(payload.get("op")) != TYPE_STRING:
		return
	edit_message.emit(payload)
	_to_editor(payload)


# ---------------------------------------------------------------- link to the editor

func _connect_to_editor() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find(PORT_ARG)
	if at < 0 or at + 1 >= args.size() or not args[at + 1].is_valid_int():
		return  # run by hand or by a test: no editor to talk to
	_client = StreamPeerTCP.new()
	if _client.connect_to_host("127.0.0.1", int(args[at + 1])) != OK:
		_client = null


func _process(_delta: float) -> void:
	if _client == null:
		return
	_client.poll()
	match _client.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			_was_connected = true
			for payload: Dictionary in _outbox:
				_write(payload)
			_outbox.clear()
			var available := _client.get_available_bytes()
			if available > 0:
				_buffer += _client.get_utf8_string(available)
				_drain()
		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			_client = null
			if _was_connected:
				get_tree().quit()  # the editor closed: nothing left to edit for


func _to_editor(payload: Dictionary) -> void:
	if _client == null:
		return
	if _client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_write(payload)
	elif _outbox.size() < MAX_OUTBOX:
		_outbox.append(payload)


func _write(payload: Dictionary) -> void:
	_client.put_data((JSON.stringify(payload) + "\n").to_utf8_buffer())


func _drain() -> void:
	while true:
		var newline := _buffer.find("\n")
		if newline < 0:
			return
		var line := _buffer.substr(0, newline)
		_buffer = _buffer.substr(newline + 1)
		var data: Variant = JSON.parse_string(line)
		if typeof(data) == TYPE_DICTIONARY and typeof(data.get("op")) == TYPE_STRING and typeof(data.get("payload")) == TYPE_DICTIONARY:
			_on_editor_message(data.op, data.payload)


## A command from the editor.
func _on_editor_message(op: String, payload: Dictionary) -> void:
	if op == "sample":
		_sample = payload
		_push_sample()
	elif op == "page" and typeof(payload.get("page")) == TYPE_STRING and ui != null and ui.is_started():
		_sample = {}  # belonged to the previous page; the editor sends the new page's once it is ready
		ui.load_page(payload.page)
		_to_editor({"op": "preview_opened", "ui_dir": ui._ui_dir, "page": payload.page})
	elif op in BACKEND_OPS:
		backend_op(op)
	elif op in PAGE_OPS:
		var command := payload.duplicate()
		command["op"] = op
		send_edit(command)
