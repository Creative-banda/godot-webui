class_name WebUIBackendNull
extends WebUIBackend
## Used where no overlay backend exists. Reports an error and does nothing else.


func create(_ui_dir: String, _bridge_script: String, _host: Node = null) -> bool:
	if OS.has_feature("editor"):
		error.emit("unsupported_platform", "WebUI has no backend on '%s'." % OS.get_name())
	else:
		error.emit("unsupported_platform", "WebUI has no backend on '%s'. Only Android is supported; the desktop preview only runs from the Godot editor." % OS.get_name())
	return false
