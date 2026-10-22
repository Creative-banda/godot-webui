class_name WebUIBackendNull
extends WebUIBackend
## Used where no native WebView exists (editor, desktop). Reports an error and does nothing else.


func create(_ui_dir: String, _bridge_script: String) -> bool:
	error.emit("unsupported_platform", "WebUI has no backend on '%s'; only Android is implemented." % OS.get_name())
	return false
