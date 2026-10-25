class_name Skybound
extends Node3D
## SKYBOUND: a first-person parkour course over the clouds, built to show what an HTML interface can
## do on top of a 3D game. Godot owns everything that matters (movement, the run, medals, saves,
## settings); the page (ui/index.html) shows it and sends intent:
##
##   page -> Godot   move_changed, jump, jump_released, look_drag, sprint, keys_changed, start_run,
##                   pause, resume, retry_checkpoint, restart_run, to_menu, quit, settings_changed
##   Godot -> page   state "screen" (which screen is up), "settings", "profile" (best run), "hud"
##                   (20 Hz while running: time, speed, shards, marker positions projected from 3D),
##                   "results"; events: countdown, section, toast, shard, respawn, finish
##
## Run this scene (F6). Desktop preview: WASD / arrows move, Shift sprints, Space jumps, drag the
## mouse to look, Esc pauses, R returns to the checkpoint. On a phone: stick, jump button and a swipe
## anywhere else to look. Android Back pauses, resumes or leaves, depending on the screen.

enum Mode { MENU, COUNTDOWN, PLAYING, PAUSED, RESULTS }

const UI_DIR := "res://examples/skybound/ui"
const SAVE_PATH := "user://skybound.cfg"
const HUD_INTERVAL := 0.05
const RADIANS_PER_SCREEN_HEIGHT := PI
const KILL_DEPTH := 26.0  ## metres below the last checkpoint
## Medal times in seconds: gold, silver, bronze.
const MEDAL_TIMES := [150.0, 210.0, 300.0]
const MEDAL_NAMES := ["gold", "silver", "bronze"]

@onready var player: SBPlayer = $Player
@onready var menu_rig: Node3D = $MenuRig
@onready var menu_camera: Camera3D = $MenuRig/Camera

var ui: GodotWebUI
var mode := Mode.MENU
var settings := {
	"sensitivity": 1.0, "fov": 78.0, "invert_y": false, "auto_sprint": true,
	"head_bob": true, "speed_lines": true, "show_fps": false,
}
var profile := {"best_time": -1.0, "best_shards": 0, "best_deaths": -1, "plays": 0, "finishes": 0}

var run_time := 0.0
var run_deaths := 0
var run_shards := 0
var shard_total := 0
var current_cp := 0
var has_wings := false

var _checkpoints: Array[SBCheckpoint] = []
var _shards: Array[SBShard] = []
var _wings: Array[SBWings] = []
var _goal: SBGoal
var _stick := Vector2.ZERO
var _page_keys := Vector2.ZERO
var _hud_timer := 0.0
var _results := {}


func _ready() -> void:
	_load_save()
	ui = GodotWebUI.new()
	ui.process_mode = Node.PROCESS_MODE_ALWAYS  # keep serving the page while the game is paused
	add_child(ui)
	ui.handle_back_button = true
	ui.back_requested.connect(on_back)
	ui.error.connect(func(code: String, text: String) -> void: printerr("WebUI ", code, ": ", text))
	ui.page_ready.connect(_push_all)
	ui.set_touch_mode(GodotWebUI.TouchMode.REGIONS)
	_register_handlers()
	menu_rig.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_wire_level()
	_apply_settings()
	_enter_menu()
	ui.start(UI_DIR, "index.html")
	_dev_arguments.call_deferred()


func _register_handlers() -> void:
	ui.on("move_changed", _on_move_changed)
	ui.on("keys_changed", _on_keys_changed)
	ui.on("jump", func(_p: Dictionary) -> void: player.request_jump())
	ui.on("jump_released", func(_p: Dictionary) -> void: player.release_jump())
	ui.on("sprint", _on_sprint)
	ui.on("look_drag", _on_look_drag)
	ui.on("start_run", func(_p: Dictionary) -> void: start_run())
	ui.on("pause", func(_p: Dictionary) -> void: set_paused(true))
	ui.on("resume", func(_p: Dictionary) -> void: set_paused(false))
	ui.on("retry_checkpoint", func(_p: Dictionary) -> void: retry_checkpoint())
	ui.on("restart_run", func(_p: Dictionary) -> void: start_run())
	ui.on("to_menu", func(_p: Dictionary) -> void: to_menu())
	ui.on("quit", func(_p: Dictionary) -> void: get_tree().quit())
	ui.on("settings_changed", _on_settings_changed)


