extends SceneTree
## Run: godot --headless --path . -s res://tests/headless_test.gd
## Verifies the GDScript half (protocol validation + physics reacting to bridge messages) with no WebView.

var failures := 0


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	# --- protocol validation
	check(WebUIBridge.parse_incoming('{"t":"ready"}').ok, "ready accepted")
	var ev := WebUIBridge.parse_incoming('{"t":"event","name":"move_changed","payload":{"x":0.5,"y":-1}}')
	check(ev.ok and ev.name == "move_changed" and ev.payload.x == 0.5, "event parsed")
	check(WebUIBridge.parse_incoming('{"t":"event","name":"jump"}').ok, "missing payload defaults to {}")
	check(not WebUIBridge.parse_incoming("not json").ok, "garbage rejected")
	check(not WebUIBridge.parse_incoming("[1,2]").ok, "non-object rejected")
	check(not WebUIBridge.parse_incoming('{"t":"event","name":"bad name!","payload":{}}').ok, "bad name rejected")
	check(not WebUIBridge.parse_incoming('{"t":"event","name":"x","payload":[1]}').ok, "array payload rejected")
	check(not WebUIBridge.parse_incoming('{"t":"call","name":"queue_free"}').ok, "unknown type rejected")
	check(not WebUIBridge.parse_incoming(" ".repeat(70000)).ok, "oversized rejected")
	check(WebUIBridge.encode_payload({"a": 1}) == '{"a":1}', "payload encoded")

	# --- menu -> game flow driven only through bridge messages
	var app: DemoApp = load("res://examples/playable_character/main.tscn").instantiate()
	root.add_child(app)
	await physics_frames(3)
	check(app._scene != null and app._scene.name == "Menu", "app starts on the menu")
	if DisplayServer.get_name() == "headless":
		check(app.ui.get_backend_name() == "none", "GodotWebUI.start() uses the factory (null backend without a window)")
	elif OS.get_name() in ["Windows", "macOS", "Linux"] and OS.has_feature("editor"):
		check(app.ui.get_backend_name() == "desktop_preview", "GodotWebUI.start() uses the factory (desktop preview in the editor)")
	app.ui._on_raw_message('{"t":"event","name":"settings_changed","payload":{"difficulty":"hard","music":2,"sfx":"x"}}')
	check(app.settings.difficulty == "hard" and app.settings.music == 1.0 and app.settings.sfx == true, "settings validated (clamp, bad type ignored)")
	app.ui._on_raw_message('{"t":"event","name":"settings_changed","payload":{"difficulty":"nightmare"}}')
	check(app.settings.difficulty == "hard", "invalid difficulty ignored")
	app.ui._on_raw_message('{"t":"event","name":"menu_play","payload":{"level":9}}')
	await physics_frames(2)
	check(app._scene.name == "Menu", "invalid level rejected")
	app.ui._on_raw_message('{"t":"event","name":"menu_play","payload":{"level":2}}')
	await physics_frames(60)
	check(app._scene.name == "Main" and app.level == 2 and app.stats.plays >= 1, "menu_play starts level 2")
	var main: Node = app._scene
	check(main.player.gravity_scale == 0.6 and main.player.damage_scale == 2.0, "level + difficulty applied in Godot")
	var player: DemoPlayer = main.get_node("Player")
	check(player.is_on_floor(), "player settles on floor")
	var x0 := player.position.x
	app.ui._on_raw_message('{"t":"event","name":"move_changed","payload":{"x":1,"y":0}}')
	await physics_frames(30)
	check(player.position.x > x0 + 50, "move_changed moves player (%.0f -> %.0f)" % [x0, player.position.x])
	app.ui._on_raw_message('{"t":"event","name":"move_changed","payload":{"x":0,"y":0}}')
	await physics_frames(40)
	var y0 := player.position.y
	app.ui._on_raw_message('{"t":"event","name":"jump","payload":{}}')
	await physics_frames(10)
	check(player.position.y < y0 - 20, "jump lifts player via physics")
	await physics_frames(90)  # land again

	# Keyboard fallback driven by injected key events (what the desktop preview overlay forwards)
	var kx := player.position.x
	root.push_input(_key(KEY_RIGHT, true))
	await physics_frames(20)
	check(player.position.x > kx + 20, "keyboard: injected right-arrow events move the player")
	root.push_input(_key(KEY_RIGHT, false))
	await physics_frames(40)
	var kx2 := player.position.x
	await physics_frames(10)
	check(absf(player.position.x - kx2) < 1.0, "keyboard: releasing the key stops the player")
	var ky := player.position.y
	root.push_input(_key(KEY_SPACE, true))
	root.push_input(_key(KEY_SPACE, false))
	await physics_frames(10)
	check(player.position.y < ky - 20, "keyboard: space jumps")
	await physics_frames(90)
	root.push_input(_key(KEY_X, true))
	check(player.attacking, "keyboard: X attacks while held")
	root.push_input(_key(KEY_X, false))
	check(not player.attacking, "keyboard: releasing X ends the attack")
	app.ui._on_raw_message('{"t":"event","name":"attack_pressed","payload":{}}')
	check(player.attacking, "attack_pressed")
	app.ui._on_raw_message('{"t":"event","name":"attack_released","payload":{}}')
	check(not player.attacking, "attack_released")
	app.ui._on_raw_message('{"t":"event","name":"move_changed","payload":{"x":"evil","y":0}}')
	check(player.move_input == Vector2.ZERO, "non-numeric move ignored")
	app.ui._on_raw_message('{"t":"event","name":"damage_self","payload":{}}')
	check(player.health == 80, "damage_self reduces health (hard = x2)")
	app.ui._on_raw_message('{"t":"event","name":"pause_toggle","payload":{}}')
	check(paused, "pause_toggle pauses the tree")
	app.ui._on_raw_message('{"t":"event","name":"pause_toggle","payload":{}}')
	check(not paused, "pause_toggle resumes")
	app.ui._on_raw_message('{"t":"event","name":"back_to_menu","payload":{}}')
	await physics_frames(3)
	check(app._scene.name == "Menu" and not paused, "back_to_menu returns to menu")
	await _test_desktop_preview()
	await _test_desktop_surfaces()
	quit(failures)


