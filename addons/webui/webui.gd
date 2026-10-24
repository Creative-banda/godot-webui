class_name GodotWebUI
extends Node
## Full-screen HTML/CSS/JS overlay for Godot games.
##
##   var ui := GodotWebUI.new()
##   add_child(ui)
##   ui.on("jump", func(_p): player.jump())                      # page -> Godot
##   ui.page_ready.connect(func(): ui.set_state("hud", {"health": 100}))
##   ui.start("res://ui")                                         # loads index.html from that folder
##
## Godot -> page has two kinds of message:
##   set_state(name, payload)   persistent value. The newest one wins, and the page's
##                              Godot.onState(name, fn) also receives the latest value when it
##                              subscribes late or the page reloads and you resend it.
##   emit_event(name, payload)  one-shot notification (a toast, a hit flash). Delivered in order,
##                              never replayed; the page listens with Godot.onEvent(name, fn).

enum TouchMode {
	MODAL,    ## the overlay receives every touch
	REGIONS,  ## only elements the page marks (data-webui-touch) receive touches; the rest reach the game
	AUTO,     ## MODAL until the page calls Godot.touchRegions(), then REGIONS (default)
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
## The overlay was re-created after the WebView renderer died. Best effort, see the README.
signal recovered
## The Android Back button was pressed and the page did not use it (no Godot.onBack handler returned true,
## or the page did not answer in time). Only emitted when handle_back_button is on. Decide what Back does here:
## pause, go to the previous scene, ask to quit, or get_tree().quit().
signal back_requested

const MAX_PENDING_EVENTS := 64
const EVENT_PREFIX := "@e:"           # internal marker the page-side bridge uses for events
const INTERNAL_PREFIX := "webui."     # page -> Godot events reserved for the addon itself
const BACK_TIMEOUT_SEC := 0.3       # how long the page has to answer a Back request
const MAX_RECOVERIES := 3
const RECOVERY_WINDOW_MSEC := 60000

## Default TouchMode.AUTO: pages work out of the box and opt in to pass-through explicitly.
@export var touch_mode: TouchMode = TouchMode.AUTO
## Desktop preview only (ignored on Android): reload the page when UI files change.
@export var desktop_preview_hot_reload := true
## Desktop preview only: allow opening the browser inspector (F12 / right click).
@export var desktop_preview_devtools := true
## Desktop preview only (ignored on Android): extra scripts (res:// paths) inlined after godot.js into
## the preview copy of every page. Used by the visual editor's edit mode; leave empty otherwise.
@export var desktop_preview_inject_scripts := PackedStringArray()

## Take over the Android Back button instead of letting Godot quit the game. While true (and started), Back is
## offered to the page first (Godot.onBack) and then reported through back_requested. Turning it off, or
## shutdown(), restores SceneTree.quit_on_go_back. Default false: Back quits the app as before.
@export var handle_back_button := false:
	set(value):
		handle_back_button = value
		_apply_back_setting()

var is_ready := false  ## true once the page's handshake arrived; stays true across reloads (each reload sends a new handshake and page_ready)

## Only one overlay can exist at a time (the native plugin owns a single WebView).
static var _active: GodotWebUI = null
## Test hook: when valid, returns the WebUIBackend to use instead of the platform one.
static var _backend_factory := Callable()

var _backend: WebUIBackend
var _handlers := {}          # event name -> Array[Callable]
var _pending_state := {}     # name -> JSON, newest wins, held until the page is ready
var _pending_events: Array = []  # [name, JSON] in order, held until the page is ready
var _state_cache := {}       # name -> JSON of every set_state, used to restore a recovered overlay
var _started := false
var _visible := true
var _start_msec := 0
var _ui_dir := ""
var _page := ""
var _regions_opted_in := false
var _page_serial := 0
var _recovering := false
var _recovery_times: Array = []
var _back_overridden := false
var _back_previous_quit := true
var _back_pending := false
var _back_serial := 0


## Loads `page` from `ui_dir` (a res:// folder). Returns false if the overlay could not be created
## (the reason is also emitted through `error`).
func start(ui_dir: String, page: String = "index.html") -> bool:
	if _started:
		push_warning("GodotWebUI.start() called twice; call shutdown() first.")
		return false
	if is_instance_valid(_active) and _active != self and _active._started:
		_report("overlay_already_active", "Another GodotWebUI overlay is already running; only one is supported at a time. Call shutdown() on it first.")
		return false
	_start_msec = Time.get_ticks_msec()
	_ui_dir = ui_dir
	_page = page
	_backend = _backend_factory.call() if _backend_factory.is_valid() else WebUIBackendFactory.create_backend()
	_backend.options = {
		"hot_reload": desktop_preview_hot_reload,
		"devtools": desktop_preview_devtools,
		"inject_scripts": desktop_preview_inject_scripts,
	}
	_backend.message.connect(_on_raw_message)
	_backend.error.connect(_on_backend_error)
	_backend.console.connect(func(level: String, text: String) -> void:
		console_message.emit(level, text)
		print("[WebUI:js:%s] %s" % [level, text]))
	var script := FileAccess.get_file_as_string("res://addons/webui/web/godot.js")
	if script.is_empty():
		_report("missing_script", "res://addons/webui/web/godot.js could not be read. In an exported game this means the godot-webui plugin was not enabled at export time (its export plugin packages this file); enable it under Project Settings > Plugins and export again.")
		return false
	if not _backend.create(ui_dir, script, self):
		return false
	_started = true
	_active = self
	_apply_back_setting()
	_regions_opted_in = false
	_backend.set_touch_mode(_native_touch_mode())
	_backend.set_visible(_visible)
	_backend.load_page(page)
	return true


func is_started() -> bool:
	return _started


## "android", "desktop_preview" or "none" (not started or no backend). The desktop preview is a
## development aid for running from the Godot editor, not an Android-equivalent runtime.
func get_backend_name() -> String:
	return _backend.get_backend_name() if _backend else "none"


## Navigates the overlay to another page of the same UI folder. State and events sent before the new
## page's handshake are held and delivered once it is ready; those held for the old page are dropped.
func load_page(page: String) -> void:
	if not _started:
		push_warning("GodotWebUI.load_page() called before a successful start().")
		return
	_page = page
	is_ready = false
	_pending_state.clear()
	_pending_events.clear()
	_page_serial += 1
	_regions_opted_in = false  # each page opts in again
	_start_msec = Time.get_ticks_msec()
	_backend.set_touch_mode(_native_touch_mode())
	_backend.load_page(page)


## Removes every handler registered with on(). Use when switching pages/screens.
func clear_handlers() -> void:
	_handlers.clear()


## Registers a handler for a page event: handler(payload: Dictionary).
func on(event_name: String, handler: Callable) -> void:
	if not WebUIBridge.is_valid_name(event_name):
		_report("bad_name", "Invalid event name '%s'." % event_name)
		return
	if event_name.begins_with(INTERNAL_PREFIX):
		_report("bad_name", "Event names starting with '%s' are reserved." % INTERNAL_PREFIX)
		return
	if not _handlers.has(event_name):
		_handlers[event_name] = []
	_handlers[event_name].append(handler)


func off(event_name: String, handler: Callable) -> void:
	if _handlers.has(event_name):
		_handlers[event_name].erase(handler)


## Persistent state for the page (JS: Godot.onState(name, fn)). The newest payload per name wins and
## is what late subscribers receive. Before the page is ready it is held and delivered on ready.
func set_state(state_name: String, payload: Dictionary) -> void:
	var json := _encode(state_name, payload)
	if json.is_empty():
		return
	_state_cache[state_name] = json
	if is_ready:
		_backend.send_message(state_name, json)
	else:
		_pending_state[state_name] = json


## One-shot notification for the page (JS: Godot.onEvent(name, fn)). Delivered in order and never
## replayed. Before the page is ready (or while a page is loading) up to 64 are held.
func emit_event(event_name: String, payload: Dictionary = {}) -> void:
	var json := _encode(event_name, payload)
	if json.is_empty():
		return
	if is_ready:
		_backend.send_message(EVENT_PREFIX + event_name, json)
	elif _pending_events.size() < MAX_PENDING_EVENTS:
		_pending_events.append([event_name, json])
	else:
		_report("event_queue_full", "Dropped event '%s': more than %d events queued while the page loads." % [event_name, MAX_PENDING_EVENTS])


## Deprecated alias of set_state(), kept so existing projects keep working.
func send(state_name: String, payload: Dictionary) -> void:
	set_state(state_name, payload)


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
		_backend.set_touch_mode(_native_touch_mode())


## Removes the overlay and frees native resources. Safe to call repeatedly.
func shutdown() -> void:
	if _backend:
		_backend.destroy()
		_backend = null
	if _active == self:
		_active = null
	_started = false
	_apply_back_setting()
	_back_pending = false
	is_ready = false
	_regions_opted_in = false
	_pending_state.clear()
	_pending_events.clear()


func _exit_tree() -> void:
	shutdown()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		suspended.emit()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST and handle_back_button and _started:
		_ask_page_back()


## Offers the Back press to the page; back_requested follows if the page does not use it.
func _ask_page_back() -> void:
	if not is_ready or not _visible:
		back_requested.emit()
		return
	_back_serial += 1
	var serial := _back_serial
	_back_pending = true
	emit_event("webui.back")
	await get_tree().create_timer(BACK_TIMEOUT_SEC, true, false, true).timeout
	if is_instance_valid(self) and _back_pending and serial == _back_serial:
		_back_pending = false  # the page did not answer: do not leave the player stuck
		back_requested.emit()


func _apply_back_setting() -> void:
	if not is_inside_tree():
		return
	var tree := get_tree()
	var want := handle_back_button and _started
	if want and not _back_overridden:
		_back_previous_quit = tree.quit_on_go_back
		tree.quit_on_go_back = false
		_back_overridden = true
	elif not want and _back_overridden:
		tree.quit_on_go_back = _back_previous_quit
		_back_overridden = false


# ---------------------------------------------------------------- internals

func _encode(message_name: String, payload: Dictionary) -> String:
	if not WebUIBridge.is_valid_name(message_name):
		_report("bad_name", "Invalid message name '%s'." % message_name)
		return ""
	var json := WebUIBridge.encode_payload(payload)
	if json.is_empty():
		_report("bad_payload", "Payload for '%s' is not encodable or exceeds %d chars." % [message_name, WebUIBridge.MAX_MESSAGE_CHARS])
	return json


func _native_touch_mode() -> String:
	match touch_mode:
		TouchMode.MODAL:
			return "modal"
		TouchMode.REGIONS:
			return "regions"
	return "regions" if _regions_opted_in else "modal"


func _on_raw_message(raw: String) -> void:
	var msg := WebUIBridge.parse_incoming(raw)
	if not msg.ok:
		_report("bad_message", "Rejected page message: %s" % msg.error)
		return
	if msg.type == "ready":
		_on_page_ready()
		return
	if msg.name.begins_with(INTERNAL_PREFIX):
		_on_internal_event(msg.name)
		return
	event_received.emit(msg.name, msg.payload)
	for handler: Callable in _handlers.get(msg.name, []):
		if handler.is_valid():
			handler.call(msg.payload)


func _on_page_ready() -> void:
	is_ready = true
	print("[WebUI] page ready %d ms after start()/load_page()" % (Time.get_ticks_msec() - _start_msec))
	if _recovering:
		for state_name in _state_cache:
			_pending_state[state_name] = _state_cache[state_name]
	for pending_name in _pending_state:
		_backend.send_message(pending_name, _pending_state[pending_name])
	_pending_state.clear()
	for pending in _pending_events:
		_backend.send_message(EVENT_PREFIX + pending[0], pending[1])
	_pending_events.clear()
	page_ready.emit()
	if _recovering:
		_recovering = false
		recovered.emit()
	_watch_touch_regions()


## Internal page -> addon events (names start with "webui."). Unknown ones are ignored so newer
## pages keep working with an older addon.
func _on_internal_event(internal_name: String) -> void:
	if internal_name == "webui.back_handled":
		_back_pending = false
		return
	if internal_name == "webui.back_unhandled":
		if _back_pending:
			_back_pending = false
			back_requested.emit()
		return
	if internal_name == "webui.touch_regions":
		_regions_opted_in = true
		if _started and touch_mode == TouchMode.AUTO:
			_backend.set_touch_mode(_native_touch_mode())


## With TouchMode.REGIONS forced, a page that never calls Godot.touchRegions() has nothing touchable.
func _watch_touch_regions() -> void:
	if touch_mode != TouchMode.REGIONS or not is_inside_tree():
		return
	var serial := _page_serial
	await get_tree().create_timer(3.0).timeout
	if is_instance_valid(self) and _started and serial == _page_serial and not _regions_opted_in:
		_report("touch_regions_missing", "TouchMode.REGIONS is set but page '%s' never called Godot.touchRegions(), so no area receives touches. Call it from the page, or use TouchMode.AUTO / MODAL." % _page)


func _on_backend_error(code: String, text: String) -> void:
	_report(code, text)
	if code == "render_process_gone":
		_recover.call_deferred()


## Best effort: the native layer reports a dead WebView renderer and has already removed the view.
## Re-create the overlay on the same page and restore the state sent so far. Limited to a few
## attempts per minute; not verified on a device.
func _recover() -> void:
	if not _started or _recovering:
		return
	var now := Time.get_ticks_msec()
	_recovery_times = _recovery_times.filter(func(t: int) -> bool: return now - t < RECOVERY_WINDOW_MSEC)
	if _recovery_times.size() >= MAX_RECOVERIES:
		_report("recovery_failed", "The WebView renderer died %d times within a minute; not restarting it again." % MAX_RECOVERIES)
		return
	_recovery_times.append(now)
	var ui_dir := _ui_dir
	var page := _page
	var cache := _state_cache.duplicate()
	shutdown()
	_state_cache = cache
	_recovering = true
	if not start(ui_dir, page):
		_recovering = false
		_report("recovery_failed", "Could not re-create the overlay after the WebView renderer died.")


func _report(code: String, text: String) -> void:
	push_warning("[WebUI] %s: %s" % [code, text])
	error.emit(code, text)
