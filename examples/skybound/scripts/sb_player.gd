class_name SBPlayer
extends CharacterBody3D
## First-person parkour body. It knows nothing about the WebView: skybound.gd feeds it a move vector,
## jump presses and look deltas.
##
## The camera ("Head") is a top-level node that is placed every frame from this body's interpolated
## position, so mouse and swipe look never wait for a physics tick and the view stays smooth.
##
## Feel: a quick start, air control, coyote time and an input buffer, a held jump goes higher than a
## tap, gravity is heavier on the way down, an optional double jump (the Wing Orb), speed-driven
## field of view, a footstep bob, a camera dip when landing and a roll into strafes.

signal jumped(double: bool)
signal landed(impact: float)
signal stepped
signal bounced

const WALK_SPEED := 6.5
const SPRINT_SPEED := 10.0
const GROUND_ACCEL := 70.0
const GROUND_DECEL := 55.0
const AIR_ACCEL := 17.0
const AIR_DRAG := 1.2
const JUMP_SPEED := 9.5
const DOUBLE_JUMP_SPEED := 8.6
const JUMP_CUT := 0.5
const GRAVITY_UP := 24.0
const GRAVITY_DOWN := 36.0
const HANG_FACTOR := 0.6
const HANG_SPEED := 1.6
const TERMINAL_SPEED := 42.0
const COYOTE_TIME := 0.12
const JUMP_BUFFER := 0.13
const EYE_HEIGHT := 1.62
const PITCH_LIMIT := deg_to_rad(88.0)
const STEP_LENGTH := 2.6

## When true the body ignores input and does not fall (menu, countdown, results).
var frozen := true
var can_double_jump := false
## Pushing the stick fully sprints (touch). On a keyboard a direction key is always a full push, so there
## sprint is the Shift key: auto sprint only listens to an analog stick.
var auto_sprint := true
var analog_input := false
var sprint_held := false
## The controller's own sprint state: sprint input is active and the player is actually moving.
var sprinting := false
var head_bob := true
var base_fov := 78.0
var move_input := Vector2.ZERO  ## x right, y down: pushing the stick up is y = -1
var yaw := 0.0
var pitch := 0.0

var _jump_buffer := 0.0
var _coyote := 0.0
var _jump_held := false
var _can_cut := false
var _air_jumps := 0
var _fall_speed := 0.0
var _was_grounded := true
var _phase := 0.0
var _dip := 0.0
var _dip_speed := 0.0
var _roll := 0.0
var _fov_boost := 0.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera


func _ready() -> void:
	add_to_group("sb_player")
	head.top_level = true
	head.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_place_head(0.0)


## Positive x looks right, positive y looks up (radians).
func look(angles: Vector2) -> void:
	yaw = wrapf(yaw - angles.x, -PI, PI)
	pitch = clampf(pitch + angles.y, -PITCH_LIMIT, PITCH_LIMIT)


func request_jump() -> void:
	if frozen:
		return
	_jump_buffer = JUMP_BUFFER
	_jump_held = true


func release_jump() -> void:
	_jump_held = false


## A spring pad or similar: throws the player upward and refills the air jump.
func bounce(speed: float) -> void:
	velocity.y = speed
	_air_jumps = 1 if can_double_jump else 0
	_can_cut = false
	_dip_speed -= 1.2
	bounced.emit()


## Puts the body at `at` facing `new_yaw`, standing still.
func teleport(at: Vector3, new_yaw: float) -> void:
	global_position = at
	velocity = Vector3.ZERO
	yaw = new_yaw
	pitch = 0.0
	_fall_speed = 0.0
	_jump_buffer = 0.0
	_jump_held = false
	reset_physics_interpolation()
	_place_head(0.0)


func clear_input() -> void:
	move_input = Vector2.ZERO
	analog_input = false
	sprint_held = false
	sprinting = false
	_jump_held = false
	_jump_buffer = 0.0


func horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


## True while the double jump is unlocked and not yet spent in this jump.
func air_jump_ready() -> bool:
	return can_double_jump and _air_jumps > 0


func is_sprinting() -> bool:
	if move_input.length() < 0.1:
		return false
	var forward := -move_input.y
	return sprint_held or (auto_sprint and analog_input and move_input.length() > 0.85 and forward > -0.2)


