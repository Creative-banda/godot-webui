class_name Demo3DCameraRig
extends Node3D
## Orbit camera: follows `target`, turns with look(), pulls in when a wall is behind the character.
## Node layout: CameraRig (yaw) > Pitch (pitch) > SpringArm3D > Camera3D.

const PITCH_MIN := deg_to_rad(-70.0)  # looking down from above
const PITCH_MAX := deg_to_rad(35.0)   # looking up from below

@export var target: Node3D
@export var height := 1.4
@export var follow_speed := 14.0

var yaw := 0.0
var pitch := deg_to_rad(-18.0)

@onready var _pitch_pivot: Node3D = $Pitch
@onready var _arm: SpringArm3D = $Pitch/SpringArm3D


func _ready() -> void:
	top_level = true
	if target:
		global_position = target.global_position + Vector3.UP * height
		if target is CollisionObject3D:
			_arm.add_excluded_object(target.get_rid())
	_apply()


## Positive x looks right, positive y looks up (radians).
func look(angles: Vector2) -> void:
	yaw = wrapf(yaw - angles.x, -PI, PI)
	pitch = clampf(pitch + angles.y, PITCH_MIN, PITCH_MAX)
	_apply()


func _process(delta: float) -> void:
	if target:
		var goal := target.global_position + Vector3.UP * height
		global_position = global_position.lerp(goal, 1.0 - exp(-follow_speed * delta))


func _apply() -> void:
	rotation.y = yaw
	_pitch_pivot.rotation.x = pitch
