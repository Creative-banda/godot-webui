class_name DemoApp
extends Node
## Demo shell (main.tscn). Owns the single GodotWebUI overlay for the whole run, swaps Godot scenes
## (menu / game) and navigates the overlay between HTML pages. Settings and stats are authoritative
## here; the pages only display them and send change requests.

const UI_DIR := "res://examples/playable_character/ui"
const MENU_SCENE := "res://examples/playable_character/menu.tscn"
const GAME_SCENE := "res://examples/playable_character/game.tscn"
const SCENE_3D := "res://examples/third_person_3d/main3d.tscn"
const SAVE_PATH := "user://demo_save.cfg"
const BENCH_WARMUP_SEC := 3.0
const BENCH_MEASURE_SEC := 10.0
const BENCH_RESULTS_PATH := "user://bench_results.json"
const BENCH_TRIGGER := "user://run_benchmark"  # create this file (e.g. via adb) to start a run on launch
const DIFFICULTIES := ["easy", "normal", "hard"]
const LEVELS := {
	1: {"name": "The Hollow", "gravity": 1.0, "wisp_speed": 1.0},
	2: {"name": "Deep Hollow", "gravity": 0.6, "wisp_speed": 1.45},
}

var ui := GodotWebUI.new()
var settings := {"music": 0.7, "sfx": true, "difficulty": "normal", "show_debug": true,
	"player_name": "Keeper", "grove_note": ""}
var stats := {"plays": 0, "deaths": 0, "jumps": 0}
var best := {}  # level -> best victory time in seconds
var level := 1

var _sfx := SfxBank.new()
var _scene: Node
var _page := ""
var _ui_failed := false
var _on_page_ready := Callable()
var _nav_serial := 0  # bumps on every show_page change; older deferred navigations see a stale serial

# FPS benchmark state (a run is in progress when _bench_active).
var _bench_active := false
var _bench_phase := ""  # "" | "warmup" | "measure"
var _bench_tag := ""
var _bench_frames := PackedInt64Array()
var _bench_skip_frame := false
var _bench_last_usec := 0
var _bench_label: Label
var _bench_label_next := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # keep serving the UI while the game is paused
	add_child(ui)
	ui.handle_back_button = true  # Android Back: the page gets it first, then _on_back()
	ui.back_requested.connect(_on_back)
	ui.error.connect(func(code: String, text: String) -> void: printerr("WebUI error ", code, ": ", text))
	ui.page_ready.connect(_page_ready)
	_load_save()
	_apply_settings()
	show_menu()
	if FileAccess.file_exists(BENCH_TRIGGER):
		DirAccess.remove_absolute(BENCH_TRIGGER)
		run_benchmark.call_deferred()


## Android Back, when the page did not use it. The current scene decides; the menu (no on_back) quits.
func _on_back() -> void:
	if _bench_active:
		return
	if _scene and _scene.has_method("on_back"):
		_scene.on_back()
	else:
		get_tree().quit()


func show_menu() -> void:
	get_tree().paused = false
	_swap_scene(MENU_SCENE)


func start_game(new_level: int) -> void:
	if _bench_active:
		return  # user input during a benchmark run would change the conditions being measured
	if not LEVELS.has(new_level):
		printerr("Unknown level ", new_level)
		return
	level = new_level
	stats.plays += 1
	_save()
	get_tree().paused = false
	_swap_scene(GAME_SCENE)


func start_3d() -> void:
	if _bench_active:
		return
	get_tree().paused = false
	_swap_scene(SCENE_3D)


## Called by scenes: points the overlay at `page`, resets page handlers to the common ones and
## runs `on_ready` each time the page is ready (immediately if it already is). A page *change* is
## navigated only once the new scene has rendered (see _navigate_when_painted).
func show_page(page: String, touch_mode: GodotWebUI.TouchMode, on_ready: Callable) -> void:
	ui.clear_handlers()
	ui.on("settings_changed", change_settings)
	_on_page_ready = on_ready
	ui.set_touch_mode(touch_mode)
	if not ui.is_started() and not _ui_failed:
		_ui_failed = not ui.start(UI_DIR, page)
		_page = page
	elif page != _page:
		_page = page
		_navigate_when_painted(page)
	elif ui.is_ready:
		_page_ready()


