class_name WebUIBackendDesktop
extends WebUIBackend
## Desktop DEVELOPMENT PREVIEW backend. It is not a supported runtime platform: it exists so a
## developer can press F5/F6 in the Godot editor and iterate on the HTML UI without exporting.
##
## It drives the `WebView` node of the optional godot_wry extension (not bundled, see
## docs/desktop-preview.md). That node is a native OS webview child window covering the game
## window, always on top. Differences from the Android overlay are listed in the docs.
##
## The extension is meant to live OUTSIDE the project (a user-level folder or $GODOT_WEBUI_WRY) and
## is loaded at run time with GDExtensionManager, so it can never end up in an export.
##
## How the UI reaches the webview:
##  - The godot_wry node cannot inject a script before page scripts run, and it serves `res://`
##    only. So the UI folder is copied to res://.webui_preview/ui with godot.js inlined into every
##    HTML file, and the webview navigates there. Editing the source files re-copies and reloads.
##  - page -> Godot: window.ipc.postMessage(string) -> `ipc_message` signal (godot.js adapts to it).
##  - Godot -> page: eval() calling window.Godot.__receive(name, json), as on Android.

const DEPENDENCY_CLASS := "WebView"
const STAGE_ROOT := "res://.webui_preview"
const STAGE_UI := "res://.webui_preview/ui"
const POLL_SECONDS := 0.5
const EXTENSION_FILE := "WRY.gdextension"
const ENV_VAR := "GODOT_WEBUI_WRY"
const GLOBAL_SUBDIR := "godot_webui/godot_wry"
const MAX_UI_SCALE := 4.0  # same cap as the Android plugin
const MAX_SURFACES := 8  # same cap as the Android plugin
const SURFACE_TICK_SECONDS := 0.05

## Tests inject a stand-in for the godot_wry node here. Returns a Control with the WebView API.
var view_factory := Callable()

var _host: Node
var _view: Control
var _timer: Timer
var _ui_dir := ""
var _script := ""
var _extra_scripts: Array[String] = []
var _page := ""
var _mtimes := {}
var _hold_reload := false
var _modal_note_shown := false
var _ui_reference := 720.0
var _zoom := 1.0  # page zoom applied to the webview = the UI scale
var _surfaces := {}  # surface id -> WebUISurfacePreview
var _surface_timer: Timer
var _overlay_loaded := false  # the overlay's page finished loading: only then may more webviews be created
var _waiting_surfaces: Array = []  # surfaces created before that, opened afterwards


func get_backend_name() -> String:
	return "desktop_preview"


func is_available() -> bool:
	return view_factory.is_valid() or _class_ready()


static func _class_ready() -> bool:
	return ClassDB.class_exists(DEPENDENCY_CLASS) \
			and ClassDB.can_instantiate(DEPENDENCY_CLASS) \
			and ClassDB.is_parent_class(DEPENDENCY_CLASS, "Control")


## Where the godot_wry .gdextension is looked for when the class is not already available.
static func candidate_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	var env := OS.get_environment(ENV_VAR)
	if not env.is_empty():
		paths.append(env if env.get_extension() == "gdextension" else env.path_join(EXTENSION_FILE))
	paths.append(OS.get_data_dir().path_join(GLOBAL_SUBDIR).path_join(EXTENSION_FILE))
	# The engine's data dir can differ for portable ("self-contained") editors; also try the OS's own.
	for base: String in [OS.get_environment("APPDATA"), OS.get_environment("XDG_DATA_HOME")]:
		if not base.is_empty():
			var extra: String = base.replace("\\", "/").path_join(GLOBAL_SUBDIR).path_join(EXTENSION_FILE)
			if not paths.has(extra):
				paths.append(extra)
	return paths


static func install_hint() -> String:
	return "Desktop preview needs the optional godot_wry extension (class 'WebView', Godot 4.7+). Install it OUTSIDE your project so exports are unaffected: put the contents of the zip's addons/godot_wry folder into '%s' (or point the %s environment variable at that folder), then restart the game. See docs/desktop-preview.md." % [OS.get_data_dir().path_join(GLOBAL_SUBDIR), ENV_VAR]


