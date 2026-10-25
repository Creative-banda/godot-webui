extends SceneTree
## Run: godot --headless --path . -s res://tests/player_feel_test.gd
## The 2D player's movement feel (examples/playable_character/player.gd) on a flat floor: how a jump
## behaves when held and when tapped, gravity shaping, run acceleration, braking, skid, air momentum
## and the squash reactions. Numbers are loose bounds, not exact values: they catch a regression
## that makes the character feel floaty, glued or unresponsive.

var failures := 0
var floor_body: StaticBody2D
var player: DemoPlayer


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _fresh() -> void:
	if is_instance_valid(floor_body):
		floor_body.queue_free()
	await process_frame
	floor_body = StaticBody2D.new()
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(40000, 40)
	shape.shape = rect
	shape.position = Vector2(0, 20)
	floor_body.add_child(shape)
	root.add_child(floor_body)
	player = load("res://examples/playable_character/player.tscn").instantiate()
	player.position = Vector2(0, 0)
	floor_body.add_child(player)
	await _frames(20)


func _jump_peak(hold_frames: int) -> float:
	await _fresh()
	var y0 := player.position.y
	var peak := y0
	player.request_jump()
	for i in 90:
		if i == hold_frames:
			player.release_jump()
		await physics_frame
		peak = minf(peak, player.position.y)
	return y0 - peak


func _initialize() -> void:
	await _fresh()
	check(player.is_on_floor(), "player stands on the floor")

	# ---- jump height: held is a full jump, a tap is a hop
	var full := await _jump_peak(999)
	var hop := await _jump_peak(2)
	print("      full jump %.0f px, hop %.0f px" % [full, hop])
	check(full > 150.0 and full < 300.0, "a held jump is a full jump (150-300 px)")
	check(hop > 25.0 and hop < full * 0.6, "a tapped jump is a clearly smaller hop")

	# ---- gravity shaping: the fall is quicker than the climb, and speed is capped
	await _fresh()
	player.request_jump()
	var rise_frames := 0
	var fall_frames := 0
	var seen_top := false
	var max_fall := 0.0
	for i in 200:
		await physics_frame
		if not seen_top:
			if player.velocity.y < 0.0:
				rise_frames += 1
			else:
				seen_top = true
		elif not player.is_on_floor():
			fall_frames += 1
		max_fall = maxf(max_fall, player.velocity.y)
	print("      rise %d frames, fall %d frames, max fall speed %.0f" % [rise_frames, fall_frames, max_fall])
	check(fall_frames < rise_frames * 1.2 + 6, "the way down is not slower than the way up")
	check(max_fall <= DemoPlayer.TERMINAL_SPEED + 1.0, "fall speed is capped")
	check(player.is_on_floor(), "player lands again")

	# ---- running: quick start, firm stop, hard turn
	await _fresh()
	player.move_input = Vector2(1, 0)
	var start_frames := 0
	while player.velocity.x < DemoPlayer.SPEED * 0.99 and start_frames < 60:
		await physics_frame
		start_frames += 1
	print("      full speed after %d frames" % start_frames)
	check(start_frames >= 6 and start_frames <= 20, "full speed in about 0.1-0.35 s (not instant, not sluggish)")
	player.move_input = Vector2.ZERO
	var stop_frames := 0
	while absf(player.velocity.x) > 1.0 and stop_frames < 90:
		await physics_frame
		stop_frames += 1
	check(stop_frames <= 14, "letting go stops within about 0.25 s (%d frames)" % stop_frames)

	player.move_input = Vector2(1, 0)
	await _frames(25)
	var skids := [0]
	player.skidded.connect(func(_at: Vector2) -> void: skids[0] += 1)
	player.move_input = Vector2(-1, 0)
	var turn_frames := 0
	while player.velocity.x > 0.0 and turn_frames < 60:
		await physics_frame
		turn_frames += 1
	print("      reversed after %d frames" % turn_frames)
	check(turn_frames <= 10, "reversing is quicker than coasting to a stop")
	check(skids[0] > 0, "a reversal at speed reports a skid")

	# ---- air: momentum is kept without input, and control is a little softer
	await _fresh()
	player.move_input = Vector2(1, 0)
	await _frames(25)
	player.request_jump()
	player.move_input = Vector2.ZERO
	await _frames(10)
	var vx_air := player.velocity.x
	check(vx_air > DemoPlayer.SPEED * 0.6, "letting go in the air keeps most of the speed (%.0f)" % vx_air)

	# ---- squash and stretch reacts
	await _fresh()
	var impacts: Array = []
	player.landed.connect(func(i: float) -> void: impacts.append(i))
	player.request_jump()
	await _frames(1)
	check(player._squash > 1.05, "take-off stretches the body")
	await _frames(100)
	check(impacts.size() == 1 and impacts[0] > 0.2, "landing reports an impact from the fall speed (%s)" % [impacts])
	check(absf(player._squash - 1.0) < 0.12, "the body settles back to its normal shape")
	var footsteps := [0]
	player.stepped.connect(func(_at: Vector2) -> void: footsteps[0] += 1)
	player.move_input = Vector2(1, 0)
	await _frames(60)
	check(footsteps[0] >= 3, "running reports footsteps (%d in a second)" % footsteps[0])

	# ---- coyote time and buffering
	await _fresh()
	player.position = Vector2(0, -2)
	player.request_jump()
	await _frames(3)
	check(player.velocity.y < 0.0 or player.position.y < -10.0, "a jump pressed just before landing is buffered")

	print("\n%d failure(s)" % failures)
	quit(failures)
