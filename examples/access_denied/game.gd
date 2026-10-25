extends Node3D
## ACCESS DENIED — authoritative game state. Owns the overlay lifecycle (menu / HUD / terminal /
## completion), first-person input routing, doors, journal, the three puzzles (TRACE, OVERRIDE,
## GRID) with server-side validation, facility power and the ending. The WebUI pages render the
## state pushed from here and send intent events back.

const UI_DIR := "res://examples/access_denied/ui"

const TRACE_PATH := ["ACCESS_REQUEST", "GATEWAY", "VERIFY_01", "DOOR_CONTROL"]
const TRACE_NODES := [
	{"id": "ACCESS_REQUEST", "label": "ACCESS REQUEST"},
	{"id": "GATEWAY", "label": "GATEWAY"},
	{"id": "VERIFY_01", "label": "VERIFY-01"},
	{"id": "RELAY_09", "label": "RELAY-09"},
	{"id": "DOOR_CONTROL", "label": "DOOR CONTROL"},
]
const TRACE_LINKS := [
	["ACCESS_REQUEST", "GATEWAY"], ["GATEWAY", "VERIFY_01"], ["GATEWAY", "RELAY_09"],
	["RELAY_09", "VERIFY_01"], ["VERIFY_01", "DOOR_CONTROL"], ["RELAY_09", "DOOR_CONTROL"],
]
const OVERRIDE_CORRECT := ["check_auth", "verify_recovery", "release_access"]
const OVERRIDE_STAGES := [
	{"id": "check_auth", "label": "CHECK MAINTENANCE AUTHORIZATION"},
	{"id": "verify_recovery", "label": "VERIFY EMERGENCY RECOVERY REQUEST"},
	{"id": "release_access", "label": "RELEASE POWER ROOM ACCESS"},
]
const GRID_CAPACITY := 9
const GRID_SYSTEMS := [
	{"id": "lighting", "label": "Emergency lighting", "need": 2, "essential": true},
	{"id": "controller", "label": "Central controller", "need": 4, "essential": true},
	{"id": "security", "label": "Door/security system", "need": 3, "essential": true},
	{"id": "aux", "label": "Auxiliary equipment", "need": 2, "essential": false},
]

const CLUES := {
	"log_verify": {"title": "MAINTENANCE LOG 07-14", "text": "Ran credential validation from the checkpoint bench. VERIFY-01 returned VERIFIED for access token #A-113. Cleared and filed."},
	"log_relay": {"title": "MAINTENANCE LOG 07-14 (cont.)", "text": "RELAY-09 forwarded a REJECTED status for the same token. Door controllers are wired to ignore relay results — that unit has been forwarding garbage since the surge."},
	"log_route": {"title": "NETWORK NOTE", "text": "Door control accepts authentication ONLY from VERIFY-01. Any route that passes RELAY-09 is dead on arrival. Gateway is the only entry point."},
	"log_order1": {"title": "SECURITY SOP 4.1", "text": "Standard recovery order: (1) check maintenance authorization, (2) verify the emergency recovery request, (3) release access. Never verify a recovery request before authorization is confirmed."},
	"log_order2": {"title": "INCIDENT 04:12", "text": "Recovery request was verified while maintenance authorization was still pending. The system flagged the sequence and hard-locked the procedure."},
	"log_power": {"title": "GENERATOR SPEC", "text": "Generator output: 9 units. Essential loads — emergency lighting 2, central controller 4, door/security 3."},
	"log_aux": {"title": "POWER ADVISORY", "text": "Auxiliary equipment draws 2 units and is non-essential. Keep it de-energized until the controller is stable."},
}

var trace_solved := false
var override_solved := false
var grid_solved := false
var power_on := false
var finished := false
var paused := false
var clue_ids: Array[String] = []
var elapsed := 0.0
var _settings := {"sens": 1.0, "volume": 0.8}
var _page := ""
var _ui_failed := false
var _terminal_app := ""
var _last_interact_msec := 0

var ui := GodotWebUI.new()
var _last_state := {}

