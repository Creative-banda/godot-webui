@tool
extends EditorPlugin

const EXPORT_PLUGIN := preload("res://addons/webui/export_plugin.gd")

var _export_plugin: EditorExportPlugin
var _link: WebUIEditLink
var _dock: WebUIEditorDock
var _screen_inspector: WebUIScreenInspector


func _enter_tree() -> void:
	_register_setting(WebUIExportScan.SETTING_UI_FOLDERS, PackedStringArray())
	_export_plugin = EXPORT_PLUGIN.new()
	add_export_plugin(_export_plugin)

	# Visual editor: a dock for editing a page's CSS, and the link to the preview window it runs.
	_link = WebUIEditLink.new()
	add_child(_link)
	_dock = WebUIEditorDock.new()
	_dock.setup(WebUIEditorModel.new(), _link, _open_preview)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)

	# WebUIScreen nodes: their Inspector block can open a page in the dock.
	_screen_inspector = WebUIScreenInspector.new()
	_screen_inspector.open_page = func(page: String) -> String: return _dock.open_page(page) if _dock else "The WebUI editor is not available."
	add_inspector_plugin(_screen_inspector)


func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null
	if _screen_inspector:
		remove_inspector_plugin(_screen_inspector)
		_screen_inspector = null
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	if _link:
		_link.stop()
		_link.queue_free()
		_link = null


## (Re)starts the preview window.
func _open_preview() -> bool:
	return _link.launch()


func _register_setting(setting: String, default: Variant) -> void:
	if not ProjectSettings.has_setting(setting):
		ProjectSettings.set_setting(setting, default)
	ProjectSettings.set_initial_value(setting, default)
	ProjectSettings.add_property_info({"name": setting, "type": typeof(default)})
