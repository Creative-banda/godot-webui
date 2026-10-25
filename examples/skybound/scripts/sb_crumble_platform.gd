@tool
class_name SBCrumblePlatform
extends StaticBody3D
## A platform that shakes when you land on it, drops away, and comes back a few seconds later.

@export var size := Vector3(3.5, 0.8, 3.5):
	set(value):
		size = value
		_rebuild()
@export_range(0, 4) var theme := 2:
	set(value):
		theme = value
		_rebuild()
@export var delay := 0.55
@export var respawn_after := 3.0

var _trigger: Area3D
var _busy := false


func _ready() -> void:
	_rebuild()
	if Engine.is_editor_hint():
		return
	_trigger = Area3D.new()
	_trigger.name = "Trigger"
	var box := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x * 0.92, 0.6, size.z * 0.92)
	box.shape = shape
	box.position = Vector3(0.0, size.y * 0.5 + 0.3, 0.0)
	_trigger.add_child(box)
	_trigger.body_entered.connect(_on_body_entered)
	add_child(_trigger)


func _rebuild() -> void:
	if is_inside_tree():
		SBBuild.fill_body(self, size, theme)


func world_boxes() -> Array[AABB]:
	return [SBBuild.world_box(global_position, size, global_rotation.y)]


func _on_body_entered(body: Node3D) -> void:
	if _busy or not body is SBPlayer:
		return
	_busy = true
	_crumble()


func _crumble() -> void:
	var mesh := get_node("Mesh") as MeshInstance3D
	var shape := get_node("Shape") as CollisionShape3D
	var color := SBBuild.theme_color(theme)
	var warn := Color(1.0, 0.35, 0.3)
	# Shake and glow red while it holds.
	var shake := create_tween()
	for i in 8:
		var step := delay / 8.0
		var amount := 0.04 + 0.012 * i
		shake.tween_property(mesh, "position", Vector3(randf_range(-amount, amount), randf_range(-amount, amount) * 0.5, randf_range(-amount, amount)), step)
	shake.parallel().tween_method(func(k: float) -> void:
		var c := color.lerp(warn, k)
		mesh.set_instance_shader_parameter("tint", Vector4(c.r, c.g, c.b, 1.0)), 0.0, 1.0, delay)
	await shake.finished
	if not is_inside_tree():
		return
	shape.set_deferred("disabled", true)
	var fall := create_tween().set_parallel(true)
	fall.tween_property(mesh, "position", Vector3(0.0, -6.0, 0.0), 0.7).set_ease(Tween.EASE_IN)
	fall.tween_property(mesh, "scale", Vector3(0.6, 0.6, 0.6), 0.7)
	await get_tree().create_timer(respawn_after).timeout
	if not is_inside_tree():
		return
	mesh.position = Vector3.ZERO
	mesh.scale = Vector3.ONE
	mesh.set_instance_shader_parameter("tint", Vector4(color.r, color.g, color.b, 1.0))
	shape.set_deferred("disabled", false)
	_busy = false
