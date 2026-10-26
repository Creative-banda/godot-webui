@tool
class_name WebUISurface3D
extends StaticBody3D
## A screen in the 3D world that shows an HTML page: a terminal, a wall display, a diegetic menu. Add it to a scene,
## set `page` (a file of your UI folder, like "terminal.html") and `world_width`, and it draws the page onto a quad.
## The same page code as the full-screen overlay runs in it: `Godot.onState`, `Godot.emit`, and so on.
##
##   $Terminal.set_state("run", {"time": 12.3})                  # Godot -> page (Godot.onState in the page)
##   $Terminal.on("terminal_action", func(p): print(p))          # page -> Godot (Godot.emit in the page)
##   $Terminal.use(camera)                                       # tap the page where the camera's centre ray hits it
##
## It finds the running GodotWebUI by itself (or set `ui_path`), so start the overlay first. The overlay may stay empty
## or hidden: surfaces only share its UI folder and bridge.
##
## Platforms (see docs/world-space.md):
##  - Android: the page is drawn by a real off-screen WebView into the texture (about `redraw_fps` times a second).
##  - Desktop, only when the game is run from the editor with the optional godot_wry preview installed: the page is a
##    SNAPSHOT drawn a few times a second (GodotWebUI.surface_preview_fps). Animations are drawn at rest, :hover is not
##    drawn, taps are synthetic events. It shows the real layout and wiring, not the final look or smoothness. A small
##    "DESKTOP PREVIEW" label says so (`show_preview_label`).
##  - Anywhere else a text label stands in and every call is a harmless no-op.
## Pages should have an opaque background: the surface texture is not blended.

## The page is ready (its handshake arrived). Send initial state here, or just call set_state() any time: it is held.
signal page_ready
## A validated event from the page (JS: Godot.emit(name, payload)), in addition to handlers registered with on().
signal page_event(event_name: String, payload: Dictionary)
## The crosshair (centre of the camera) moved onto or off the screen. Use it to show a "Use" prompt.
signal aimed_changed(aimed: bool)
## The page was connected to a GodotWebUI, or lost it (shutdown, or this node left the tree).
signal attached
signal detached

## The page to show: a file inside the UI folder the overlay was started with ("terminal.html", "screens/map.html").
@export var page := "":
	set(value):
		page = value
		if surface:
			detach()  # auto_attach starts the new page
		_refresh_label()
## Layout size of the page in CSS pixels, and the size of the texture (64..2048 each). Text needs enough pixels to be
## readable from where the player stands: 640x400 on a 2.4 m wide screen is readable at about 2 m.
@export var page_size := Vector2i(640, 400):
	set(value):
		page_size = Vector2i(clampi(value.x, 64, 2048), clampi(value.y, 64, 2048))
		if surface:
			detach()  # the texture size changes: auto_attach starts the page again
		_rebuild()
## Width of the screen in metres (local units); the height follows the page's aspect ratio.
@export_range(0.1, 50.0, 0.05, "or_greater") var world_width := 2.4:
	set(value):
		world_width = maxf(value, 0.05)
		_rebuild()
## How often the page is redrawn on Android (1-30). The desktop preview uses GodotWebUI.surface_preview_fps instead.
@export_range(1, 30) var redraw_fps := 10
## Beyond this distance (metres) from the camera the page is not redrawn at all. 0 = no limit.
@export_range(0.0, 200.0, 0.5, "or_greater") var active_distance := 0.0
## Stop redrawing while the screen is outside the camera's view (uses a VisibleOnScreenNotifier3D). It does not know
## about walls in front of it.
@export var pause_when_offscreen := true
## Connect to the running GodotWebUI by itself. Turn it off to call attach() yourself.
@export var auto_attach := true
## The GodotWebUI to use. Empty = the overlay that is running.
@export var ui_path: NodePath
## Unshaded (emissive-looking): the screen is not darkened by scene lighting.
@export var unshaded := true
## Give the StaticBody3D a thin collider so physics rays can hit the screen (needed by aim() and use()).
@export var collider := true:
	set(value):
		collider = value
		_rebuild()
## Send the page the state "cursor" {aimed, x, y} (page pixels) while the crosshair is on the screen, so it can draw a
## pointer or highlight what a tap would hit. Needs `auto_aim`.
@export var send_cursor_state := true
## Track whether the camera's centre ray hits the screen (aimed_changed, "cursor" state) about ten times a second.
@export var auto_aim := true
## How far (metres) the centre ray reaches for aim() and use().
@export_range(0.5, 50.0, 0.1, "or_greater") var aim_reach := 4.0
## Show the small "DESKTOP PREVIEW" label above the screen when the page is a snapshot.
@export var show_preview_label := true