## Finds the course pieces the level builder placed and listens to them.
func _wire_level() -> void:
	for node in get_tree().get_nodes_in_group("sb_checkpoint"):
		var cp := node as SBCheckpoint
		_checkpoints.append(cp)
		cp.reached.connect(_on_checkpoint)
	_checkpoints.sort_custom(func(a: SBCheckpoint, b: SBCheckpoint) -> bool: return a.index < b.index)
	for node in get_tree().get_nodes_in_group("sb_shard"):
		var shard := node as SBShard
		_shards.append(shard)
		shard.collected.connect(_on_shard)
	shard_total = _shards.size()
	for node in get_tree().get_nodes_in_group("sb_wings"):
		var orb := node as SBWings
		_wings.append(orb)
		orb.collected.connect(_on_wings)
	var goals := get_tree().get_nodes_in_group("sb_goal")
	if not goals.is_empty():
		_goal = goals[0]
		_goal.reached.connect(_on_goal)


# ---------------------------------------------------------------- development shortcuts

## Optional arguments after `--` (godot ... -- --sb-autostart): used for screenshots and smoke tests.
##   --sb-touch      show the touch controls (stick, jump) in the desktop preview
##   --sb-autostart  start a run by itself;  --sb-run  also run forward and jump;  --sb-pause / --sb-results  end there
func _dev_arguments() -> void:
	var args := OS.get_cmdline_user_args()
	if "--sb-touch" in args:
		ui.set_state("dev", {"touch": true})
	if not ("--sb-autostart" in args or "--sb-run" in args or "--sb-pause" in args or "--sb-results" in args):
		return
	await get_tree().create_timer(2.0).timeout
	start_run()
	await get_tree().create_timer(3.6).timeout
	if "--sb-run" in args:
		_page_keys = Vector2(0, -1)
		await get_tree().create_timer(1.1).timeout
		player.request_jump()
		await get_tree().create_timer(0.2).timeout
		player.release_jump()
		await get_tree().create_timer(2.0).timeout
	if "--sb-pause" in args:
		set_paused(true)
	if "--sb-results" in args:
		run_time = 161.3
		run_shards = mini(21, shard_total)
		run_deaths = 3
		_on_goal()


# ---------------------------------------------------------------- flow

func _enter_menu() -> void:
	get_tree().paused = false
	mode = Mode.MENU
	player.frozen = true
	player.clear_input()
	_stick = Vector2.ZERO
	_page_keys = Vector2.ZERO
	menu_camera.make_current()
	_push_screen()


func to_menu() -> void:
	_enter_menu()


func start_run() -> void:
	get_tree().paused = false
	run_time = 0.0
	run_deaths = 0
	run_shards = 0
	current_cp = 0
	has_wings = false
	player.can_double_jump = false
	for shard in _shards:
		shard.reset()
	for orb in _wings:
		orb.reset()
	if _goal:
		_goal.reset()
	for cp in _checkpoints:
		cp.set_active(false)
	if not _checkpoints.is_empty():
		_checkpoints[0].set_active(true)
	_place_player_at_checkpoint()
	player.frozen = true
	player.camera.make_current()
	profile.plays += 1
	_save()
	mode = Mode.COUNTDOWN
	_push_screen()
	_push_hud()
	_countdown()


func _countdown() -> void:
	for n in [3, 2, 1]:
		ui.emit_event("countdown", {"n": n})
		await get_tree().create_timer(0.8, true, false, true).timeout
		if mode != Mode.COUNTDOWN:
			return
	ui.emit_event("countdown", {"n": 0})
	player.frozen = false
	mode = Mode.PLAYING
	_push_screen()
	_announce_section(0)


func set_paused(value: bool) -> void:
	if value and mode in [Mode.PLAYING, Mode.COUNTDOWN]:
		mode = Mode.PAUSED
		get_tree().paused = true
		player.clear_input()
		_stick = Vector2.ZERO
		_page_keys = Vector2.ZERO
		_push_screen()
	elif not value and mode == Mode.PAUSED:
		get_tree().paused = false
		mode = Mode.PLAYING if not player.frozen else Mode.COUNTDOWN
		_push_screen()


func retry_checkpoint() -> void:
	if mode == Mode.PAUSED:
		set_paused(false)
	if mode != Mode.PLAYING:
		return
	_respawn(false)


## Android Back (the page already had its chance through Godot.onBack).
func on_back() -> void:
	match mode:
		Mode.MENU:
			get_tree().quit()
		Mode.PLAYING, Mode.COUNTDOWN:
			set_paused(true)
		Mode.PAUSED:
			set_paused(false)
		Mode.RESULTS:
			to_menu()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_stick = Vector2.ZERO
		_page_keys = Vector2.ZERO
		player.clear_input()
		if mode == Mode.PLAYING:
			set_paused(true)


func _place_player_at_checkpoint() -> void:
	if _checkpoints.is_empty():
		return
	var cp := _checkpoints[clampi(current_cp, 0, _checkpoints.size() - 1)]
	var at := cp.spawn_transform()
	player.teleport(at.origin, at.basis.get_euler().y)


func _respawn(count_death: bool) -> void:
	if count_death:
		run_deaths += 1
	_place_player_at_checkpoint()
	ui.emit_event("respawn", {"deaths": run_deaths})


