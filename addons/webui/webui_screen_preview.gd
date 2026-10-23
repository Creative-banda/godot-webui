class_name WebUIScreenPreview
extends RefCounted
## Preview images for WebUIScreen nodes: where they are cached, how to tell that one is out of date, and
## how to start the capture program that makes one. Editor-time helpers only; nothing here runs in a game.
##
## A preview is a PNG of the page rendered by a separate program (see webui_preview_capture.gd), kept in
## res://.godot/webui_previews/ (the editor's own cache folder: never exported, normally git-ignored)
## next to a small JSON file that records what the page looked like it was made from.

const CACHE_DIR := "res://.godot/webui_previews"
const CAPTURE_SCENE := "res://addons/webui/webui_preview_capture.tscn"
## Bumped when the capture code changes in a way that makes older previews wrong.
const CAPTURE_VERSION := 1
const PAGE_ARG := "--webui-capture-page"
const OUT_ARG := "--webui-capture-out"
const SIZE_ARG := "--webui-capture-size"
const SIGNATURE_ARG := "--webui-capture-signature"
const MAX_SIGNATURE_FILES := 800
const TRACKED_EXTENSIONS := ["html", "htm", "css", "js", "json", "svg", "png", "jpg", "jpeg", "webp", "gif", "ttf", "otf", "woff", "woff2"]


## The project's configured game viewport, which is the size a preview is made at.
static func viewport_size() -> Vector2i:
	return Vector2i(int(ProjectSettings.get_setting("display/window/size/viewport_width", 1152)), int(ProjectSettings.get_setting("display/window/size/viewport_height", 648)))


## The UI folder (one of the folders the export plugin would package) that holds `page`, or the page's own folder.
static func ui_dir_for(page: String) -> String:
	var best := ""
	for folder: String in WebUIExportScan.resolve().folders:
		if page.begins_with(folder.path_join("")) and folder.length() > best.length():
			best = folder
	return best if best != "" else page.get_base_dir()


## Why `page` cannot be used, or "" when it is an existing .html file.
static func page_problem(page: String) -> String:
	if page.strip_edges() == "":
		return "No page assigned."
	if not page.begins_with("res://") or page.contains(".."):
		return "The page must be a res:// path (got %s)." % page
	if page.get_extension().to_lower() not in ["html", "htm"]:
		return "%s is not an HTML file." % page
	if not FileAccess.file_exists(page):
		return "File not found: %s" % page
	return ""


## "<page name>-<10 hex digits of the path's hash>": unique per page, readable in the cache folder.
static func cache_key(page: String) -> String:
	return "%s-%s" % [page.get_file().get_basename(), page.sha1_text().left(10)]


static func cache_png(page: String) -> String:
	return CACHE_DIR.path_join(cache_key(page) + ".png")


static func cache_meta(page: String) -> String:
	return CACHE_DIR.path_join(cache_key(page) + ".json")


## What the preview was made from; compare with signature() to see whether the page changed since.
static func read_meta(page: String) -> Dictionary:
	var path := cache_meta(page)
	if not FileAccess.file_exists(path):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if typeof(data) == TYPE_DICTIONARY else {}


## A fingerprint of everything the page is drawn from: the files in its folder (names, sizes, modified
## times), its sample state, the preview size and the capture code version. Cheap enough to compare every
## couple of seconds; it never reads file contents, so an edit that keeps both the size and the modified
## time (to the second) goes unnoticed.
static func signature(page: String, size: Vector2i) -> String:
	var parts := PackedStringArray(["v%d" % CAPTURE_VERSION, "%dx%d" % [size.x, size.y], page])
	var folder := ui_dir_for(page)
	var budget := [MAX_SIGNATURE_FILES]
	_collect(folder, parts, budget)
	var sample := WebUIEditorModel.sample_path(folder, page.trim_prefix(folder.path_join("")))
	if FileAccess.file_exists(sample):
		parts.append("%s:%d" % [sample, FileAccess.get_modified_time(sample)])
	return "\n".join(parts).sha1_text()


static func _collect(dir: String, parts: PackedStringArray, budget: Array) -> void:
	for file_name in DirAccess.get_files_at(dir):
		if budget[0] <= 0:
			return
		if file_name.get_extension().to_lower() in TRACKED_EXTENSIONS:
			budget[0] -= 1
			var path := dir.path_join(file_name)
			var length := 0
			var file := FileAccess.open(path, FileAccess.READ)
			if file != null:
				length = file.get_length()  # a second file edit within one second still changes the size
			parts.append("%s:%d:%d" % [path, FileAccess.get_modified_time(path), length])
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			_collect(dir.path_join(sub), parts, budget)


## The texture for a PNG file, or null when it is missing or not an image.
static func load_texture(png_path: String) -> ImageTexture:
	if not FileAccess.file_exists(png_path):
		return null
	var image := Image.load_from_file(png_path)
	if image == null or image.is_empty():
		return null
	return ImageTexture.create_from_image(image)


## Starts the capture program for `page` and returns its process id (-1 if it could not be started).
## The program writes cache_png(page) and cache_meta(page) and exits; it is a separate Godot process
## because the web view cannot run inside the editor.
static func start_capture(page: String, size: Vector2i) -> int:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var args := PackedStringArray([
		"--path", ProjectSettings.globalize_path("res://"),
		"--position", "-12000,-12000",  # off screen: nothing flashes, the page is drawn by the web view anyway
		"--resolution", "%dx%d" % [size.x, size.y],
		CAPTURE_SCENE, "--",
		PAGE_ARG, page,
		OUT_ARG, ProjectSettings.globalize_path(cache_png(page)),
		SIZE_ARG, "%dx%d" % [size.x, size.y],
		SIGNATURE_ARG, signature(page, size),
	])
	return OS.create_process(OS.get_executable_path(), args)