## The underlying surface (null until attached). Everything this node does goes through it.
var surface: GodotWebUISurface
## Whether the camera's centre ray is on the screen now (updated by auto_aim).
var aimed := false

var _mesh: MeshInstance3D
var _shape: CollisionShape3D
var _notifier: VisibleOnScreenNotifier3D
var _material: StandardMaterial3D
var _status: Label3D
var _badge: Label3D
var _handlers: Array = []        # [event name, Callable], applied on every attach
var _states := {}                # name -> Dictionary, the newest per name, replayed on every attach
var _events: Array = []          # [name, Dictionary] sent before the first attach
var _attach_timer := 0.0
var _aim_timer := 0.0
var _cursor_sent := Vector2(-1000, -1000)
var _announced_waiting := false


func _ready() -> void:
	_rebuild()
	if Engine.is_editor_hint():
		return
	set_process(true)


func _enter_tree() -> void:
	_attach_timer = 0.0


func _exit_tree() -> void:
	if not Engine.is_editor_hint():
		detach()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if surface == null:
		if auto_attach and is_inside_tree():
			_attach_timer -= delta
			if _attach_timer <= 0.0:
				_attach_timer = 0.25
				var ui := _find_ui()
				if ui:
					attach(ui)
				elif not _announced_waiting:
					_announced_waiting = true
					_set_status("Waiting for GodotWebUI.start()\n" + page)
		return
	_aim_timer += delta
	if _aim_timer >= 0.1:
		_aim_timer = 0.0
		_update_aim_and_activity()


# ---------------------------------------------------------------- connecting

## Connects the node to a started GodotWebUI and starts the page. Returns true if the page is being drawn (Android, or
## the desktop preview). False leaves a text label on the screen; calls stay harmless. Called for you with `auto_attach`.
func attach(ui: GodotWebUI) -> bool:
	detach()
	if ui == null or not ui.is_started():
		_set_status("Waiting for GodotWebUI.start()\n" + page)
		return false
	if page.is_empty():
		push_warning("WebUISurface3D '%s': set `page` to a file of the UI folder." % name)
		_set_status("No page set")
		return false
	var made := ui.create_surface(page, page_size, redraw_fps)
	if not made.available:
		_set_status("%s\nThe page is drawn on Android and in the\neditor-run desktop preview only." % page)
		return false
	surface = made
	_material.albedo_texture = surface.texture
	_material.albedo_color = Color.WHITE
	surface.page_ready.connect(page_ready.emit)
	surface.event_received.connect(page_event.emit)
	surface.frame_updated.connect(_on_first_frame, CONNECT_ONE_SHOT)
	surface.destroyed.connect(_on_surface_destroyed, CONNECT_ONE_SHOT)
	for entry: Array in _handlers:
		surface.on(entry[0], entry[1])
	for state_name: String in _states:
		surface.set_state(state_name, _states[state_name])
	for event: Array in _events:
		surface.emit_event(event[0], event[1])
	_events.clear()
	_set_status("Loading " + page + " ...")
	_refresh_badge()
	_announced_waiting = false
	attached.emit()
	return true


## Releases the page and its native resources. The node keeps its handlers and state and reattaches on its own
## (`auto_attach`) or when you call attach() again. Called when the node leaves the tree.
func detach() -> void:
	if surface == null:
		return
	var old := surface
	surface = null
	if is_instance_valid(old) and old.destroyed.is_connected(_on_surface_destroyed):
		old.destroyed.disconnect(_on_surface_destroyed)
	old.destroy()
	_after_detach()


func _on_surface_destroyed() -> void:
	surface = null  # the overlay was shut down
	_after_detach()


func _after_detach() -> void:
	if _material:
		_material.albedo_texture = null
		_material.albedo_color = Color(0.05, 0.08, 0.16)
	if aimed:
		aimed = false
		aimed_changed.emit(false)
	_cursor_sent = Vector2(-1000, -1000)
	_refresh_badge()
	_set_status("Page stopped")
	_attach_timer = 0.0
	detached.emit()


func is_attached() -> bool:
	return surface != null and surface.available


## True when the page on the surface is a desktop-preview snapshot rather than the real Android WebView.
func is_preview() -> bool:
	return surface != null and surface.is_preview


