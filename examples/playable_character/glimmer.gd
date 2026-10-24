class_name Glimmer
extends Area2D
## A lumen seed collectible: a bobbing glowing leaf-tear placed in the level scene.

signal collected(glimmer: Glimmer)

var _base_y := 0.0
var _t := 0.0
var _taken := false


func _ready() -> void:
	_base_y = position.y
	_t = fmod(absf(position.x * 0.7), TAU)
	body_entered.connect(_on_body_entered)


func _process(delta: float) -> void:
	if _taken:
		return
	_t += delta
	position.y = _base_y + sin(_t * 1.6) * 5.0


func _on_body_entered(body: Node2D) -> void:
	if _taken or not body is DemoPlayer or body.dead:
		return
	_taken = true
	set_deferred("monitoring", false)
	collected.emit(self)
	_burst()
	var tween := create_tween()
	tween.tween_property(self, "scale", Vector2(1.6, 1.6), 0.16).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(self, "modulate:a", 0.0, 0.16)
	tween.tween_callback(queue_free)


## Transient pickup burst (one-shot particles, created on demand and freed).
func _burst() -> void:
	var burst := CPUParticles2D.new()
	burst.one_shot = true
	burst.emitting = true
	burst.amount = 12
	burst.lifetime = 0.5
	burst.explosiveness = 1.0
	burst.direction = Vector2.UP
	burst.spread = 180.0
	burst.initial_velocity_min = 50.0
	burst.initial_velocity_max = 150.0
	burst.gravity = Vector2(0, 160)
	burst.scale_amount_min = 1.2
	burst.scale_amount_max = 2.6
	burst.color = Color(1.0, 0.9, 0.62)
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	burst.material = additive
	burst.position = global_position
	get_parent().add_child(burst)
	get_tree().create_timer(1.0).timeout.connect(burst.queue_free)
