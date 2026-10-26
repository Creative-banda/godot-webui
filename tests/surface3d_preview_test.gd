extends SceneTree
## Run (needs a window and the optional godot_wry preview dependency, so NOT --headless):
##   godot --path . -s res://tests/surface3d_preview_test.gd
## Puts a real page (Skybound's terminal) on WebUISurface3D nodes in the desktop development preview and checks: frames
## arrive as snapshots, Godot -> page state changes the picture, a tap reaches the page and comes back as an event, the
## camera ray maps to the right page pixel, several surfaces share the work, and everything is freed on detach/shutdown.
## Skips (exit 0) when godot_wry is not installed. Exit code = number of failures.

const UI_DIR := "res://examples/skybound/ui"

var failures := 0


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		print("SKIP  surface3d_preview_test needs a window (run it without --headless)")
		quit(0)
		return
	var failure := WebUIBackendDesktop._load_dependency()
	if not failure.is_empty():
		print("SKIP  godot_wry is not installed: ", failure.code)
		quit(0)
		return
	_run()


func _frames(node: WebUISurface3D, at_least: int, seconds := 20.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		if node.surface and node.surface.frames >= at_least:
			return true
		await process_frame
	return false


func _count_views(host: Node) -> int:
	return host.find_children("*", "WebView", false, false).size()


func _run() -> void:
	await process_frame
	var ui := GodotWebUI.new()
	ui.desktop_preview_hot_reload = false
	ui.desktop_preview_devtools = false
	root.add_child(ui)
	var overlay_errors: Array = []
	ui.error.connect(func(code: String, _text: String) -> void: overlay_errors.append(code))
	check(ui.start(UI_DIR, "index.html"), "the overlay starts in the desktop preview")
	ui.hide_ui()

	var camera := Camera3D.new()
	root.add_child(camera)
	camera.make_current()
	var screen := WebUISurface3D.new()
	screen.page = "terminal.html"
	screen.world_width = 2.0  # 2.0 x 1.25 m
	screen.position = Vector3(0, 0, -2)
	var actions: Array = []
	screen.on("terminal_action", func(p: Dictionary) -> void: actions.append(p))
	screen.set_state("run", {"time": 5.0, "section": 1, "section_name": "LAUNCH PAD", "shards": 0, "shard_total": 25, "deaths": 0, "best_time": -1.0, "wings": false})
	root.add_child(screen)

	check(await _frames(screen, 2), "snapshot frames arrive on the surface")
	check(screen.is_attached() and screen.is_preview() and screen.surface.is_preview, "the node reports that this is a preview")
	check(not screen.surface.stats().is_empty() and screen.surface.stats().mode == "desktop_preview_snapshot", "stats say these are snapshots")
	var first := screen.surface.texture.get_image()
	check(first.get_size() == Vector2i(640, 400) and not first.is_invisible(), "the texture holds a 640x400 picture")
	check(_count_distinct_colours(first) > 20, "the picture is the page, not a flat placeholder")
	check(_count_views(ui) == 2, "one hidden view for the overlay and one for the surface")

	# Godot -> page: new state changes the picture
	var before := screen.surface.frames
	screen.set_state("run", {"time": 83.45, "section": 3, "section_name": "CARGO RUN", "shards": 14, "shard_total": 25, "deaths": 2, "best_time": 140.0, "wings": true})
	await _frames(screen, before + 2)
	var second := screen.surface.texture.get_image()
	check(second.get_data() != first.get_data(), "state sent with set_state changes the drawn page")

	# camera ray -> page pixel
	var hit := screen.aim(camera)
	check(hit.hit and (hit.pixel as Vector2).distance_to(Vector2(320, 200)) < 2.0, "the centre ray maps to the middle of the page")
	var corner := screen.world_to_pixel(screen.to_global(Vector3(-1.0 + 0.001, 0.625 - 0.001, 0)))
	check(corner.distance_to(Vector2(0.32, 0.32)) < 0.5, "the top-left corner maps to pixel 0,0")
	check(screen.world_to_pixel(screen.to_global(Vector3(1.5, 0, 0))) == Vector2(-1, -1), "a point beside the screen is not on the page")
	await create_timer(0.35).timeout
	check(screen.aimed, "aimed is true while the crosshair is on the screen")

	# page -> Godot: a tap on "Back to checkpoint" (button around 100,350)
	screen.tap_pixel(Vector2(100, 350))
	var end := Time.get_ticks_msec() + 5000
	while actions.is_empty() and Time.get_ticks_msec() < end:
		await process_frame
	check(actions == [{"action": "retry"}], "a tap reaches the page's button and its event comes back")

	# several surfaces share the work; limits; cleanup
	var extra: Array[WebUISurface3D] = []
	for i in 2:
		var more := WebUISurface3D.new()
		more.page = "terminal.html"
		more.position = Vector3(i * 3, 0, -6)
		root.add_child(more)
		extra.append(more)
	await process_frame
	check(await _frames(extra[0], 1) and await _frames(extra[1], 1), "three surfaces all get frames (captures are shared)")
	check(ui.surface_count() == 3 and _count_views(ui) == 4, "three surfaces, three hidden views")
	extra[0].queue_free()
	extra[1].page = "terminal.html"  # same page: nothing changes
	await process_frame
	await process_frame
	check(ui.surface_count() == 2, "freeing a node destroys its surface")
	await process_frame
	check(_count_views(ui) == 3, "the hidden view of a destroyed surface is freed")

	# a surface too far from the camera draws nothing new (the node switches it off by itself)
	extra[1].active_distance = 1.0
	await create_timer(0.5).timeout
	var held := extra[1].surface.frames
	await create_timer(1.5).timeout
	check(not extra[1].surface.is_active() and extra[1].surface.frames <= held + 1, "beyond active_distance the redraws stop")
	extra[1].active_distance = 0.0
	await create_timer(0.5).timeout
	check(extra[1].surface.is_active(), "and resume when the camera is back in range")

	var overlay_surface_count_before := ui.surface_count()
	screen.detach()
	check(not screen.is_attached() and ui.surface_count() == overlay_surface_count_before - 1, "detach() releases the surface")
	check(await _frames(screen, 1), "the node attaches again by itself and keeps its state")

	ui.shutdown()
	await process_frame
	await process_frame
	check(ui.surface_count() == 0 and not screen.is_attached() and not extra[1].is_attached(), "shutdown retires every surface")
	check(_count_views(ui) == 0, "no hidden view is left after shutdown")
	check(overlay_errors.is_empty(), "no errors were reported (%s)" % str(overlay_errors))
	quit(failures)


func _count_distinct_colours(image: Image) -> int:
	var seen := {}
	for y in range(0, image.get_height(), 7):
		for x in range(0, image.get_width(), 7):
			seen[image.get_pixel(x, y).to_html(false)] = true
	return seen.size()
