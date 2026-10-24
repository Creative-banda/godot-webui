extends Node2D
## Lumen Hollow: a short gather-and-reach platformer. The level is AUTHORED in game.tscn
## (platforms, grounds, seeds, wisps, gate, backdrop are real scene nodes you can move in the
## editor); this script only reads that layout and runs the loop: gather the seeds, wake the
## gate, reach it. All gameplay lives here and in player.gd; the page sends input and renders
## the state it is given.

@onready var player: DemoPlayer = $Player
@onready var camera: Camera2D = $Player/Camera2D
@onready var gate: GroveGate = $Gate

const PAGE := "hud.html"

const WISP_DAMAGE := 15
const STUN_TIME := 3.0
const FLARES_MAX := 3
const FLARE_RECHARGE := 5.0
const CAMERA_LEFT := -60
const CAMERA_RIGHT := 4320

var shards := 0
var shards_total := 0
var hits := 0
var deaths := 0
var flares := FLARES_MAX
var finished := false

## Set by the demo shell (app.gd) when this scene is opened from the menu.
var app: DemoApp

var _wisps: Array[Wisp] = []
var _elapsed := 0.0
var _time_sec := -1
var _flare_recharge := FLARE_RECHARGE
var _shake := 0.0
var _last_state := {}
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	player.gravity_scale = DemoApp.LEVELS[app.level].gravity
	player.damage_scale = app.damage_scale()
	player.died.connect(_on_player_died)
	player.jumped.connect(func() -> void: app.sfx("jump"))
	player.landed.connect(_on_player_landed)
	player.flared.connect(func(_from: Vector2) -> void: _attempt_flare())

	# Everything below is read from the authored scene so the editor stays the source of truth.
	for seed_pod in $Glimmers.get_children():
		seed_pod.collected.connect(_on_glimmer_collected)
	shards_total = $Glimmers.get_child_count()
	for wisp in $Wisps.get_children():
		wisp.speed_scale *= DemoApp.LEVELS[app.level].wisp_speed
		_wisps.append(wisp)
	gate.entered.connect(_victory)
	# Falling off the map (the gaps between ground segments) is a death: the player respawns.
	$KillFloor.body_entered.connect(func(body: Node2D) -> void:
		if body == player and not player.dead:
			player.kill())
	camera.limit_left = CAMERA_LEFT
	camera.limit_right = CAMERA_RIGHT
	camera.limit_top = -900
	camera.limit_bottom = 840

	show_hud()
	app.sfx("gate", 0.6, -8.0)  # a soft low tone as the hollow wakes up


## Points the shell overlay at the HUD page and registers this scene's page handlers. Also called
## by the benchmark after it shut the overlay down (show_page resets the handlers before these run).
func show_hud() -> void:
	app.show_page(PAGE, GodotWebUI.TouchMode.REGIONS, _on_page_ready)
	var ui := app.ui
	ui.on("move_changed", _on_move_changed)
	ui.on("jump", func(_p: Dictionary) -> void: player.request_jump())
	ui.on("attack_pressed", func(_p: Dictionary) -> void:
		player.attacking = true
		_attempt_flare())
	ui.on("attack_released", func(_p: Dictionary) -> void: player.attacking = false)
	ui.on("flare", func(_p: Dictionary) -> void: _attempt_flare())
	ui.on("damage_self", func(_p: Dictionary) -> void: player.damage(10))
	ui.on("pause_toggle", func(_p: Dictionary) -> void: _set_paused(not get_tree().paused))
	ui.on("restart", func(_p: Dictionary) -> void: app.start_game(app.level))
	ui.on("play_again", func(_p: Dictionary) -> void: app.start_game(app.level))
	ui.on("next_level", func(_p: Dictionary) -> void: app.start_game(2 if app.level == 1 else 1))
	ui.on("back_to_menu", func(_p: Dictionary) -> void: app.show_menu())
	# Desktop dev shortcut forwarded by the page (hud.js, KeyG): jump near the gate.
	ui.on("warp", func(_p: Dictionary) -> void:
		if OS.get_name() != "Android" and not finished:
			player.global_position = gate.position + Vector2(-260.0, -60.0)
			player.velocity = Vector2.ZERO
			player.reset_physics_interpolation())


