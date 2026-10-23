class_name WebUIBackend
extends RefCounted
## Platform interface behind WebUI. Android is the only real implementation;
## a future iOS backend only has to implement this same surface.

signal message(raw: String)                 ## raw JSON from the page (validated by WebUIBridge)
signal error(code: String, text: String)
signal page_loaded(url: String)
signal console(level: String, text: String)

## Backend-specific settings, filled by GodotWebUI before create().
var options := {}


func is_available() -> bool:
	return false


## "android", "desktop_preview" or "none".
func get_backend_name() -> String:
	return "none"


## ui_dir is a res:// directory; script is the bridge client JavaScript; host is the node that owns
## the backend (must be in the scene tree) for backends that need to add nodes.
func create(_ui_dir: String, _bridge_script: String, _host: Node = null) -> bool:
	return false


func load_page(_relative_path: String) -> void:
	pass


func send_message(_event_name: String, _json_payload: String) -> void:
	pass


func set_visible(_visible: bool) -> void:
	pass


func set_touch_mode(_mode: String) -> void:
	pass


func destroy() -> void:
	pass
