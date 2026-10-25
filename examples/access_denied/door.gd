class_name ADDoor
extends StaticBody3D
## A security door. Locked: closed with an amber-red strip. Unlocked: strip turns cyan and the
## panel slides up (tween). Collision is disabled while open so the player can walk through.

@export var door_id := ""
@export var title := "SECURITY DOOR"

var unlocked := false:
	set(value):
		unlocked = value
		_update()

var _open := false

@onready var panel: Node3D = $Panel
@onready var strip: MeshInstance3D = $Panel/Strip
@onready var label: Label3D = $Label3D


func _ready() -> void:
	add_to_group("interactable")
	set_meta("kind", "door")
	_update()


func _update() -> void:
	if label:
		label.text = ("%s · OPEN" % title) if unlocked else ("%s · LOCKED" % title)
	var mat := strip.get_active_material(0) as StandardMaterial3D
	if mat:
		mat.emission = Color(0.34, 0.84, 1.0) if unlocked else Color(1.0, 0.42, 0.3)


func open() -> void:
	if _open or not unlocked:
		return
	_open = true
	set_collision_layer_value(1, false)
	var tween := create_tween()
	tween.tween_property(panel, "position:y", panel.position.y + 2.35, 0.7) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	label.text = "%s · OPEN" % title


func prompt_text() -> String:
	return "E — Override door" if unlocked and not _open else ""