## Navigates to `page` only after the scene that requested it has rendered a frame, so the WebView
## never paints the new page over a scene that has not drawn yet. The WebView and the game surface
## render independently, so they cannot swap in the same frame; the closest reliable sync is this
## wait plus the pages themselves: they start hidden (body.loading) and fade in on their first
## state push, so a page can only appear over a scene that is drawn and has sent its state.
## Headless never draws, so there the wait falls back to process frames.
func _navigate_when_painted(page: String) -> void:
	_nav_serial += 1
	var serial := _nav_serial
	for i in 2:
		await get_tree().process_frame
		if serial != _nav_serial or not is_inside_tree():
			return
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		if serial != _nav_serial or not is_inside_tree():
			return
	ui.load_page(page)


func change_settings(p: Dictionary) -> void:
	if typeof(p.get("music")) in [TYPE_FLOAT, TYPE_INT]:
		settings.music = clampf(p.music, 0.0, 1.0)
	if typeof(p.get("sfx")) == TYPE_BOOL:
		settings.sfx = p.sfx
	if typeof(p.get("difficulty")) == TYPE_STRING and p.difficulty in DIFFICULTIES:
		settings.difficulty = p.difficulty
	if typeof(p.get("show_debug")) == TYPE_BOOL:
		settings.show_debug = p.show_debug
	if typeof(p.get("player_name")) == TYPE_STRING:
		settings.player_name = (p.player_name as String).strip_edges().substr(0, 16)
	if typeof(p.get("grove_note")) == TYPE_STRING:
		settings.grove_note = (p.grove_note as String).strip_edges().substr(0, 120)
	_apply_settings()
	_save()
	ui.set_state("settings", settings)


func damage_scale() -> float:
	return {"easy": 0.5, "normal": 1.0, "hard": 2.0}[settings.difficulty]


func sfx(sound_name: String, pitch := 1.0, volume_db := 0.0) -> void:
	_sfx.play(sound_name, pitch, volume_db)


func record(stat: String) -> void:
	stats[stat] += 1
	_save()


## A run finished; keeps the per-level best time and reports the record for the results screen.
func record_victory(finished_level: int, time: float, _hits: int) -> Dictionary:
	var new_best := not best.has(finished_level) or time < float(best[finished_level])
	if new_best:
		best[finished_level] = time
		_save()
	return {"best": format_time(float(best.get(finished_level, time))), "new_best": new_best}


func format_time(seconds: float) -> String:
	return "%d:%02d.%d" % [int(seconds / 60.0), int(seconds) % 60, int(fmod(seconds, 1.0) * 10)]


func _page_ready() -> void:
	ui.set_state("settings", settings)
	ui.set_state("stats", stats)
	var records := {}
	for finished_level in best:
		records["best_%d" % finished_level] = format_time(float(best[finished_level]))
	ui.set_state("records", records)
	ui.set_state("info", {
		"engine": Engine.get_version_info().string,
		"os": OS.get_name(),
		"renderer": str(ProjectSettings.get_setting("rendering/renderer/rendering_method")),
		"level": level,
	})
	if _on_page_ready.is_valid():
		_on_page_ready.call()


func _swap_scene(path: String) -> void:
	var next: Node = load(path).instantiate()
	if next == null:
		return
	if ui.is_started():
		# Tell the currently loaded page to fade itself out while the new scene loads. The event is
		# held while a page is loading and load_page() drops held events, so it never re-hides a page.
		ui.emit_event("app_loading")
	if _scene:
		_scene.queue_free()
		_scene = null
	_scene = next
	_scene.set("app", self)
	add_child(_scene)


func _apply_settings() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(settings.music, 0.0001)))
	_sfx.enabled = settings.sfx


