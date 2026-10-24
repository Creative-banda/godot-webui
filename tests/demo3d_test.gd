extends SceneTree
## Run: godot --headless --path . -s res://tests/demo3d_test.gd
## Covers the 3D demo (examples/third_person_3d): the scene loads, the character stands, runs relative to
## the camera, jumps, and the swipe look / settings validation behave. No WebView involved: headless
## uses the null backend, so the page's input is simulated by calling the same handlers.

var failures := 0


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _wait_physics(frames: int) -> void:
	for i in frames:
		await physics_frame


func _initialize() -> void:
	var scene: Node3D = load("res://examples/third_person_3d/main3d.tscn").instantiate()
	root.add_child(scene)
	var player: Demo3DPlayer = scene.get_node("Player")
	var rig: Demo3DCameraRig = scene.get_node("CameraRig")
	check(player != null and rig != null, "scene has player and camera rig")

	await _wait_physics(60)
	check(player.is_on_floor(), "player lands on the ground")
	check(absf(player.global_position.y) < 0.05, "player stands at ground level")

	# Stick up with the camera at yaw 0: run away from the camera (-Z).
	var z0 := player.global_position.z
	scene._on_move_changed({"x": 0.0, "y": -1.0})
	await _wait_physics(30)
	check(player.global_position.z < z0 - 1.0, "stick up runs away from the camera")
	check(absf(player.global_position.x) < 0.2, "straight run does not drift sideways")
	scene._on_move_changed({"x": 0.0, "y": 0.0})
	await _wait_physics(30)
	check(Vector2(player.velocity.x, player.velocity.z).length() < 0.1, "releasing the stick stops the player")

	# Rotate the camera a quarter turn to the right: stick up now runs along the camera's new forward.
	rig.look(Vector2(PI / 2.0, 0.0))
	check(is_equal_approx(rig.yaw, -PI / 2.0), "look right decreases yaw by a quarter turn")
	var x0 := player.global_position.x
	scene._on_move_changed({"x": 0.0, "y": -1.0})
	await _wait_physics(30)
	check(player.global_position.x > x0 + 1.0, "stick up follows the camera direction after turning")
	scene._on_move_changed({"x": 0.0, "y": 0.0})
	await _wait_physics(30)

	# The camera follows the player.
	var goal := player.global_position + Vector3.UP * rig.height
	check(rig.global_position.distance_to(goal) < 0.3, "camera rig follows the player")
	scene._on_move_changed({"x": 0.0, "y": -1.0})
	await _wait_physics(60)
	goal = player.global_position + Vector3.UP * rig.height
	check(rig.global_position.distance_to(goal) < 0.5, "camera keeps following while the player runs")
	scene._on_move_changed({"x": 0.0, "y": 0.0})
	await _wait_physics(30)

	# Keys forwarded by the page (keyboard fallback) move the player like the stick.
	var kx := player.global_position.x
	var kz := player.global_position.z
	scene._on_keys_changed({"up": false, "down": false, "left": false, "right": true})
	await _wait_physics(30)
	check(scene._page_keys == Vector2(1, 0), "page keys give a direction")
	check(absf(player.global_position.x - kx) + absf(player.global_position.z - kz) > 0.5, "forwarded keys move the player")
	scene._on_keys_changed({"up": false, "down": false, "left": false, "right": false})
	scene._on_keys_changed({"up": "x"})
	check(scene._page_keys == Vector2.ZERO, "released and invalid keys leave no input")
	await _wait_physics(30)

	# Jump.
	var y0 := player.global_position.y
	player.request_jump()
	await _wait_physics(10)
	check(player.global_position.y > y0 + 0.3, "jump leaves the ground")
	await _wait_physics(60)
	check(player.is_on_floor(), "player lands again")

	# Swipe: a full-height drag at 1x turns 180 degrees, and pitch is clamped.
	rig.yaw = 0.0
	rig.pitch = 0.0
	scene.sensitivity = 1.0
	scene._look(Vector2(0.0, 0.0))
	var height := scene.get_viewport().get_visible_rect().size.y
	scene._look(Vector2(height / 2.0, 0.0))
	check(is_equal_approx(rig.yaw, -PI / 2.0), "half-height swipe right turns 90 degrees at 1x")
	rig.yaw = 0.0
	scene.invert_x = true
	scene._look(Vector2(height / 2.0, 0.0))
	check(is_equal_approx(rig.yaw, PI / 2.0), "invert X flips the swipe direction")
	scene.invert_x = false
	rig.pitch = 0.0
	scene._look(Vector2(0.0, -height * 10.0))
	check(is_equal_approx(rig.pitch, Demo3DCameraRig.PITCH_MAX), "pitch clamps looking up")
	scene._look(Vector2(0.0, height * 10.0))
	check(is_equal_approx(rig.pitch, Demo3DCameraRig.PITCH_MIN), "pitch clamps looking down")

	# Settings and payload validation.
	scene._on_camera_settings({"sensitivity": 99, "invert_y": true})
	check(is_equal_approx(scene.sensitivity, scene.SENSITIVITY_MAX) and scene.invert_y, "settings are clamped and applied")
	scene._on_camera_settings({"sensitivity": "fast", "invert_x": "yes"})
	check(is_equal_approx(scene.sensitivity, scene.SENSITIVITY_MAX) and not scene.invert_x, "wrong types are ignored")
	scene._on_move_changed({"x": "a", "y": 1})
	check(scene._stick == Vector2.ZERO, "non-numeric stick payload is rejected")

	# A click that starts on a page control must not turn the camera (desktop preview).
	rig.yaw = 0.0
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	scene._input(press)
	scene._on_ui_busy({"busy": true})  # the page reports the same click a moment later
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(200, 0)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	scene._input(motion)
	check(is_equal_approx(rig.yaw, 0.0), "a click on a page control does not rotate the camera")
	scene._on_ui_busy({"busy": false})
	scene._input(motion)
	check(is_equal_approx(rig.yaw, 0.0), "the same press stays ignored after the control is released")
	press.pressed = false
	scene._input(press)
	press.pressed = true
	scene._input(press)
	scene._input(motion)
	check(not is_equal_approx(rig.yaw, 0.0), "a new press on open screen turns the camera")
	motion.button_mask = 0
	var yaw_before := rig.yaw
	scene._input(motion)
	check(is_equal_approx(rig.yaw, yaw_before), "moving without a button held does not rotate the camera")
	press.pressed = false
	scene._input(press)

	# Falling off the world respawns.
	player.global_position = Vector3(0, -30, 0)
	await _wait_physics(2)
	check(player.global_position.y > -1.0, "falling out of the world respawns the player")

	# Opened from the demo menu: the shell owns the overlay and the scene swaps both ways.
	scene.queue_free()
	var shell: DemoApp = load("res://examples/playable_character/main.tscn").instantiate()
	root.add_child(shell)
	await process_frame
	shell.start_3d()
	await process_frame
	await process_frame
	var from_menu: Node = shell._scene
	check(from_menu.has_method("_on_ui_busy"), "start_3d() opens the 3D scene")
	check(from_menu.app == shell and from_menu.ui == shell.ui, "the 3D scene uses the shell overlay")
	shell.show_menu()
	await process_frame
	await process_frame
	check(not shell._scene.has_method("_on_ui_busy"), "show_menu() leaves the 3D scene")
	shell.queue_free()

	print("\n%d failure(s)" % failures)
	quit(failures)