## Android Back (the shell calls this when the page did not use it): pause, or resume when paused.
func on_back() -> void:
	_set_paused(not get_tree().paused)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		player.clear_input()  # app backgrounded: never leave input held


# ---------------------------------------------------------------- per-frame

func _process(delta: float) -> void:
	if not finished and not get_tree().paused:
		_elapsed += delta
		if int(_elapsed) != _time_sec:
			_time_sec = int(_elapsed)
			_push_state()
	if flares < FLARES_MAX:
		_flare_recharge -= delta
		if _flare_recharge <= 0.0:
			flares += 1
			_flare_recharge = FLARE_RECHARGE
			_push_state()
	# Camera: gentle look-ahead plus a short shake on hits.
	_shake = move_toward(_shake, 0.0, delta * 26.0)
	var look := clampf(player.velocity.x * 0.24, -90.0, 90.0)
	var jitter := Vector2.ZERO
	if _shake > 0.1:
		jitter = Vector2(_rng.randf_range(-_shake, _shake), _rng.randf_range(-_shake, _shake))
	camera.offset = camera.offset.lerp(Vector2(look, -120.0) + jitter, minf(delta * 5.0, 1.0))


func _physics_process(_delta: float) -> void:
	if finished:
		return
	for wisp in _wisps:
		if wisp.is_stunned():
			continue
		for body in wisp.get_overlapping_bodies():
			if body == player and not player.dead:
				_hit_player(wisp)


# ---------------------------------------------------------------- flow

func _on_glimmer_collected(_glimmer: Glimmer) -> void:
	shards += 1
	app.sfx("pick", 1.0 + shards * 0.06)
	# One-shot event so the HUD can answer the pickup where it happened on screen.
	app.ui.emit_event("seed_collected", {
		"x": _screen_pos_of_player().x,
		"y": _screen_pos_of_player().y,
		"shards": shards,
		"total": shards_total,
	})
	if shards >= shards_total:
		gate.open = true
		app.sfx("gate")
		app.ui.emit_event("gate_awake", {})
	_push_state()


## The player's position in fractions of the viewport, so the page can place effects without
## knowing the resolution.
func _screen_pos_of_player() -> Vector2:
	var center := camera.get_screen_center_position()
	var size := get_viewport().get_visible_rect().size
	return Vector2(
		(player.global_position.x - center.x) / size.x + 0.5,
		(player.global_position.y - center.y) / size.y + 0.5)


func _attempt_flare() -> void:
	if finished or player.dead or flares <= 0:
		return
	flares -= 1
	if flares < FLARES_MAX and _flare_recharge <= 0.0:
		_flare_recharge = FLARE_RECHARGE
	var ring := FlareRing.new()
	ring.position = player.global_position
	add_child(ring)
	for wisp in _wisps:
		if wisp.global_position.distance_to(player.global_position) <= DemoPlayer.FLARE_RADIUS:
			wisp.stun(STUN_TIME)
	_shake = 5.0
	app.sfx("flare")
	_push_state()


func _hit_player(wisp: Wisp) -> void:
	hits += 1
	_shake = 9.0
	player.velocity.y = -360.0
	player.velocity.x = signf(player.global_position.x - wisp.global_position.x) * 280.0
	player.damage(WISP_DAMAGE)
	app.sfx("hurt")
	_push_state()


func _on_player_died() -> void:
	deaths += 1
	app.record("deaths")
	app.sfx("ko")
	_push_state()


func _on_player_landed() -> void:
	app.sfx("land", _rng.randf_range(0.9, 1.1), -6.0)
	_dust(player.global_position + Vector2(0, 28))


## Transient landing dust (one-shot particles).
func _dust(at: Vector2) -> void:
	var dust := CPUParticles2D.new()
	dust.one_shot = true
	dust.emitting = true
	dust.amount = 8
	dust.lifetime = 0.4
	dust.explosiveness = 1.0
	dust.spread = 70.0
	dust.direction = Vector2.UP
	dust.initial_velocity_min = 30.0
	dust.initial_velocity_max = 80.0
	dust.gravity = Vector2(0, 240)
	dust.scale_amount_min = 1.5
	dust.scale_amount_max = 3.0
	dust.color = Color(0.5, 0.55, 0.75, 0.45)
	dust.position = at
	add_child(dust)
	get_tree().create_timer(0.8).timeout.connect(dust.queue_free)


