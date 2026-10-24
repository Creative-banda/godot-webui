class_name Wisp
extends Area2D
## A drifting hazard: a violet wisp patrolling around its authored position in the level scene.
## Stunned wisps sink, dim and cannot hurt the player until the stun expires.

@export var patrol_range := 200.0
@export var speed_scale := 1.0

var home := Vector2.ZERO
var stunned_for := 0.0

var _t := 0.0
var _art: Sprite2D


func _ready() -> void:
	home = position
	_t = fmod(absf(home.x * 0.13), TAU)
	_art = $Art


func stun(duration: float) -> void:
	stunned_for = duration


func is_stunned() -> bool:
	return stunned_for > 0.0


func _physics_process(delta: float) -> void:
	if stunned_for > 0.0:
		stunned_for -= delta
		position.y = move_toward(position.y, home.y + 46.0, 90.0 * delta)
		_art.modulate = Color(0.62, 0.58, 0.8, 0.55)
	else:
		_t += delta * speed_scale
		position.x = home.x + sin(_t) * patrol_range
		position.y = home.y + sin(_t * 1.63) * 20.0
		_art.modulate = Color(1, 1, 1, 0.88 + 0.12 * sin(Time.get_ticks_msec() * 0.004))
