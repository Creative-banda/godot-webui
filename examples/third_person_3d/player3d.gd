class_name Demo3DPlayer
extends CharacterBody3D
## Third-person character. It knows nothing about the WebView: main3d.gd feeds it a stick vector and
## jump requests, and the camera yaw so that "up" on the stick always means "away from the camera".

signal jumped

const SPEED := 6.0
const ACCELERATION := 45.0
const AIR_CONTROL := 0.5
const JUMP_VELOCITY := 7.5
const GRAVITY := 22.0
const TURN_SPEED := 12.0
const JUMP_BUFFER := 0.12
const COYOTE_TIME := 0.1
const FALL_LIMIT := -15.0

## Screen-space stick: x right, y down (so pushing the stick up is y = -1). Length 0..1.
var move_input := Vector2.ZERO
## Yaw of the camera in radians; the stick is interpreted relative to it.
var camera_yaw := 0.0

var _jump_buffer := 0.0
var _coyote := 0.0
var _spawn: Vector3


func _ready() -> void:
	_spawn = global_position


func request_jump() -> void:
	_jump_buffer = JUMP_BUFFER


func clear_input() -> void:
	move_input = Vector2.ZERO
	_jump_buffer = 0.0


func _physics_process(delta: float) -> void:
	var direction := Vector3(move_input.x, 0.0, move_input.y).rotated(Vector3.UP, camera_yaw).limit_length(1.0)
	var grounded := is_on_floor()
	_coyote = COYOTE_TIME if grounded else maxf(_coyote - delta, 0.0)
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)

	var accel := ACCELERATION * (1.0 if grounded else AIR_CONTROL)
	var horizontal := Vector3(velocity.x, 0.0, velocity.z).move_toward(direction * SPEED, accel * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	if not grounded:
		velocity.y -= GRAVITY * delta
	if _jump_buffer > 0.0 and _coyote > 0.0:
		velocity.y = JUMP_VELOCITY
		_jump_buffer = 0.0
		_coyote = 0.0
		jumped.emit()

	move_and_slide()

	if direction.length() > 0.1:  # face the way we run (the model's front is -Z)
		rotation.y = lerp_angle(rotation.y, atan2(-direction.x, -direction.z), minf(TURN_SPEED * delta, 1.0))
	if global_position.y < FALL_LIMIT:
		global_position = _spawn
		reset_physics_interpolation()  # a teleport must not be smoothed into a slide
		velocity = Vector3.ZERO
