@tool
class_name SBCheckpoint
extends Area3D
## A checkpoint ring standing on a platform. Touching it saves the run position and names the section.
## The node sits on the platform's top surface.

signal reached(index: int)

@export var index := 0
@export var section_name := ""
@export_range(0, 4) var theme := 0

var active := false

var _ring: MeshInstance3D
var _beam: MeshInstance3D
var _clock := 0.0


func _ready() -> void:
	add_to_group("sb_checkpoint")
	_build()
	if Engine.is_editor_hint():
		return
	var zone := SBPieces.add_box_area(self, Vector3(7.0, 5.0, 7.0), Vector3(0.0, 2.2, 0.0))
	zone.body_entered.connect(func(body: Node3D) -> void:
		if body is SBPlayer:
			reached.emit(index))


func _build() -> void:
	if get_node_or_null("Ring") != null:
		return
	var color := SBBuild.theme_color(theme)
	var torus := TorusMesh.new()
	torus.inner_radius = 1.5
	torus.outer_radius = 1.75
	_ring = SBPieces.add_mesh(self, torus, SBBuild.glow_material(color, 2.5), Vector3(0.0, 2.2, 0.0))
	_ring.name = "Ring"
	_ring.rotation.x = PI / 2.0
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = 1.45
	beam_mesh.bottom_radius = 1.45
	beam_mesh.height = 7.0
	beam_mesh.cap_top = false
	beam_mesh.cap_bottom = false
	_beam = SBPieces.add_mesh(self, beam_mesh, SBBuild.glow_material(color, 1.0, 0.12), Vector3(0.0, 3.5, 0.0))
	_beam.name = "Beam"


func set_active(value: bool) -> void:
	active = value
	var color := Color("#ffd166") if value else SBBuild.theme_color(theme)
	if _ring:
		_ring.material_override = SBBuild.glow_material(color, 3.2 if value else 2.5)
	if _beam:
		_beam.material_override = SBBuild.glow_material(color, 1.0, 0.2 if value else 0.12)


func spawn_transform() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, global_rotation.y), global_position + Vector3(0.0, 0.15, 0.0))


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _ring == null:
		return
	_clock += delta
	_ring.position.y = 2.2 + sin(_clock * 1.6) * 0.12
	_ring.rotation.z += delta * (1.4 if active else 0.5)
