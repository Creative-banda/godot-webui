class_name GodotWebUISurface
extends RefCounted
## A web page drawn onto a surface in the 3D world (a terminal, a wall screen): the same page API as the overlay, but
## the pixels arrive as a texture instead of covering the screen. Make one with GodotWebUI.create_surface().
##
##   var screen := ui.create_surface("terminal.html", Vector2i(640, 400))
##   $Screen.material_override.albedo_texture = screen.texture
##   screen.on("retry", func(_p): ...)                  # page -> Godot, like GodotWebUI.on()
##   screen.set_state("progress", {"shards": 12})       # Godot -> page, like GodotWebUI.set_state()
##   screen.tap_uv(hit_uv)                              # a tap at a point of the surface (from a raycast)
##
## Android: an off-screen WebView drawn into frames (see WorldSurface.java). Desktop: only in the editor-run development
## preview, as slow snapshots of the page (`is_preview`, see docs/world-space.md). Elsewhere `available` is false, the
## texture stays a plain placeholder and every call is a harmless no-op, so game code does not need to branch.
## Not verified beyond the one device it was measured on; limits are listed in docs/world-space.md.

## The page loaded and its bridge handshake arrived (send initial state here).
signal page_ready
## Every validated page event, in addition to handlers registered with on().
signal event_received(event_name: String, payload: Dictionary)
## A new frame was copied into `texture`.
signal frame_updated
## destroy() ran, or the overlay was shut down; the surface does nothing afterwards.
signal destroyed

const EVENT_PREFIX := "@e:"
const MAX_PENDING_EVENTS := 64

var id := ""
var size := Vector2i.ZERO
## False where the platform cannot draw web pages into textures (everything except an Android build).
var available := false
var is_ready := false
## True in the desktop development preview: the texture is a snapshot of the page a few times a second (animations at
## rest, no :hover, synthetic taps), not the real WebView of Android. Do not judge final look or smoothness from it.
var is_preview := false
## The page as a texture: put it on a material. Updated about `fps` times a second while the surface is active.
var texture: ImageTexture
## Frames received so far.
var frames := 0

var _backend: WebUIBackend
var _handlers := {}
var _pending_state := {}
var _pending_events: Array = []
var _active := true
var _last_frame := -1


func _init(surface_id: String, surface_size: Vector2i, backend: WebUIBackend, is_available: bool) -> void:
	id = surface_id
	size = surface_size
	_backend = backend
	available = is_available
	var placeholder := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	placeholder.fill(Color(0.04, 0.06, 0.12, 1.0))
	texture = ImageTexture.create_from_image(placeholder)


## Registers a handler for a page event (JS: Godot.emit(name, payload)). The handler receives the payload Dictionary.
func on(event_name: String, handler: Callable) -> void:
	if not _handlers.has(event_name):
		_handlers[event_name] = []
	if not _handlers[event_name].has(handler):
		_handlers[event_name].append(handler)


func off(event_name: String, handler: Callable) -> void:
	if _handlers.has(event_name):
		_handlers[event_name].erase(handler)


## Persistent state for the page (JS: Godot.onState(name, fn)); the newest value per name wins and is held until ready.
func set_state(state_name: String, payload: Dictionary) -> void:
	var json := _encode(state_name, payload)
	if json.is_empty():
		return
	if is_ready:
		_backend.surface_send(id, state_name, json)
	else:
		_pending_state[state_name] = json


## One-shot notification for the page (JS: Godot.onEvent(name, fn)); never replayed, up to 64 held until ready.
func emit_event(event_name: String, payload: Dictionary = {}) -> void:
	var json := _encode(event_name, payload)
	if json.is_empty():
		return
	if is_ready:
		_backend.surface_send(id, EVENT_PREFIX + event_name, json)
	elif _pending_events.size() < MAX_PENDING_EVENTS:
		_pending_events.append([event_name, json])


## A tap at `pixel` (page pixels from the top-left, 0..size). The page sees a normal touch: pointerdown, pointerup, click.
func tap(pixel: Vector2) -> void:
	if available:
		_backend.surface_tap(id, clampf(pixel.x, 0.0, size.x - 1.0), clampf(pixel.y, 0.0, size.y - 1.0))


## A tap at `uv` (0..1 across the surface, v from the top), for example from a raycast hit on the screen mesh.
func tap_uv(uv: Vector2) -> void:
	tap(Vector2(uv.x * size.x, uv.y * size.y))


## Stops (or resumes) drawing the page: a screen nobody can see needs no frames. Defaults to active.
func set_active(value: bool) -> void:
	if value == _active:
		return
	_active = value
	if available:
		_backend.surface_set_active(id, value)


func is_active() -> bool:
	return _active


## Timing measured by the native side: {mode, frames, draw_ms, copy_ms, latency_ms, interval_ms}. Empty off Android.
func stats() -> Dictionary:
	if not available:
		return {}
	var parsed: Variant = JSON.parse_string(_backend.surface_stats(id))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func destroy() -> void:
	if available:
		_backend.destroy_surface(id)
	var was_alive := available or is_ready
	available = false
	is_ready = false
	if was_alive:
		destroyed.emit()


# ---------------------------------------------------------------- called by GodotWebUI

func _on_message(raw: String) -> void:
	var msg := WebUIBridge.parse_incoming(raw)
	if not msg.ok:
		return
	if msg.type == "ready":
		_on_ready()
		return
	if msg.name.begins_with("webui."):
		return
	event_received.emit(msg.name, msg.payload)
	for handler: Callable in _handlers.get(msg.name, []):
		if handler.is_valid():
			handler.call(msg.payload)


func _on_ready() -> void:
	is_ready = true
	for name in _pending_state:
		_backend.surface_send(id, name, _pending_state[name])
	_pending_state.clear()
	for pending in _pending_events:
		_backend.surface_send(id, EVENT_PREFIX + pending[0], pending[1])
	_pending_events.clear()
	page_ready.emit()


func _on_frame(frame: int) -> void:
	if frame == _last_frame:
		return
	_last_frame = frame
	var bytes := _backend.surface_read_frame(id)
	if bytes.size() != size.x * size.y * 4:
		return
	texture.update(Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, bytes))
	frames += 1
	frame_updated.emit()


func _encode(message_name: String, payload: Dictionary) -> String:
	if not WebUIBridge.is_valid_name(message_name):
		push_warning("[WebUI] surface %s: invalid message name '%s'." % [id, message_name])
		return ""
	var json := WebUIBridge.encode_payload(payload)
	if json.is_empty():
		push_warning("[WebUI] surface %s: payload for '%s' is not encodable or too large." % [id, message_name])
	return json