## Loads godot_wry from outside the project if its class is not registered yet.
## Returns {} on success or {"code": ..., "text": ...}.
static func _load_dependency() -> Dictionary:
	if _class_ready():
		return {}
	var tried := PackedStringArray()
	for path in candidate_paths():
		if not FileAccess.file_exists(path):
			var probe := FileAccess.open(path, FileAccess.READ)
			tried.append("%s [not found by this process; open error %d, engine data dir '%s']" % [path, FileAccess.get_open_error(), OS.get_data_dir()])
			if probe:
				probe.close()
			continue
		tried.append(path)
		var status := GDExtensionManager.load_extension(path)
		if status == GDExtensionManager.LOAD_STATUS_NEEDS_RESTART:
			return {"code": "desktop_preview_needs_restart", "text": "godot_wry at '%s' needs an editor restart to load." % path}
		if status == GDExtensionManager.LOAD_STATUS_FAILED:
			return {"code": "desktop_preview_load_failed", "text": "Godot could not load the godot_wry extension at '%s' (it needs Godot 4.7+ and the library for this OS next to it)." % path}
		if _class_ready():
			return {}
		return {"code": "desktop_preview_incompatible", "text": "Loaded '%s' but no instantiable Control class '%s' appeared; it is not the godot_wry WebView." % [path, DEPENDENCY_CLASS]}
	return {"code": "desktop_preview_missing_dependency", "text": "%s (looked in: %s)" % [install_hint(), ", ".join(tried)]}


func create(ui_dir: String, bridge_script: String, host: Node = null) -> bool:
	if host == null or not host.is_inside_tree():
		error.emit("desktop_preview_no_host", "Add the GodotWebUI node to the scene tree before calling start().")
		return false
	if not view_factory.is_valid():
		var failure := _load_dependency()
		if not failure.is_empty():
			error.emit(failure.code, failure.text)
			return false
	_host = host
	_ui_dir = ui_dir
	_ui_reference = float(options.get("ui_reference", 720.0))
	_script = bridge_script
	_extra_scripts.clear()
	for extra_path: String in options.get("inject_scripts", PackedStringArray()):
		var extra := FileAccess.get_file_as_string(extra_path)
		if extra.is_empty():
			error.emit("inject_failed", "Cannot read the injected script %s." % extra_path)
			return false
		_extra_scripts.append(extra)
	if not _stage():
		return false

	var view: Control = view_factory.call() if view_factory.is_valid() else ClassDB.instantiate(DEPENDENCY_CLASS)
	# Properties must be set before the node enters the tree (the native webview is created then).
	view.set("full_window_size", true)
	view.set("transparent", true)
	view.set("devtools", bool(options.get("devtools", true)))
	view.set("zoom_hotkeys", false)  # the preview zoom is the UI scale, not the user's
	view.set("forward_input_events", true)  # keyboard/mouse also reach the game
	view.set("url", "")
	view.set("html", "<!doctype html><html><body style='background:transparent'></body></html>")
	view.set("data_directory", "user://webui_preview_data")
	view.connect("ipc_message", _on_ipc_message)
	view.connect("page_load_finished", func(url: String) -> void:
		_publish_ui_scale()  # a new document starts at 1x
		if not url.begins_with("about:") and not _overlay_loaded:
			_overlay_loaded = true
			_open_waiting_surfaces.call_deferred()
		page_loaded.emit(url))
	host.add_child(view)
	_view = view

	if bool(options.get("hot_reload", true)):
		_timer = Timer.new()
		_timer.wait_time = POLL_SECONDS
		_timer.timeout.connect(_poll_sources)
		host.add_child(_timer)
		_timer.start()
	if OS.get_name() == "Linux":
		push_warning("[WebUI preview] Linux webviews do not support transparency; the page will cover the game unless the page background is opaque by design.")
	print("[WebUI preview] Desktop development preview (godot_wry). Not Android: no touch, region pass-through or lifecycle events.")
	return true


func load_page(relative_path: String) -> void:
	if _view == null:
		return
	if relative_path.is_empty() or relative_path.begins_with("/") or relative_path.contains("..") or relative_path.contains(":"):
		error.emit("bad_path", "Invalid UI path: %s" % relative_path)
		return
	_page = relative_path
	_view.call("load_url", STAGE_UI.path_join(relative_path))


func send_message(event_name: String, json_payload: String) -> void:
	if _view == null:
		return
	_view.call("eval", "window.Godot&&window.Godot.__receive(%s,%s)" % [_js_quote(event_name), _js_quote(json_payload)])


func set_visible(visible: bool) -> void:
	if _view:
		_view.visible = visible


