@tool
class_name SBMovingPlatform
extends AnimatableBody3D
## A platform that glides back and forth. `travel` is the full path in the platform's own axes
## (x right, y up, z back); it swings half of it to each side of where it was placed.

@export var size := Vector3(5.0, 1.0, 5.0):
	set(value):
		size = value
		_rebuild()
@export_range(0, 4) var theme := 2:
	set(value):
		theme = value
		_rebuild()
@export var travel := Vector3(0.0, 0.0, 6.0)
@export var period := 5.0
@export var phase := 0.0

var _home := Vector3.ZERO
var _clock := 0.0


func _ready() -> void:
	_rebuild()
	_home = position
	sync_to_physics = true
	set_physics_process(not Engine.is_editor_hint())


func _physics_process(delta: float) -> void:
	_clock += delta
	var swing := sin(TAU * _clock / period + phase)
	position = _home + basis * (travel * 0.5 * swing)


func _rebuild() -> void:
	if is_inside_tree():
		SBBuild.fill_body(self, size, theme)


func world_boxes() -> Array[AABB]:
	var home: Vector3 = global_position if _home == Vector3.ZERO else get_parent().to_global(_home)
	var yaw := global_rotation.y
	var half := global_basis * (travel * 0.5)
	return [
		SBBuild.world_box(home - half, size, yaw),
		SBBuild.world_box(home + half, size, yaw),
	]
