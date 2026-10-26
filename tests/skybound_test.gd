extends SceneTree
## Run: godot --headless --path . -s res://tests/skybound_test.gd
## Skybound (examples/skybound): the scene's structure, the first-person body's physics, the game flow
## driven through the same handlers the page uses, and a bot that tries every jump of the course:
## it runs up to the edge of each platform and jumps toward the next one, with a single jump
## (sections 1-2, before the Wing Orb) or with the double jump (sections 3-5).

var failures := 0
var root_node: Skybound
var player: SBPlayer
var order: Array[Node3D] = []  # every platform in course order
var section_of := {}


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	root_node = load("res://examples/skybound/main.tscn").instantiate()
	root.add_child(root_node)
	await _frames(3)
	player = root_node.player
	await _test_structure()
	await _test_body()
	await _test_flow()
	await _test_course()
	print("\n%d failure(s)" % failures)
	quit(failures)


func _test_structure() -> void:
	var level := root_node.get_node("Level")
	check(level.get_child_count() == 5, "the level has five sections")
	for holder in level.get_children():
		for node in holder.get_children():
			if node.has_method("world_boxes"):
				order.append(node)
				section_of[node] = int(str(holder.name).substr(1)) - 1
	check(order.size() >= 40, "the course has at least 40 platforms (%d)" % order.size())
	check(root_node._checkpoints.size() == 5, "five checkpoints")
	for i in 5:
		check(root_node._checkpoints[i].index == i, "checkpoint %d is in order" % i)
	check(root_node.shard_total >= 20, "at least 20 shards (%d)" % root_node.shard_total)
	check(root_node._wings.size() == 1 and root_node._goal != null, "one Wing Orb and one goal")
	check(root_node.mode == Skybound.Mode.MENU and player.frozen, "the game starts on the menu with the player frozen")


func _test_body() -> void:
	# On the first platform: stand, run, jump, land.
	var first: Node3D = order[0]
	var top := (first.world_boxes()[0] as AABB).end.y
	player.frozen = false
	player.teleport(Vector3(0, top + 0.1, 0), 0.0)
	await _frames(30)
	check(player.is_on_floor(), "the player stands on the first platform")
	player.move_input = Vector2(0, -1)
	var z0 := player.global_position.z
	await _frames(20)
	check(player.global_position.z < z0 - 1.2, "stick up runs forward (-Z)")
	check(not player.is_sprinting() and not player.sprinting and player.horizontal_speed() < 7.0, "a keyboard-style full push only walks (no accidental sprint)")
	player.sprint_held = true
	await _frames(20)
	check(player.sprinting and player.horizontal_speed() > 8.0, "holding sprint sprints, and the controller reports it")
	player.sprint_held = false
	player.analog_input = true
	await _frames(5)
	check(player.is_sprinting(), "a full push on an analog stick sprints")
	player.move_input = Vector2(0, -0.5)
	await _frames(5)
	check(not player.is_sprinting(), "a half push on the stick does not")
	player.analog_input = false
	player.move_input = Vector2(0, -1)
	player.move_input = Vector2.ZERO
	await _frames(30)
	check(player.horizontal_speed() < 0.2, "letting go stops quickly")
	player.teleport(Vector3(0, top + 0.1, 0), 0.0)
	await _frames(20)
	var y0 := player.global_position.y
	var peak := y0
	player.request_jump()
	for i in 60:
		await physics_frame
		peak = maxf(peak, player.global_position.y)
	print("      held jump rises %.2f m" % (peak - y0))
	check(peak - y0 > 1.5 and peak - y0 < 2.4, "a held jump rises about 1.8 m")
	player.teleport(Vector3(0, top + 0.1, 0), 0.0)
	await _frames(20)
	peak = player.global_position.y
	player.request_jump()
	for i in 4:
		await physics_frame
	player.release_jump()
	for i in 60:
		await physics_frame
		peak = maxf(peak, player.global_position.y)
	print("      tapped jump rises %.2f m" % (peak - y0))
	check(peak - y0 < 1.3, "a tapped jump is a hop")
	# Double jump: only with the Wing Orb.
	player.can_double_jump = false
	player.teleport(Vector3(0, top + 0.1, 0), 0.0)
	await _frames(20)
	player.request_jump()
	await _frames(14)
	player.request_jump()
	await _frames(2)
	check(player.velocity.y < 6.0, "without the Wing Orb a second press does nothing in the air")
	player.can_double_jump = true
	player.teleport(Vector3(0, top + 0.1, 0), 0.0)
	await _frames(20)
	player.request_jump()
	await _frames(14)
	player.request_jump()
	await _frames(2)
	check(player.velocity.y > 5.0, "with the Wing Orb a second press jumps again")
	player.can_double_jump = false
	player.frozen = true
	player.clear_input()
	await _frames(40)


