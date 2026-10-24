extends Node3D
## 3D demo: a character on a small test arena, a virtual stick and jump button drawn by the HTML page
## (hud3d.html), and camera look by swiping anywhere on the screen outside those controls.
##
##   stick / jump   page --Godot.emit("move_changed" / "jump")--> handlers below
##   camera swipe   page look zone --Godot.emit("look_drag" {dx, dy})--> _on_look_drag (see below)
##   telemetry      Godot --set_state("telemetry")--> the page shows yaw, pitch, FPS, swipe state
##
## Run this scene (F6) or set it as the main scene to export it. The page only sends input and shows
## what Godot tells it. Camera settings (sensitivity, invert) are owned here and echoed back.
## Why the swipe goes through the page: on Android the WebView owns a touch sequence once a finger is on
## the stick, and a second finger is then given to the WebView as well, so Godot would never see a swipe
## made while the stick is held. A full-screen look zone in the page keeps every finger in one multi-touch
## system. The page sends fractions of the screen height; Godot owns the sensitivity and turns the camera.
## Desktop preview: WASD / arrows move, Space jumps, drag with the mouse to look (all through the page).

## Shared with the 2D demo: one overlay serves one folder, so both HUD pages live there.
const UI_DIR := "res://examples/playable_character/ui"
const PAGE := "hud3d.html"
const RADIANS_PER_SCREEN_HEIGHT := PI  # a swipe over the full screen height turns the view 180 degrees at 1x
const TELEMETRY_INTERVAL := 0.1
const SENSITIVITY_MIN := 0.2
const SENSITIVITY_MAX := 3.0

@onready var player: Demo3DPlayer = $Player
@onready var rig: Demo3DCameraRig = $CameraRig

## Set by the demo shell (app.gd) when this scene is opened from the menu; null when run on its own.
var app: DemoApp
var ui: GodotWebUI
var sensitivity := 1.0
var invert_x := false
var invert_y := false

var _stick := Vector2.ZERO
var _page_keys := Vector2.ZERO  # direction keys forwarded by the page (see _on_keys_changed)
var _look_active := false  # the page reports a finger or the mouse dragging on its look zone
var _telemetry_timer := 0.0
var _last_telemetry := {}


func _ready() -> void:
	if app:
		# Opened from the menu: the shell owns the overlay.
		ui = app.ui
		show_hud()
	else:
		ui = GodotWebUI.new()
		add_child(ui)
		ui.error.connect(func(code: String, text: String) -> void: printerr("WebUI ", code, ": ", text))
		ui.page_ready.connect(_push_all)
		# Only elements marked data-webui-touch take touches. The page marks its whole look zone.
		ui.set_touch_mode(GodotWebUI.TouchMode.REGIONS)
		_connect_page()
		ui.start(UI_DIR, PAGE)


## Points the shell overlay at the 3D HUD page and registers this scene's page handlers. Also called
## by the benchmark after it shut the overlay down (show_page resets the handlers before these run).
func show_hud() -> void:
	app.show_page(PAGE, GodotWebUI.TouchMode.REGIONS, _push_all)
	_connect_page()


func _connect_page() -> void:
	ui.on("move_changed", _on_move_changed)
	ui.on("jump", func(_p: Dictionary) -> void: player.request_jump())
	ui.on("keys_changed", _on_keys_changed)
	ui.on("look_drag", _on_look_drag)
	ui.on("look_active", _on_look_active)
	ui.on("camera_settings", _on_camera_settings)
	ui.on("back_to_menu", func(_p: Dictionary) -> void:
		if app:
			app.show_menu())


## Android Back (the shell calls this when the page did not use it): back to the menu.
func on_back() -> void:
	if app:
		app.show_menu()
	else:
		get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_stick = Vector2.ZERO
		_page_keys = Vector2.ZERO
		_look_active = false
		player.clear_input()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_SPACE:
		player.request_jump()


func _physics_process(_delta: float) -> void:
	player.camera_yaw = rig.yaw
	if _stick != Vector2.ZERO:
		player.move_input = _stick
	elif _page_keys != Vector2.ZERO:
		player.move_input = _page_keys
	else:
		player.move_input = _keyboard_vector()


