class_name WebUISurfacePreview
extends RefCounted
## One world-space page in the DESKTOP DEVELOPMENT PREVIEW. Not a supported platform and not real-time browser rendering.
##
## A hidden godot_wry WebView lays the page out at the surface's size; web/capture.js (the same code the visual editor
## uses) copies the page's DOM into an SVG, draws that into a PNG, and sends it back over the bridge. Godot decodes it and
## that is the surface's frame. So:
##  - it is a SNAPSHOT a few times a second (default 4, a few tens of ms each), not a live video of the page;
##  - CSS animations and transitions are drawn at rest, :hover is not drawn, video/iframes/WebGL are missing, and a few
##    fonts or images may not embed (capture notes are printed once);
##  - taps are synthetic DOM events (web/surface_preview.js), not real touches: pointer/mouse/click handlers run.
## Android draws the real WebView instead (WorldSurface.java). Use the preview to lay out and wire a page, and check the
## final look on a device.
##
## WebUIBackendDesktop owns these and schedules their captures one at a time.

signal message(raw: String)
signal frame_ready
signal failed(code: String, text: String)

const CAPTURE_SCRIPT := "res://addons/webui/web/capture.js"
const TAP_SCRIPT := "res://addons/webui/web/surface_preview.js"
const CAPTURE_TIMEOUT_MSEC := 8000

var id := ""
var page := ""
var size := Vector2i.ZERO
var interval_msec := 250
var active := true
var frames := 0
var rgba := PackedByteArray()
var loaded := false
var capturing := false
var last_request_msec := -100000

var _view: Control
var _chunks := {}
var _notes_printed := false
var _started_msec := 0
var _capture_ms_sum := 0.0
var _last_capture_ms := 0.0
var _scripts := ""


func _init(surface_id: String, surface_page: String, surface_size: Vector2i, fps: int) -> void:
	id = surface_id
	page = surface_page
	size = surface_size
	interval_msec = int(1000.0 / maxf(1.0, float(fps)))


## Creates the hidden view and starts loading `url` (a res:// path inside the staged preview copy of the UI folder).
func open(host: Node, view: Control, url: String) -> bool:
	_scripts = "window.__godotSurface=%s;" % WebUIBackendDesktop._js_quote(id)
	for path: String in [CAPTURE_SCRIPT, TAP_SCRIPT]:
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			failed.emit("inject_failed", "Cannot read %s." % path)
			return false
		_scripts += "\n" + text
	_view = view
	# Properties must be set before the node enters the tree (the native webview is created then). Hidden: nothing is
	# shown on screen and no input reaches it; it only has to lay the page out and be asked for pictures.
	view.set("full_window_size", false)
	view.set("transparent", false)
	view.set("devtools", false)
	view.set("zoom_hotkeys", false)
	view.set("forward_input_events", false)
	view.set("url", "")
	view.set("html", "<!doctype html><html><body></body></html>")
	view.set("data_directory", "user://webui_preview_data_surfaces")
	view.connect("ipc_message", _on_ipc_message)
	view.connect("page_load_finished", _on_loaded)
	host.add_child(view)
	view.size = Vector2(size)
	view.visible = false
	view.call("load_url", url)
	return true


func reload(url: String) -> void:
	if _view == null:
		return
	loaded = false
	capturing = false
	_view.call("load_url", url)


func destroy() -> void:
	if _view and is_instance_valid(_view):
		_view.queue_free()
	_view = null
	loaded = false
	capturing = false
	rgba = PackedByteArray()


func send(event_name: String, json_payload: String) -> void:
	if _view:
		_view.call("eval", "window.Godot&&window.Godot.__receive(%s,%s)" % [WebUIBackendDesktop._js_quote(event_name), WebUIBackendDesktop._js_quote(json_payload)])


func tap(x: float, y: float) -> void:
	if _view and loaded:
		_view.call("eval", "window.__webuiSurfaceTap&&window.__webuiSurfaceTap(%d,%d)" % [roundi(x), roundi(y)])


## Asks the page for a new picture. Returns false if it cannot be asked now (still loading, or one is on its way).
func request_capture() -> bool:
	if _view == null or not loaded or capturing:
		return false
	capturing = true
	_chunks.clear()
	_started_msec = Time.get_ticks_msec()
	last_request_msec = _started_msec
	_view.call("eval", "window.__webuiCapture&&window.__webuiCapture.run(%d,%d)" % [size.x, size.y])
	return true


## True when a requested picture never arrived (the backend then lets the next capture go ahead).
func timed_out(now_msec: int) -> bool:
	return capturing and now_msec - _started_msec > CAPTURE_TIMEOUT_MSEC


func stats() -> Dictionary:
	return {
		"mode": "desktop_preview_snapshot",
		"frames": frames,
		"capture_ms": snappedf(_capture_ms_sum / maxf(1.0, float(frames)), 0.1),
		"last_capture_ms": snappedf(_last_capture_ms, 0.1),
		"interval_ms": interval_msec,
	}


# ---------------------------------------------------------------- the view's callbacks

func _on_loaded(url: String) -> void:
	if url.begins_with("about:"):
		return
	loaded = false
	# Deferred: never call into the web view from inside its own callback.
	_after_load.call_deferred()


func _after_load() -> void:
	if _view == null:
		return
	_view.call("eval", _scripts)
	loaded = true


func _on_ipc_message(raw: String) -> void:
	if raw.begins_with("{\"t\":\"regions\"") or raw.begins_with("{\"t\":\"viewport\""):
		return  # touch regions and the overlay's UI scale mean nothing to a surface
	_handle.call_deferred(raw)


func _handle(raw: String) -> void:
	if _view == null:
		return
	if not raw.contains("\"webui_capture\""):
		if raw.length() <= WebUIBridge.MAX_MESSAGE_CHARS:
			message.emit(raw)
		return
	var msg := WebUIBridge.parse_incoming(raw)
	if not msg.ok or msg.name != "webui_capture":
		return
	var payload: Dictionary = msg.payload
	match payload.get("t"):
		"meta":
			if not _notes_printed:
				_notes_printed = true
				var notes: Array = payload.get("notes", [])
				if not notes.is_empty():
					print("[WebUI preview] surface %s snapshot notes: %s" % [id, "; ".join(PackedStringArray(notes))])
		"chunk":
			_chunks[int(payload.get("n", -1))] = str(payload.get("data", ""))
		"done":
			_finish(int(payload.get("chunks", 0)))
		"error":
			capturing = false
			failed.emit("surface_capture_failed", "surface %s: %s" % [id, str(payload.get("text", "the page could not be drawn"))])


func _finish(count: int) -> void:
	var base64 := ""
	for i in range(count):
		if not _chunks.has(i):
			capturing = false
			failed.emit("surface_capture_failed", "surface %s: the picture arrived incomplete" % id)
			return
		base64 += _chunks[i]
	_chunks.clear()
	var image := Image.new()
	if image.load_png_from_buffer(Marshalls.base64_to_raw(base64)) != OK or image.get_size() != size:
		capturing = false
		failed.emit("surface_capture_failed", "surface %s: the picture was not a valid %dx%d image" % [id, size.x, size.y])
		return
	image.convert(Image.FORMAT_RGBA8)
	rgba = image.get_data()
	_last_capture_ms = float(Time.get_ticks_msec() - _started_msec)
	_capture_ms_sum += _last_capture_ms
	frames += 1
	capturing = false
	frame_ready.emit()
