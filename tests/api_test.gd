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

	func destroy() -> void:
		destroyed = true


func _initialize() -> void:
	await _test_state_and_events()
	await _test_touch_modes()
	await _test_guard_and_recovery()
	_test_export_plugin()
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
	ProjectSettings.set_setting(setting, saved)
