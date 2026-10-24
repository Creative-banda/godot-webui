class_name DemoPlayer
extends CharacterBody2D
## The Seed Keeper: a small acorn-bodied grove keeper carrying the last lantern.
## The body art is a child sprite (feet at the local origin) so squash & stretch never
## touches the collider. It knows nothing about the WebView: game.gd feeds it input.

signal health_changed
signal died
signal jumped
signal landed
signal flared(from: Vector2)

const SPEED := 360.0
const ACCELERATION := 3200.0
const JUMP_VELOCITY := -640.0
const JUMP_BUFFER := 0.12
const COYOTE_TIME := 0.1
const MAX_HEALTH := 100
const INVULNERABLE_TIME := 0.6
const RESPAWN_TIME := 1.2
const FLARE_RADIUS := 260.0

var move_input := Vector2.ZERO
var attacking := false
var health := MAX_HEALTH
var dead := false
var gravity_scale := 1.0
var damage_scale := 1.0

var _jump_buffer := 0.0
var _coyote := 0.0
var _invulnerable := 0.0
var _facing := 1.0
var _spawn: Vector2
var _was_on_floor := true
var _squash := 1.0  # >1 stretched (rising), <1 squashed (landing); eased back to 1
var _key_left := false
var _key_right := false

@onready var _body: Sprite2D = $Body


func _ready() -> void:
	_spawn = position


func request_jump() -> void:
	_jump_buffer = JUMP_BUFFER


func damage(amount: int) -> void:
	if dead or _invulnerable > 0.0:
		return
	health = maxi(health - maxi(roundi(amount * damage_scale), 1), 0)
	_invulnerable = INVULNERABLE_TIME
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
	elif _key_is(event, [KEY_X, KEY_J]):
		attacking = pressed and not dead
		if attacking:
			flared.emit(global_position)


func _notification(what: int) -> void:
	# Never leave a key "held" when focus moves between the game window and the overlay.
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_key_left = false
		_key_right = false


func _key_is(event: InputEventKey, keys: Array) -> bool:
	return event.keycode in keys or event.physical_keycode in keys


func _key_axis() -> float:
	return float(int(_key_right) - int(_key_left))


func _physics_process(delta: float) -> void:
	_invulnerable = maxf(_invulnerable - delta, 0.0)
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	_coyote = maxf(_coyote - delta, 0.0)

	if not is_on_floor():
		velocity += get_gravity() * gravity_scale * delta
	if is_on_floor():
		_coyote = COYOTE_TIME
	if _jump_buffer > 0.0 and _coyote > 0.0 and not dead:
		velocity.y = JUMP_VELOCITY
		_jump_buffer = 0.0
		_coyote = 0.0
		_squash = 1.22  # stretch on take-off
		jumped.emit()

	var axis := 0.0 if dead else move_input.x
	# Desktop keyboard fallback (see _input) so the physics can be tried without touch.
	if axis == 0.0 and not dead:
		axis = _key_axis()
	if absf(axis) > 0.01:
		_facing = signf(axis)
	velocity.x = move_toward(velocity.x, axis * SPEED, ACCELERATION * delta)
	move_and_slide()

	if is_on_floor() and not _was_on_floor:
		_squash = 0.78  # squash on landing
		landed.emit()
	_was_on_floor = is_on_floor()
	_squash = lerpf(_squash, 1.0, minf(delta * 12.0, 1.0))
	_update_body()


## Presentation only: squash & stretch from the feet, facing flip, hit blink, KO grey.
func _update_body() -> void:
	_body.scale = Vector2(2.0 - _squash, _squash)
	_body.flip_h = _facing < 0.0
	if dead:
		_body.modulate = Color(0.55, 0.55, 0.62)
	elif _invulnerable > 0.0 and fmod(_invulnerable, 0.16) > 0.08:
		_body.modulate = Color(2.2, 2.2, 2.2)
	else:
		_body.modulate = Color.WHITE
