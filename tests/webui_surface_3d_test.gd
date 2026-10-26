extends SceneTree
## Run: godot --headless --path . -s res://tests/webui_surface_3d_test.gd
## Covers the WebUISurface3D node with a fake backend (no WebView): waiting for the overlay, state and handlers set
## before it is attached, the camera ray to page pixel mapping, taps, cursor state, activity (distance), detach and
## re-attach, and cleanup. The desktop preview end to end is tests/surface3d_preview_test.gd (needs a window).

var failures := 0


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


class FakeBackend extends WebUIBackend:
	var surfaces_ok := true
	var preview := false
	var log: Array = []

	func get_backend_name() -> String:
		return "fake"

	func create(_ui_dir: String, _script: String, _host: Node = null) -> bool:
		return true

	func supports_surfaces() -> bool:
		return surfaces_ok

	func surface_is_preview() -> bool:
		return preview

	func create_surface(surface_id: String, page: String, size: Vector2i, fps: int) -> bool:
		log.append(["create", surface_id, page, size, fps])
		return true

	func destroy_surface(surface_id: String) -> void:
		log.append(["destroy", surface_id])

	func surface_send(surface_id: String, event_name: String, json_payload: String) -> void:
		log.append(["send", surface_id, event_name, json_payload])

	func surface_tap(surface_id: String, x: float, y: float) -> void:
		log.append(["tap", surface_id, x, y])

	func surface_set_active(surface_id: String, active: bool) -> void:
		log.append(["active", surface_id, active])

	func entries(kind: String) -> Array:
		return log.filter(func(e: Array) -> bool: return e[0] == kind)

	## The "run" state messages sent to a surface (the node also sends "cursor" by itself).
	func runs() -> Array:
		return log.filter(func(e: Array) -> bool: return e[0] == "send" and e[2] == "run")


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var fake := FakeBackend.new()
	GodotWebUI._backend_factory = func() -> WebUIBackend: return fake

	# the node can be configured before any overlay exists
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.make_current()
	var screen := WebUISurface3D.new()
	screen.page = "terminal.html"
	screen.page_size = Vector2i(640, 400)
	screen.world_width = 2.0
	screen.pause_when_offscreen = false  # headless: nothing is ever "on screen"
	screen.position = Vector3(0, 0, -2)
	var got: Array = []
	var handler := func(p: Dictionary) -> void: got.append(p)
	screen.on("terminal_action", handler)
	screen.set_state("run", {"time": 1.5})
	var ready_count := [0]
	screen.page_ready.connect(func() -> void: ready_count[0] += 1)
	root.add_child(screen)
	await process_frame
	check(not screen.is_attached() and screen.surface == null, "without an overlay the node waits (no surface, no error)")
	check(fake.entries("create").is_empty(), "nothing is created before the overlay starts")

	var ui := GodotWebUI.new()
	root.add_child(ui)
	check(ui.start("res://examples/skybound/ui", "index.html"), "the overlay starts")
	await create_timer(0.4).timeout
	check(screen.is_attached(), "the node attaches by itself once the overlay runs")
	var created: Array = fake.entries("create")
	check(created.size() == 1 and created[0][2] == "terminal.html" and created[0][3] == Vector2i(640, 400), "it asks for its page at its size")
	var surface_id: String = created[0][1]

	# state set before the attach is replayed, held until the page is ready
	check(fake.runs().is_empty(), "state is held until the page is ready")
	ui._on_surface_message(surface_id, '{"t":"ready"}')
	check(fake.runs() == [["send", surface_id, "run", '{"time":1.5}']] and ready_count[0] == 1, "state set earlier is delivered when the page is ready; page_ready is forwarded")
	ui._on_surface_message(surface_id, '{"t":"event","name":"terminal_action","payload":{"action":"retry"}}')
	check(got == [{"action": "retry"}], "handlers registered earlier receive page events")
	var seen := []
	screen.page_event.connect(func(event_name: String, payload: Dictionary) -> void: seen.append([event_name, payload]))
	ui._on_surface_message(surface_id, '{"t":"event","name":"other","payload":{"a":1}}')
	check(seen == [["other", {"a": 1.0}]], "page_event reports every event")
	screen.set_state("run", {"time": 1.5})
	check(fake.runs().size() == 1, "an unchanged state is not sent again")
	screen.set_state("run", {"time": 2.5})
	check(fake.runs().size() == 2, "a changed state is sent")

	# geometry: 2.0 x 1.25 m at (0, 0, -2), camera at the origin looking down -Z
	check(screen.world_to_pixel(Vector3(0, 0, -2)).is_equal_approx(Vector2(320, 200)), "the middle of the screen is page pixel 320,200")
	check(screen.world_to_pixel(Vector3(-1, 0.625, -2)).is_equal_approx(Vector2(0, 0)), "the top-left corner is 0,0")
	check(screen.world_to_pixel(Vector3(1, -0.625, -2)).is_equal_approx(Vector2(640, 400)), "the bottom-right corner is 640,400")
	check(screen.world_to_pixel(Vector3(1.2, 0, -2)) == Vector2(-1, -1), "a point beside the screen is outside")
	await physics_frame
	await physics_frame
	var hit := screen.aim(camera)
	check(hit.hit and (hit.pixel as Vector2).distance_to(Vector2(320, 200)) < 1.0 and absf(hit.distance - 2.0) < 0.05, "the centre ray hits the middle of the page")
	camera.rotation.y = 0.8
	check(not screen.aim(camera).hit, "turned away, the ray misses")
	camera.rotation.y = 0.0
	var offset_hit := screen.aim_ray(Vector3(0.5, 0.25, 0), Vector3(0, 0, -1))
	check(offset_hit.hit and (offset_hit.pixel as Vector2).distance_to(Vector2(480, 120)) < 1.0, "an off-centre ray maps to the matching pixel")
	check(not screen.aim_ray(Vector3(0, 0, 0), Vector3(0, 0, -1), 1.0).hit, "the reach limits the ray")

	fake.log.clear()
	check(screen.use(camera), "use() taps when the ray hits")
	var taps: Array = fake.entries("tap")
	check(taps.size() == 1 and absf(taps[0][2] - 320.0) < 1.0 and absf(taps[0][3] - 200.0) < 1.0, "the tap is at the hit pixel")
	camera.rotation.y = 0.5
	check(not screen.use(camera) and fake.entries("tap").size() == 1, "use() sends nothing when the ray misses")
	camera.rotation.y = 0.0
	screen.tap_uv(Vector2(0.25, 0.5))
	check(fake.entries("tap").back().slice(2) == [160.0, 200.0], "tap_uv maps uv to pixels")

	# auto aim: aimed_changed and the cursor state
	camera.rotation.y = 0.8
	await create_timer(0.35).timeout
	check(not screen.aimed, "turned away, the crosshair is off the screen")
	var aimed_log := []
	screen.aimed_changed.connect(func(aimed: bool) -> void: aimed_log.append(aimed))
	camera.rotation.y = 0.0
	await create_timer(0.35).timeout
	check(screen.aimed and aimed_log == [true], "auto aim reports the crosshair on the screen")
	check(fake.entries("send").any(func(e: Array) -> bool: return e[2] == "cursor" and e[3].contains("\"aimed\":true")), "the page is told where the cursor is")
	camera.rotation.y = 0.8
	await create_timer(0.35).timeout
	check(not screen.aimed and aimed_log == [true, false], "and when it leaves")
	check(fake.entries("send").back()[3].contains("\"aimed\":false"), "the cursor is cleared on the page")
	camera.rotation.y = 0.0

	# activity follows distance
	fake.log.clear()
	screen.active_distance = 1.0  # the camera is 2 m away
	await create_timer(0.35).timeout
	check(fake.entries("active").back() == ["active", surface_id, false], "beyond active_distance the surface is switched off")
	screen.active_distance = 5.0
	await create_timer(0.35).timeout
	check(fake.entries("active").back() == ["active", surface_id, true], "and back on when in range")

	# detach and re-attach keep handlers and state
	fake.log.clear()
	var detached_count := [0]
	screen.detached.connect(func() -> void: detached_count[0] += 1)
	screen.detach()
	check(not screen.is_attached() and fake.entries("destroy").size() == 1 and detached_count[0] == 1 and ui.surface_count() == 0, "detach() releases the surface")
	await create_timer(0.4).timeout
	check(screen.is_attached() and fake.entries("create").size() == 1, "auto_attach puts the page back")
	var second_id: String = fake.entries("create")[0][1]
	ui._on_surface_message(second_id, '{"t":"ready"}')
	check(fake.entries("send").any(func(e: Array) -> bool: return e[1] == second_id and e[2] == "run" and e[3] == '{"time":2.5}'), "the newest state is sent to the new page")
	ui._on_surface_message(second_id, '{"t":"event","name":"terminal_action","payload":{"action":"restart"}}')
	check(got.back() == {"action": "restart"}, "handlers survive the re-attach")

	# leaving the tree frees the surface; entering again re-attaches
	fake.log.clear()
	root.remove_child(screen)
	check(fake.entries("destroy").size() == 1 and ui.surface_count() == 0, "leaving the tree destroys the surface")
	root.add_child(screen)
	await create_timer(0.4).timeout
	check(screen.is_attached() and ui.surface_count() == 1, "entering the tree again re-attaches")

	# a preview is flagged and labelled
	var preview_node := WebUISurface3D.new()
	preview_node.page = "terminal.html"
	preview_node.pause_when_offscreen = false
	fake.preview = true
	root.add_child(preview_node)
	await create_timer(0.4).timeout
	check(preview_node.is_preview() and preview_node.get_node("PreviewLabel").visible, "a snapshot preview shows its label")
	preview_node.show_preview_label = false
	preview_node.detach()
	await create_timer(0.4).timeout
	check(not preview_node.get_node("PreviewLabel").visible, "the label can be turned off")
	fake.preview = false

	# no support: a harmless label
	var unsupported := FakeBackend.new()
	unsupported.surfaces_ok = false
	GodotWebUI._backend_factory = func() -> WebUIBackend: return unsupported
	ui.shutdown()
	check(not screen.is_attached() and ui.surface_count() == 0, "shutdown retires the page")
	var ui2 := GodotWebUI.new()
	root.add_child(ui2)
	ui2.start("res://examples/skybound/ui", "index.html")
	var errors: Array = []
	ui2.error.connect(func(code: String, _t: String) -> void: errors.append(code))
	var plain := WebUISurface3D.new()
	plain.page = "terminal.html"
	root.add_child(plain)
	await create_timer(0.4).timeout
	check(not plain.is_attached() and plain.get_node("StatusLabel").visible, "without support the node shows a label")
	plain.set_state("x", {"a": 1})
	plain.tap_pixel(Vector2(1, 1))
	check(not plain.use(camera), "every call is a harmless no-op")

	GodotWebUI._backend_factory = Callable()
	quit(failures)