func set_touch_mode(mode: String) -> void:
	# The webview always takes mouse input in its whole area (and forwards it to the game too).
	if mode == "regions" and not _modal_note_shown:
		_modal_note_shown = true
		print("[WebUI preview] Touch pass-through ('regions') is not emulated on desktop: clicks reach both the page and the game.")


func set_ui_scale_reference(css_pixels: float) -> void:
	_ui_reference = css_pixels
	if _view:
		_view.call_deferred("eval", "window.dispatchEvent(new Event('resize'))")  # the page answers with its size


func destroy() -> void:
	_waiting_surfaces.clear()
	for surface_id: String in _surfaces.keys():
		destroy_surface(surface_id)
	if _surface_timer:
		_surface_timer.queue_free()
		_surface_timer = null
	if _timer:
		_timer.stop()
		_timer.queue_free()
		_timer = null
	if _view:
		_view.queue_free()
		_view = null
	_host = null


# ---------------------------------------------------------------- messages

func _on_ipc_message(raw: String) -> void:
	# Android consumes touch-region reports natively; the preview has nothing to do with them.
	if raw.begins_with("{\"t\":\"regions\""):
		return
	if raw.begins_with("{\"t\":\"viewport\""):
		_on_viewport(raw)
		return
	if raw.length() > WebUIBridge.MAX_MESSAGE_CHARS:
		error.emit("message_too_large", "Ignored page message of %d chars (max %d)." % [raw.length(), WebUIBridge.MAX_MESSAGE_CHARS])
		return
	message.emit(raw)


## The page reports its size; the preview answers with the page zoom that gives the same layout space as on
## Android (see ui_scale_for). devicePixelRatio * innerWidth is the window in physical pixels at any zoom, and
## devicePixelRatio / zoom is the OS scale, so the answer does not depend on the zoom already applied.
func _on_viewport(raw: String) -> void:
	var data: Variant = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		return
	var w: Variant = data.get("w")
	var h: Variant = data.get("h")
	var dpr: Variant = data.get("dpr")
	if typeof(w) not in [TYPE_INT, TYPE_FLOAT] or typeof(h) not in [TYPE_INT, TYPE_FLOAT] or typeof(dpr) not in [TYPE_INT, TYPE_FLOAT]:
		return
	if w <= 0 or h <= 0 or dpr <= 0:
		return
	var os_scale: float = float(dpr) / _zoom
	var short_css: float = minf(float(w), float(h)) * float(dpr) / os_scale
	var wanted := ui_scale_for(short_css, _ui_reference)
	if absf(wanted - _zoom) < 0.02:
		return
	_zoom = wanted
	_publish_ui_scale()


## Same rule as the Android plugin: below the reference nothing changes; above it the page scales in proportion.
static func ui_scale_for(short_side_css: float, reference: float) -> float:
	if reference <= 0.0:
		return 1.0
	return clampf(short_side_css / reference, 1.0, MAX_UI_SCALE)


func _publish_ui_scale() -> void:
	if _view == null:
		return
	# Deferred: this runs inside the extension's own callbacks (see the re-entrancy note at the top of this file).
	_view.call_deferred("zoom", _zoom)
	_view.call_deferred("eval", "window.Godot&&window.Godot.__uiScale(%s)" % str(_zoom))


## JSON.stringify yields a valid JS string literal except for the raw U+2028/2029 separators.
static func _js_quote(text: String) -> String:
	return JSON.stringify(text).replace(char(0x2028), "\\u2028").replace(char(0x2029), "\\u2029")


# ---------------------------------------------------------------- staging and hot reload

func _stage() -> bool:
	if not DirAccess.dir_exists_absolute(_ui_dir):
		error.emit("bad_ui_dir", "UI directory not found: %s" % _ui_dir)
		return false
	if DirAccess.dir_exists_absolute(STAGE_UI):
		_remove_tree(STAGE_UI)
	if DirAccess.make_dir_recursive_absolute(STAGE_UI) != OK:
		error.emit("stage_failed", "Cannot create %s (the project folder must be writable when running from the editor)." % STAGE_UI)
		return false
	var marker := FileAccess.open(STAGE_ROOT.path_join(".gdignore"), FileAccess.WRITE)  # keep the editor from importing the copy
	if marker:
		marker.close()
	if not _copy_tree(_ui_dir, STAGE_UI):
		return false
	_mtimes = _scan(_ui_dir)
	return true


