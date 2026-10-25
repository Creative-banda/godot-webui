@tool
class_name SBGoal
extends Area3D
## The finish beacon at the top of the Spire.

signal reached

var _rings: Array[MeshInstance3D] = []
var _clock := 0.0
var _done := false


func _ready() -> void:
	add_to_group("sb_goal")
	if get_node_or_null("Beam") == null:
		var beam := CylinderMesh.new()
		beam.top_radius = 1.6
		beam.bottom_radius = 1.6
		beam.height = 60.0
		beam.cap_top = false
		beam.cap_bottom = false
		var node := SBPieces.add_mesh(self, beam, SBBuild.glow_material(Color("#ffd166"), 1.4, 0.16), Vector3(0.0, 30.0, 0.0))
		node.name = "Beam"
		for i in 3:
			var torus := TorusMesh.new()
			torus.inner_radius = 2.2 + i * 0.5
			torus.outer_radius = 2.35 + i * 0.5
			var ring := SBPieces.add_mesh(self, torus, SBBuild.glow_material(Color("#ffd166"), 2.4), Vector3(0.0, 0.6 + i * 0.7, 0.0))
			ring.name = "Ring%d" % i
			_rings.append(ring)
	else:
		for i in 3:
			_rings.append(get_node("Ring%d" % i))
	if Engine.is_editor_hint():
		return
	var zone := SBPieces.add_box_area(self, Vector3(5.0, 4.0, 5.0), Vector3(0.0, 2.0, 0.0))
	zone.body_entered.connect(func(body: Node3D) -> void:
		if not _done and body is SBPlayer:
			_done = true
			reached.emit())


func reset() -> void:
	_done = false


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_clock += delta
	for i in _rings.size():
		_rings[i].position.y = 0.6 + i * 0.7 + sin(_clock * 2.0 + i) * 0.1
		_rings[i].rotation.y += delta * (0.8 + i * 0.3)