func physics_frames(n: int) -> void:
	for i in n:
		await physics_frame



## Stand-in for the godot_wry `WebView` node (same signals/methods the backend uses).
class FakeWebView extends Control:
	signal ipc_message(message: String)
	signal page_load_started(url: String)
	signal page_load_finished(url: String)
	var props := {}
	var evals: Array = []
	var loaded: Array = []
	var zooms: Array = []

	func _set(property: StringName, value: Variant) -> bool:
		props[property] = value
		return true

	func eval(js: String) -> void:
		evals.append(js)

	func load_url(url: String) -> void:
		loaded.append(url)

	func reload() -> void:
		loaded.append("reload")

	func zoom(factor: float) -> void:
		zooms.append(factor)


## A stand-in webview that answers a capture request with a real PNG of the requested size, like capture.js would.
class FakeCaptureView extends FakeWebView:
	func eval(js: String) -> void:
		evals.append(js)
		var run := RegEx.create_from_string("__webuiCapture\\.run\\((\\d+),(\\d+)\\)").search(js)
		if run:
			var image := Image.create_empty(int(run.get_string(1)), int(run.get_string(2)), false, Image.FORMAT_RGBA8)
			image.fill(Color(0.2, 0.4, 0.6))
			var base64 := Marshalls.raw_to_base64(image.save_png_to_buffer())
			var chunk_size := 2000
			var count := 0
			for i in range(0, base64.length(), chunk_size):
				ipc_message.emit(JSON.stringify({"t": "event", "name": "webui_capture", "payload": {"t": "chunk", "n": count, "data": base64.substr(i, chunk_size)}}))
				count += 1
			ipc_message.emit(JSON.stringify({"t": "event", "name": "webui_capture", "payload": {"t": "done", "chunks": count}}))


