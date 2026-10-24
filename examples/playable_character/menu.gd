extends Node2D
## Main menu: a still corner of the hollow composed in menu.tscn; the HTML page (ui/menu.html)
## is the interface. Wires the page's intents to the shell (play, 3D arena, benchmark, quit).

var app: DemoApp

## Desktop fallback: Enter begins the run when the game window (not the overlay) has the keyboard.
## The page reports which screen it shows ("menu_screen" event), so this only fires on the main
## screen; it is debounced because the page may forward the same key press through the bridge.
var _screen := "main"
var _last_begin := -10.0


func _ready() -> void:
	app.show_page("menu.html", GodotWebUI.TouchMode.MODAL, Callable())
	app.ui.on("menu_play", _on_play)
	app.ui.on("menu_screen", func(p: Dictionary) -> void:
		if typeof(p.get("name")) == TYPE_STRING and p.name in ["main", "settings", "about"]:
			_screen = p.name)
	app.ui.on("menu_play_3d", func(_p: Dictionary) -> void: app.start_3d())
	app.ui.on("menu_bench", func(_p: Dictionary) -> void: app.run_benchmark())
	app.ui.on("menu_quit", func(_p: Dictionary) -> void: get_tree().quit())


func _input(event: InputEvent) -> void:
	if OS.get_name() == "Android" or not event is InputEventKey:
		return
	if event.pressed and not event.echo and event.physical_keycode in [KEY_ENTER, KEY_KP_ENTER] \
			and _screen == "main":
		_begin()


func _begin() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_begin < 0.5:
		return
	_begin_from(1)


func _on_play(payload: Dictionary) -> void:
	var lvl: Variant = payload.get("level", 1)
	if typeof(lvl) not in [TYPE_FLOAT, TYPE_INT] or not DemoApp.LEVELS.has(int(lvl)):
		printerr("menu_play: invalid level ", lvl)
		return
	_begin_from(int(lvl))


func _begin_from(lvl: int) -> void:
	_last_begin = Time.get_ticks_msec() / 1000.0
	app.sfx("ui")
	app.start_game(lvl)