func _load_save() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	# Go through the same validation as page requests.
	change_settings(cfg.get_value("settings", "values", {}))
	var saved: Variant = cfg.get_value("stats", "values", {})
	if typeof(saved) == TYPE_DICTIONARY:
		for key in stats:
			if typeof(saved.get(key)) == TYPE_INT:
				stats[key] = saved[key]
	var records: Variant = cfg.get_value("records", "best", {})
	if typeof(records) == TYPE_DICTIONARY:
		for key: Variant in records:
			if typeof(records[key]) == TYPE_FLOAT or typeof(records[key]) == TYPE_INT:
				best[int(key)] = float(records[key])


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "values", settings)
	cfg.set_value("stats", "values", stats)
	var records := {}
	for finished_level in best:
		records[finished_level] = best[finished_level]
	cfg.set_value("records", "best", records)
	cfg.save(SAVE_PATH)


# ---------------------------------------------------------------- FPS benchmark
# One automated run over the real demo configurations, started from the menu button or the
# user://run_benchmark trigger file. All measurements run on the current device and build with the
# same scene, camera, resolution and rendering settings; the native Label is drawn in every phase
# (beneath the WebView when a page is up), so its overhead is equal across tests. Frame times are
# collected in _process() from Time.get_ticks_usec() deltas after a warm-up; nothing is printed or
# sent until a measurement window closes, so logging cannot skew the numbers.
#
#   A  3D arena scene, WebUI overlay shut down with ui.shutdown() (proper addon lifecycle)
#   B  the same 3D arena scene with its HTML HUD (hud3d.html) in its normal visible state
#   C  the main menu scene with its HTML page (animated canvas background) as a diagnostic

func run_benchmark() -> void:
	if _bench_active or _ui_failed:
		return
	_bench_active = true
	_bench_tag = ""
	_make_bench_label()
	var viewport_size := get_viewport().get_visible_rect().size
	var refresh := DisplayServer.screen_get_refresh_rate()
	print("[bench] run: warmup %.1f s, measure %.1f s | godot %s | renderer %s | model %s | viewport %.0fx%.0f | refresh %s Hz"
		% [BENCH_WARMUP_SEC, BENCH_MEASURE_SEC, Engine.get_version_info().string,
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method")), OS.get_model_name(),
		viewport_size.x, viewport_size.y, ("%.1f" % refresh) if refresh > 0.0 else "unknown"])
	get_tree().paused = false
	_swap_scene(SCENE_3D)  # loads through the normal flow; the 3D HUD page is up only as warm-up
	await _bench_wait_page()
	await _bench_wait(1.0)  # let the page reveal transition finish and the scene settle
	ui.shutdown()
	await _bench_wait(0.5)  # let the overlay teardown settle before Test A
	var results := {}
	results["a_3d_no_ui"] = await _bench_measure("A 3D arena, no UI")
	if _scene and _scene.has_method("show_hud"):
		_scene.show_hud()
	await _bench_wait_page()
	results["b_3d_html"] = await _bench_measure("B 3D arena + HTML HUD")
	show_menu()
	await _bench_wait_page()
	results["c_menu_html"] = await _bench_measure("C menu + HTML page")
	_bench_phase = ""
	_bench_active = false
	_bench_report(results)


## Waits until the overlay is serving a ready page (page_ready fires on every load and restart).
func _bench_wait_page() -> void:
	if ui.is_ready:
		return
	await ui.page_ready


func _bench_wait(seconds: float) -> void:
	_bench_phase = "warmup"
	await get_tree().create_timer(seconds).timeout


func _bench_measure(label: String) -> Dictionary:
	_bench_tag = label
	_bench_frames.clear()
	_bench_skip_frame = true  # the frame spanning the phase change would pollute the window
	_bench_phase = "measure"
	await get_tree().create_timer(BENCH_MEASURE_SEC).timeout
	_bench_phase = ""
	return _bench_stats(label)


