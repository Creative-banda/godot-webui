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
	view.set("forward_input_events", true)  # keyboard/mouse also reach the game
	view.set("url", "")
	view.set("html", "<!doctype html><html><body style='background:transparent'></body></html>")
	view.set("data_directory", "user://webui_preview_data")
	view.connect("ipc_message", _on_ipc_message)
	view.connect("page_load_finished", func(url: String) -> void: page_loaded.emit(url))
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


func destroy() -> void:
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
	if raw.length() > WebUIBridge.MAX_MESSAGE_CHARS:
		error.emit("message_too_large", "Ignored page message of %d chars (max %d)." % [raw.length(), WebUIBridge.MAX_MESSAGE_CHARS])
		return
	message.emit(raw)


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
		if _page.is_empty():
			_view.call("reload")
		else:
			_view.call("load_url", STAGE_UI.path_join(_page))
