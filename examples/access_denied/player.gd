class_name ADPlayer
extends CharacterBody3D
## ACCESS DENIED first-person controller. Movement and look come from the WebUI page
## (move/look events) with direct keyboard/mouse as a fallback when the game window
## has the focus; gravity and capsule collision are real physics.

const SPEED := 3.4
const ACCEL := 12.0
const LOOK_SENS := 0.0032
const REACH := 2.9

var move_vec := Vector2.ZERO        # page input, x=strafe z=forward
var look_delta := Vector2.ZERO      # page input, pixels
var sens := 1.0
var frozen := false                 # true while a terminal/menu owns the screen
var interact_target: Node = null
var prompt := ""  # center-screen interaction prompt (set by game.gd)

var _yaw := 0.0
var _pitch := 0.0
var _keys := {}

signal interact_pressed
signal pause_pressed

@onready var camera: Camera3D = $Camera3D


func _ready() -> void:
	_yaw = rotation.y


func set_frozen(value: bool) -> void:
	frozen = value
	if value:
		move_vec = Vector2.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		look_delta += event.relative
	if event is InputEventKey and event.pressed and not event.echo:
		_keys[event.physical_keycode] = true
		if event.physical_keycode == KEY_E:
			interact_pressed.emit()
		elif event.physical_keycode == KEY_ESCAPE:
			pause_pressed.emit()
	elif event is InputEventKey and not event.pressed:
		_keys[event.physical_keycode] = false


func _physics_process(delta: float) -> void:
	# Look: page deltas first (WebView owns the pointer), direct mouse fallback.
	var direct := Vector2.ZERO
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		direct = look_delta * 1.0
	_apply_look(look_delta if look_delta != Vector2.ZERO else Vector2.ZERO)
	look_delta = Vector2.ZERO

	# Move: page vector first, direct WASD fallback.
	var dir := Vector2.ZERO
	if not frozen:
		dir = move_vec
		if dir == Vector2.ZERO:
			dir = Vector2(
				float(_keys.get(KEY_D, false)) - float(_keys.get(KEY_A, false)),
				float(_keys.get(KEY_W, false)) - float(_keys.get(KEY_S, false)))
		dir = dir.limit_length(1.0)
	var forward := -camera.global_transform.basis.z
	var right := camera.global_transform.basis.x
	var wish := right * dir.x + forward * dir.y
	if wish.length() > 0.01:
		wish = wish.normalized() * SPEED * dir.length()
	else:
		wish = Vector3.ZERO
	velocity.x = move_toward(velocity.x, wish.x, SPEED * ACCEL * delta)
	velocity.z = move_toward(velocity.z, wish.z, SPEED * ACCEL * delta)
	if not is_on_floor():
		velocity += get_gravity() * delta
	else:
		velocity.y = 0.0
	move_and_slide()


func _apply_look(page_delta: Vector2) -> void:
	_yaw -= page_delta.x * LOOK_SENS * sens
	_pitch = clampf(_pitch - page_delta.y * LOOK_SENS * sens, -1.45, 1.45)
	rotation.y = _yaw
	camera.rotation.x = _pitch


## Center-screen raycast; returns the interactable collider within reach, or null.
func ray_target() -> Node:
	var space := get_world_3d().direct_space_state
	var from := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from - camera.global_transform.basis.z * REACH)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit and hit.collider is Node and (hit.collider as Node).is_in_group("interactable"):
		return hit.collider
	return null
