class_name WebUIBackendAndroid
extends WebUIBackend
## Talks to the native "WebUI" Android plugin (native/android).

const STAGE_DIR := "user://webui_ui"

var _plugin: Object = null


func get_backend_name() -> String:
	return "android"


func is_available() -> bool:
	return OS.get_name() == "Android" and Engine.has_singleton("WebUI")


func create(ui_dir: String, bridge_script: String, _host: Node = null) -> bool:
	if not is_available():
		error.emit("plugin_missing", "Android plugin 'WebUI' not found. Enable Gradle build and the WebUI export plugin (see README).")
		return false
	if not _stage(ui_dir):
		return false
	_plugin = Engine.get_singleton("WebUI")
	# Native signals may fire on Android's UI thread; deferred connections hop to the main thread.
	_plugin.connect("message", func(raw: String) -> void: message.emit(raw), CONNECT_DEFERRED)
	_plugin.connect("error", func(code: String, text: String) -> void: error.emit(code, text), CONNECT_DEFERRED)
	_plugin.connect("page_loaded", func(url: String) -> void: page_loaded.emit(url), CONNECT_DEFERRED)
	_plugin.connect("console", func(level: String, text: String) -> void: console.emit(level, text), CONNECT_DEFERRED)
	_plugin.create(ProjectSettings.globalize_path(STAGE_DIR), bridge_script)
	return true


func load_page(relative_path: String) -> void:
	if _plugin:
		_plugin.load(relative_path)


func send_message(event_name: String, json_payload: String) -> void:
	if _plugin:
		_plugin.sendMessage(event_name, json_payload)


func set_visible(visible: bool) -> void:
	if _plugin:
		_plugin.setVisible(visible)


func set_touch_mode(mode: String) -> void:
	if _plugin:
		_plugin.setTouchMode(mode)


func destroy() -> void:
	if _plugin:
		_plugin.destroy()
		for sig in ["message", "error", "page_loaded", "console"]:
			for c in _plugin.get_signal_connection_list(sig):
				_plugin.disconnect(sig, c.callable)
		_plugin = null


## Android's WebView cannot read Godot's packed res:// files, so the UI folder is copied to user://.
func _stage(ui_dir: String) -> bool:
	if not DirAccess.dir_exists_absolute(ui_dir):
		error.emit("bad_ui_dir", "UI directory not found: %s. In an exported game this means it was not packaged: the godot-webui export plugin packages every folder (outside addons/) that contains an .html file, or the folders listed in Project Settings > webui/export/ui_folders. Check that the plugin is enabled and read the export log." % ui_dir)
		return false
	if DirAccess.dir_exists_absolute(STAGE_DIR):
		_remove_tree(STAGE_DIR)
	return _copy_tree(ui_dir, STAGE_DIR)


func _copy_tree(from: String, to: String) -> bool:
	DirAccess.make_dir_recursive_absolute(to)
	for file_name in DirAccess.get_files_at(from):
		if file_name.ends_with(".import") or file_name.ends_with(".uid"):
			continue
		var bytes := FileAccess.get_file_as_bytes(from.path_join(file_name))
		if bytes.is_empty() and FileAccess.get_open_error() != OK:
			error.emit("stage_failed", "Cannot read %s: it was not packaged. Keep it inside the UI folder (see Project Settings > webui/export/ui_folders) and export again." % from.path_join(file_name))
			return false
		var out := FileAccess.open(to.path_join(file_name), FileAccess.WRITE)
		if out == null:
			error.emit("stage_failed", "Cannot write %s" % to.path_join(file_name))
			return false
		out.store_buffer(bytes)
	for dir_name in DirAccess.get_directories_at(from):
		if not _copy_tree(from.path_join(dir_name), to.path_join(dir_name)):
			return false
	return true


func _remove_tree(path: String) -> void:
	for dir_name in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(dir_name))
	for file_name in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)