@onready var player: ADPlayer = $Player
@onready var camera: Camera3D = $Player/Camera3D
@onready var door_a: ADDoor = $Facility/Doors/DoorA
@onready var door_b: ADDoor = $Facility/Doors/DoorB
@onready var door_c: ADDoor = $Facility/Doors/DoorC
@onready var door_d: ADDoor = $Facility/Doors/DoorD
@onready var room_lights := $Facility/Lights


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(ui)
	ui.error.connect(func(code: String, text: String) -> void: printerr("WebUI error ", code, ": ", text))
	ui.page_ready.connect(_page_ready)
	_apply_settings()
	sfx_bank = SfxBank.new()
	add_child(sfx_bank)
	sfx_bank.enabled = true
	_show_page("menu.html", GodotWebUI.TouchMode.MODAL)
	_push_all()


# ---------------------------------------------------------------- overlay lifecycle

func _show_page(page: String, mode: GodotWebUI.TouchMode) -> void:
	ui.clear_handlers()
	_wire_common()
	_wire_page(page)
	ui.set_touch_mode(mode)
	player.set_frozen(page != "hud.html")
	if not ui.is_started() and not _ui_failed:
		_ui_failed = not ui.start(UI_DIR, page)
		_page = page
	elif page != _page:
		_page = page
		ui.load_page(page)
	elif ui.is_ready:
		_page_ready()


func _wire_common() -> void:
	ui.on("settings_changed", _on_settings_changed)
	ui.on("pause_toggle", func(_p: Dictionary) -> void: _set_paused(not paused))
	ui.on("restart", func(_p: Dictionary) -> void: get_tree().reload_current_scene())
	ui.on("to_menu", func(_p: Dictionary) -> void: _to_menu())
	ui.on("look", _on_look)
	ui.on("move", _on_move)


func _wire_page(page: String) -> void:
	match page:
		"menu.html":
			ui.on("menu_start", func(_p: Dictionary) -> void: _show_page("hud.html", GodotWebUI.TouchMode.REGIONS))
			ui.on("menu_quit", func(_p: Dictionary) -> void: get_tree().quit())
		"hud.html":
			ui.on("interact", func(_p: Dictionary) -> void: _interact())
		"terminal.html":
			ui.on("terminal_close", func(_p: Dictionary) -> void: _close_terminal())
			ui.on("trace_submit", _on_trace_submit)
			ui.on("override_submit", _on_override_submit)
			ui.on("grid_apply", _on_grid_apply)
		"complete.html":
			ui.on("replay", func(_p: Dictionary) -> void: get_tree().reload_current_scene())
	# player signals (always live, but only act in HUD)
	if not player.interact_pressed.is_connected(_on_player_interact):
		player.interact_pressed.connect(_on_player_interact)
	if not player.pause_pressed.is_connected(_on_player_pause):
		player.pause_pressed.connect(_on_player_pause)


func _on_player_interact() -> void:
	if _page == "hud.html" and not paused:
		_interact()


func _on_player_pause() -> void:
	if _page == "hud.html":
		_set_paused(not paused)


func _page_ready() -> void:
	_last_state = {}
	_push_all()
	if _page == "terminal.html" and _terminal_app != "":
		ui.emit_event("terminal_open", {"app": _terminal_app})


func _to_menu() -> void:
	get_tree().paused = false
	_terminal_app = ""
	_show_page("menu.html", GodotWebUI.TouchMode.MODAL)


func _set_paused(value: bool) -> void:
	if finished:
		return
	paused = value
	get_tree().paused = value
	player.set_frozen(value or _page != "hud.html")
	_push_player()


# ---------------------------------------------------------------- input routing

func _on_move(p: Dictionary) -> void:
	var x: Variant = p.get("x")
	var z: Variant = p.get("z")
	if typeof(x) in [TYPE_FLOAT, TYPE_INT] and typeof(z) in [TYPE_FLOAT, TYPE_INT]:
		player.move_vec = Vector2(clampf(float(x), -1, 1), clampf(float(z), -1, 1))