## Timing of the drawing (see GodotWebUISurface.stats()). Empty when not attached.
func stats() -> Dictionary:
	return surface.stats() if surface else {}


func _find_ui() -> GodotWebUI:
	if not ui_path.is_empty():
		var node := get_node_or_null(ui_path) as GodotWebUI
		return node if node and node.is_started() else null
	return GodotWebUI.active_overlay()


# ---------------------------------------------------------------- talking to the page

## Registers a handler for a page event (JS: Godot.emit(name, payload)). Works before the node is attached.
func on(event_name: String, handler: Callable) -> void:
	for entry: Array in _handlers:
		if entry[0] == event_name and entry[1] == handler:
			return
	_handlers.append([event_name, handler])
	if surface:
		surface.on(event_name, handler)


func off(event_name: String, handler: Callable) -> void:
	for i in range(_handlers.size() - 1, -1, -1):
		if _handlers[i][0] == event_name and _handlers[i][1] == handler:
			_handlers.remove_at(i)
	if surface:
		surface.off(event_name, handler)


## Persistent state for the page (JS: Godot.onState(name, fn)). The newest value per name is kept and sent again to a
## page that reloads or is attached later, so you can call this before the page exists.
func set_state(state_name: String, payload: Dictionary) -> void:
	if _states.get(state_name) == payload and surface:
		return  # unchanged: nothing to draw again
	_states[state_name] = payload.duplicate(true)
	if surface:
		surface.set_state(state_name, payload)


## One-shot notification for the page (JS: Godot.onEvent(name, fn)). Events sent before the first attach are delivered
## in order once the page is ready; after a detach they are dropped.
func emit_event(event_name: String, payload: Dictionary = {}) -> void:
	if surface:
		surface.emit_event(event_name, payload)
	elif _events.size() < GodotWebUISurface.MAX_PENDING_EVENTS:
		_events.append([event_name, payload])


# ---------------------------------------------------------------- pointing and tapping

## Maps a point in the world (on the screen's plane) to page pixels. Returns Vector2(-1, -1) outside the screen.
func world_to_pixel(point: Vector3) -> Vector2:
	var local := to_local(point)
	var u := local.x / world_width + 0.5
	var v := 0.5 - local.y / _world_height()
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return Vector2(-1, -1)
	return Vector2(u * page_size.x, v * page_size.y)


## Casts a physics ray from `from` along `direction` and reports whether it hits THIS screen first.
## Returns {"hit": bool, "pixel": Vector2 (page pixels), "uv": Vector2, "distance": float, "position": Vector3}.
func aim_ray(from: Vector3, direction: Vector3, reach := -1.0) -> Dictionary:
	var result := {"hit": false, "pixel": Vector2.ZERO, "uv": Vector2.ZERO, "distance": 0.0, "position": Vector3.ZERO}
	if not is_inside_tree() or not collider or direction.is_zero_approx():
		return result
	var to := from + direction.normalized() * (reach if reach > 0.0 else aim_reach)
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	if hit.is_empty() or hit.collider != self:
		return result
	var pixel := world_to_pixel(hit.position)
	if pixel.x < 0.0:
		return result
	result.hit = true
	result.pixel = pixel
	result.uv = Vector2(pixel.x / page_size.x, pixel.y / page_size.y)
	result.distance = from.distance_to(hit.position)
	result.position = hit.position
	return result


## The camera's centre ray (its forward direction); the viewport's current camera when `camera` is null.
func aim(camera: Camera3D = null, reach := -1.0) -> Dictionary:
	var cam := camera if camera else get_viewport().get_camera_3d()
	if cam == null:
		return {"hit": false, "pixel": Vector2.ZERO, "uv": Vector2.ZERO, "distance": 0.0, "position": Vector3.ZERO}
	return aim_ray(cam.global_position, -cam.global_basis.z, reach)


## The Use action: taps the page where the camera's centre ray meets the screen. Returns whether a tap was sent.
func use(camera: Camera3D = null, reach := -1.0) -> bool:
	return _tap_result(aim(camera, reach))


## Taps the page where a ray meets it, for example `camera.project_ray_origin(touch)` / `project_ray_normal(touch)`
## from a touch on the 3D view. Returns whether a tap was sent.
func use_ray(from: Vector3, direction: Vector3, reach := -1.0) -> bool:
	return _tap_result(aim_ray(from, direction, reach))


