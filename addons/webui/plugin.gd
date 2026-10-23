@tool
extends EditorPlugin

const EXPORT_PLUGIN := preload("res://addons/webui/export_plugin.gd")

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_register_setting(WebUIExportScan.SETTING_UI_FOLDERS, PackedStringArray())
	_export_plugin = EXPORT_PLUGIN.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null


func _register_setting(setting: String, default: Variant) -> void:
	if not ProjectSettings.has_setting(setting):
		ProjectSettings.set_setting(setting, default)
	ProjectSettings.set_initial_value(setting, default)
	ProjectSettings.add_property_info({"name": setting, "type": typeof(default)})
