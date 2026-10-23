class_name WebUIBackendFactory
extends RefCounted
## Chooses the platform backend. Android uses the native plugin; desktop gets the development
## preview only when running from the Godot editor; everything else gets the null backend.


static func create_backend() -> WebUIBackend:
	match OS.get_name():
		"Android":
			return WebUIBackendAndroid.new()
		"Windows", "macOS", "Linux":
			# No window (headless tests, servers): a native webview cannot be created.
			if OS.has_feature("editor") and DisplayServer.get_name() != "headless":
				return WebUIBackendDesktop.new()
	return WebUIBackendNull.new()
