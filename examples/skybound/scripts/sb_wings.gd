@tool
class_name SBWings
extends Area3D
## The Wing Orb: taking it unlocks the double jump for the rest of the run.

signal collected

var _orb: MeshInstance3D
var _halo: MeshInstance3D
var _clock := 0.0
var _taken := false


func _ready() -> void:
	add_to_group("sb_wings")
	if get_node_or_null("Orb") == null:
		var sphere := SphereMesh.new()
		sphere.radius = 0.6
		sphere.height = 1.2
		_orb = SBPieces.add_mesh(self, sphere, SBBuild.glow_material(Color("#ffe29a"), 3.0))
		_orb.name = "Orb"
		var torus := TorusMesh.new()
		torus.inner_radius = 0.95
		torus.outer_radius = 1.05
		_halo = SBPieces.add_mesh(self, torus, SBBuild.glow_material(Color("#ffd166"), 2.0))
		_halo.name = "Halo"
	else:
		_orb = get_node("Orb")
		_halo = get_node_or_null("Halo")
	if Engine.is_editor_hint():
		return
	var zone := SBPieces.add_box_area(self, Vector3(2.4, 2.4, 2.4), Vector3.ZERO)
	zone.body_entered.connect(_on_body_entered)


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _orb == null or _taken:
		return
	_clock += delta
	_orb.position.y = sin(_clock * 2.0) * 0.18
	if _halo:
		_halo.position.y = _orb.position.y
		_halo.rotation = Vector3(_clock * 1.1, _clock * 1.7, 0.0)


func _on_body_entered(body: Node3D) -> void:
	if _taken or not body is SBPlayer:
		return
	_taken = true
	collected.emit()
	var burst := create_tween().set_parallel(true)
	burst.tween_property(self, "scale", Vector3(3.0, 3.0, 3.0), 0.4).set_ease(Tween.EASE_OUT)
	burst.tween_property(_orb, "transparency", 1.0, 0.4)
	if _halo:
		burst.tween_property(_halo, "transparency", 1.0, 0.4)
	burst.chain().tween_callback(func() -> void: visible = false)


## Brings the orb back for a new run.
func reset() -> void:
	_taken = false
	visible = true
	scale = Vector3.ONE
	if _orb:
		_orb.transparency = 0.0
	if _halo:
		_halo.transparency = 0.0