func _physics_process(delta: float) -> void:
	if frozen:
		velocity = Vector3.ZERO
		sprinting = false
		return
	var grounded := is_on_floor()
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	_coyote = COYOTE_TIME if grounded else maxf(_coyote - delta, 0.0)
	if grounded:
		_air_jumps = 1 if can_double_jump else 0
		if _jump_buffer <= 0.0:
			_jump_held = false

	# ---- jumping: ground (with coyote time), then the air jump
	if _jump_buffer > 0.0:
		if _coyote > 0.0:
			velocity.y = JUMP_SPEED
			if not _jump_held:
				velocity.y *= 0.65  # tapped and released before it started: a hop
			_can_cut = _jump_held
			_consume_jump(false)
		elif _air_jumps > 0 and not _near_ground():  # close to the floor the press is kept for a normal jump
			velocity.y = DOUBLE_JUMP_SPEED
			_air_jumps -= 1
			_can_cut = false
			_consume_jump(true)
	if _can_cut and not _jump_held and velocity.y > JUMP_SPEED * 0.35:
		velocity.y *= JUMP_CUT  # let go while still rising fast: cut it once
		_can_cut = false

	# ---- gravity: lighter at the top of a held jump, heavy on the way down, capped
	if not grounded:
		var g := GRAVITY_DOWN if velocity.y < 0.0 else GRAVITY_UP
		if absf(velocity.y) < HANG_SPEED and _jump_held:
			g *= HANG_FACTOR
		velocity.y = maxf(velocity.y - g * delta, -TERMINAL_SPEED)
		_fall_speed = maxf(_fall_speed, -velocity.y)

	# ---- horizontal movement relative to where the camera looks
	var wish := Vector3(move_input.x, 0.0, move_input.y).rotated(Vector3.UP, yaw)
	wish = wish.limit_length(1.0)
	var top_speed := SPRINT_SPEED if is_sprinting() else WALK_SPEED
	var target := wish * top_speed
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	var rate := AIR_ACCEL
	if grounded:
		rate = GROUND_ACCEL if wish.length() > 0.05 else GROUND_DECEL
	elif wish.length() < 0.05:
		rate = AIR_DRAG
	flat = flat.move_toward(target, rate * delta)
	velocity.x = flat.x
	velocity.z = flat.z

	move_and_slide()

	grounded = is_on_floor()
	if grounded and not _was_grounded:
		var impact := clampf(_fall_speed / 22.0, 0.0, 1.0)
		_dip_speed -= 2.0 + impact * 5.0
		landed.emit(impact)
	if grounded:
		_fall_speed = 0.0
		_can_cut = false
	_was_grounded = grounded
	sprinting = is_sprinting() and horizontal_speed() > 1.0


func _near_ground() -> bool:
	return velocity.y <= 0.0 and test_move(global_transform, Vector3.DOWN * 0.8)


func _consume_jump(double: bool) -> void:
	_jump_buffer = 0.0
	_coyote = 0.0
	_dip_speed += 1.2 if not double else 0.6
	jumped.emit(double)


func _process(delta: float) -> void:
	_update_camera(delta)


func _update_camera(delta: float) -> void:
	var grounded := is_on_floor()
	var speed := horizontal_speed()
	var bob_x := 0.0
	var bob_y := 0.0
	if grounded and speed > 1.0 and not frozen:
		var before := _phase
		_phase += speed * delta / STEP_LENGTH * PI
		if int(_phase / PI) != int(before / PI):
			stepped.emit()
		if head_bob:
			bob_y = sin(_phase * 2.0) * 0.035 * clampf(speed / SPRINT_SPEED, 0.0, 1.0)
			bob_x = cos(_phase) * 0.022 * clampf(speed / SPRINT_SPEED, 0.0, 1.0)
	# landing dip: a damped spring pulls the eye back up
	_dip_speed += (-_dip * 260.0 - _dip_speed * 15.0) * delta
	_dip += _dip_speed * delta
	_dip = clampf(_dip, -0.35, 0.15)
	_place_head(delta, bob_x, bob_y)
	# roll into a strafe, widen the field of view with speed
	var right := Vector3.RIGHT.rotated(Vector3.UP, yaw)
	var strafe := velocity.dot(right) / SPRINT_SPEED
	_roll = lerpf(_roll, -strafe * deg_to_rad(2.2), minf(delta * 8.0, 1.0))
	head.rotation = Vector3(pitch, yaw, _roll)
	var wanted := clampf((speed - WALK_SPEED) / (SPRINT_SPEED - WALK_SPEED), 0.0, 1.0) * 7.0
	wanted += clampf(velocity.y / 20.0, -0.5, 0.5) * 3.0 if not grounded else 0.0
	_fov_boost = lerpf(_fov_boost, wanted, minf(delta * 5.0, 1.0))
	camera.fov = base_fov + _fov_boost


func _place_head(_delta: float, bob_x := 0.0, bob_y := 0.0) -> void:
	var origin := get_global_transform_interpolated().origin
	var right := Vector3.RIGHT.rotated(Vector3.UP, yaw)
	head.global_position = origin + Vector3.UP * (EYE_HEIGHT + _dip + bob_y) + right * bob_x
