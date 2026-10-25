@tool
class_name SBPlatform
extends StaticBody3D
## A solid box platform. Change `size` and `theme` in the Inspector; the mesh and collider follow.

@export var size := Vector3(6.0, 1.0, 6.0):
	set(value):
		size = value
		_rebuild()
@export_range(0, 4) var theme := 0:
	set(value):
		theme = value
		_rebuild()


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	if is_inside_tree():
		SBBuild.fill_body(self, size, theme)


## Boxes this platform can occupy, in world space (used by the course tests).
func world_boxes() -> Array[AABB]:
	return [SBBuild.world_box(global_position, size, global_rotation.y)]
