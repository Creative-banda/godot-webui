extends SceneTree
## Run: godot --headless --path . -s res://tests/webui_screen_test.gd
## Covers WebUIScreen and WebUIScreenPreview without an editor or a web view: the node does nothing at
## runtime (no overlay, no input, hidden), reports missing or invalid pages instead of a misleading
## preview, finds its preview in the cache and notices when the page changed since. Exit code = failures.

var failures := 0
const TEMP := "res://tmp_webui_screen_test"
const PAGE_FOR_BLOCK := "res://tmp_webui_screen_test/block.html"


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	await process_frame
	await _test_runtime_is_inert()
	_test_page_problems()
	_test_cache_and_signature()
	await _test_status_from_cache()
	_test_helpers()
	await _test_dock_open_page()
	await _test_inspector_block()
	_remove_tree(TEMP)
	quit(failures)


func _test_runtime_is_inert() -> void:
	var before := _count_nodes(root)
	var screen := WebUIScreen.new()
	screen.page = "res://examples/playable_character/ui/menu.html"
	root.add_child(screen)
	await process_frame
	check(not screen.visible, "at runtime the node hides itself")
	check(screen.mouse_filter == Control.MOUSE_FILTER_IGNORE and screen.focus_mode == Control.FOCUS_NONE, "and never takes input")
	check(not screen.is_processing() and screen.get_child_count() == 0, "it does not process and creates no children")
	check(GodotWebUI._active == null and _count_nodes(root) == before + 1, "it starts no overlay: no GodotWebUI exists")
	check(screen.get_ui_dir() == "res://examples/playable_character/ui" and screen.get_page_file() == "menu.html", "it tells scripts which page belongs to the scene: %s + %s" % [screen.get_ui_dir(), screen.get_page_file()])
	check(not screen.refresh_preview(), "a capture cannot be started outside the editor")
	screen.queue_free()


func _count_nodes(node: Node) -> int:
	var total := 1
	for child in node.get_children():
		total += _count_nodes(child)
	return total


func _test_page_problems() -> void:
	check(WebUIScreenPreview.page_problem("") == "No page assigned.", "no page")
	check(WebUIScreenPreview.page_problem("res://nope/missing.html").begins_with("File not found"), "a missing file is reported, not previewed")
	check(WebUIScreenPreview.page_problem("res://README.md").contains("not an HTML file"), "a non-HTML file is refused")
	check(WebUIScreenPreview.page_problem("C:/x/page.html").contains("res://"), "a path outside the project is refused")
	check(WebUIScreenPreview.page_problem("res://ui/../project.godot.html").contains("res://"), "a path with .. is refused")
	check(WebUIScreenPreview.page_problem("res://examples/playable_character/ui/menu.html") == "", "an existing page is fine")


func _test_cache_and_signature() -> void:
	var a := "res://examples/playable_character/ui/menu.html"
	var b := "res://examples/minimal_hud/ui/menu.html"
	check(WebUIScreenPreview.cache_png(a).begins_with("res://.godot/webui_previews/") and WebUIScreenPreview.cache_png(a).ends_with(".png"), "previews are cached in the editor's .godot folder")
	check(WebUIScreenPreview.cache_png(a) != WebUIScreenPreview.cache_png(b) and WebUIScreenPreview.cache_png(a) == WebUIScreenPreview.cache_png(a), "the cache path is unique per page, even for the same file name")
	check(WebUIScreenPreview.cache_meta(a).get_basename() == WebUIScreenPreview.cache_png(a).get_basename(), "its metadata sits next to it")
	check(WebUIScreenPreview.viewport_size() == Vector2i(int(ProjectSettings.get_setting("display/window/size/viewport_width")), int(ProjectSettings.get_setting("display/window/size/viewport_height"))), "the preview size is the project's viewport, not a fixed resolution")

	DirAccess.make_dir_recursive_absolute(TEMP)
	var page := TEMP.path_join("page.html")
	FileAccess.open(page, FileAccess.WRITE).store_string("<p>hi</p>")
	FileAccess.open(TEMP.path_join("style.css"), FileAccess.WRITE).store_string("p { color: red; }")
	var size := Vector2i(1280, 720)
	var first := WebUIScreenPreview.signature(page, size)
	check(first == WebUIScreenPreview.signature(page, size), "the signature is stable while nothing changes")
	check(first != WebUIScreenPreview.signature(page, Vector2i(800, 600)), "it changes with the preview size")
	FileAccess.open(TEMP.path_join("style.css"), FileAccess.WRITE).store_string("p { color: blue; padding: 4px; }")
	check(first != WebUIScreenPreview.signature(page, size), "it changes when a file of the page changes")
	FileAccess.open(TEMP.path_join("notes.txt"), FileAccess.WRITE).store_string("x")
	var second := WebUIScreenPreview.signature(page, size)
	FileAccess.open(TEMP.path_join("notes.txt"), FileAccess.WRITE).store_string("changed")
	check(second == WebUIScreenPreview.signature(page, size), "but not for files the page cannot use")


