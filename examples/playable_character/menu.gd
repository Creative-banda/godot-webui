extends Node2D
## Main menu: Godot draws an animated background; the HTML page (ui/menu.html) is the interface.

var app: DemoApp
var _t := 0.0


func _ready() -> void:
	app.show_page("menu.html", GodotWebUI.TouchMode.MODAL, Callable())
	app.ui.on("menu_play", _on_play)
	app.ui.on("menu_play_3d", func(_p: Dictionary) -> void: app.start_3d())
	app.ui.on("menu_quit", func(_p: Dictionary) -> void: get_tree().quit())


func _on_play(payload: Dictionary) -> void:
	var lvl: Variant = payload.get("level", app.level)
	if typeof(lvl) not in [TYPE_FLOAT, TYPE_INT] or not DemoApp.LEVELS.has(int(lvl)):
		printerr("menu_play: invalid level ", lvl)
		return
	app.start_game(int(lvl))


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	var size := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.09, 0.16))
	for i in 14:
		var phase := _t * 0.25 + i * 0.9
		var c := Vector2(fmod(i * 197.0 + _t * 20.0 * (1 + i % 3), size.x + 200.0) - 100.0, size.y * (0.5 + 0.4 * sin(phase)))
		draw_circle(c, 20.0 + 14.0 * (i % 4), Color.from_hsv(fmod(i * 0.09 + _t * 0.02, 1.0), 0.5, 0.9, 0.25))
