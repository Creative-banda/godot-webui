@tool
class_name SBTerminal
extends Node3D
## The run terminal: a pedestal and frame around a WebUISurface3D ("Screen") that shows ui/terminal.html. All the web
## page work (drawing the page into the 3D screen, taps from the crosshair raycast, the page's events) is the node's;
## this script builds the furniture and turns the page's buttons into game actions.

signal action_requested(action: String)

const PEDESTAL_HEIGHT := 0.95
const FRAME_DEPTH := 0.14

@onready var screen: WebUISurface3D = $Screen


func _ready() -> void:
	_build_frame()
	if not Engine.is_editor_hint():
		screen.on("terminal_action", _on_terminal_action)


func _build_frame() -> void:
	if get_node_or_null("Frame") != null:
		return
	var w := screen.world_width
	var h := w * float(screen.page_size.y) / float(screen.page_size.x)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color("#0b1630")
	dark.metallic = 0.4
	dark.roughness = 0.5
	var pedestal := MeshInstance3D.new()
	pedestal.name = "Pedestal"
	var pedestal_mesh := BoxMesh.new()
	pedestal_mesh.size = Vector3(0.34, PEDESTAL_HEIGHT, 0.3)
	pedestal.mesh = pedestal_mesh
	pedestal.material_override = dark
	pedestal.position = Vector3(0.0, PEDESTAL_HEIGHT * 0.5, -0.05)
	add_child(pedestal)
	var frame := MeshInstance3D.new()
	frame.name = "Frame"
	var frame_mesh := BoxMesh.new()
	frame_mesh.size = Vector3(w + 0.24, h + 0.24, FRAME_DEPTH)
	frame.mesh = frame_mesh
	frame.material_override = dark
	frame.position = screen.position + Vector3(0.0, 0.0, -FRAME_DEPTH * 0.5 - 0.03)
	add_child(frame)


## Figures for the page (state "run").
func show_run(run: Dictionary) -> void:
	screen.set_state("run", run)


## Use (E, or the USE button): taps the page where the camera's centre ray meets the screen.
func use(camera: Camera3D) -> bool:
	return screen.use(camera)


func _on_terminal_action(payload: Dictionary) -> void:
	var action: Variant = payload.get("action")
	if typeof(action) == TYPE_STRING and action in ["retry", "restart"]:
		action_requested.emit(action)
	else:
		printerr("terminal_action needs 'retry' or 'restart', got ", payload)