func _announce_section(index: int) -> void:
	var names := SBBuild.SECTION_NAMES
	ui.emit_event("section", {"number": index + 1, "total": names.size(), "name": names[clampi(index, 0, names.size() - 1)]})


# ---------------------------------------------------------------- course events

func _on_checkpoint(index: int) -> void:
	if index <= current_cp:
		return
	current_cp = index
	for cp in _checkpoints:
		cp.set_active(cp.index == index)
	if index > 0:
		_announce_section(index)
		ui.emit_event("toast", {"text": "Checkpoint saved", "kind": "checkpoint"})


func _on_shard(_shard: SBShard) -> void:
	run_shards += 1
	ui.emit_event("shard", {"n": run_shards, "total": shard_total})


func _on_wings() -> void:
	has_wings = true
	player.can_double_jump = true
	ui.emit_event("toast", {"text": "Wing Orb: double jump unlocked", "kind": "power", "hint": "Press jump again in the air"})


func _on_goal() -> void:
	if mode != Mode.PLAYING:
		return
	mode = Mode.RESULTS
	player.frozen = true
	player.clear_input()
	_stick = Vector2.ZERO
	var previous_best: float = profile.best_time
	var new_best := previous_best < 0.0 or run_time < previous_best
	if new_best:
		profile.best_time = run_time
		profile.best_deaths = run_deaths
	profile.best_shards = maxi(int(profile.best_shards), run_shards)
	profile.finishes += 1
	_save()
	_results = {
		"time": snappedf(run_time, 0.01),
		"shards": run_shards,
		"shards_total": shard_total,
		"deaths": run_deaths,
		"medal": medal_for(run_time),
		"new_best": new_best,
		"best_time": snappedf(profile.best_time, 0.01),
		"perfect": run_shards == shard_total and run_deaths == 0,
		"medal_times": MEDAL_TIMES,
	}
	ui.emit_event("finish", {})
	ui.set_state("results", _results)
	_push_profile()
	_push_screen()


static func medal_for(seconds: float) -> String:
	for i in MEDAL_TIMES.size():
		if seconds <= MEDAL_TIMES[i]:
			return MEDAL_NAMES[i]
	return "none"


# ---------------------------------------------------------------- loop

func _physics_process(delta: float) -> void:
	if mode == Mode.PLAYING:
		run_time += delta
		player.move_input = _stick if _stick != Vector2.ZERO else _page_keys
		var floor_y := _checkpoints[current_cp].global_position.y if not _checkpoints.is_empty() else 0.0
		if player.global_position.y < floor_y - KILL_DEPTH:
			_respawn(true)
	elif mode == Mode.COUNTDOWN:
		player.move_input = Vector2.ZERO


func _process(delta: float) -> void:
	if mode == Mode.MENU:
		menu_rig.rotation.y += delta * 0.07
		menu_camera.look_at(menu_rig.global_position + Vector3(0.0, 3.0, 0.0))
	if mode == Mode.PLAYING or mode == Mode.COUNTDOWN:
		_hud_timer += delta
		if _hud_timer >= HUD_INTERVAL:
			_hud_timer = 0.0
			_push_hud()


# ---------------------------------------------------------------- page input

func _on_move_changed(payload: Dictionary) -> void:
	var x: Variant = payload.get("x")
	var y: Variant = payload.get("y")
	if typeof(x) not in [TYPE_FLOAT, TYPE_INT] or typeof(y) not in [TYPE_FLOAT, TYPE_INT]:
		printerr("move_changed needs numeric x and y, got ", payload)
		return
	_stick = Vector2(clampf(x, -1.0, 1.0), clampf(y, -1.0, 1.0)).limit_length(1.0)


func _on_keys_changed(payload: Dictionary) -> void:
	for key in ["up", "down", "left", "right"]:
		if typeof(payload.get(key, false)) != TYPE_BOOL:
			printerr("keys_changed: '", key, "' must be a bool, got ", payload)
			return
	_page_keys = Vector2(
		float(payload.get("right", false)) - float(payload.get("left", false)),
		float(payload.get("down", false)) - float(payload.get("up", false))).limit_length(1.0)


func _on_sprint(payload: Dictionary) -> void:
	if typeof(payload.get("held")) != TYPE_BOOL:
		printerr("sprint needs a bool 'held', got ", payload)
		return
	player.sprint_held = payload.held


## `dx`, `dy` are fractions of the screen height, so the feel is the same on every screen.
func _on_look_drag(payload: Dictionary) -> void:
	var dx: Variant = payload.get("dx")
	var dy: Variant = payload.get("dy")
	if typeof(dx) not in [TYPE_FLOAT, TYPE_INT] or typeof(dy) not in [TYPE_FLOAT, TYPE_INT]:
		printerr("look_drag needs numeric dx and dy, got ", payload)
		return
	if mode != Mode.PLAYING and mode != Mode.COUNTDOWN:
		return
	var k: float = RADIANS_PER_SCREEN_HEIGHT * settings.sensitivity
	var invert := -1.0 if settings.invert_y else 1.0
	player.look(Vector2(clampf(dx, -1.0, 1.0) * k, -clampf(dy, -1.0, 1.0) * k * invert))


