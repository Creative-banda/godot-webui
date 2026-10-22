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
	# Desktop fallback so the physics can be tried without the WebView.
	if OS.get_name() != "Android" and axis == 0.0 and not dead:
		axis = Input.get_axis("ui_left", "ui_right")
		if Input.is_action_just_pressed("ui_accept"):
			request_jump()
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
