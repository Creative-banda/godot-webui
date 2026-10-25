class_name SBPieces
extends RefCounted
## Small helpers shared by the pickups and markers (checkpoint, shard, wings, goal, bounce pad).

## An Area3D child with a box shape, centred at `at`.
static func add_box_area(parent: Node3D, size: Vector3, at: Vector3) -> Area3D:
	var area := Area3D.new()
	area.name = "Zone"
	area.monitorable = false
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	area.position = at
	area.add_child(shape)
	parent.add_child(area)
	return area


static func add_mesh(parent: Node3D, mesh: Mesh, material: Material, at := Vector3.ZERO) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.position = at
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)
	return node