func _test_desktop_surfaces() -> void:
	var host := Node.new()
	root.add_child(host)
	var views: Array = []
	var errors: Array = []
	var backend := WebUIBackendDesktop.new()
	backend.view_factory = func() -> Control:
		var view := FakeCaptureView.new()
		views.append(view)
		return view
	backend.options = {"hot_reload": false, "surface_preview_fps": 10}
	backend.error.connect(func(code: String, _t: String) -> void: errors.append(code))
	var frames: Array = []
	var forwarded: Array = []
	backend.surface_frame.connect(func(surface_id: String, frame: int) -> void: frames.append([surface_id, frame]))
	backend.surface_message.connect(func(surface_id: String, raw: String) -> void: forwarded.append([surface_id, raw]))
	check(not backend.supports_surfaces(), "no surfaces before the overlay exists")
	var script := FileAccess.get_file_as_string("res://addons/webui/web/godot.js")
	check(backend.create("res://examples/skybound/ui", script, host), "preview backend starts")
	check(backend.supports_surfaces() and backend.surface_is_preview(), "surfaces are supported and flagged as a preview")

	check(backend.create_surface("a", "terminal.html", Vector2i(128, 80), 10), "a surface is accepted")
	check(views.size() == 1, "its webview waits until the overlay page has loaded")
	views[0].page_load_finished.emit("http://res..webui_preview/ui/index.html")
	await process_frame
	backend._surface_timer.stop()  # the test drives the scheduler itself
	check(views.size() == 2 and views[1].get_parent() == host, "then the surface gets its own webview")
	check(views[1].props.get("full_window_size") == false and views[1].props.get("forward_input_events") == false and views[1].props.get("visible") == false and views[1].props.get("size") == Vector2(128, 80), "the surface view is hidden, page-sized and takes no input")

	backend.create_surface("b", "terminal.html", Vector2i(64, 64), 10)
	check(views.size() == 3, "a surface created after the overlay loaded opens at once")
	check(not backend.create_surface("a", "terminal.html", Vector2i(128, 80), 10) and "surface_bad_id" in errors, "a duplicate id is refused")
	check(not backend.create_surface("c", "nope.html", Vector2i(128, 80), 10) and "bad_path" in errors, "a page that is not in the UI folder is refused")
	check(not backend.create_surface("c", "terminal.html", Vector2i(10, 10), 10) and "surface_bad_size" in errors, "a bad size is refused")

	# page loads: the helper scripts are injected, then it can be captured
	views[1].page_load_finished.emit("http://res..webui_preview/ui/terminal.html")
	views[2].page_load_finished.emit("http://res..webui_preview/ui/terminal.html")
	await process_frame
	check(views[1].evals.any(func(js: String) -> bool: return js.contains("window.__godotSurface=\"a\"") and js.contains("__webuiSurfaceTap")), "the page gets its surface id, the capture and the tap scripts")

	backend._surface_tick()
	var capturing := 0
	for view: FakeCaptureView in [views[1], views[2]]:
		if view.evals.any(func(js: String) -> bool: return js.contains("__webuiCapture.run(")):
			capturing += 1
	await process_frame
	check(capturing == 1, "only one capture is in flight across surfaces")
	check(frames.size() == 1 and backend.surface_read_frame(frames[0][0]).size() == 128 * 80 * 4 or frames.size() == 1 and backend.surface_read_frame(frames[0][0]).size() == 64 * 64 * 4, "the picture arrives as RGBA bytes of the surface size")
	check(JSON.parse_string(backend.surface_stats(frames[0][0])).frames == 1, "stats count the frame")
	var first_id: String = frames[0][0]
	backend.surface_set_active("a", false)
	backend.surface_set_active("b", false)
	backend._surface_tick()
	await process_frame
	check(frames.size() == 1, "inactive surfaces are not captured")
	backend.surface_set_active(first_id, true)
	backend.surface_tap(first_id, 12.4, 30.6)
	var tapped := false
	for view: FakeCaptureView in [views[1], views[2]]:
		tapped = tapped or view.evals.any(func(js: String) -> bool: return js.contains("__webuiSurfaceTap(12,31)"))
	check(tapped, "a tap becomes a synthetic tap in the page at the rounded pixel")

	views[1].ipc_message.emit('{"t":"ready"}')
	views[1].ipc_message.emit('{"t":"viewport","w":100,"h":100,"dpr":1}')
	await process_frame
	check(forwarded == [["a", '{"t":"ready"}']], "page messages are forwarded with the surface id; viewport reports are dropped")

	# cap and cleanup
	for i in range(6):
		backend.create_surface("x%d" % i, "terminal.html", Vector2i(64, 64), 10)
	check(not backend.create_surface("too_many", "terminal.html", Vector2i(64, 64), 10) and "surface_limit" in errors, "at most 8 surfaces")
	backend.destroy_surface("b")
	await process_frame
	check(not is_instance_valid(views[2]) or views[2].is_queued_for_deletion(), "destroying a surface frees its webview")
	backend.destroy()
	await process_frame
	var left := 0
	for view in views:
		if is_instance_valid(view) and not view.is_queued_for_deletion():
			left += 1
	check(left == 0, "destroy() frees the overlay view and every surface view")
	host.queue_free()


