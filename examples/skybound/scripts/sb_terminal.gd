@tool
class_name SBTerminal
extends StaticBody3D
## A computer terminal whose screen is a web page (terminal.html) drawn into a texture by Godot WebUI
## (GodotWebUI.create_surface, Android). The screen mesh and its collider are built here; the player uses it by aiming the
## crosshair at it and pressing Use: the ray hit becomes a point on the page, which Godot taps like a finger.
##
## Off Android the surface is unavailable, so the screen shows a small Godot label with the same figures instead.

signal action_requested(action: String)

@export var page := "terminal.html"
@export var page_size := Vector2i(640, 400)
@export var screen_width := 2.4
@export var redraw_fps := 10
## Beyond this distance (metres) from the camera the page is not redrawn at all.
@export var active_distance := 32.0

var surface: GodotWebUISurface
var aimed := false

var _screen: MeshInstance3D
var _label: Label3D
var _material: StandardMaterial3D
var _cursor_sent := Vector2(-1, -1)
var _last_aimed := false

const FRAME_DEPTH := 0.14
const PEDESTAL_HEIGHT := 0.95


func _ready() -> void:
	_build()
	if Engine.is_editor_hint():
		return
	add_to_group("sb_terminal")


func _screen_height() -> float:
	return screen_width * float(page_size.y) / float(page_size.x)


func _screen_centre() -> Vector3:
	return Vector3(0.0, PEDESTAL_HEIGHT + _screen_height() * 0.5 + 0.1, 0.0)


func _build() -> void:
	if get_node_or_null("Screen") != null:
		return
	var h := _screen_height()
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
	frame_mesh.size = Vector3(screen_width + 0.24, h + 0.24, FRAME_DEPTH)
	frame.mesh = frame_mesh
	frame.material_override = dark
	frame.position = _screen_centre() + Vector3(0.0, 0.0, -FRAME_DEPTH * 0.5)
	add_child(frame)

	_screen = MeshInstance3D.new()
	_screen.name = "Screen"
	var quad := QuadMesh.new()
	quad.size = Vector2(screen_width, h)
	_screen.mesh = quad
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = Color(0.05, 0.08, 0.16)
	_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_screen.material_override = _material
	_screen.position = _screen_centre() + Vector3(0.0, 0.0, 0.005)
	add_child(_screen)

	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(screen_width + 0.24, h + 0.24, FRAME_DEPTH)
	shape.shape = box
	shape.position = frame.position
	add_child(shape)
	var base_shape := CollisionShape3D.new()
	base_shape.name = "BaseShape"
	var base_box := BoxShape3D.new()
	base_box.size = pedestal_mesh.size
	base_shape.shape = base_box
	base_shape.position = pedestal.position
	add_child(base_shape)

	_label = Label3D.new()
	_label.name = "Fallback"
	_label.text = "RUN TERMINAL\nWorld-space HTML\nneeds an Android build"
	_label.pixel_size = 0.004
	_label.font_size = 42
	_label.modulate = Color("#7be0ff")
	_label.shaded = false
	_label.position = _screen.position + Vector3(0.0, 0.0, 0.01)
	_label.visible = Engine.is_editor_hint()
	add_child(_label)


## Starts the page on `ui` (the overlay must already be started). Safe on every platform.
func attach(ui: GodotWebUI) -> void:
	_build()
	surface = ui.create_surface(page, page_size, redraw_fps)
	if surface.available:
		_material.albedo_texture = surface.texture
		_material.albedo_color = Color.WHITE
		surface.on("terminal_action", _on_terminal_action)
	else:
		_label.visible = true


## Figures for the page (state "run") or, off Android, for the fallback label.
func show_run(run: Dictionary) -> void:
	if surface and surface.available:
		surface.set_state("run", run)
	elif _label:
		_label.text = "RUN TERMINAL\n%s  ·  %d/%d shards\nsection %d  ·  %d falls\n(World-space HTML runs on Android)" % [
			_format_time(float(run.get("time", 0.0))), int(run.get("shards", 0)), int(run.get("shard_total", 0)),
			int(run.get("section", 1)), int(run.get("deaths", 0))]


## Looks along the camera's centre line: returns {"hit": bool, "pixel": Vector2 (page pixels), "distance": float}.
func aim(camera: Camera3D, reach := 3.2) -> Dictionary:
	var result := {"hit": false, "pixel": Vector2.ZERO, "distance": 0.0}
	if camera == null or not is_inside_tree():
		return result
	var from := camera.global_position
	var to := from - camera.global_basis.z * reach
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit.collider != self:
		return result
	var local := to_local(hit.position)
	var centre := _screen_centre()
	var u := (local.x - centre.x) / screen_width + 0.5
	var v := 0.5 - (local.y - centre.y) / _screen_height()
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return result
	result.hit = true
	result.pixel = Vector2(u * page_size.x, v * page_size.y)
	result.distance = from.distance_to(hit.position)
	return result


## Called a few times a second with the camera: tracks whether the player is aiming at the screen, tells the page where
## (state "cursor") and pauses drawing when the camera is far away.
func update_aim(camera: Camera3D) -> void:
	if surface == null:
		return
	var in_range := camera != null and camera.global_position.distance_to(global_position) < active_distance
	surface.set_active(in_range)
	var result := aim(camera) if in_range else {"hit": false, "pixel": Vector2.ZERO}
	aimed = result.hit
	if not surface.available:
		return
	if aimed:
		var px := (result.pixel as Vector2).round()
		if px.distance_to(_cursor_sent) >= 3.0 or not _last_aimed:
			_cursor_sent = px
			surface.set_state("cursor", {"aimed": true, "x": px.x, "y": px.y})
	elif _last_aimed:
		surface.set_state("cursor", {"aimed": false, "x": 0, "y": 0})
	_last_aimed = aimed


## The Use button: taps the page where the crosshair meets the screen. Returns whether a tap was sent.
func use(camera: Camera3D) -> bool:
	var result := aim(camera)
	if not result.hit:
		return false
	if surface and surface.available:
		surface.tap(result.pixel)
	return true


func _on_terminal_action(payload: Dictionary) -> void:
	var action: Variant = payload.get("action")
	if typeof(action) == TYPE_STRING and action in ["retry", "restart"]:
		action_requested.emit(action)
	else:
		printerr("terminal_action needs 'retry' or 'restart', got ", payload)


static func _format_time(seconds: float) -> String:
	return "%d:%05.2f" % [int(seconds / 60.0), fmod(seconds, 60.0)]