func _victory() -> void:
	if finished:
		return
	finished = true
	player.clear_input()
	# The payoff: a breath of slow motion while light bursts from the gate, a warm flash from the
	# page, then the results.
	app.ui.emit_event("victory", {})
	Engine.time_scale = 0.35
	_gate_burst()
	await get_tree().create_timer(0.55, true, false, true).timeout
	Engine.time_scale = 1.0
	var record := app.record_victory(app.level, _elapsed, hits)
	app.sfx("win")
	ui_set_state("results", {
		"time": _format_time(_elapsed),
		"time_sec": snappedf(_elapsed, 0.1),
		"shards": shards,
		"shards_total": shards_total,
		"hits": hits,
		"deaths": deaths,
		"best": record.best,
		"new_best": record.new_best,
		"verdict": _verdict(),
		"level_name": DemoApp.LEVELS[app.level].name,
		"next_name": DemoApp.LEVELS[2 if app.level == 1 else 1].name,
	})
	_push_state()


func _verdict() -> String:
	if hits == 0 and deaths == 0:
		return "Flawless run — not a scratch"
	if _elapsed < 75.0:
		return "Swift keeper"
	if deaths == 0:
		return "A steady walk home"
	return "The hollow tests everyone"


## One-shot golden burst at the gate when the run completes.
func _gate_burst() -> void:
	var ring := FlareRing.new()
	ring.position = gate.position + Vector2(0, -110.0)
	add_child(ring)
	var burst := CPUParticles2D.new()
	burst.one_shot = true
	burst.emitting = true
	burst.amount = 26
	burst.lifetime = 0.9
	burst.explosiveness = 1.0
	burst.direction = Vector2.UP
	burst.spread = 160.0
	burst.initial_velocity_min = 90.0
	burst.initial_velocity_max = 260.0
	burst.gravity = Vector2(0, 220)
	burst.scale_amount_min = 1.6
	burst.scale_amount_max = 3.4
	burst.color = Color(1.0, 0.88, 0.55)
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	burst.material = additive
	burst.position = gate.position + Vector2(0, -110.0)
	add_child(burst)
	get_tree().create_timer(1.4).timeout.connect(burst.queue_free)


func _exit_tree() -> void:
	Engine.time_scale = 1.0
	get_tree().paused = false


func _set_paused(value: bool) -> void:
	get_tree().paused = value
	player.clear_input()
	_push_state()


func _on_page_ready() -> void:
	_last_state = {}
	_push_state()


# ---------------------------------------------------------------- HUD state

## Small helper so every state push goes through the same validated path.
func ui_set_state(name: String, payload: Dictionary) -> void:
	app.ui.set_state(name, payload)


func _format_time(seconds: float) -> String:
	return "%d:%02d.%d" % [int(seconds / 60.0), int(seconds) % 60, int(fmod(seconds, 1.0) * 10)]


func _push_state() -> void:
	var state := {
		"shards": shards,
		"shards_total": shards_total,
		"health": player.health,
		"max_health": DemoPlayer.MAX_HEALTH,
		"dead": player.dead,
		"paused": get_tree().paused,
		"finished": finished,
		"flares": flares,
		"flares_max": FLARES_MAX,
		"flare_k": snappedf(1.0 - clampf(_flare_recharge / FLARE_RECHARGE, 0.0, 1.0), 0.05) if flares < FLARES_MAX else 1.0,
		"gate_open": gate.open,
		"time_sec": _time_sec,
		"hits": hits,
		"level": app.level,
		"level_name": DemoApp.LEVELS[app.level].name,
		"difficulty": app.settings.difficulty,
		"show_debug": app.settings.show_debug,
	}
	if state != _last_state:
		_last_state = state
		ui_set_state("state", state)


# ---------------------------------------------------------------- page input

func _on_move_changed(payload: Dictionary) -> void:
	var x: Variant = payload.get("x")
	var y: Variant = payload.get("y")
	if typeof(x) not in [TYPE_FLOAT, TYPE_INT] or typeof(y) not in [TYPE_FLOAT, TYPE_INT]:
		printerr("move_changed needs numeric x and y, got ", payload)
		return
	player.move_input = Vector2(clampf(x, -1.0, 1.0), clampf(y, -1.0, 1.0))
