extends SceneTree
## Run: godot --headless --path . -s res://tests/api_test.gd
## Covers the GodotWebUI API (state vs events, touch modes, duplicate guard, recovery) with a fake
## backend, and the export plugin's folder detection. No WebView involved.

var failures := 0


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


## Backend stand-in that records what GodotWebUI asks of it.
class FakeBackend extends WebUIBackend:
	var sent: Array = []        # [name, json]
	var ui_references: Array = []
	var touch_modes: Array = []
	var loaded: Array = []
	var destroyed := false

	func get_backend_name() -> String:
		return "fake"

	func create(_ui_dir: String, _script: String, _host: Node = null) -> bool:
		return true

	func load_page(path: String) -> void:
		loaded.append(path)

	func send_message(event_name: String, json: String) -> void:
		sent.append([event_name, json])

	func set_touch_mode(mode: String) -> void:
		touch_modes.append(mode)

	func set_ui_scale_reference(css_pixels: float) -> void:
		ui_references.append(css_pixels)

	func destroy() -> void:
		destroyed = true


func _initialize() -> void:
	await _test_state_and_events()
	await _test_touch_modes()
	await _test_guard_and_recovery()
	await _test_back_button()
	_test_ui_scale()
	_test_export_plugin()
	await _test_minimal_example()
	quit(failures)


func _fake_ui() -> Array:
	var ui := GodotWebUI.new()
	root.add_child(ui)
	var backend := FakeBackend.new()
	ui._backend = backend
	ui._started = true
	backend.message.connect(ui._on_raw_message)
	backend.error.connect(ui._on_backend_error)
	return [ui, backend]


func _test_state_and_events() -> void:
	var made := _fake_ui()
	var ui: GodotWebUI = made[0]
	var fake: FakeBackend = made[1]
	var ready_count := [0]
	ui.page_ready.connect(func() -> void: ready_count[0] += 1)

	# held until ready: newest state per name, events in order
	ui.set_state("hud", {"hp": 1})
	ui.set_state("hud", {"hp": 2})
	ui.emit_event("toast", {"n": 1})
	ui.emit_event("toast", {"n": 2})
	check(fake.sent.is_empty(), "state and events are held until the page is ready")
	fake.message.emit('{"t":"ready"}')
	check(fake.sent == [["hud", '{"hp":2}'], ["@e:toast", '{"n":1}'], ["@e:toast", '{"n":2}']], "ready delivers newest state, then events in order")
	check(ready_count[0] == 1, "page_ready emitted once")

	fake.sent.clear()
	ui.set_state("hud", {"hp": 3})
	ui.emit_event("flash")
	ui.send("legacy", {"a": 1})
	check(fake.sent == [["hud", '{"hp":3}'], ["@e:flash", "{}"], ["legacy", '{"a":1}']], "after ready: state plain, events prefixed, send() is a set_state alias")

	# page navigation drops what was held for the old page and caps the event queue
	ui.load_page("other.html")
	check(not ui.is_ready and fake.loaded == ["other.html"], "load_page resets readiness")
	var errors: Array = []
	ui.error.connect(func(code: String, _t: String) -> void: errors.append(code))
	for i in 70:
		ui.emit_event("spam", {"i": i})
	check(ui._pending_events.size() == GodotWebUI.MAX_PENDING_EVENTS and errors.count("event_queue_full") == 6, "event queue is capped at 64")
	ui.load_page("third.html")
	check(ui._pending_events.is_empty(), "queued events are dropped on navigation")

	# validation
	ui.set_state("bad name", {})
	check("bad_name" in errors, "invalid state name rejected")
	errors.clear()
	ui.on("webui.touch_regions", func(_p: Dictionary) -> void: pass)
	check("bad_name" in errors, "reserved webui.* names cannot be registered")
	ui.shutdown()
	ui.queue_free()


func _test_touch_modes() -> void:
	var made := _fake_ui()
	var ui: GodotWebUI = made[0]
	var fake: FakeBackend = made[1]
	var seen: Array = []
	ui.on("probe", func(p: Dictionary) -> void: seen.append(p))
	ui.event_received.connect(func(n: String, _p: Dictionary) -> void: seen.append(n))

	check(ui.touch_mode == GodotWebUI.TouchMode.AUTO and ui._native_touch_mode() == "modal", "default touch mode is AUTO and starts modal")
	ui._on_raw_message('{"t":"event","name":"webui.touch_regions","payload":{"selector":"[x]"}}')
	check(fake.touch_modes.back() == "regions" and seen.is_empty(), "webui.touch_regions switches AUTO to regions and is not dispatched")
	ui.load_page("next.html")
	check(fake.touch_modes.back() == "modal", "a new page starts modal again")
	ui.set_touch_mode(GodotWebUI.TouchMode.REGIONS)
	check(fake.touch_modes.back() == "regions", "explicit REGIONS is honoured")
	ui.set_touch_mode(GodotWebUI.TouchMode.MODAL)
	ui._on_raw_message('{"t":"event","name":"webui.touch_regions","payload":{}}')
	check(fake.touch_modes.back() == "modal", "explicit MODAL ignores the page's opt-in")
	ui._on_raw_message('{"t":"event","name":"probe","payload":{"k":1}}')
	check(seen.size() == 2, "normal events still dispatch")
	ui._on_raw_message('{"t":"event","name":"webui.future_thing","payload":{}}')
	check(seen.size() == 2, "unknown webui.* events are ignored")
	ui.shutdown()
	check(fake.destroyed and not ui.is_started(), "shutdown destroys the backend")
	ui.queue_free()


