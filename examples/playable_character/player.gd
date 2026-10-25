class_name DemoPlayer
extends CharacterBody2D
## The Seed Keeper: a small acorn-bodied grove keeper carrying the last lantern.
## The body art is a child sprite (feet at the local origin) so squash & stretch never
## touches the collider. It knows nothing about the WebView: game.gd feeds it input.
##
## Feel (all tunable below):
##  - Run: quick start, a firmer stop, and a hard brake when you reverse (with a skid).
##  - Jump: hold for a full jump, tap for a hop (release cuts the rise); a moment of hang at the
##    top, heavier gravity on the way down, a terminal speed, coyote time and an input buffer.
##  - Body: a spring-driven squash & stretch, a smooth turn, a lean into the run, a step bounce
##    that is in time with the feet, and a slow breath when standing still.

signal health_changed
signal died
signal jumped
signal landed(impact: float)  ## impact 0..1 from the fall speed
signal flared(from: Vector2)
signal stepped(at: Vector2)  ## a foot touches the ground while running
signal skidded(at: Vector2)  ## reversed direction at speed

const SPEED := 380.0
const GROUND_ACCEL := 2600.0   ## from standing to full speed in about 0.15 s
const GROUND_DECEL := 3200.0   ## letting go of the stick
const GROUND_TURN := 5600.0    ## pushing the opposite way
const AIR_ACCEL := 1900.0
const AIR_DECEL := 450.0       ## momentum carries in the air
const AIR_TURN := 2400.0

const JUMP_VELOCITY := -620.0
const JUMP_CUT := 0.42         ## releasing the button while rising keeps this much of the speed
const FALL_GRAVITY := 1.65     ## times gravity on the way down
const HANG_GRAVITY := 0.5      ## times gravity near the top of a held jump
const HANG_SPEED := 130.0      ## |vertical speed| below this counts as the top
const TERMINAL_SPEED := 1150.0
const JUMP_BUFFER := 0.13
const COYOTE_TIME := 0.11

const MAX_HEALTH := 100
const INVULNERABLE_TIME := 0.6
const RESPAWN_TIME := 1.2
const FLARE_RADIUS := 260.0

const SQUASH_STIFFNESS := 420.0
const SQUASH_DAMPING := 17.0
const STEP_LENGTH := 74.0      ## pixels between footfalls

var move_input := Vector2.ZERO
var attacking := false
var health := MAX_HEALTH
var dead := false
var gravity_scale := 1.0
var damage_scale := 1.0

var _jump_buffer := 0.0
var _coyote := 0.0
var _jump_held := false
var _can_cut := false   # a full jump is rising and has not been cut yet
var _invulnerable := 0.0
var _facing := 1.0
var _face_scale := 1.0  # eased toward _facing so a turn is a quick spin, not a snap
var _spawn: Vector2
var _was_on_floor := true
var _fall_speed := 0.0
var _squash := 1.0      # >1 stretched, <1 squashed; a spring pulls it to its target
var _squash_speed := 0.0
var _step_phase := 0.0
var _clock := 0.0
var _key_left := false
var _key_right := false

@onready var _body: Sprite2D = $Body


func _ready() -> void:
	_spawn = position


func request_jump() -> void:
	_jump_buffer = JUMP_BUFFER
	_jump_held = true


## The jump button was released: a rising jump is cut short (a tap is a hop, a hold a full jump).
func release_jump() -> void:
	_jump_held = false


func damage(amount: int) -> void:
	if dead or _invulnerable > 0.0:
		return
	health = maxi(health - maxi(roundi(amount * damage_scale), 1), 0)
	_invulnerable = INVULNERABLE_TIME
	_squash = 0.74  # a flinch
	health_changed.emit()
	if health == 0:
		_die()


## An unconditional death (falling off the map): ignores the invulnerability window.
func kill() -> void:
	if dead:
		return
	health = 0
	_invulnerable = 0.0
	_die()


func clear_input() -> void:
	move_input = Vector2.ZERO
	attacking = false
	_jump_held = false
	_key_left = false
	_key_right = false


func _die() -> void:
	dead = true
	died.emit()
	clear_input()
	await get_tree().create_timer(RESPAWN_TIME).timeout
	if not is_inside_tree():
		return
	health = MAX_HEALTH
	dead = false
	position = _spawn
	reset_physics_interpolation()  # a teleport must not be smoothed into a slide
	velocity = Vector2.ZERO
	_squash = 1.3  # pop back in
	health_changed.emit()


## Desktop keyboard controls: arrows or A/D move, Space / Up / W jump, X or J flare.
## Keys are tracked from input *events* instead of polling Input, because when the desktop preview
## overlay has keyboard focus its key presses reach Godot as injected events, which Input.is_action_*
## polling does not see.
func _input(event: InputEvent) -> void:
	if OS.get_name() == "Android" or not event is InputEventKey or event.echo:
		return
	var pressed: bool = event.pressed
	if _key_is(event, [KEY_LEFT, KEY_A]):
		_key_left = pressed
	elif _key_is(event, [KEY_RIGHT, KEY_D]):
		_key_right = pressed
	elif _key_is(event, [KEY_SPACE, KEY_UP, KEY_W]):
		if pressed and not dead:
			request_jump()
		elif not pressed:
			release_jump()
	elif _key_is(event, [KEY_X, KEY_J]):
		attacking = pressed and not dead
		if attacking:
			flared.emit(global_position)


func _notification(what: int) -> void:
	# Never leave a key "held" when focus moves between the game window and the overlay.
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_key_left = false
		_key_right = false
		_jump_held = false