func _test_flow() -> void:
	var ui := root_node.ui
	# Settings go through the same validation as page requests.
	ui._on_raw_message('{"t":"event","name":"settings_changed","payload":{"sensitivity":99,"fov":5,"invert_y":true,"head_bob":"x"}}')
	check(is_equal_approx(root_node.settings.sensitivity, 3.0) and is_equal_approx(root_node.settings.fov, 65.0), "settings are clamped")
	check(root_node.settings.invert_y == true and root_node.settings.head_bob == true, "settings: a bad type is ignored")
	ui._on_raw_message('{"t":"event","name":"settings_changed","payload":{"sensitivity":1.0,"fov":78,"invert_y":false}}')
	# Performance settings: effects (glow and color grade) and the 3D resolution step.
	var env: Environment = root_node.world_environment.environment
	ui._on_raw_message('{"t":"event","name":"settings_changed","payload":{"effects":false,"render_scale":0.7}}')
	check(not env.glow_enabled and not env.adjustment_enabled, "turning effects off turns glow and the color grade off")
	check(is_equal_approx(root_node.settings.render_scale, 0.75) and is_equal_approx(root_node.get_viewport().scaling_3d_scale, 0.75), "the 3D resolution snaps to the nearest step and is applied")
	ui._on_raw_message('{"t":"event","name":"settings_changed","payload":{"effects":"yes","render_scale":"high"}}')
	check(not env.glow_enabled and is_equal_approx(root_node.settings.render_scale, 0.75), "bad types leave the performance settings alone")
	ui._on_raw_message('{"t":"event","name":"settings_changed","payload":{"effects":true,"render_scale":1.0}}')
	check(env.glow_enabled and is_equal_approx(root_node.get_viewport().scaling_3d_scale, 1.0), "effects on and Sharp restore the full look")

	# Run: start, countdown, look, move, pause, back, retry, finish.
	ui._on_raw_message('{"t":"event","name":"start_run","payload":{}}')
	check(root_node.mode == Skybound.Mode.COUNTDOWN and player.frozen, "start_run begins the countdown with the player frozen")
	await create_timer(3.0).timeout
	check(root_node.mode == Skybound.Mode.PLAYING and not player.frozen, "after 3 seconds the run is live")
	root_node._push_hud()
	var hud: Dictionary = JSON.parse_string(ui._state_cache["hud"])
	check(not hud.has("speed") and not hud.has("sprint"), "the HUD state carries no speed value (the speedometer is gone)")
	check(hud.has("sprinting") and hud.sprinting == false and hud.has("air_jump") and hud.air_jump == false, "the HUD reports the controller's sprint and double-jump state")
	check(not root_node.touch_controls(), "the desktop keeps keyboard and mouse (no touch controls)")
	root_node.player.can_double_jump = true
	await _frames(3)
	root_node._push_hud()
	hud = JSON.parse_string(ui._state_cache["hud"])
	check(hud.air_jump == true, "with the Wing Orb the HUD shows the double jump as available")
	root_node.player.can_double_jump = false
	var yaw := player.yaw
	ui._on_raw_message('{"t":"event","name":"look_drag","payload":{"dx":0.25,"dy":0.0}}')
	check(is_equal_approx(player.yaw, wrapf(yaw - PI / 4.0, -PI, PI)), "a quarter-height swipe turns the view 45 degrees")
	ui._on_raw_message('{"t":"event","name":"look_drag","payload":{"dx":"a","dy":0}}')
	ui._on_raw_message('{"t":"event","name":"move_changed","payload":{"x":0,"y":-1}}')
	var start := player.global_position
	await _frames(30)
	check(player.global_position.distance_to(start) > 1.5, "move_changed moves the player")
	ui._on_raw_message('{"t":"event","name":"move_changed","payload":{"x":0,"y":0}}')
	var t0: float = root_node.run_time
	root_node.on_back()
	check(root_node.mode == Skybound.Mode.PAUSED and paused, "Back while playing pauses")
	await create_timer(0.3).timeout
	check(is_equal_approx(root_node.run_time, t0), "the run clock stops while paused")
	root_node.on_back()
	check(root_node.mode == Skybound.Mode.PLAYING and not paused, "Back while paused resumes")
	# Falling off respawns at the checkpoint and counts a death.
	var deaths: int = root_node.run_deaths
	player.global_position = Vector3(0, -200, 0)
	await _frames(3)
	check(root_node.run_deaths == deaths + 1 and player.global_position.y > -5.0, "falling off respawns at the checkpoint (+1 death)")
	# Collecting a shard counts it; the goal ends the run with a medal.
	var shard: SBShard = root_node._shards[0]
	shard._on_body_entered(player)
	check(root_node.run_shards == 1, "a shard is counted")
	root_node.run_time = 120.0
	root_node._on_goal()
	check(root_node.mode == Skybound.Mode.RESULTS and root_node._results.medal == "gold", "finishing in 2:00 earns gold")
	check(root_node.profile.best_time > 0.0 and root_node.profile.finishes >= 1, "the best time is saved")
	check(Skybound.medal_for(200.0) == "silver" and Skybound.medal_for(290.0) == "bronze" and Skybound.medal_for(400.0) == "none", "medal thresholds")
	root_node.on_back()
	check(root_node.mode == Skybound.Mode.MENU, "Back on the results screen returns to the menu")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Skybound.SAVE_PATH))