func _process(delta: float) -> void:
	_telemetry_timer += delta
	if _telemetry_timer >= TELEMETRY_INTERVAL:
		_telemetry_timer = 0.0
		_push_telemetry()


## `swipe` is in fractions of the screen height, so the feel is the same on every resolution and aspect
## ratio: a swipe over the full height turns the view RADIANS_PER_SCREEN_HEIGHT at sensitivity 1.
func _look(swipe: Vector2) -> void:
	var k := RADIANS_PER_SCREEN_HEIGHT * sensitivity
	var x := swipe.x * k * (-1.0 if invert_x else 1.0)
	var y := -swipe.y * k * (-1.0 if invert_y else 1.0)
	rig.look(Vector2(x, y))


func _keyboard_vector() -> Vector2:
	var v := Vector2(
		float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT))
		- float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT)),
		float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN))
		- float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)))
	return v.limit_length(1.0)


func _on_move_changed(payload: Dictionary) -> void:
	var x: Variant = payload.get("x")
	var y: Variant = payload.get("y")
	if typeof(x) not in [TYPE_FLOAT, TYPE_INT] or typeof(y) not in [TYPE_FLOAT, TYPE_INT]:
		printerr("move_changed needs numeric x and y, got ", payload)
		return
	_stick = Vector2(clampf(x, -1.0, 1.0), clampf(y, -1.0, 1.0)).limit_length(1.0)


## Keyboard fallback for the desktop preview: when the page's WebView has the keyboard focus, key
## presses never reach Godot, so the page forwards the direction keys it sees.
func _on_keys_changed(payload: Dictionary) -> void:
	for key in ["up", "down", "left", "right"]:
		if typeof(payload.get(key, false)) != TYPE_BOOL:
			printerr("keys_changed: '", key, "' must be a bool, got ", payload)
			return
	_page_keys = Vector2(
		float(payload.get("right", false)) - float(payload.get("left", false)),
		float(payload.get("down", false)) - float(payload.get("up", false))).limit_length(1.0)


func _on_look_drag(payload: Dictionary) -> void:
	var dx: Variant = payload.get("dx")
	var dy: Variant = payload.get("dy")
	if typeof(dx) not in [TYPE_FLOAT, TYPE_INT] or typeof(dy) not in [TYPE_FLOAT, TYPE_INT]:
		printerr("look_drag needs numeric dx and dy, got ", payload)
		return
	_look(Vector2(clampf(dx, -1.0, 1.0), clampf(dy, -1.0, 1.0)))  # one message never turns more than a full swipe


func _on_look_active(payload: Dictionary) -> void:
	if typeof(payload.get("active")) != TYPE_BOOL:
		printerr("look_active needs a bool 'active', got ", payload)
		return
	_look_active = payload.active


func _on_camera_settings(payload: Dictionary) -> void:
	if typeof(payload.get("sensitivity")) in [TYPE_FLOAT, TYPE_INT]:
		sensitivity = clampf(payload.sensitivity, SENSITIVITY_MIN, SENSITIVITY_MAX)
	if typeof(payload.get("invert_x")) == TYPE_BOOL:
		invert_x = payload.invert_x
	if typeof(payload.get("invert_y")) == TYPE_BOOL:
		invert_y = payload.invert_y
	_push_camera()


func _push_all() -> void:
	_last_telemetry = {}
	_push_camera()
	_push_telemetry()


func _push_camera() -> void:
	ui.set_state("camera", {"sensitivity": sensitivity, "invert_x": invert_x, "invert_y": invert_y, "can_exit": app != null})


func _push_telemetry() -> void:
	var state := {
		"yaw": roundi(fposmod(rad_to_deg(rig.yaw), 360.0)),
		"pitch": roundi(rad_to_deg(rig.pitch)),
		"swiping": _look_active,
		"on_floor": player.is_on_floor(),
		"speed": snappedf(Vector2(player.velocity.x, player.velocity.z).length(), 0.1),
		"fps": roundi(Engine.get_frames_per_second()),
	}
	if state != _last_telemetry:  # only send when something changed
		_last_telemetry = state
		ui.set_state("telemetry", state)
