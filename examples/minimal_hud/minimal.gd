extends Node2D
## Smallest realistic WebUI flow. Run this scene (F6).
##
##   HTML button  --Godot.emit("attack")-->  on("attack") handler  --> Godot decides the damage
##   Godot state  --set_state("hud")------>  Godot.onState("hud")  --> the page renders it
##   Godot event  --emit_event("hit")----->  Godot.onEvent("hit")   --> the page plays an animation
##
## The page only sends intent and draws what it is told. Coins, damage and health live here.

const UI_DIR := "res://examples/minimal_hud/ui"
const DUMMY_MAX_HP := 100
const REPAIR_COST := 5
const KILL_REWARD := 10

var ui := GodotWebUI.new()
var coins := 0
var dummy_hp := DUMMY_MAX_HP


func _ready() -> void:
	add_child(ui)
	ui.error.connect(func(code: String, text: String) -> void: printerr("WebUI ", code, ": ", text))
	# Resend the full state after every page load (first load, reload, hot reload, recovery).
	ui.page_ready.connect(_push_state)
	ui.on("attack", _on_attack)
	ui.on("repair", _on_repair)
	ui.start(UI_DIR)  # needs the node in the tree; returns false and emits `error` on failure

	var income := Timer.new()  # state that changes without any UI input
	income.wait_time = 1.0
	income.autostart = true
	income.timeout.connect(func() -> void:
		coins += 1
		_push_state())
	add_child(income)


func _on_attack(payload: Dictionary) -> void:
	# Never trust the page: validate types, then let Godot decide the outcome.
	var heavy: Variant = payload.get("heavy", false)
	if typeof(heavy) != TYPE_BOOL:
		printerr("attack: 'heavy' must be a bool, got ", heavy)
		return
	var crit := randf() < 0.2
	var damage := (15 if heavy else 5) * (2 if crit else 1)
	dummy_hp = maxi(dummy_hp - damage, 0)
	ui.emit_event("hit", {"damage": damage, "crit": crit})  # one-shot: never replayed
	if dummy_hp == 0:
		coins += KILL_REWARD
		dummy_hp = DUMMY_MAX_HP
		ui.emit_event("toast", {"text": "Dummy defeated! +%d coins" % KILL_REWARD})
	_push_state()


func _on_repair(_payload: Dictionary) -> void:
	if coins < REPAIR_COST:
		ui.emit_event("toast", {"text": "Not enough coins (%d needed)" % REPAIR_COST})
		return
	coins -= REPAIR_COST
	dummy_hp = DUMMY_MAX_HP
	_push_state()


func _push_state() -> void:
	ui.set_state("hud", {"coins": coins, "dummy_hp": dummy_hp, "dummy_max": DUMMY_MAX_HP})  # persistent
	queue_redraw()


func _draw() -> void:
	# What Godot itself renders behind the transparent overlay.
	var size := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.1, 0.12, 0.18))
	var health := float(dummy_hp) / DUMMY_MAX_HP
	var body := Rect2(size / 2.0 - Vector2(40, 80), Vector2(80, 160))
	draw_rect(body, Color(0.9, 0.3, 0.3).lerp(Color(0.3, 0.8, 0.4), health))
	draw_string(ThemeDB.fallback_font, body.position + Vector2(-20, 190), "Training dummy: %d / %d" % [dummy_hp, DUMMY_MAX_HP], HORIZONTAL_ALIGNMENT_LEFT, -1, 20)
