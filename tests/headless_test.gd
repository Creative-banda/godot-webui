extends SceneTree
## Run: godot --headless --path . -s res://tests/headless_test.gd
## Verifies the GDScript half (protocol validation + physics reacting to bridge messages) with no WebView.

var failures := 0


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	# --- protocol validation
	check(WebUIBridge.parse_incoming('{"t":"ready"}').ok, "ready accepted")
	var ev := WebUIBridge.parse_incoming('{"t":"event","name":"move_changed","payload":{"x":0.5,"y":-1}}')
	check(ev.ok and ev.name == "move_changed" and ev.payload.x == 0.5, "event parsed")
	check(WebUIBridge.parse_incoming('{"t":"event","name":"jump"}').ok, "missing payload defaults to {}")
	check(not WebUIBridge.parse_incoming("not json").ok, "garbage rejected")
	check(not WebUIBridge.parse_incoming("[1,2]").ok, "non-object rejected")
	check(not WebUIBridge.parse_incoming('{"t":"event","name":"bad name!","payload":{}}').ok, "bad name rejected")
	check(not WebUIBridge.parse_incoming('{"t":"event","name":"x","payload":[1]}').ok, "array payload rejected")
	check(not WebUIBridge.parse_incoming('{"t":"call","name":"queue_free"}').ok, "unknown type rejected")
	check(not WebUIBridge.parse_incoming(" ".repeat(70000)).ok, "oversized rejected")
	check(WebUIBridge.encode_payload({"a": 1}) == '{"a":1}', "payload encoded")

	# --- menu -> game flow driven only through bridge messages
	var app: DemoApp = load("res://examples/playable_character/main.tscn").instantiate()
	root.add_child(app)
	await physics_frames(3)
	check(app._scene != null and app._scene.name == "Menu", "app starts on the menu")
	app.ui._on_raw_message('{"t":"event","name":"settings_changed","payload":{"difficulty":"hard","music":2,"sfx":"x"}}')
	check(app.settings.difficulty == "hard" and app.settings.music == 1.0 and app.settings.sfx == true, "settings validated (clamp, bad type ignored)")
	app.ui._on_raw_message('{"t":"event","name":"settings_changed","payload":{"difficulty":"nightmare"}}')
	check(app.settings.difficulty == "hard", "invalid difficulty ignored")
	app.ui._on_raw_message('{"t":"event","name":"menu_play","payload":{"level":9}}')
	await physics_frames(2)
	check(app._scene.name == "Menu", "invalid level rejected")
	app.ui._on_raw_message('{"t":"event","name":"menu_play","payload":{"level":2}}')
	await physics_frames(60)
	check(app._scene.name == "Main" and app.level == 2 and app.stats.plays >= 1, "menu_play starts level 2")
	var main: Node = app._scene
	check(main.player.gravity_scale == 0.6 and main.player.damage_scale == 2.0, "level + difficulty applied in Godot")
	var player: DemoPlayer = main.get_node("Player")
	check(player.is_on_floor(), "player settles on floor")
	var x0 := player.position.x
	app.ui._on_raw_message('{"t":"event","name":"move_changed","payload":{"x":1,"y":0}}')
	await physics_frames(30)
	check(player.position.x > x0 + 50, "move_changed moves player (%.0f -> %.0f)" % [x0, player.position.x])
	app.ui._on_raw_message('{"t":"event","name":"move_changed","payload":{"x":0,"y":0}}')
	await physics_frames(40)
	var y0 := player.position.y
	app.ui._on_raw_message('{"t":"event","name":"jump","payload":{}}')
	await physics_frames(10)
	check(player.position.y < y0 - 20, "jump lifts player via physics")
	app.ui._on_raw_message('{"t":"event","name":"attack_pressed","payload":{}}')
	check(player.attacking, "attack_pressed")
	app.ui._on_raw_message('{"t":"event","name":"attack_released","payload":{}}')
	check(not player.attacking, "attack_released")
	app.ui._on_raw_message('{"t":"event","name":"move_changed","payload":{"x":"evil","y":0}}')
	check(player.move_input == Vector2.ZERO, "non-numeric move ignored")
	app.ui._on_raw_message('{"t":"event","name":"damage_self","payload":{}}')
	check(player.health == 80, "damage_self reduces health (hard = x2)")
	app.ui._on_raw_message('{"t":"event","name":"pause_toggle","payload":{}}')
	check(paused, "pause_toggle pauses the tree")
	app.ui._on_raw_message('{"t":"event","name":"pause_toggle","payload":{}}')
	check(not paused, "pause_toggle resumes")
	app.ui._on_raw_message('{"t":"event","name":"back_to_menu","payload":{}}')
	await physics_frames(3)
	check(app._scene.name == "Menu" and not paused, "back_to_menu returns to menu")
	quit(failures)


func physics_frames(n: int) -> void:
	for i in n:
		await physics_frame