func _test_status_from_cache() -> void:
	var page := TEMP.path_join("page.html")
	var size := WebUIScreenPreview.viewport_size()
	var screen := WebUIScreen.new()
	screen.page = page
	root.add_child(screen)
	await process_frame
	screen._reload_preview()
	check(screen.get_status().state == "no_preview" and screen._texture == null, "a page without a preview says so and shows no image")

	DirAccess.make_dir_recursive_absolute(WebUIScreenPreview.CACHE_DIR)
	var image := Image.create(64, 36, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.6, 0.9))
	image.save_png(WebUIScreenPreview.cache_png(page))
	FileAccess.open(WebUIScreenPreview.cache_meta(page), FileAccess.WRITE).store_string(JSON.stringify({"ok": true, "signature": WebUIScreenPreview.signature(page, size), "size": [size.x, size.y], "notes": ["1 video"]}))
	screen._reload_preview()
	check(screen.get_status().state == "fresh" and screen._texture != null and screen._texture.get_size() == Vector2(64, 36), "a cached preview is loaded as a texture")
	check(screen.get_status().notes == ["1 video"], "notes about content that could not be drawn are kept")

	FileAccess.open(TEMP.path_join("style.css"), FileAccess.WRITE).store_string("p { color: green; }")
	screen._check_stale()
	check(screen.get_status().state == "stale", "a changed file marks the preview stale (no capture is started)")
	check(screen._capture_pid == -1, "and nothing was launched")

	FileAccess.open(WebUIScreenPreview.cache_meta(page), FileAccess.WRITE).store_string(JSON.stringify({"ok": false, "error": "boom"}))
	screen._reload_preview()
	check(screen.get_status().state == "no_preview", "a failed capture's leftovers are not shown as a preview")

	var manual := TEMP.path_join("mine.png")
	image.save_png(manual)
	screen.manual_preview = manual
	screen._reload_preview()
	check(screen.get_status().state == "manual" and screen.get_status().text.contains("mine.png"), "a manual preview image is shown and labelled")
	screen.manual_preview = TEMP.path_join("absent.png")
	screen._reload_preview()
	check(screen.get_status().state == "no_preview", "a manual image that does not exist falls back")

	screen.page = ""
	screen._reload_preview()
	check(screen.get_status().state == "no_page" and screen._texture == null and not screen._get_configuration_warnings().is_empty(), "no page: no image, and a configuration warning")
	screen.page = TEMP.path_join("gone.html")
	screen._reload_preview()
	check(screen.get_status().state == "invalid" and screen.get_status().text.begins_with("File not found") and screen._texture == null, "a renamed or deleted page is reported, and the old image is not kept")
	DirAccess.remove_absolute(WebUIScreenPreview.cache_png(page))
	DirAccess.remove_absolute(WebUIScreenPreview.cache_meta(page))
	screen.queue_free()


func _test_helpers() -> void:
	var node := WebUIScreen.new()
	check(not node.show_backdrop, "no backdrop is drawn by default, so a transparent page lets the scene behind it show")
	node.free()
	var fitted := WebUIScreen._fit(Rect2(0, 0, 1000, 500), Vector2(1280, 720))
	check(is_equal_approx(fitted.size.x / fitted.size.y, 1280.0 / 720.0) and is_equal_approx(fitted.size.y, 500.0) and fitted.position.x > 0.0, "the preview keeps its aspect ratio inside the node (letterboxed)")
	check(WebUIScreen._fit(Rect2(0, 0, 640, 360), Vector2(1280, 720)) == Rect2(0, 0, 640, 360), "and fills the node when the ratios match")


func _test_dock_open_page() -> void:
	var model := WebUIEditorModel.new()
	var dock := WebUIEditorDock.new()
	root.add_child(dock)
	dock.setup(model, null, Callable())
	check(dock.open_page("res://nowhere/page.html").contains("not in a UI folder"), "the dock refuses a page outside the UI folders, with the reason")
	var message := dock.open_page("res://examples/minimal_hud/ui/index.html")
	check(message == "" and model.page == "index.html" and model.ui_dir == "res://examples/minimal_hud/ui", "the dock opens the page the node names (%s)" % model.page)
	dock.queue_free()


func _test_inspector_block() -> void:
	DirAccess.make_dir_recursive_absolute(TEMP)  # a page of its own: the demo pages may already have previews in .godot
	FileAccess.open(PAGE_FOR_BLOCK, FileAccess.WRITE).store_string("<p>block</p>")
	var screen := WebUIScreen.new()
	root.add_child(screen)
	await process_frame
	var opened: Array = []
	var block := WebUIScreenInspectorBlock.new()
	block.setup(screen, func(page: String) -> String:
		opened.append(page)
		return "")
	root.add_child(block)
	check(block._status.text == screen.get_status().text and block._edit.disabled and block._refresh.disabled, "the block shows the node's status; without a page both actions are off")
	screen.page = PAGE_FOR_BLOCK
	screen._reload_preview()
	check(not block._edit.disabled and not block._refresh.disabled and block._status.text.begins_with("No preview yet"), "it follows the node when a page is assigned")
	block._on_edit_pressed()
	check(opened == [PAGE_FOR_BLOCK] and not block._feedback.visible, "Edit UI asks the dock to open the node's page")
	var refused := WebUIScreenInspectorBlock.new()
	refused.setup(screen, func(_page: String) -> String: return "not in a UI folder")
	root.add_child(refused)
	refused._on_edit_pressed()
	check(refused._feedback.visible and refused._feedback.text == "not in a UI folder", "a refusal is shown under the buttons")
	# The Inspector rebuilds its controls on every selection change: a freed block must leave nothing connected
	# (a lambda would be called with freed captures: "Lambda capture ... was freed").
	block.free()
	refused.free()
	check(screen.status_changed.get_connections().is_empty(), "a freed block leaves no connection to the node's signal")
	screen.status_changed.emit()
	screen.queue_free()


func _remove_tree(path: String) -> void:
	for sub in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(sub))
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)
