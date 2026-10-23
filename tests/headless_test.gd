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
	if OS.get_name() in ["Windows", "macOS", "Linux"] and OS.has_feature("editor"):
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

	func _set(property: StringName, value: Variant) -> bool:
		props[property] = value
		return true

	func eval(js: String) -> void:
		evals.append(js)

	func load_url(url: String) -> void:
		loaded.append(url)

	func reload() -> void:
		loaded.append("reload")


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