func _tap_result(result: Dictionary) -> bool:
	if not result.hit or surface == null:
		return false
	surface.tap(result.pixel)
	return true


## A tap at a page pixel (0..page_size from the top-left).
func tap_pixel(pixel: Vector2) -> void:
	if surface:
		surface.tap(pixel)


## A tap at uv (0..1, v from the top).
func tap_uv(uv: Vector2) -> void:
	if surface:
		surface.tap_uv(uv)


func _update_aim_and_activity() -> void:
	var cam := get_viewport().get_camera_3d()
	var want := is_visible_in_tree()
	if want and active_distance > 0.0 and cam:
		want = cam.global_position.distance_to(global_position) < active_distance
	if want and pause_when_offscreen and _notifier and _notifier.is_inside_tree():
		want = _notifier.is_on_screen()
	surface.set_active(want)
	if not auto_aim or cam == null or not want:
		_set_aimed(false)
		return
	var result := aim(cam)
	_set_aimed(result.hit)
	if not send_cursor_state or not surface.available:
		return
	if result.hit:
		var px: Vector2 = (result.pixel as Vector2).round()
		if px.distance_to(_cursor_sent) >= 3.0:
			_cursor_sent = px
			surface.set_state("cursor", {"aimed": true, "x": px.x, "y": px.y})
	elif _cursor_sent.x > -999.0:
		_cursor_sent = Vector2(-1000, -1000)
		surface.set_state("cursor", {"aimed": false, "x": 0, "y": 0})


func _set_aimed(value: bool) -> void:
	if value != aimed:
		aimed = value
		aimed_changed.emit(value)


# ---------------------------------------------------------------- geometry and labels

func _world_height() -> float:
	return world_width * float(page_size.y) / float(page_size.x)


func _rebuild() -> void:
	if not is_node_ready():
		return
	var h := _world_height()
	if _mesh == null:
		_mesh = MeshInstance3D.new()
		_mesh.name = "ScreenMesh"
		_mesh.mesh = QuadMesh.new()
		_material = StandardMaterial3D.new()
		_material.albedo_color = Color(0.05, 0.08, 0.16)
		_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
		_mesh.material_override = _material
		add_child(_mesh)  # internal-looking helper children are not saved: they are rebuilt on load
		_status = Label3D.new()
		_status.name = "StatusLabel"
		_status.modulate = Color("#7be0ff")
		_status.shaded = false
		_status.font_size = 32
		_status.position = Vector3(0, 0, 0.01)
		add_child(_status)
		_badge = Label3D.new()
		_badge.name = "PreviewLabel"
		_badge.text = "DESKTOP PREVIEW - snapshots, not Android rendering"
		_badge.modulate = Color("#ffd166")
		_badge.shaded = false
		_badge.font_size = 24
		_badge.visible = false
		add_child(_badge)
		if not Engine.is_editor_hint():
			_notifier = VisibleOnScreenNotifier3D.new()
			_notifier.name = "OnScreen"
			add_child(_notifier)
	(_mesh.mesh as QuadMesh).size = Vector2(world_width, h)
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if unshaded else BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_status.pixel_size = world_width * 0.8 / 640.0
	_badge.pixel_size = world_width * 0.9 / 700.0
	_badge.position = Vector3(0, h * 0.5 + _badge.pixel_size * 20.0, 0.01)
	if _notifier:
		_notifier.aabb = AABB(Vector3(-world_width * 0.5, -h * 0.5, -0.05), Vector3(world_width, h, 0.1))
	if collider:
		if _shape == null:
			_shape = CollisionShape3D.new()
			_shape.name = "ScreenShape"
			_shape.shape = BoxShape3D.new()
			add_child(_shape)
		(_shape.shape as BoxShape3D).size = Vector3(world_width, h, 0.04)
		_shape.position = Vector3(0, 0, -0.02)
	elif _shape:
		_shape.queue_free()
		_shape = null
	_refresh_label()


func _refresh_label() -> void:
	if _status == null:
		return
	if surface == null:
		_status.visible = true
		if _status.text.is_empty():
			_set_status("WebUISurface3D\n" + (page if not page.is_empty() else "(no page)"))


func _set_status(text: String) -> void:
	if _status:
		_status.text = text
		_status.visible = true


func _refresh_badge() -> void:
	if _badge:
		_badge.visible = show_preview_label and surface != null and surface.is_preview


func _on_first_frame() -> void:
	if _status:
		_status.visible = false
