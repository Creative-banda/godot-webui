class_name GodotWebUI
extends Node
## Full-screen HTML/CSS/JS overlay for Godot games.
##
##   var ui := GodotWebUI.new()
##   add_child(ui)
##   ui.on("jump", func(_p): player.jump())
##   ui.page_ready.connect(func(): ui.send("state", {"health": 100}))
##   ui.start("res://ui")            # loads index.html from that folder

enum TouchMode {
	MODAL,    ## the WebView receives every touch
	REGIONS,  ## only elements the page marks (data-webui-touch) receive touches; the rest reach the game
}

## Fired each time the page has loaded and its bridge handshake arrived. Send initial state here.
signal page_ready
## Every validated page event, in addition to handlers registered with on().
signal event_received(event_name: String, payload: Dictionary)
## Native or protocol problems (code is a short identifier, e.g. "blocked_navigation").
signal error(code: String, text: String)
## console.log/warn/error output of the page.
signal console_message(level: String, text: String)
## The app went to the background; stop any held input.
signal suspended

@export var touch_mode: TouchMode = TouchMode.REGIONS

var is_ready := false  ## true once the page's handshake arrived; stays true across reloads (each reload sends a new handshake and page_ready)

var _backend: WebUIBackend
var _handlers := {}          # event name -> Array[Callable]
var _pending := {}           # event name -> JSON payload, held until the page is ready
var _started := false
var _visible := true
var _start_msec := 0


## Loads `page` from `ui_dir` (a res:// folder). Returns false if the overlay could not be created
## (the reason is also emitted through `error`).
func start(ui_dir: String, page: String = "index.html") -> bool:
	if _started:
		push_warning("GodotWebUI.start() called twice; call shutdown() first.")
		return false
	_start_msec = Time.get_ticks_msec()
	_backend = WebUIBackendAndroid.new() if OS.get_name() == "Android" else WebUIBackendNull.new()
	_backend.message.connect(_on_raw_message)
	_backend.error.connect(func(code: String, text: String) -> void: _report(code, text))
	_backend.console.connect(func(level: String, text: String) -> void:
		console_message.emit(level, text)
		print("[WebUI:js:%s] %s" % [level, text]))
	var script := FileAccess.get_file_as_string("res://addons/webui/web/godot.js")
	if script.is_empty():
		_report("missing_script", "res://addons/webui/web/godot.js could not be read.")
		return false
	if not _backend.create(ui_dir, script):
		return false
	_started = true
	_backend.set_touch_mode("regions" if touch_mode == TouchMode.REGIONS else "modal")
	_backend.set_visible(_visible)
	_backend.load_page(page)
	return true


## Navigates the overlay to another page of the same UI folder. State sent before the new page's
## handshake is held and delivered once it is ready; state held for the old page is dropped.
func load_page(page: String) -> void:
	if not _started:
		push_warning("WebUI.load_page() called before a successful start().")
		return
	is_ready = false
	_pending.clear()
	_backend.load_page(page)


## Removes every handler registered with on(). Use when switching pages/screens.
func clear_handlers() -> void:
	_handlers.clear()


## Registers a handler for a page event: handler(payload: Dictionary).
func on(event_name: String, handler: Callable) -> void:
	if not WebUIBridge.is_valid_name(event_name):
		_report("bad_name", "Invalid event name '%s'." % event_name)
		return
	if not _handlers.has(event_name):
		_handlers[event_name] = []
	_handlers[event_name].append(handler)


func off(event_name: String, handler: Callable) -> void:
	if _handlers.has(event_name):
		_handlers[event_name].erase(handler)


## Sends named state to the page (received by Godot.on(name, fn)). Before the page is ready only
## the newest payload per name is kept and delivered when it becomes ready.
func send(event_name: String, payload: Dictionary) -> void:
	if not WebUIBridge.is_valid_name(event_name):
		_report("bad_name", "Invalid event name '%s'." % event_name)
		return
	var json := WebUIBridge.encode_payload(payload)
	if json.is_empty():
		_report("bad_payload", "Payload for '%s' is not encodable or exceeds %d chars." % [event_name, WebUIBridge.MAX_MESSAGE_CHARS])
		return
	if is_ready:
		_backend.send_message(event_name, json)
	else:
		_pending[event_name] = json


func show_ui() -> void:
	_visible = true
	if _started:
		_backend.set_visible(true)


func hide_ui() -> void:
	_visible = false
	if _started:
		_backend.set_visible(false)


func set_touch_mode(mode: TouchMode) -> void:
	touch_mode = mode
	if _started:
		_backend.set_touch_mode("regions" if mode == TouchMode.REGIONS else "modal")


## Removes the overlay and frees native resources. Safe to call repeatedly.
func shutdown() -> void:
	if _backend:
		_backend.destroy()
		_backend = null
	_started = false
	is_ready = false
	_pending.clear()


func _exit_tree() -> void:
	shutdown()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		suspended.emit()


func _on_raw_message(raw: String) -> void:
	var msg := WebUIBridge.parse_incoming(raw)
	if not msg.ok:
		_report("bad_message", "Rejected page message: %s" % msg.error)
		return
	if msg.type == "ready":
		is_ready = true
		print("[WebUI] page ready %d ms after start()" % (Time.get_ticks_msec() - _start_msec))
		for pending_name in _pending:
			_backend.send_message(pending_name, _pending[pending_name])
		_pending.clear()
		page_ready.emit()
		return
	event_received.emit(msg.name, msg.payload)
	for handler: Callable in _handlers.get(msg.name, []):
		if handler.is_valid():
			handler.call(msg.payload)


func _report(code: String, text: String) -> void:
	push_warning("[WebUI] %s: %s" % [code, text])
	error.emit(code, text)