## Tries every jump of the course with a bot.
func _test_course() -> void:
	root_node.mode = Skybound.Mode.MENU
	for node in order:
		if node is SBMovingPlatform:
			node.set_physics_process(false)
	var bad: Array[String] = []
	var needs_double: Array[String] = []
	var tried := 0
	for i in range(1, order.size()):
		var from: Node3D = order[i - 1]
		var to: Node3D = order[i]
		var section: int = section_of[to]
		var double_allowed := section >= 2
		var how := await _find_way(from, to, double_allowed)
		tried += 1
		var label := "%s/%s -> %s/%s" % [from.get_parent().name, from.name, to.get_parent().name, to.name]
		if how == "":
			bad.append(label + (" (with double jump)" if double_allowed else " (single jump)"))
		elif how.ends_with("+double"):
			needs_double.append(label)
	print("      %d jumps tried, %d impossible, %d need the double jump" % [tried, bad.size(), needs_double.size()])
	for line in bad:
		print("      cannot jump: ", line)
	check(bad.is_empty(), "every jump of the course can be made")
	check(needs_double.size() >= 3, "the Wing Orb matters: some jumps need the double jump (%d)" % needs_double.size())
	player.frozen = true


## Tries ways of making one jump (a sprint, a walk, a sprint with braking; with and without the double jump
## when allowed). Returns how it worked, or "" when no way did.
func _find_way(from: Node3D, to: Node3D, double_allowed: bool) -> String:
	var variants := _target_variants(to)
	var launches := _target_variants(from)  # a moving platform can be left from any point of its path
	for use_double in ([false, true] if double_allowed else [false]):
		for style in ["sprint", "walk", "brake"]:
			for from_at in launches:
				for target_at in variants:
					if await _attempt(from, from_at, to, target_at, use_double, style):
						return style + ("+double" if use_double else "")
	return ""


## Where the target might be: its home, and for a moving platform each end of its path.
func _target_variants(node: Node3D) -> Array[Vector3]:
	var variants: Array[Vector3] = [node.global_position]
	if node is SBMovingPlatform:
		var half: Vector3 = node.global_basis * (node.travel * 0.5)
		variants.append(node.global_position - half)
		variants.append(node.global_position + half)
	return variants


