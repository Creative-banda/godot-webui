class_name ADInteractable
extends StaticBody3D
## A generic interactable device: terminal screen, note sheet or breaker. The game script owns
## what interacting does; this node provides the identity, prompt text and screen glow state.

@export var kind := "terminal"  # terminal | note | breaker | console
@export var id := ""
@export var title := "TERMINAL"

var active := false  # solved/used state; screens glow cyan when active


func _ready() -> void:
	add_to_group("interactable")
	set_meta("kind", kind)
	set_meta("id", id)


func set_active(value: bool) -> void:
	active = value
	var screen := get_node_or_null("Screen")
	if screen is MeshInstance3D:
		var mat := (screen as MeshInstance3D).get_active_material(0) as StandardMaterial3D
		if mat:
			mat.emission = Color(0.2, 0.75, 1.0) if value else Color(0.55, 0.16, 0.16)


func prompt_text() -> String:
	match kind:
		"terminal":
			return "E — Access terminal"
		"note":
			return "E — Read log"
		"breaker":
			return "E — Release breaker"
		"console":
			return "E — Access central console"
	return ""