func _test_desktop_preview() -> void:
	var host := Node.new()
	root.add_child(host)
	var fake := FakeWebView.new()
	var errors: Array = []
	var messages: Array = []
	var backend := WebUIBackendDesktop.new()
	backend.view_factory = func() -> Control: return fake
	backend.options = {"hot_reload": false}
	backend.error.connect(func(code: String, _t: String) -> void: errors.append(code))
	backend.message.connect(func(raw: String) -> void: messages.append(raw))

	var script := FileAccess.get_file_as_string("res://addons/webui/web/godot.js")
	check(backend.create("res://examples/playable_character/ui", script, host), "preview backend starts with a stand-in view")
	check(fake.get_parent() == host, "view is added under the host node")
	check(fake.props.get("transparent") == true and fake.props.get("full_window_size") == true, "view is transparent and full window")
	check(fake.props.get("url") == "", "view does not load a default URL")
	check(backend.get_backend_name() == "desktop_preview", "backend reports desktop_preview")

	var staged := FileAccess.get_file_as_string("res://.webui_preview/ui/menu.html")
	var bridge_at := staged.find("__receive")
	check(bridge_at != -1 and bridge_at < staged.find("<link"), "godot.js is inlined before page content")
	check(FileAccess.get_file_as_bytes("res://.webui_preview/ui/menu.css").size() == FileAccess.get_file_as_bytes("res://examples/playable_character/ui/menu.css").size(), "non-HTML files are copied unchanged")

	backend.load_page("hud.html")
	check(fake.loaded.back() == "res://.webui_preview/ui/hud.html", "load_page navigates to the staged page")
	backend.load_page("../secret.html")
	check("bad_path" in errors, "path traversal rejected")

	backend.send_message("state", '{"a":1}')
	check(fake.evals.back() == 'window.Godot&&window.Godot.__receive("state","{\\"a\\":1}")', "send_message evals __receive with quoted JSON")
	check(WebUIBackendDesktop._js_quote("a" + char(0x2028) + "b") == '"a' + "\\u2028" + 'b"', "line separators escaped for JS")

	fake.ipc_message.emit('{"t":"ready"}')
	fake.ipc_message.emit('{"t":"regions","rects":[1,2,3,4]}')
	fake.ipc_message.emit('{"t":"event","name":"jump","payload":{}}')
	check(messages == ['{"t":"ready"}', '{"t":"event","name":"jump","payload":{}}'], "ipc messages forwarded, touch regions dropped")
	fake.ipc_message.emit(" ".repeat(70000))
	check("message_too_large" in errors, "oversized ipc message rejected")

	# UI scale in the preview: the page reports its size, the backend answers with a page zoom
	check(fake.props.get("zoom_hotkeys") == false, "the preview disables the user's zoom hotkeys")
	check(is_equal_approx(WebUIBackendDesktop.ui_scale_for(1080.0, 720.0), 1.5), "ui scale: 1080 px high at reference 720 is x1.5")
	check(is_equal_approx(WebUIBackendDesktop.ui_scale_for(392.0, 720.0), 1.0), "ui scale: a phone (392 dp high) is never scaled")
	check(is_equal_approx(WebUIBackendDesktop.ui_scale_for(9000.0, 720.0), WebUIBackendDesktop.MAX_UI_SCALE), "ui scale is capped")
	check(is_equal_approx(WebUIBackendDesktop.ui_scale_for(2160.0, 0.0), 1.0), "ui scale: reference 0 turns it off")
	messages.clear()
	fake.ipc_message.emit('{"t":"viewport","w":1920,"h":1080,"dpr":1}')
	await process_frame
	check(fake.zooms == [1.5] and messages.is_empty(), "a 1080p window gets page zoom 1.5 and the report is not forwarded")
	check(fake.evals.back() == "window.Godot&&window.Godot.__uiScale(1.5)", "the page is told the scale")
	fake.zooms.clear()
	fake.ipc_message.emit('{"t":"viewport","w":1280,"h":720,"dpr":1.5}')  # the same window after zooming: nothing to do
	await process_frame
	check(fake.zooms.is_empty(), "the zoomed report does not change the zoom again")
	backend._zoom = 1.0
	fake.ipc_message.emit('{"t":"viewport","w":1920,"h":1080,"dpr":2.0}')  # a 4K window at 200% OS scaling is 1080 CSS px high at 1x
	await process_frame
	check(is_equal_approx(fake.zooms.back(), 1.5), "OS display scaling is taken into account (4K at 200% -> 1.5, not 3)")
	fake.zooms.clear()
	fake.ipc_message.emit('{"t":"viewport","w":"x","h":720,"dpr":1}')
	fake.ipc_message.emit('{"t":"viewport","w":0,"h":720,"dpr":1}')
	await process_frame
	check(fake.zooms.is_empty(), "invalid viewport reports are ignored")
	backend.set_ui_scale_reference(0.0)
	fake.ipc_message.emit('{"t":"viewport","w":1280,"h":720,"dpr":1.5}')
	await process_frame
	check(is_equal_approx(fake.zooms.back(), 1.0), "reference 0 returns the preview to 1x")
	backend.set_ui_scale_reference(720.0)

	var plain := WebUIBackendDesktop.new()
	plain._script = "S"
	check(plain._inject_bridge("<!doctype html><html><head><title>x</title></head></html>") == "<!doctype html><html><head><script>S</script><title>x</title></head></html>", "injects after <head>")
	check(plain._inject_bridge("<html><body></body></html>") == "<html><script>S</script><body></body></html>", "injects after <html> when there is no head")
	check(plain._inject_bridge("<p>hi</p>") == "<script>S</script><p>hi</p>", "prepends for fragments")

	# hot reload: change a source file, the poll re-stages and reloads the page
	var src := "res://.webui_preview/test_src"
	DirAccess.make_dir_recursive_absolute(src)
	var f := FileAccess.open(src + "/index.html", FileAccess.WRITE)
	f.store_string("<html><head></head><body>one</body></html>")
	f.close()
	var fake2 := FakeWebView.new()
	var reload_backend := WebUIBackendDesktop.new()
	reload_backend.view_factory = func() -> Control: return fake2
	reload_backend.options = {"hot_reload": false}
	check(reload_backend.create(src, script, host), "second backend starts")
	reload_backend.load_page("index.html")
	reload_backend._poll_sources()
	var loads_before := fake2.loaded.size()
	f = FileAccess.open(src + "/index.html", FileAccess.WRITE)
	f.store_string("<html><head></head><body>two</body></html>")
	f.close()
	reload_backend._mtimes = {}  # modified-time resolution can be coarse; force a detected change
	reload_backend._poll_sources()
	check(fake2.loaded.size() == loads_before + 1, "changed source triggers a reload")
	check(FileAccess.get_file_as_string("res://.webui_preview/ui/index.html").contains("two"), "reload re-stages the new content")
	reload_backend.destroy()
	check(not is_instance_valid(fake2) or fake2.is_queued_for_deletion(), "destroy frees the view")

	var wry_installed := ClassDB.class_exists("WebView")
	for candidate in WebUIBackendDesktop.candidate_paths():
		wry_installed = wry_installed or FileAccess.file_exists(candidate)
	if not wry_installed:
		var missing := WebUIBackendDesktop.new()
		var missing_errors: Array = []
		missing.error.connect(func(code: String, _t: String) -> void: missing_errors.append(code))
		check(not missing.create("res://examples/playable_character/ui", script, host) and missing_errors == ["desktop_preview_missing_dependency"], "missing dependency reports a clear error")
	var no_host := WebUIBackendDesktop.new()
	no_host.view_factory = func() -> Control: return FakeWebView.new()
	var host_errors: Array = []
	no_host.error.connect(func(code: String, _t: String) -> void: host_errors.append(code))
	check(not no_host.create("res://examples/playable_character/ui", script, null) and host_errors == ["desktop_preview_no_host"], "missing host reports an error")

	backend.destroy()
	# remove the generated preview folder
	backend._remove_tree("res://.webui_preview/ui")
	backend._remove_tree(src)
	DirAccess.remove_absolute("res://.webui_preview/.gdignore")
	DirAccess.remove_absolute("res://.webui_preview")


func _key(code: Key, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = pressed
	return event