func _attempt(from: Node3D, from_at: Vector3, to: Node3D, target_at: Vector3, double: bool, style: String) -> bool:
	var moved := to.global_position
	var left := from.global_position
	from.global_position = from_at
	to.global_position = target_at
	var from_box := SBBuild.world_box(from_at, from.size, from.global_rotation.y)
	var to_box := SBBuild.world_box(target_at, to.size, to.global_rotation.y)
	var pad: Variant = null
	for node in get_nodes_in_group("sb_bounce"):
		var at: Vector3 = node.global_position
		if at.x > from_box.position.x and at.x < from_box.end.x and at.z > from_box.position.z and at.z < from_box.end.z:
			pad = at
	var result := await _run_bot(from_box, to_box, double, style, pad)
	to.global_position = moved
	from.global_position = left
	return result


func _run_bot(from_box: AABB, to_box: AABB, double: bool, style: String, pad: Variant) -> bool:
	var from_centre := from_box.get_center()
	var to_centre := to_box.get_center()
	var source := from_centre if pad == null else (pad as Vector3)
	var dir := Vector3(to_centre.x - source.x, 0.0, to_centre.z - source.z).normalized()
	var run_up := 2.0
	var start := Vector3(source.x, from_box.end.y, source.z) - dir * run_up
	var jump_along := run_up - 0.12
	if pad == null:
		var half := from_box.size * 0.5
		var t := INF
		if absf(dir.x) > 0.001:
			t = minf(t, half.x / absf(dir.x))
		if absf(dir.z) > 0.001:
			t = minf(t, half.z / absf(dir.z))
		run_up = clampf(t - 0.3, 0.4, 4.0)
		var edge := Vector3(from_centre.x, from_box.end.y, from_centre.z) + dir * t
		start = edge - dir * run_up
		jump_along = run_up - 0.12
	start.y += 0.05
	player.frozen = false
	player.can_double_jump = double
	player.teleport(start, atan2(-dir.x, -dir.z))
	await physics_frame
	var aim_back := 0.0
	for node in get_nodes_in_group("sb_bounce"):
		var at: Vector3 = node.global_position
		if at.x > to_box.position.x and at.x < to_box.end.x and at.z > to_box.position.z and at.z < to_box.end.z:
			aim_back = 1.9  # land before a spring pad, not on it
	var magnitude := 0.8 if style == "walk" else 1.0
	player.sprint_held = style != "walk"  # sprint is Shift on a keyboard; the bot is not an analog stick
	player.move_input = Vector2(0, -magnitude)
	var jumped_at := -1
	var second := false
	var target_top := to_box.end.y
	for frame in 300:
		await physics_frame
		var along := (player.global_position - start).dot(dir)
		if pad == null and jumped_at < 0 and along >= jump_along:
			player.request_jump()
			jumped_at = frame
		elif pad != null and jumped_at < 0 and player.velocity.y > 3.0:
			jumped_at = frame  # the spring pad threw the player
		if jumped_at >= 0 and not player.is_on_floor():
			# Steer at the target centre while in the air.
			var aim := to_centre - dir * aim_back
			var to_target := Vector3(aim.x - player.global_position.x, 0.0, aim.z - player.global_position.z)
			if to_target.length() > 0.3:
				player.yaw = atan2(-to_target.x, -to_target.z)
			if style == "brake" and to_target.length() < 2.2 and player.horizontal_speed() > 4.0:
				player.move_input = Vector2(0, 1.0)  # push back to stop over the platform
			if double and not second and frame > jumped_at + 6 and player.velocity.y < 0.4:
				player.request_jump()
				second = true
		if jumped_at >= 0 and frame > jumped_at + 12 and player.is_on_floor():
			var p := player.global_position
			var on_target := p.x > to_box.position.x - 0.3 and p.x < to_box.end.x + 0.3 				and p.z > to_box.position.z - 0.3 and p.z < to_box.end.z + 0.3 				and absf(p.y - target_top) < 0.5
			player.move_input = Vector2.ZERO
			return on_target
		if player.global_position.y < from_box.end.y - 14.0:
			break
	player.move_input = Vector2.ZERO
	return false