func _on_settings_changed(payload: Dictionary) -> void:
	_merge_settings(payload)
	_apply_settings()
	_save()
	ui.set_state("settings", settings)


func _apply_settings() -> void:
	player.base_fov = settings.fov
	player.auto_sprint = settings.auto_sprint
	player.head_bob = settings.head_bob


# ---------------------------------------------------------------- page output

func _push_all() -> void:
	ui.set_state("settings", settings)
	_push_profile()
	_push_screen()
	if not _results.is_empty():
		ui.set_state("results", _results)
	_push_hud()


func _push_profile() -> void:
	var best: float = profile.best_time
	ui.set_state("profile", {
		"best_time": snappedf(best, 0.01) if best >= 0.0 else -1.0,
		"best_medal": medal_for(best) if best >= 0.0 else "none",
		"best_shards": profile.best_shards,
		"shard_total": shard_total,
		"plays": profile.plays,
		"finishes": profile.finishes,
		"medal_times": MEDAL_TIMES,
	})


func _push_screen() -> void:
	var names := {
		Mode.MENU: "menu", Mode.COUNTDOWN: "play", Mode.PLAYING: "play",
		Mode.PAUSED: "pause", Mode.RESULTS: "results",
	}
	ui.set_state("screen", {"name": names[mode], "counting": mode == Mode.COUNTDOWN})


func _push_hud() -> void:
	var cam := get_viewport().get_camera_3d()
	var markers: Array = []
	if cam and mode in [Mode.PLAYING, Mode.COUNTDOWN]:
		var next_cp := current_cp + 1
		if next_cp < _checkpoints.size():
			markers.append(_marker(cam, "checkpoint", _checkpoints[next_cp].global_position + Vector3(0, 3.6, 0), SBBuild.SECTION_NAMES[next_cp]))
		elif _goal:
			markers.append(_marker(cam, "goal", _goal.global_position + Vector3(0, 5.0, 0), "FINISH"))
	ui.set_state("hud", {
		"time": snappedf(run_time, 0.01),
		"speed": roundi(player.horizontal_speed() * 3.6),
		"sprint": player.is_sprinting() and player.horizontal_speed() > 6.0,
		"air": not player.is_on_floor(),
		"shards": run_shards,
		"shard_total": shard_total,
		"deaths": run_deaths,
		"section": current_cp + 1,
		"section_name": SBBuild.SECTION_NAMES[clampi(current_cp, 0, SBBuild.SECTION_NAMES.size() - 1)],
		"wings": has_wings,
		"fps": roundi(Engine.get_frames_per_second()),
		"markers": markers,
	})


func _marker(cam: Camera3D, kind: String, at: Vector3, label: String) -> Dictionary:
	var size := get_viewport().get_visible_rect().size
	var behind := cam.is_position_behind(at)
	var p := cam.unproject_position(at)
	var x := p.x / size.x
	var y := p.y / size.y
	if behind:
		x = 1.0 - x  # keep the arrow on the side the target is on
		y = 1.0
	return {
		"kind": kind, "label": label, "x": snappedf(x, 0.001), "y": snappedf(y, 0.001),
		"behind": behind, "dist": roundi(player.global_position.distance_to(at)),
	}


# ---------------------------------------------------------------- saving

func _load_save() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	var saved: Variant = cfg.get_value("settings", "values", {})
	if typeof(saved) == TYPE_DICTIONARY:
		_merge_settings(saved)
	var prof: Variant = cfg.get_value("profile", "values", {})
	if typeof(prof) == TYPE_DICTIONARY:
		for key in profile:
			if typeof(prof.get(key)) in [TYPE_INT, TYPE_FLOAT]:
				profile[key] = prof[key]


## Takes the values it recognises from `payload`, clamped and type-checked (page requests and saved files).
func _merge_settings(payload: Dictionary) -> void:
	for key in ["sensitivity", "fov"]:
		if typeof(payload.get(key)) in [TYPE_FLOAT, TYPE_INT]:
			settings[key] = clampf(payload[key], 0.2 if key == "sensitivity" else 65.0, 3.0 if key == "sensitivity" else 100.0)
	for key in ["invert_y", "auto_sprint", "head_bob", "speed_lines", "show_fps"]:
		if typeof(payload.get(key)) == TYPE_BOOL:
			settings[key] = payload[key]


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "values", settings)
	cfg.set_value("profile", "values", profile)
	cfg.save(SAVE_PATH)