func _on_look(p: Dictionary) -> void:
	if _page == "hud.html" and not paused:
		var dx: Variant = p.get("dx")
		var dy: Variant = p.get("dy")
		if typeof(dx) in [TYPE_FLOAT, TYPE_INT] and typeof(dy) in [TYPE_FLOAT, TYPE_INT]:
			player.look_delta += Vector2(float(dx), float(dy))


func _interact() -> void:
	if finished or paused or _page != "hud.html":
		return
	var now := Time.get_ticks_msec()
	if now - _last_interact_msec < 250:
		return  # the page may forward a key the controller also saw directly
	_last_interact_msec = now
	var target := player.ray_target()
	if target == null:
		return
	var kind: String = target.get_meta("kind")
	var id: String = target.get_meta("id", "")
	match kind:
		"door":
			var door := target as ADDoor
			if door.unlocked:
				door.open()
		"terminal":
			_open_terminal(id)
		"breaker":
			_use_breaker(id)
		"note":
			_read_note(id)
		"console":
			_final_console()


# ---------------------------------------------------------------- world interactions

@onready var _terminals := {
	"trace": $Facility/Props/TerminalTrace,
	"override": $Facility/Props/TerminalOverride,
	"grid": $Facility/Props/TerminalGrid,
	"final": $Facility/Props/ConsoleFinal,
}


func _use_breaker(id: String) -> void:
	door_a.unlocked = true
	door_a.open()
	app_sfx("gate", 0.8, -6.0)
	_add_clue("breaker")
	_toast("Checkpoint breaker released — the maintenance office door is open.")
	_push_world()


func _open_terminal(id: String) -> void:
	_terminal_app = id
	_set_paused(false)
	player.set_frozen(true)
	_show_page("terminal.html", GodotWebUI.TouchMode.MODAL)


func _close_terminal() -> void:
	_terminal_app = ""
	_show_page("hud.html", GodotWebUI.TouchMode.REGIONS)


func _read_note(id: String) -> void:
	_add_clue(id)
	var clue: Dictionary = CLUES[id]
	_toast(clue.title)
	# Notes glow cyan once read.
	for child in $Facility/Props.get_children():
		if child is ADInteractable and child.id == id:
			child.set_active(true)
	_push_journal()


func _add_clue(id: String) -> void:
	if not CLUES.has(id) or id in clue_ids:
		return
	clue_ids.append(id)
	ui.emit_event("journal_added", {"id": id, "title": CLUES[id].title})


func _final_console() -> void:
	if finished:
		return
	finished = true
	player.set_frozen(true)
	ui.emit_event("victory", {})
	ui.set_state("run", {"elapsed": snappedf(elapsed, 0.1), "clues": clue_ids.size()})
	# Let the reveal breathe, then show the completion page.
	await get_tree().create_timer(1.4, true, false, true).timeout
	_show_page("complete.html", GodotWebUI.TouchMode.MODAL)
	_push_all()


# ---------------------------------------------------------------- puzzle validation (server side)

func _on_trace_submit(p: Dictionary) -> void:
	if trace_solved:
		_puzzle_result(true, "Route already active.", "trace")
		return
	var path: Array = p.get("path", [])
	var ok := false
	var msg := ""
	for node_id in path:
		if not typeof(node_id) == TYPE_STRING:
			msg = "Malformed route."
			break
	var valid := true
	var names := {}
	for node in TRACE_NODES:
		names[node.id] = node.label
	if path != TRACE_PATH:
		valid = false
		var relayed := path.has("RELAY_09")
		var has_verify := path.has("VERIFY_01")
		if path.is_empty() or path[0] != "ACCESS_REQUEST":
			msg = "Route must start at ACCESS REQUEST."
		elif path.back() != "DOOR_CONTROL":
			msg = "Route must end at DOOR CONTROL."
		elif relayed:
			msg = "RELAY-09 forwarded a REJECTED status. Remove it from the route."
		elif not has_verify:
			msg = "DOOR CONTROL requires a VERIFIED result from VERIFY-01. Include VERIFY-01."
		elif not path.has("GATEWAY"):
			msg = "ACCESS REQUEST reaches the network through GATEWAY."
		elif path.size() > TRACE_PATH.size():
			msg = "Route contains redundant hops. Keep it minimal."
		else:
			msg = "Nodes are out of order. GATEWAY → VERIFY-01 → DOOR CONTROL."
	if valid:
		ok = true
		trace_solved = true
		door_b.unlocked = true
		(_terminals.trace as ADInteractable).set_active(true)
		msg = "ROUTE ACCEPTED — VERIFY-01 → DOOR CONTROL. Checkpoint authentication restored."
		app_sfx("gate")
		_toast("Checkpoint authentication restored.")
		_push_world()
	_puzzle_result(ok, msg, "trace")


