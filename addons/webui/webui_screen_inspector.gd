@tool
class_name WebUIScreenInspector
extends EditorInspectorPlugin
## Adds the Edit UI / Refresh Preview block (WebUIScreenInspectorBlock) to the Inspector of a WebUIScreen
## node. Editor-only.

## Called with the node's page path; returns "" when the dock opened it, or why it could not.
var open_page := Callable()


func _can_handle(object: Object) -> bool:
	return object is WebUIScreen


func _parse_begin(object: Object) -> void:
	var block := WebUIScreenInspectorBlock.new()
	block.setup(object as WebUIScreen, open_page)
	add_custom_control(block)