func _copy_tree(from: String, to: String) -> bool:
	DirAccess.make_dir_recursive_absolute(to)
	for file_name in DirAccess.get_files_at(from):
		if file_name.ends_with(".import") or file_name.ends_with(".uid"):
			continue
		var src := from.path_join(file_name)
		var bytes := FileAccess.get_file_as_bytes(src)
		if bytes.is_empty() and FileAccess.get_open_error() != OK:
			error.emit("stage_failed", "Cannot read %s" % src)
			return false
		if file_name.get_extension().to_lower() in ["html", "htm"]:
			bytes = _inject_bridge(bytes.get_string_from_utf8()).to_utf8_buffer()
		var out := FileAccess.open(to.path_join(file_name), FileAccess.WRITE)
		if out == null:
			error.emit("stage_failed", "Cannot write %s" % to.path_join(file_name))
			return false
		out.store_buffer(bytes)
		out.close()
	for dir_name in DirAccess.get_directories_at(from):
		if not _copy_tree(from.path_join(dir_name), to.path_join(dir_name)):
			return false
	return true


## Inlines godot.js right at the start of <head> so window.Godot exists before any page script.
func _inject_bridge(html: String) -> String:
	var tag := "<script>" + _script.replace("</script", "<\\/script") + "</script>"
	for extra: String in _extra_scripts:  # separate tags: a broken extra script cannot break godot.js
		tag += "<script>" + extra.replace("</script", "<\\/script") + "</script>"
	var head := RegEx.create_from_string("(?i)<head[^>]*>").search(html)
	if head:
		return html.insert(head.get_end(), tag)
	var root := RegEx.create_from_string("(?i)<html[^>]*>").search(html)
	if root:
		return html.insert(root.get_end(), tag)
	return tag + html


func _remove_tree(path: String) -> void:
	for dir_name in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(dir_name))
	for file_name in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)


## path -> modified time for every UI source file.
func _scan(dir: String) -> Dictionary:
	var result := {}
	for file_name in DirAccess.get_files_at(dir):
		if file_name.ends_with(".import") or file_name.ends_with(".uid"):
			continue
		var path := dir.path_join(file_name)
		result[path] = FileAccess.get_modified_time(path)
	for dir_name in DirAccess.get_directories_at(dir):
		result.merge(_scan(dir.path_join(dir_name)))
	return result


## Pauses hot reload (the visual editor does this while it writes a stylesheet that the page already shows).
func hold_reload(hold: bool) -> void:
	_hold_reload = hold


## Treats the current source files as already shown, so hot reload does not fire for them.
func sync_baseline() -> void:
	_mtimes = _scan(_ui_dir)


## Re-stages the sources and reloads the current page now.
func reload_now() -> void:
	if _view and _stage():
		_mtimes = _scan(_ui_dir)
		_reload_surfaces()
		if _page.is_empty():
			_view.call("reload")
		else:
			_view.call("load_url", STAGE_UI.path_join(_page))


func _poll_sources() -> void:
	if _hold_reload:
		return
	var now := _scan(_ui_dir)
	if now == _mtimes:
		return
	if _stage() and _view:
		print("[WebUI preview] UI files changed; reloading.")
		_reload_surfaces()
		if _page.is_empty():
			_view.call("reload")
		else:
			_view.call("load_url", STAGE_UI.path_join(_page))


# ---------------------------------------------------------------- world-space pages (snapshot preview)

func supports_surfaces() -> bool:
	return _view != null


func surface_is_preview() -> bool:
	return true


