class_name WebUIBackend
extends RefCounted
## Platform interface behind WebUI. Android is the only real implementation;
## a future iOS backend only has to implement this same surface.

signal message(raw: String)                 ## raw JSON from the page (validated by WebUIBridge)
signal error(code: String, text: String)
signal page_loaded(url: String)
signal console(level: String, text: String)
signal surface_message(surface_id: String, raw: String)  ## raw JSON from a world-space page
signal surface_frame(surface_id: String, frame: int)     ## a new frame of a world-space page is ready to read

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


## UI scale reference in CSS pixels (GodotWebUI.ui_reference_size); 0 turns scaling off. Backends that cannot scale ignore it.
func set_ui_scale_reference(_css_pixels: float) -> void:
	pass


## World-space pages (GodotWebUISurface): pages drawn into textures instead of covering the screen. Only Android has them.
func supports_surfaces() -> bool:
	return false


func create_surface(_surface_id: String, _page: String, _size: Vector2i, _fps: int) -> bool:
	return false


func destroy_surface(_surface_id: String) -> void:
	pass


func surface_send(_surface_id: String, _event_name: String, _json_payload: String) -> void:
	pass


func surface_tap(_surface_id: String, _x: float, _y: float) -> void:
	pass


func surface_set_active(_surface_id: String, _active: bool) -> void:
	pass


func surface_read_frame(_surface_id: String) -> PackedByteArray:
	return PackedByteArray()


func surface_stats(_surface_id: String) -> String:
	return "{}"


func destroy() -> void:
	pass
