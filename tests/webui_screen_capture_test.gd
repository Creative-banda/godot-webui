extends SceneTree
## Run: godot --headless --path . -s res://tests/webui_screen_capture_test.gd
## Runs the real capture program (a separate Godot process with an off-screen web view) on demo pages and
## checks the pictures it makes. Needs the optional godot_wry preview dependency; skips (exit 0) without it.
## The test itself needs no window. Exit code = number of failures.

var failures := 0
const KEEP_DIR_ENV := "WEBUI_CAPTURE_TEST_KEEP"


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	if not WebUIBackendDesktop._load_dependency().is_empty():
		print("SKIP  godot_wry is not installed")
		quit(0)
		return
	await process_frame
	await _capture_demo("res://examples/playable_character/ui/hud.html", true)
	await _capture_demo("res://examples/playable_character/ui/menu.html", false)
	await _capture_failure()
	quit(failures)


## Runs the capture for `page` and waits for it. Returns the metadata, or {} on a timeout.
func _run(page: String) -> Dictionary:
	var size := WebUIScreenPreview.viewport_size()
	DirAccess.remove_absolute(WebUIScreenPreview.cache_meta(page))
	DirAccess.remove_absolute(WebUIScreenPreview.cache_png(page))
	var started := Time.get_ticks_msec()
	var pid := WebUIScreenPreview.start_capture(page, size)
	check(pid > 0, "the capture program starts for %s" % page.get_file())
	if pid <= 0:
		return {}
	while OS.is_process_running(pid):
		await create_timer(0.25).timeout
		if Time.get_ticks_msec() - started > 60000:
			OS.kill(pid)
			check(false, "the capture finished within 60 s")
			return {}
	print("      capture of %s took %d ms" % [page.get_file(), Time.get_ticks_msec() - started])
	return WebUIScreenPreview.read_meta(page)


func _capture_demo(page: String, with_sample: bool) -> void:
	var size := WebUIScreenPreview.viewport_size()
	var meta := await _run(page)
	check(meta.get("ok", false), "%s: the capture reports success (%s)" % [page.get_file(), meta.get("error", "")])
	if not meta.get("ok", false):
		return
	var image := Image.load_from_file(WebUIScreenPreview.cache_png(page))
	check(image != null and image.get_size() == size, "%s: the picture has the project viewport size %s" % [page.get_file(), size])
	check(str(meta.signature) == WebUIScreenPreview.signature(page, size), "the metadata records what the page was made from, so it is fresh until a file changes")
	var drawn := _count_drawn(image)
	check(drawn > 2000, "%s: the picture is not blank (%d drawn pixels)" % [page.get_file(), drawn])
	if with_sample:
		# the glass panels at the top corners and the joystick bottom left are drawn
		check(_alpha_at(image, 60, 40) > 0.1 and _alpha_at(image, 1170, 80) > 0.1 and _alpha_at(image, 130, 590) > 0.05, "the HUD's health panel, telemetry panel and joystick are in their places")
		check(_alpha_at(image, 640, 360) < 0.05, "the transparent page stays transparent where it has nothing")
	else:
		check(meta.notes is Array, "notes about what could not be drawn are recorded: %s" % [meta.notes])
	var keep := OS.get_environment(KEEP_DIR_ENV)
	if keep != "":
		image.save_png(keep.path_join(page.get_file().get_basename() + "_preview.png"))
	DirAccess.remove_absolute(WebUIScreenPreview.cache_png(page))
	DirAccess.remove_absolute(WebUIScreenPreview.cache_meta(page))


func _capture_failure() -> void:
	var page := "res://tmp_capture_missing/none.html"
	var size := WebUIScreenPreview.viewport_size()
	DirAccess.make_dir_recursive_absolute(WebUIScreenPreview.CACHE_DIR)
	var pid := WebUIScreenPreview.start_capture(page, size)
	var started := Time.get_ticks_msec()
	while OS.is_process_running(pid) and Time.get_ticks_msec() - started < 30000:
		await create_timer(0.25).timeout
	var meta := WebUIScreenPreview.read_meta(page)
	check(not meta.is_empty() and not meta.ok and str(meta.error).begins_with("File not found"), "a page that does not exist ends the capture with a clear error: %s" % meta.get("error", ""))
	check(not FileAccess.file_exists(WebUIScreenPreview.cache_png(page)), "and leaves no picture behind")
	DirAccess.remove_absolute(WebUIScreenPreview.cache_meta(page))


static func _count_drawn(image: Image) -> int:
	var count := 0
	for y in range(0, image.get_height(), 2):
		for x in range(0, image.get_width(), 2):
			if image.get_pixel(x, y).a > 0.02:
				count += 1
	return count


static func _alpha_at(image: Image, x: int, y: int) -> float:
	var best := 0.0
	for dy in range(-6, 7, 2):
		for dx in range(-6, 7, 2):
			best = maxf(best, image.get_pixel(clampi(x + dx, 0, image.get_width() - 1), clampi(y + dy, 0, image.get_height() - 1)).a)
	return best
