extends SceneTree
## Throwaway probe: drives ACCESS DENIED through the bridge like the WebUI would.

var failures := 0
func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond: failures += 1

func _initialize() -> void:
	var game: Node = load("res://examples/access_denied/main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	var ui: GodotWebUI = game.ui
	var world := {}
	ui.set_state("world", world)  # no-op, ensures call shape
	# menu -> hud
	ui._on_raw_message('{"t":"event","name":"menu_start","payload":{}}')
	await process_frame
	check(game._page == "hud.html", "menu_start opens the HUD")
	check(game.player.frozen == false, "player unfrozen during exploration")
	# breaker opens Door A
	var breaker = game.get_node("Facility/Props/Breaker")
	game._use_breaker(breaker.id)
	check(game.door_a.unlocked and game.door_a._open, "breaker releases Door A")
	# TRACE (open the terminal first, as a player would)
	game._open_terminal("trace")
	await process_frame
	ui._on_raw_message('{"t":"event","name":"trace_submit","payload":{"path":["ACCESS_REQUEST","GATEWAY","RELAY_09","DOOR_CONTROL"]}}')
	check(not game.trace_solved, "relay route rejected")
	# TRACE correct
	ui._on_raw_message('{"t":"event","name":"trace_submit","payload":{"path":["ACCESS_REQUEST","GATEWAY","VERIFY_01","DOOR_CONTROL"]}}')
	check(game.trace_solved and game.door_b.unlocked, "correct route unlocks Door B")
	# OVERRIDE wrong then right
	game._open_terminal("override")
	await process_frame
	ui._on_raw_message('{"t":"event","name":"override_submit","payload":{"order":["verify_recovery","check_auth","release_access"]}}')
	check(not game.override_solved, "reversed procedure rejected")
	ui._on_raw_message('{"t":"event","name":"override_submit","payload":{"order":["check_auth","verify_recovery","release_access"]}}')
	check(game.override_solved and game.door_c.unlocked, "correct procedure unlocks Door C")
	# GRID: over-capacity and aux-on rejected
	game._open_terminal("grid")
	await process_frame
	ui._on_raw_message('{"t":"event","name":"grid_apply","payload":{"alloc":{"lighting":2,"controller":4,"security":3,"aux":2}}}')
	check(not game.grid_solved, "over-capacity / aux-on rejected")
	ui._on_raw_message('{"t":"event","name":"grid_apply","payload":{"alloc":{"lighting":2,"controller":4,"security":3,"aux":0}}}')
	check(game.grid_solved and game.power_on and game.door_d.unlocked, "essential power unlocks Door D")
	# final console ends the game
	game._final_console()
	await process_frame
	check(game.finished, "final console completes the game")
	print("\n%d failure(s)" % failures)
	quit(failures)
