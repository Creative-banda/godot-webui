class_name WebUIExportScan
extends RefCounted
## Finds the UI folders the export plugin packages. Kept apart from the export plugin (which needs
## editor-only classes) so it can be tested.

## Project setting: PackedStringArray of res:// folders to package. Empty = auto-detect.
const SETTING_UI_FOLDERS := "webui/export/ui_folders"
## Top-level folders that are never scanned for UI pages when auto-detecting.
const AUTO_DETECT_SKIP := ["addons", "android", "native"]


## Returns {"folders": Array, "errors": PackedStringArray, "warnings": PackedStringArray}.
static func resolve() -> Dictionary:
	var result := {"folders": [], "errors": PackedStringArray(), "warnings": PackedStringArray()}
	var configured: Variant = ProjectSettings.get_setting(SETTING_UI_FOLDERS, PackedStringArray())
	if typeof(configured) == TYPE_PACKED_STRING_ARRAY and not configured.is_empty():
		for entry in configured:
			var folder: String = entry.strip_edges().trim_suffix("/")
			if not folder.begins_with("res://") or folder == "res://":
				result.errors.append("ignoring invalid entry '%s' in %s (use a res:// sub-folder)" % [entry, SETTING_UI_FOLDERS])
			elif not DirAccess.dir_exists_absolute(folder):
				result.errors.append("folder '%s' listed in %s does not exist" % [folder, SETTING_UI_FOLDERS])
			else:
				result.folders.append(folder)
		return result
	if has_html("res://"):
		result.warnings.append("HTML files in the project root are not packaged automatically (that would package the whole project); move them into a folder")
	_detect("res://", result.folders)
	return result


## Folders that directly contain an HTML file; their whole subtree gets packaged.
static func _detect(dir: String, out: Array) -> void:
	for sub in DirAccess.get_directories_at(dir):
		if sub.begins_with("."):
			continue
		if dir == "res://" and sub in AUTO_DETECT_SKIP:
			continue
		var path := dir.path_join(sub)
		if FileAccess.file_exists(path.path_join(".gdignore")):
			continue  # folders hidden from Godot (docs, samples, tools) are never UI folders
		if has_html(path):
			out.append(path)
		else:
			_detect(path, out)


static func has_html(dir: String) -> bool:
	for file_name in DirAccess.get_files_at(dir):
		if file_name.get_extension().to_lower() in ["html", "htm"]:
			return true
	return false
