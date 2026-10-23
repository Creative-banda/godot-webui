@tool
extends EditorExportPlugin
## Android export support for Godot WebUI:
##  - adds the native plugin AAR and its androidx.webkit dependency (Gradle builds),
##  - packages the HTML UI files itself (Godot does not export .html/.css/.js without a manual
##    "non-resource files" filter) together with the bridge script,
##  - reports misconfiguration in the export log (Gradle build off, godot_wry inside the project).
## The desktop preview's godot_wry extension is meant to live OUTSIDE the project: a user export
## plugin cannot stop Godot's built-in GDExtension handling from packaging a copy that is inside it.
## It never changes your export preset; it works through export-time hooks only.

const AAR_DEBUG := "res://addons/webui/bin/WebUI-debug.aar"
const AAR_RELEASE := "res://addons/webui/bin/WebUI-release.aar"
# Must match `webkitVersion` in native/android/webui/build.gradle.
const WEBKIT_DEPENDENCY := "androidx.webkit:webkit:1.12.1"

const BRIDGE_SCRIPT := "res://addons/webui/web/godot.js"
## Development-only content that must never be packaged.
const PREVIEW_ONLY_PREFIXES := ["res://.webui_preview/"]
## Scripts injected into the desktop preview by the visual editor and the WebUIScreen capture program.
const EDITOR_ONLY_FILES := ["res://addons/webui/web/edit_mode.js", "res://addons/webui/web/capture.js"]
const IGNORED_EXTENSIONS := ["import", "uid"]

var _ui_files := {}  # res:// path -> true, for files this plugin adds itself


func _get_name() -> String:
	return "WebUI"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid


func _get_android_libraries(_platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
	var aar := AAR_DEBUG if debug else AAR_RELEASE
	if not FileAccess.file_exists(aar):
		push_error("WebUI: %s is missing. Build it first (see README, 'Building the native plugin')." % aar)
		return PackedStringArray()
	return PackedStringArray([aar])


func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
	return PackedStringArray([WEBKIT_DEPENDENCY])


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_ui_files.clear()
	_check_android_options()

	var scan := WebUIExportScan.resolve()
	for message in scan.errors:
		push_error("WebUI: %s." % message)
	for message in scan.warnings:
		push_warning("WebUI: %s." % message)
	var folders: Array = scan.folders
	var count := 0
	for folder in folders:
		count += _add_folder(folder)
	if _add_raw(BRIDGE_SCRIPT):
		count += 1
	else:
		push_error("WebUI: %s is missing; the overlay cannot start in the exported game." % BRIDGE_SCRIPT)

	if folders.is_empty():
		push_warning("WebUI: no UI folder found to package. Put your .html files in a folder outside res://addons/, or list the folder(s) in Project Settings → %s." % WebUIExportScan.SETTING_UI_FOLDERS)
	else:
		print("WebUI export: packaged %d UI file(s) from %s." % [count, ", ".join(folders)])
	if DirAccess.dir_exists_absolute("res://addons/godot_wry"):
		push_error("WebUI: res://addons/godot_wry is inside the project, so Godot packages its libraries into the export (and fails when the Android ones are missing). Move it out of the project: the desktop preview loads it from a user-level folder instead (see docs/desktop-preview.md).")


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	for prefix in PREVIEW_ONLY_PREFIXES:
		if path.begins_with(prefix):
			skip()
			return
	if path in EDITOR_ONLY_FILES:
		skip()
		return
	# Files this plugin adds as raw copies must not also be exported the normal way (duplicates
	# break APK signing, and imported images/fonts would otherwise be exported only as .ctex etc.).
	if _ui_files.has(path):
		skip()


func _export_end() -> void:
	_ui_files.clear()


# ---------------------------------------------------------------- UI packaging


func _add_folder(folder: String) -> int:
	var count := 0
	for file_name in DirAccess.get_files_at(folder):
		if file_name.get_extension().to_lower() in IGNORED_EXTENSIONS:
			continue
		if _add_raw(folder.path_join(file_name)):
			count += 1
	for sub in DirAccess.get_directories_at(folder):
		if not sub.begins_with(".") and not FileAccess.file_exists(folder.path_join(sub).path_join(".gdignore")):
			count += _add_folder(folder.path_join(sub))
	return count


func _add_raw(path: String) -> bool:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty() and FileAccess.get_open_error() != OK:
		push_error("WebUI: cannot read %s for packaging." % path)
		return false
	add_file(path, bytes, false)
	_ui_files[path] = true
	return true


# ---------------------------------------------------------------- diagnostics

func _check_android_options() -> void:
	var preset := get_export_preset()
	if preset == null or not preset.has("gradle_build/use_gradle_build"):
		return
	if not bool(preset.get("gradle_build/use_gradle_build")):
		push_error("WebUI: this Android preset has 'Use Gradle Build' off, so the native WebUI plugin is NOT included and the overlay will report 'plugin_missing'. Enable Project → Export → Android → Options → Gradle Build → Use Gradle Build (and install the Android build template).")