func _bench_stats(label: String) -> Dictionary:
	var frames := _bench_frames.duplicate()
	frames.sort()
	var n := frames.size()
	if n < 10:
		printerr("[bench] %s: only %d frames collected, results not comparable" % [label, n])
		return {"label": label, "frames": n}
	var total := 0
	for frame in frames:
		total += frame
	var median := 0.5 * (frames[(n - 1) / 2] + frames[n / 2])
	var spikes := 0
	for frame in frames:
		if frame > median * 2.0:
			spikes += 1
	var stats := {
		"label": label,
		"frames": n,
		"duration_s": snappedf(total / 1000000.0, 0.01),
		"avg_fps": snappedf(n * 1000000.0 / total, 0.1),
		"mean_ms": snappedf(total / float(n) / 1000.0, 0.01),
		"median_ms": snappedf(median / 1000.0, 0.01),
		"p95_ms": snappedf(_bench_percentile(frames, 95.0) / 1000.0, 0.01),
		"p99_ms": snappedf(_bench_percentile(frames, 99.0) / 1000.0, 0.01),
		"max_ms": snappedf(frames[n - 1] / 1000.0, 0.01),
		"spikes_over_2x_median": spikes,
	}
	print("[bench] %s: avg %.1f fps | mean %.2f ms, median %.2f ms, p95 %.2f ms, p99 %.2f ms, max %.2f ms | %d frames in %.2f s | %d spikes > 2x median"
		% [label, stats.avg_fps, stats.mean_ms, stats.median_ms, stats.p95_ms, stats.p99_ms, stats.max_ms,
		n, stats.duration_s, spikes])
	return stats


func _bench_percentile(sorted_frames: PackedInt64Array, pct: float) -> float:
	var n := sorted_frames.size()
	return sorted_frames[clampi(int(round(pct / 100.0 * (n - 1))), 0, n - 1)]


func _bench_report(results: Dictionary) -> void:
	var refresh := DisplayServer.screen_get_refresh_rate()
	var meta := {
		"godot": Engine.get_version_info().string,
		"renderer": str(ProjectSettings.get_setting("rendering/renderer/rendering_method")),
		"model": OS.get_model_name(),
		"viewport_size": str(get_viewport().get_visible_rect().size),
		"refresh_hz": snappedf(refresh, 0.01) if refresh > 0.0 else "unknown",
		"warmup_s": BENCH_WARMUP_SEC,
		"measure_s": BENCH_MEASURE_SEC,
	}
	var doc := {"meta": meta, "results": results}
	var file := FileAccess.open(BENCH_RESULTS_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(doc, "  "))
		file.close()
		print("[bench] results written to ", BENCH_RESULTS_PATH)
	ui.set_state("bench", doc)  # the menu page shows the results card
	if _bench_label:
		_bench_label.queue_free()
		_bench_label = null


func _make_bench_label() -> void:
	if _bench_label:
		_bench_label.queue_free()
	var label := Label.new()
	var font := LabelSettings.new()
	font.font_size = 34
	font.outline_size = 10
	font.outline_color = Color.BLACK
	label.label_settings = font
	label.position = Vector2(24, 24)
	label.z_index = 100
	add_child(label)
	_bench_label = label


## Frame-time collection (every rendered frame) and the live readout on the Label. Runs in every
## phase so the Label costs the same with and without the overlay.
func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _bench_last_usec > 0:
		var frame_usec := now - _bench_last_usec
		if _bench_phase == "measure":
			if _bench_skip_frame:
				_bench_skip_frame = false
			else:
				_bench_frames.append(frame_usec)
		if _bench_label and now >= _bench_label_next:
			_bench_label_next = now + 200000  # 5 Hz is plenty for a readout and costs almost nothing
			_bench_label.text = _bench_label_text(frame_usec)
	_bench_last_usec = now


func _bench_label_text(last_frame_usec: int) -> String:
	if _bench_tag.is_empty():
		return "benchmark: starting..."
	if _bench_phase == "measure" and not _bench_frames.is_empty():
		var total := 0
		for frame in _bench_frames:
			total += frame
		return "%s\n%.1f fps (frame %.1f ms)" % [_bench_tag, _bench_frames.size() * 1000000.0 / total, last_frame_usec / 1000.0]
	return "%s\nwarming up..." % _bench_tag
