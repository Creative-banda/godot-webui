extends Node2D
## Game scene: wires the HTML HUD (ui/hud.html) to the physics player. All gameplay state lives here
## and in player.gd; the page only sends input events and renders the state it is given.

@onready var player: DemoPlayer = $Player

var app: DemoApp
var _last_state := {}


func _ready() -> void:
	player.gravity_scale = DemoApp.LEVELS[app.level].gravity
	player.damage_scale = app.damage_scale()
	player.died.connect(app.record.bind("deaths"))
	player.jumped.connect(app.record.bind("jumps"))
	player.health_changed.connect(_push_state)
	$Hazard.body_entered.connect(func(body: Node) -> void:
		if body == player:
			player.damage(20)
			player.velocity.y = DemoPlayer.JUMP_VELOCITY * 0.6)

	app.show_page("hud.html", GodotWebUI.TouchMode.REGIONS, _on_page_ready)
	var ui := app.ui
	ui.on("move_changed", _on_move_changed)
	ui.on("jump", func(_p: Dictionary) -> void: player.request_jump())
	ui.on("attack_pressed", func(_p: Dictionary) -> void: player.attacking = true)
	ui.on("attack_released", func(_p: Dictionary) -> void: player.attacking = false)
	ui.on("damage_self", func(_p: Dictionary) -> void: player.damage(10))
	ui.on("pause_toggle", func(_p: Dictionary) -> void: _set_paused(not get_tree().paused))
	ui.on("back_to_menu", func(_p: Dictionary) -> void: app.show_menu())


func _exit_tree() -> void:
	get_tree().paused = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		player.clear_input()  # app backgrounded: never leave input held


func _physics_process(_delta: float) -> void:
	_push_state()  # only sends when something changed


func _on_page_ready() -> void:
	_last_state = {}
	_push_state()


func _set_paused(value: bool) -> void:
	get_tree().paused = value
	player.clear_input()
	_push_state()


func _on_move_changed(payload: Dictionary) -> void:
	var x: Variant = payload.get("x")
	var y: Variant = payload.get("y")
	if typeof(x) not in [TYPE_FLOAT, TYPE_INT] or typeof(y) not in [TYPE_FLOAT, TYPE_INT]:
		printerr("move_changed needs numeric x and y, got ", payload)
		return
	player.move_input = Vector2(clampf(x, -1.0, 1.0), clampf(y, -1.0, 1.0))


func _push_state() -> void:
	var state := {
		"health": player.health,
		"max_health": DemoPlayer.MAX_HEALTH,
		"dead": player.dead,
		"attacking": player.attacking,
		"on_floor": player.is_on_floor(),
		"x": roundi(player.position.x),
		"y": roundi(player.position.y),
		"vx": roundi(player.velocity.x),
		"vy": roundi(player.velocity.y),
		"paused": get_tree().paused,
		"level": app.level,
		"level_name": DemoApp.LEVELS[app.level].name,
		"difficulty": app.settings.difficulty,
	}
	if state != _last_state:
		_last_state = state
		app.ui.send("state", state)
