@tool
class_name SBBouncePad
extends Area3D
## A spring pad: stepping on it throws the player upward. The node sits on a platform's top surface.

@export var strength := 20.0

var _pad: MeshInstance3D


func _ready() -> void:
	add_to_group("sb_bounce")
	if get_node_or_null("Pad") == null:
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 1.3
		cylinder.bottom_radius = 1.5
		cylinder.height = 0.3
		_pad = SBPieces.add_mesh(self, cylinder, SBBuild.glow_material(Color("#ff6b9d"), 2.6), Vector3(0.0, 0.15, 0.0))
		_pad.name = "Pad"
	else:
		_pad = get_node("Pad")
	if Engine.is_editor_hint():
		return
	var zone := SBPieces.add_box_area(self, Vector3(2.8, 1.2, 2.8), Vector3(0.0, 0.6, 0.0))
	zone.body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if not body is SBPlayer:
		return
	(body as SBPlayer).bounce(strength)
	var pop := create_tween()
	pop.tween_property(_pad, "scale", Vector3(1.25, 0.4, 1.25), 0.07)
	pop.tween_property(_pad, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
