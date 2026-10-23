class_name DemoApp
extends Node
## Demo shell (main.tscn). Owns the single GodotWebUI overlay for the whole run, swaps Godot scenes
## (menu / game) and navigates the overlay between HTML pages. Settings and stats are authoritative
## here; the pages only display them and send change requests.

const UI_DIR := "res://examples/playable_character/ui"
const MENU_SCENE := "res://examples/playable_character/menu.tscn"
const GAME_SCENE := "res://examples/playable_character/game.tscn"
const SAVE_PATH := "user://demo_save.cfg"
const DIFFICULTIES := ["easy", "normal", "hard"]
const LEVELS := {
	1: {"name": "Training Yard", "gravity": 1.0},
	2: {"name": "Moon Ledge", "gravity": 0.6},
}

var ui := GodotWebUI.new()
var settings := {"music": 0.7, "sfx": true, "difficulty": "normal", "show_debug": true}
var stats := {"plays": 0, "deaths": 0, "jumps": 0}
var level := 1

var _scene: Node
var _page := ""
var _ui_failed := false
var _on_page_ready := Callable()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # keep serving the UI while the game is paused
	add_child(ui)
	ui.error.connect(func(code: String, text: String) -> void: printerr("WebUI error ", code, ": ", text))
	ui.page_ready.connect(_page_ready)
	_load_save()
	_apply_settings()
	show_menu()


func show_menu() -> void:
	get_tree().paused = false
	_swap_scene(MENU_SCENE)


func start_game(new_level: int) -> void:
	if not LEVELS.has(new_level):
		printerr("Unknown level ", new_level)
		return
	level = new_level
	stats.plays += 1
	_save()
	get_tree().paused = false
	_swap_scene(GAME_SCENE)


## Called by scenes: points the overlay at `page`, resets page handlers to the common ones and
## runs `on_ready` each time the page is ready (immediately if it already is).
func show_page(page: String, touch_mode: GodotWebUI.TouchMode, on_ready: Callable) -> void:
	ui.clear_handlers()
	ui.on("settings_changed", change_settings)
	_on_page_ready = on_ready
	ui.set_touch_mode(touch_mode)
	if not ui.is_started() and not _ui_failed:
		_ui_failed = not ui.start(UI_DIR, page)
		_page = page
	elif page != _page:
		_page = page
		ui.load_page(page)
	elif ui.is_ready:
		_page_ready()


func change_settings(p: Dictionary) -> void:
	if typeof(p.get("music")) in [TYPE_FLOAT, TYPE_INT]:
		settings.music = clampf(p.music, 0.0, 1.0)
	if typeof(p.get("sfx")) == TYPE_BOOL:
		settings.sfx = p.sfx
	if typeof(p.get("difficulty")) == TYPE_STRING and p.difficulty in DIFFICULTIES:
		settings.difficulty = p.difficulty
	if typeof(p.get("show_debug")) == TYPE_BOOL:
		settings.show_debug = p.show_debug
	_apply_settings()
	_save()
	ui.set_state("settings", settings)


func damage_scale() -> float:
	return {"easy": 0.5, "normal": 1.0, "hard": 2.0}[settings.difficulty]


func record(stat: String) -> void:
	stats[stat] += 1
	_save()


func _page_ready() -> void:
	ui.set_state("settings", settings)
	ui.set_state("stats", stats)
	ui.set_state("info", {
		"engine": Engine.get_version_info().string,
		"os": OS.get_name(),
		"renderer": str(ProjectSettings.get_setting("rendering/renderer/rendering_method")),
		"level": level,
	})
	if _on_page_ready.is_valid():
		_on_page_ready.call()


func _swap_scene(path: String) -> void:
	if _scene:
		_scene.queue_free()
		_scene = null
	_scene = load(path).instantiate()
	_scene.set("app", self)
	add_child(_scene)


func _apply_settings() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(settings.music, 0.0001)))


func _load_save() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	# Go through the same validation as page requests.
	change_settings(cfg.get_value("settings", "values", {}))
	var saved: Variant = cfg.get_value("stats", "values", {})
	if typeof(saved) == TYPE_DICTIONARY:
		for key in stats:
			if typeof(saved.get(key)) == TYPE_INT:
				stats[key] = saved[key]


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "values", settings)
	cfg.set_value("stats", "values", stats)
	cfg.save(SAVE_PATH)