func _on_override_submit(p: Dictionary) -> void:
	if override_solved:
		_puzzle_result(true, "Procedure already approved.", "override")
		return
	var order: Array = p.get("order", [])
	var ok := false
	var msg := ""
	if order == OVERRIDE_CORRECT:
		ok = true
		override_solved = true
		door_c.unlocked = true
		(_terminals.override as ADInteractable).set_active(true)
		msg = "PROCEDURE APPROVED — power room barrier released."
		app_sfx("gate")
		_toast("Security barrier released.")
		_push_world()
	else:
		# Explain the first violated dependency.
		if order.is_empty():
			msg = "Arrange all three stages before validating."
		else:
			for i in order.size():
				var stage: String = order[i]
				var expected: String = OVERRIDE_CORRECT[i]
				if stage == expected:
					continue
				if stage == "release_access":
					msg = "STAGE %d REJECTED — access can only be released after recovery is verified." % (i + 1)
				elif stage == "verify_recovery" and not order.has("check_auth") or (stage == "verify_recovery" and order.find("check_auth") > i):
					msg = "STAGE %d REJECTED — verify recovery only AFTER maintenance authorization is confirmed." % (i + 1)
				elif stage == "check_auth" and i > 0:
					msg = "STAGE %d REJECTED — authorization check comes FIRST." % (i + 1)
				else:
					msg = "STAGE %d REJECTED — check the SOP in this room." % (i + 1)
				break
			if msg == "":
				msg = "Sequence incomplete — arrange all three stages."
	_puzzle_result(ok, msg, "override")


func _on_grid_apply(p: Dictionary) -> void:
	if grid_solved:
		_puzzle_result(true, "Essential power is online.", "grid")
		return
	var alloc: Dictionary = p.get("alloc", {})
	var used := 0
	var clean := {}
	for system in GRID_SYSTEMS:
		var v: Variant = alloc.get(system.id, 0)
		if typeof(v) not in [TYPE_FLOAT, TYPE_INT] or float(v) < 0 or float(v) > system.need:
			_puzzle_result(false, "Invalid allocation for %s." % system.label, "grid")
			return
		clean[system.id] = int(v)
		used += int(v)
	if used > GRID_CAPACITY:
		_puzzle_result(false, "ALLOC REJECTED — %d units requested, generator provides %d." % [used, GRID_CAPACITY], "grid")
		return
	var problems: Array[String] = []
	for system in GRID_SYSTEMS:
		var have: int = clean[system.id]
		if system.essential and have < system.need:
			problems.append("%s needs %d (has %d)" % [system.label, system.need, have])
	if clean["aux"] > 0:
		problems.append("Auxiliary equipment must remain offline while the controller stabilizes.")
	if not problems.is_empty():
		_puzzle_result(false, "; ".join(problems), "grid")
		return
	grid_solved = true
	power_on = true
	door_d.unlocked = true
	(_terminals.grid as ADInteractable).set_active(true)
	_power_up()
	app_sfx("gate")
	_toast("Essential power restored — central control unlocked.")
	_puzzle_result(true, "POWER ONLINE — 9/9 units to essential systems.", "grid")
	_push_world()


func _power_up() -> void:
	for light in room_lights.get_children():
		if light is Light3D:
			(light as Light3D).light_energy = 1.6


func _puzzle_result(ok: bool, msg: String, app: String) -> void:
	ui.emit_event("puzzle_result", {"ok": ok, "msg": msg, "app": app})
	if ok:
		_push_all()


# ---------------------------------------------------------------- journal / toast / sfx

func _toast(text: String) -> void:
	ui.emit_event("toast", {"text": text})


