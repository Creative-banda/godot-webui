class_name SBBuild
extends RefCounted
## Shared helpers for the Skybound course pieces: the section palette and names, the platform
## material and the code that gives a body its box mesh and collider. The pieces build their
## children at run time (unowned, so scenes stay tiny and a changed `size` is the only edit), and
## expose world_boxes() so tests can check that the course can be jumped.

const PALETTE: Array[Color] = [
	Color("#38b6ff"), Color("#06d6a0"), Color("#ffd166"), Color("#ff6b9d"), Color("#9d6bff"),
]
const SECTION_NAMES: Array[String] = ["LAUNCH PAD", "FLOATING ISLES", "CARGO RUN", "SKYLINE TOWERS", "THE SPIRE"]
const SHADER := "res://examples/skybound/platform.gdshader"

static var _material: ShaderMaterial


static func theme_color(theme: int) -> Color:
	return PALETTE[clampi(theme, 0, PALETTE.size() - 1)]


static func platform_material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = load(SHADER)
	return _material


## Gives `body` a box mesh ("Mesh") and a box collider ("Shape") of `size`, creating them on first use.
## The children are not owned by the scene, so they are rebuilt on load and never saved.
static func fill_body(body: Node3D, size: Vector3, theme: int) -> void:
	var mesh_node := body.get_node_or_null("Mesh") as MeshInstance3D
	if mesh_node == null:
		mesh_node = MeshInstance3D.new()
		mesh_node.name = "Mesh"
		body.add_child(mesh_node)
		mesh_node.material_override = platform_material()
	var box := BoxMesh.new()
	box.size = size
	mesh_node.mesh = box
	mesh_node.set_instance_shader_parameter("half_size", size * 0.5)
	var color := theme_color(theme)
	mesh_node.set_instance_shader_parameter("tint", Vector4(color.r, color.g, color.b, 1.0))
	if body is CollisionObject3D:
		var shape_node := body.get_node_or_null("Shape") as CollisionShape3D
		if shape_node == null:
			shape_node = CollisionShape3D.new()
			shape_node.name = "Shape"
			body.add_child(shape_node)
		var shape := BoxShape3D.new()
		shape.size = size
		shape_node.shape = shape


## The world-space box of a body of `size` centred on `center` and turned by `yaw` (multiples of 90 degrees).
static func world_box(center: Vector3, size: Vector3, yaw: float) -> AABB:
	var turned := absf(sin(yaw)) > 0.5
	var extent := Vector3(size.z, size.y, size.x) if turned else size
	return AABB(center - extent * 0.5, extent)


## A small emissive material for pickups and markers.
static func glow_material(color: Color, energy := 2.0, alpha := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color.r, color.g, color.b, alpha)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return m