func _test_guard_and_recovery() -> void:
	var first := GodotWebUI.new()
	var second := GodotWebUI.new()
	root.add_child(first)
	root.add_child(second)
	first._started = true
	GodotWebUI._active = first
	var guard_errors: Array = []
	second.error.connect(func(code: String, _t: String) -> void: guard_errors.append(code))
	check(not second.start("res://examples/playable_character/ui") and guard_errors == ["overlay_already_active"], "a second overlay is refused")
	GodotWebUI._active = null
	first.queue_free()
	second.queue_free()

	var backends: Array = []
	GodotWebUI._backend_factory = func() -> WebUIBackend:
		var b := FakeBackend.new()
		backends.append(b)
		return b
	var rec := GodotWebUI.new()
	root.add_child(rec)
	var recovered_count := [0]
	rec.recovered.connect(func() -> void: recovered_count[0] += 1)
	check(rec.start("res://examples/playable_character/ui", "menu.html"), "start works with an injected backend")
	var b1: FakeBackend = backends[0]
	rec.set_state("hud", {"hp": 7})
	b1.message.emit('{"t":"ready"}')
	b1.error.emit("render_process_gone", "dead")
	await physics_frame
	await physics_frame
	check(backends.size() == 2 and b1.destroyed, "renderer death re-creates the overlay")
	var b2: FakeBackend = backends[1]
	check(b2.loaded == ["menu.html"], "recovered overlay loads the same page")
	b2.message.emit('{"t":"ready"}')
	check(b2.sent == [["hud", '{"hp":7}']] and recovered_count[0] == 1, "recovery restores state and emits recovered")

	for i in 5:
		rec._recovery_times.append(Time.get_ticks_msec())
	var rec_errors: Array = []
	rec.error.connect(func(code: String, _t: String) -> void: rec_errors.append(code))
	b2.error.emit("render_process_gone", "dead again")
	await physics_frame
	await physics_frame
	check("recovery_failed" in rec_errors, "recovery is rate limited")
	rec.shutdown()
	rec.queue_free()
	GodotWebUI._backend_factory = Callable()


func _test_ui_scale() -> void:
	var made := _fake_ui()
	var ui: GodotWebUI = made[0]
	var fake: FakeBackend = made[1]
	check(is_equal_approx(ui.ui_reference_size, 720.0), "UI scale reference defaults to 720")
	ui.ui_reference_size = 540.0
	check(fake.ui_references == [540.0], "changing ui_reference_size reaches the backend")
	ui.ui_reference_size = -5.0
	check(is_zero_approx(ui.ui_reference_size) and fake.ui_references.back() == 0.0, "a negative reference becomes 0 (off)")
	ui.shutdown()

	# start() hands the reference to the backend through its options
	var started := GodotWebUI.new()
	root.add_child(started)
	var backend := FakeBackend.new()
	GodotWebUI._backend_factory = func() -> WebUIBackend: return backend
	started.ui_reference_size = 600.0
	started.start("res://examples/minimal_hud/ui")
	check(float(backend.options.get("ui_reference", -1.0)) == 600.0, "start() passes ui_reference to the backend options")
	started.shutdown()
	GodotWebUI._backend_factory = Callable()
	started.queue_free()


func _test_back_button() -> void:
	var made := _fake_ui()
	var ui: GodotWebUI = made[0]
	var fake: FakeBackend = made[1]
	var backs := [0]
	ui.back_requested.connect(func() -> void: backs[0] += 1)
	var previous: bool = quit_on_go_back

	# off by default: Back is left to the engine
	ui.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	check(backs[0] == 0 and fake.sent.is_empty(), "Back is ignored while handle_back_button is off")

	ui.handle_back_button = true
	check(quit_on_go_back == false, "handle_back_button stops the engine from quitting on Back")

	# page not ready yet: nothing can answer, so the game is told at once
	ui.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	check(backs[0] == 1, "Back before the page is ready goes straight to back_requested")

	fake.message.emit('{"t":"ready"}')
	fake.sent.clear()

	# the page uses it
	ui.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	check(fake.sent == [["@e:webui.back", "{}"]], "Back is offered to the page first")
	fake.message.emit('{"t":"event","name":"webui.back_handled","payload":{}}')
	await create_timer(GodotWebUI.BACK_TIMEOUT_SEC + 0.2).timeout
	check(backs[0] == 1, "a page that handles Back keeps it from the game")

	# the page declines
	ui.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	fake.message.emit('{"t":"event","name":"webui.back_unhandled","payload":{}}')
	check(backs[0] == 2, "a page that declines Back hands it to the game")
	await create_timer(GodotWebUI.BACK_TIMEOUT_SEC + 0.2).timeout
	check(backs[0] == 2, "the late timeout does not report it twice")

	# the page never answers
	ui.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await create_timer(GodotWebUI.BACK_TIMEOUT_SEC + 0.2).timeout
	check(backs[0] == 3, "a silent page does not swallow Back")

	# a stale answer after the timeout is ignored
	fake.message.emit('{"t":"event","name":"webui.back_unhandled","payload":{}}')
	check(backs[0] == 3, "an answer after the timeout is ignored")

	ui.handle_back_button = false
	check(quit_on_go_back == previous, "turning handle_back_button off restores quit_on_go_back")
	ui.shutdown()


