extends Node
## The program that makes the picture a WebUIScreen node shows in the 2D editor. Started by
## WebUIScreenPreview.start_capture() as a separate Godot process (the web view cannot run inside the
## editor): it opens the page in the desktop preview, off screen, with the page's sample state and
## web/capture.js injected into the preview copy of the page (never the original file), waits for the page
## to settle, lets capture.js draw the page into a PNG, saves it and the metadata in the cache folder and exits.
##
## Command line (after "--"): --webui-capture-page res://... --webui-capture-out <absolute png path>
## --webui-capture-size WxH --webui-capture-signature <hash>. Exit code 0 = a preview was written.

const CAPTURE_SCRIPT := "res://addons/webui/web/capture.js"
const SETTLE_SECONDS := 0.8
const TIMEOUT_SECONDS := 30.0

var _ui: GodotWebUI
var _page := ""
var _out := ""
var _size := Vector2i(1280, 720)
var _signature := ""
var _ui_dir := ""
var _relative := ""
var _chunks := {}
var _notes: Array = []
var _expected := 0
var _finished := false
var _last_error := ""


func _ready() -> void:
	DisplayServer.window_set_title("WebUI preview capture")
	_parse_arguments()
	var problem := WebUIScreenPreview.page_problem(_page)
	if _out == "" or problem != "":
		_finish(false, problem if problem != "" else "missing command line arguments")
		return
	_ui_dir = WebUIScreenPreview.ui_dir_for(_page)
	_relative = _page.trim_prefix(_ui_dir.path_join(""))
	get_tree().create_timer(TIMEOUT_SECONDS).timeout.connect(func() -> void: _finish(false, "timed out waiting for the page"))

	_ui = GodotWebUI.new()
	_ui.desktop_preview_hot_reload = false
	_ui.desktop_preview_devtools = false
	_ui.ui_reference_size = 0.0  # the picture is made at the editor's own size: the page must lay out at 1 CSS px = 1 px here
	_ui.desktop_preview_inject_scripts = PackedStringArray([CAPTURE_SCRIPT])
	add_child(_ui)
	_ui.error.connect(_on_ui_error)
	_ui.on("webui_capture", _on_capture_message)
	_ui.page_ready.connect(func() -> void: _after_ready.call_deferred())  # never call into the web view from inside its own callback
	if not _ui.start(_ui_dir, _relative):
		_finish(false, _describe(_last_error) if _last_error != "" else "the page could not be opened")


func _parse_arguments() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			WebUIScreenPreview.PAGE_ARG:
				_page = args[i + 1]
			WebUIScreenPreview.OUT_ARG:
				_out = args[i + 1]
			WebUIScreenPreview.SIGNATURE_ARG:
				_signature = args[i + 1]
			WebUIScreenPreview.SIZE_ARG:
				var parts := args[i + 1].split("x")
				if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
					_size = Vector2i(int(parts[0]), int(parts[1]))


func _on_ui_error(code: String, text: String) -> void:
	_last_error = code
	if code in ["desktop_preview_missing_dependency", "desktop_preview_load_failed", "desktop_preview_needs_restart", "desktop_preview_incompatible"]:
		_finish(false, _describe(code))
	elif code in ["load_failed", "bad_ui_dir", "stage_failed"]:
		_finish(false, "%s: %s" % [code, text])


static func _describe(code: String) -> String:
	if code.begins_with("desktop_preview"):
		return "the desktop preview dependency (godot_wry) is not available (%s). Run: python tools/setup.py wry" % code
	return code


## After the page's handshake: give it the sample state, let fonts and images settle, then ask for the picture.
func _after_ready() -> void:
	if _finished:
		return
	_push_sample()
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	if not _finished:
		_ui.emit_event("webui_capture_run", {"w": _size.x, "h": _size.y})


func _push_sample() -> void:
	var path := WebUIEditorModel.sample_path(_ui_dir, _relative)
	if not FileAccess.file_exists(path):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY:
		return
	var states: Variant = data.get("states", {})
	if typeof(states) == TYPE_DICTIONARY:
		for state_name: String in states:
			if typeof(states[state_name]) == TYPE_DICTIONARY:
				_ui.set_state(state_name, states[state_name])
	var events: Variant = data.get("events", [])
	if typeof(events) == TYPE_ARRAY:
		for event: Variant in events:
			if typeof(event) == TYPE_DICTIONARY and typeof(event.get("name")) == TYPE_STRING:
				_ui.emit_event(event.name, event.get("payload", {}) if typeof(event.get("payload", {})) == TYPE_DICTIONARY else {})


func _on_capture_message(payload: Dictionary) -> void:
	match payload.get("t"):
		"meta":
			_notes = payload.get("notes", [])
		"chunk":
			_chunks[int(payload.get("n", -1))] = str(payload.get("data", ""))
		"done":
			_expected = int(payload.get("chunks", 0))
			_save.call_deferred()
		"error":
			_finish(false, str(payload.get("text", "the page could not be drawn")))


func _save() -> void:
	var base64 := ""
	for i in range(_expected):
		if not _chunks.has(i):
			_finish(false, "the picture arrived incomplete")
			return
		base64 += _chunks[i]
	var bytes := Marshalls.base64_to_raw(base64)
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK or image.get_size() != _size:
		_finish(false, "the picture was not a valid %dx%d image" % [_size.x, _size.y])
		return
	DirAccess.make_dir_recursive_absolute(_out.get_base_dir())
	var temp := _out + ".tmp"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		_finish(false, "cannot write %s" % temp)
		return
	file.store_buffer(bytes)
	file.close()
	if DirAccess.rename_absolute(temp, _out) != OK:
		DirAccess.remove_absolute(_out)
		if DirAccess.rename_absolute(temp, _out) != OK:
			_finish(false, "cannot write %s" % _out)
			return
	_finish(true, "")


## Writes the result next to the picture (the editor reads it when this process ends) and exits.
func _finish(ok: bool, error: String) -> void:
	if _finished:
		return
	_finished = true
	var meta := {"ok": ok, "error": error, "page": _page, "signature": _signature, "size": [_size.x, _size.y],
			"notes": _notes, "captured": Time.get_unix_time_from_system(), "version": WebUIScreenPreview.CAPTURE_VERSION}
	if _out != "":
		DirAccess.make_dir_recursive_absolute(_out.get_base_dir())
		var meta_path := _out.get_basename() + ".json"
		var file := FileAccess.open(meta_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(meta))
			file.close()
	if not ok:
		printerr("WebUI preview capture failed: ", error)
	get_tree().quit(0 if ok else 1)