var sfx_bank: SfxBank


func app_sfx(sound: String, pitch := 1.0, volume_db := 0.0) -> void:
	if sfx_bank:
		sfx_bank.play(sound, pitch, volume_db)


# ---------------------------------------------------------------- settings

func _on_settings_changed(p: Dictionary) -> void:
	if typeof(p.get("sens")) in [TYPE_FLOAT, TYPE_INT]:
		_settings.sens = clampf(float(p.sens), 0.3, 3.0)
		player.sens = _settings.sens
	if typeof(p.get("volume")) in [TYPE_FLOAT, TYPE_INT]:
		_settings.volume = clampf(float(p.volume), 0.0, 1.0)
		_apply_settings()
	_push_settings()


func _apply_settings() -> void:
	var bus := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(_settings.volume, 0.0001)))
	AudioServer.set_bus_mute(bus, _settings.volume <= 0.001)


# ---------------------------------------------------------------- state pushes

func _push_all() -> void:
	_push_settings()
	_push_world()
	ui.set_state("run", {"elapsed": snappedf(elapsed, 0.1), "clues": clue_ids.size()})
	_push_player()
	_push_journal()
	_push_puzzles()


func _push_settings() -> void:
	ui.set_state("settings", _settings)


func _push_world() -> void:
	var objective := "Find a way past the checkpoint."
	if not trace_solved:
		objective = "Restore checkpoint authentication (TRACE)."
	elif not override_solved:
		objective = "Fix the recovery procedure (OVERRIDE)."
	elif not grid_solved:
		objective = "Restore essential power (GRID)."
	elif not finished:
		objective = "Access the central console."
	var state := {
		"trace_solved": trace_solved, "override_solved": override_solved,
		"grid_solved": grid_solved, "power_on": power_on,
		"door_a": door_a.unlocked, "door_b": door_b.unlocked,
		"door_c": door_c.unlocked, "door_d": door_d.unlocked,
		"objective": objective,
		"clues": clue_ids.size(),
	}
	if state != _last_state.get("world"):
		_last_state["world"] = state
		ui.set_state("world", state)


func _push_player() -> void:
	var prompt := ""
	if not paused and not finished and _page == "hud.html":
		var target := player.ray_target()
		prompt = target.prompt_text() if target is ADInteractable or target is ADDoor else ""
	player.prompt = prompt
	var state := {"prompt": prompt, "paused": paused, "finished": finished, "clues": clue_ids.size()}
	if state != _last_state.get("player"):
		_last_state["player"] = state
		ui.set_state("player", state)


func _push_journal() -> void:
	var entries := []
	for id in clue_ids:
		if CLUES.has(id):
			entries.append({"id": id, "title": CLUES[id].title, "text": CLUES[id].text})
	ui.set_state("journal", {"entries": entries})


func _push_puzzles() -> void:
	ui.set_state("trace", {
		"nodes": TRACE_NODES, "links": TRACE_LINKS, "solved": trace_solved,
		"start": "ACCESS_REQUEST", "end": "DOOR_CONTROL",
	})
	ui.set_state("override", {"stages": OVERRIDE_STAGES, "solved": override_solved,
		"order": [OVERRIDE_STAGES[1].id, OVERRIDE_STAGES[0].id, OVERRIDE_STAGES[2].id]})
	ui.set_state("grid", {"systems": GRID_SYSTEMS, "capacity": GRID_CAPACITY, "solved": grid_solved,
		"alloc": {"lighting": 0, "controller": 0, "security": 0, "aux": 0}})
	# Records app: all known logs, locked ones shown as placeholders until discovered.
	var records := []
	for id in CLUES:
		records.append({"id": id, "title": CLUES[id].title, "text": CLUES[id].text,
			"found": id in clue_ids})
	ui.set_state("records", {"entries": records})


# ---------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	if not paused and not finished and _page == "hud.html":
		elapsed += delta
	# Prompt + world refresh only while exploring (cheap; pushes on change only).
	if _page == "hud.html":
		_push_player()


func _exit_tree() -> void:
	Engine.time_scale = 1.0
	get_tree().paused = false
