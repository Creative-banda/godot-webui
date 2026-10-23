class_name DemoPlayer
extends CharacterBody2D
## Physics character. It knows nothing about the WebView: main.gd feeds it input.

signal health_changed
signal died
signal jumped

const SPEED := 360.0
const ACCELERATION := 3200.0
const JUMP_VELOCITY := -640.0
const JUMP_BUFFER := 0.12
const MAX_HEALTH := 100
const INVULNERABLE_TIME := 0.6
const RESPAWN_TIME := 1.5

var move_input := Vector2.ZERO
var attacking := false:
	set(value):
		attacking = value
		queue_redraw()
var health := MAX_HEALTH
var dead := false
var gravity_scale := 1.0
var damage_scale := 1.0

var _jump_buffer := 0.0
var _invulnerable := 0.0
var _facing := 1.0
var _spawn: Vector2
var _key_left := false
var _key_right := false


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
	queue_redraw()
	if health == 0:
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
	health = MAX_HEALTH
	dead = false
	position = _spawn
	velocity = Vector2.ZERO
	health_changed.emit()
	queue_redraw()


## Desktop keyboard controls: arrows or A/D move, Space / Up / W jump, X or J attack (hold).
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

	if not is_on_floor():
		velocity += get_gravity() * gravity_scale * delta
	if _jump_buffer > 0.0 and is_on_floor() and not dead:
		velocity.y = JUMP_VELOCITY
		_jump_buffer = 0.0
		jumped.emit()

	var axis := 0.0 if dead else move_input.x
	# Desktop keyboard fallback (see _input) so the physics can be tried without touch.
	if axis == 0.0 and not dead:
		axis = _key_axis()
	if absf(axis) > 0.01:
		_facing = signf(axis)
	velocity.x = move_toward(velocity.x, axis * SPEED, ACCELERATION * delta)
	move_and_slide()
	queue_redraw()


func _draw() -> void:
	var body := Color(0.9, 0.3, 0.3) if _invulnerable > 0.0 else Color(0.3, 0.7, 1.0)
	if dead:
		body = Color(0.4, 0.4, 0.4)
	draw_rect(Rect2(-20, -30, 40, 60), body)
	draw_rect(Rect2(_facing * 6 - 4, -20, 8, 8), Color.WHITE)
	if attacking and not dead:
		draw_rect(Rect2(20 if _facing > 0 else -70, -12, 50, 24), Color(1.0, 0.6, 0.1))