func create_surface(surface_id: String, page: String, size: Vector2i, fps: int) -> bool:
	if _view == null or _host == null or not _host.is_inside_tree():
		error.emit("surface_no_overlay", "create_surface() needs the overlay to be started first.")
		return false
	if page.is_empty() or page.begins_with("/") or page.contains("..") or page.contains(":"):
		error.emit("bad_path", "Invalid UI path: %s" % page)
		return false
	if not FileAccess.file_exists(STAGE_UI.path_join(page)):
		error.emit("bad_path", "Page '%s' was not found in the UI folder %s." % [page, _ui_dir])
		return false
	if _surfaces.has(surface_id):
		error.emit("surface_bad_id", "Duplicate surface id: %s" % surface_id)
		return false
	if _surfaces.size() >= MAX_SURFACES:
		error.emit("surface_limit", "At most %d world-space pages can exist at once; destroy one first." % MAX_SURFACES)
		return false
	if size.x < 64 or size.y < 64 or size.x > 2048 or size.y > 2048:
		error.emit("surface_bad_size", "Surface size must be 64..2048 pixels, got %dx%d" % [size.x, size.y])
		return false
	var preview_fps := clampi(int(options.get("surface_preview_fps", 4)), 1, 10)
	var surface := WebUISurfacePreview.new(surface_id, page, size, mini(clampi(fps, 1, 30), preview_fps))
	surface.message.connect(func(raw: String) -> void: surface_message.emit(surface_id, raw))
	surface.frame_ready.connect(func() -> void: surface_frame.emit(surface_id, surface.frames))
	surface.failed.connect(func(code: String, text: String) -> void: error.emit(code, text))
	_surfaces[surface_id] = surface
	if _overlay_loaded:
		_open_surface(surface)
	else:
		# The extension cannot create a second webview while the first one is still loading (it panics), so the
		# surface waits for the overlay's page.
		_waiting_surfaces.append(surface)
	if _surfaces.size() == 1:
		print("[WebUI preview] World-space pages are drawn as snapshots (about %d per second, shared between surfaces), not live. Animations are drawn at rest and taps are synthetic events. Android draws the real page." % preview_fps)
	return true


func _open_waiting_surfaces() -> void:
	var waiting := _waiting_surfaces.duplicate()
	_waiting_surfaces.clear()
	for surface: WebUISurfacePreview in waiting:
		if _surfaces.get(surface.id) == surface:
			_open_surface(surface)


func _open_surface(surface: WebUISurfacePreview) -> void:
	if _host == null or not _host.is_inside_tree():
		return
	var view: Control = view_factory.call() if view_factory.is_valid() else ClassDB.instantiate(DEPENDENCY_CLASS)
	if not surface.open(_host, view, STAGE_UI.path_join(surface.page)):
		view.free()
		return
	if _surface_timer == null:
		_surface_timer = Timer.new()
		_surface_timer.wait_time = SURFACE_TICK_SECONDS
		_surface_timer.timeout.connect(_surface_tick)
		_host.add_child(_surface_timer)
		_surface_timer.start()


func destroy_surface(surface_id: String) -> void:
	var surface: WebUISurfacePreview = _surfaces.get(surface_id)
	if surface == null:
		return
	_surfaces.erase(surface_id)
	_waiting_surfaces.erase(surface)
	surface.destroy()
	if _surfaces.is_empty() and _surface_timer:
		_surface_timer.queue_free()
		_surface_timer = null


func surface_send(surface_id: String, event_name: String, json_payload: String) -> void:
	var surface: WebUISurfacePreview = _surfaces.get(surface_id)
	if surface:
		surface.send(event_name, json_payload)


func surface_tap(surface_id: String, x: float, y: float) -> void:
	var surface: WebUISurfacePreview = _surfaces.get(surface_id)
	if surface:
		surface.tap(x, y)


func surface_set_active(surface_id: String, active: bool) -> void:
	var surface: WebUISurfacePreview = _surfaces.get(surface_id)
	if surface:
		surface.active = active


func surface_read_frame(surface_id: String) -> PackedByteArray:
	var surface: WebUISurfacePreview = _surfaces.get(surface_id)
	return surface.rgba if surface else PackedByteArray()


func surface_stats(surface_id: String) -> String:
	var surface: WebUISurfacePreview = _surfaces.get(surface_id)
	return JSON.stringify(surface.stats()) if surface else "{}"


## One picture at a time across all surfaces: the most overdue active surface goes first, so many surfaces share the
## budget instead of stacking up work.
func _surface_tick() -> void:
	var now := Time.get_ticks_msec()
	var best: WebUISurfacePreview
	for surface: WebUISurfacePreview in _surfaces.values():
		if surface.timed_out(now):
			surface.capturing = false  # lost: let the next one through
		if surface.capturing:
			return
		if not surface.active or not surface.loaded or now - surface.last_request_msec < surface.interval_msec:
			continue
		if best == null or surface.last_request_msec < best.last_request_msec:
			best = surface
	if best:
		best.request_capture()


func _reload_surfaces() -> void:
	for surface: WebUISurfacePreview in _surfaces.values():
		surface.reload(STAGE_UI.path_join(surface.page))