func _key_is(event: InputEventKey, keys: Array) -> bool:
	return event.keycode in keys or event.physical_keycode in keys


func _key_axis() -> float:
	return float(int(_key_right) - int(_key_left))


func _physics_process(delta: float) -> void:
	_clock += delta
	_invulnerable = maxf(_invulnerable - delta, 0.0)
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	_coyote = maxf(_coyote - delta, 0.0)
	var grounded := is_on_floor()
	if grounded:
		_coyote = COYOTE_TIME

	# ---- jump
	if grounded and _jump_buffer <= 0.0:
		_jump_held = false  # standing: a stale "held" must not give a free hang on the next ledge walk-off
	if _jump_buffer > 0.0 and _coyote > 0.0 and not dead:
		velocity.y = JUMP_VELOCITY
		if not _jump_held:
			velocity.y *= 0.62  # tapped and let go before the jump even started: a hop
		_can_cut = _jump_held
		_jump_buffer = 0.0
		_coyote = 0.0
		_squash = 1.32  # stretch on take-off
		jumped.emit()
	elif _can_cut and not _jump_held and velocity.y < JUMP_VELOCITY * 0.3:
		velocity.y *= JUMP_CUT  # released while still rising fast: cut it once, then gravity does the rest
		_can_cut = false

	# ---- gravity: lighter at the top of a held jump, heavier on the way down, capped
	if not grounded:
		var g := get_gravity().y * gravity_scale
		if velocity.y > 0.0:
			g *= FALL_GRAVITY
		elif absf(velocity.y) < HANG_SPEED and _jump_held:
			g *= HANG_GRAVITY
		velocity.y = minf(velocity.y + g * delta, TERMINAL_SPEED)
		_fall_speed = maxf(_fall_speed, velocity.y)

	# ---- run
	var axis := 0.0 if dead else move_input.x
	# Desktop keyboard fallback (see _input) so the physics can be tried without touch.
	if axis == 0.0 and not dead:
		axis = _key_axis()
	if absf(axis) > 0.01:
		_facing = signf(axis)
	var target := axis * SPEED
	var rate: float
	if grounded:
		rate = GROUND_ACCEL
		if absf(axis) < 0.01:
			rate = GROUND_DECEL
		elif signf(target) != signf(velocity.x) and absf(velocity.x) > 40.0:
			rate = GROUND_TURN
			if absf(velocity.x) > 160.0:
				skidded.emit(global_position)
	else:
		rate = AIR_ACCEL
		if absf(axis) < 0.01:
			rate = AIR_DECEL
		elif signf(target) != signf(velocity.x) and absf(velocity.x) > 40.0:
			rate = AIR_TURN
	velocity.x = move_toward(velocity.x, target, rate * delta)
	move_and_slide()

	# ---- landing
	grounded = is_on_floor()
	if grounded and not _was_on_floor:
		var impact := clampf(_fall_speed / 900.0, 0.0, 1.0)
		_squash = lerpf(0.86, 0.6, impact)  # a harder fall squashes more
		_squash_speed = 0.0
		landed.emit(impact)
	if grounded:
		_fall_speed = 0.0
		_can_cut = false
	_was_on_floor = grounded
	_update_body(delta, grounded)


## Presentation only: spring squash & stretch from the feet, smooth turn, lean, step bounce,
## idle breathing, hit blink, KO grey.
func _update_body(delta: float, grounded: bool) -> void:
	var speed := absf(velocity.x)
	var running := grounded and speed > 40.0

	# What the body wants to be right now; the spring gets it there with a little overshoot.
	var wanted := 1.0
	if not grounded:
		wanted = 1.0 + clampf(-velocity.y / 2600.0, -0.08, 0.22)  # stretched going up, a touch long falling
	elif running:
		_step_phase += speed * delta / STEP_LENGTH * PI
		wanted = 1.0 + 0.05 * cos(_step_phase * 2.0)
		if int(_step_phase / PI) != int((_step_phase - speed * delta / STEP_LENGTH * PI) / PI):
			stepped.emit(global_position)
	else:
		_step_phase = 0.0
		wanted = 1.0 + 0.022 * sin(_clock * 2.4)  # breathing
	_squash_speed += ((wanted - _squash) * SQUASH_STIFFNESS - _squash_speed * SQUASH_DAMPING) * delta
	_squash = clampf(_squash + _squash_speed * delta, 0.5, 1.5)

	# Turning: the sprite spins through its edge instead of snapping.
	_face_scale = move_toward(_face_scale, _facing, delta * 11.0)
	var width := 2.0 - _squash  # volume is roughly kept: taller = narrower
	_body.scale = Vector2(width * (_face_scale if absf(_face_scale) > 0.08 else 0.08 * signf(_facing)), _squash)

	# Hop with each step; lean into the run and a little with the vertical speed.
	if running:
		_body.position.y = -absf(sin(_step_phase)) * 5.0
	else:
		_body.position.y = lerpf(_body.position.y, 0.0, minf(delta * 20.0, 1.0))
	var lean := clampf(velocity.x / SPEED, -1.0, 1.0) * 0.16
	if not grounded:
		lean += clampf(velocity.y / 2400.0, -0.1, 0.1) * _facing * -0.5
	_body.rotation = lerp_angle(_body.rotation, lean, minf(delta * 14.0, 1.0))

	if dead:
		_body.modulate = Color(0.55, 0.55, 0.62)
	elif _invulnerable > 0.0 and fmod(_invulnerable, 0.16) > 0.08:
		_body.modulate = Color(2.2, 2.2, 2.2)
	else:
		_body.modulate = Color.WHITE