func _test_export_plugin() -> void:
	var setting := WebUIExportScan.SETTING_UI_FOLDERS
	var saved: Variant = ProjectSettings.get_setting(setting, PackedStringArray())
	ProjectSettings.set_setting(setting, PackedStringArray())
	var folders: Array = WebUIExportScan.resolve().folders
	check("res://examples/playable_character/ui" in folders, "auto-detect finds the demo UI folder")
	check(not folders.any(func(f: String) -> bool: return f.begins_with("res://addons")), "auto-detect never scans addons/")
	ProjectSettings.set_setting(setting, PackedStringArray(["res://templates/hud/", "res://nope", "res://", "elsewhere"]))
	var configured := WebUIExportScan.resolve()
	check(configured.folders == ["res://templates/hud"] and configured.errors.size() == 3, "configured folders are validated (3 invalid entries reported)")
	# folders with a .gdignore are not UI folders (docs, samples, the skill's example pages)
	var base := "res://zz_scan_test"
	DirAccess.make_dir_recursive_absolute(base + "/ui")
	DirAccess.make_dir_recursive_absolute(base + "/hidden")
	for path in [base + "/ui/index.html", base + "/hidden/index.html", base + "/hidden/.gdignore"]:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string("x")
		file.close()
	ProjectSettings.set_setting(setting, PackedStringArray())
	var detected: Array = WebUIExportScan.resolve().folders
	check(base + "/ui" in detected and not (base + "/hidden") in detected, "auto-detect skips folders containing .gdignore")
	check(not detected.any(func(f: String) -> bool: return f.begins_with("res://templates") or f.begins_with("res://skills")), "templates/ and skills/ samples are not packaged")
	for path in [base + "/ui/index.html", base + "/hidden/index.html", base + "/hidden/.gdignore"]:
		DirAccess.remove_absolute(path)
	for path in [base + "/ui", base + "/hidden", base]:
		DirAccess.remove_absolute(path)
	ProjectSettings.set_setting(setting, saved)


func _test_minimal_example() -> void:
	var scene: Node = load("res://examples/minimal_hud/minimal.tscn").instantiate()
	root.add_child(scene)
	var ui: GodotWebUI = scene.ui
	var errors: Array = []
	ui.error.connect(func(code: String, _t: String) -> void: errors.append(code))
	var events: Array = []
	var fake := FakeBackend.new()
	ui._backend = fake
	ui._started = true
	fake.message.connect(ui._on_raw_message)
	fake.message.emit('{"t":"ready"}')
	check(fake.sent.any(func(m: Array) -> bool: return m[0] == "hud"), "example pushes its state on page_ready")

	fake.sent.clear()
	ui._on_raw_message('{"t":"event","name":"attack","payload":{"heavy":false}}')
	check(scene.dummy_hp in [95, 90], "example: attack is decided in Godot (5, or 10 on a crit)")
	check(fake.sent.any(func(m: Array) -> bool: return m[0] == "@e:hit") and fake.sent.any(func(m: Array) -> bool: return m[0] == "hud"), "example: an attack sends a one-shot hit event and the new state")

	var hp: int = scene.dummy_hp
	ui._on_raw_message('{"t":"event","name":"attack","payload":{"heavy":"yes"}}')
	check(scene.dummy_hp == hp, "example: a payload of the wrong type is ignored")

	scene.coins = 3
	fake.sent.clear()
	ui._on_raw_message('{"t":"event","name":"repair","payload":{}}')
	check(scene.coins == 3 and scene.dummy_hp == hp and fake.sent.any(func(m: Array) -> bool: return m[0] == "@e:toast"), "example: repair without enough coins only shows a toast")
	scene.coins = 10
	ui._on_raw_message('{"t":"event","name":"repair","payload":{}}')
	check(scene.coins == 5 and scene.dummy_hp == scene.DUMMY_MAX_HP, "example: repair costs coins and restores health")
	ui.shutdown()
	scene.queue_free()
