@tool
class_name WebUIScreenInspectorBlock
extends VBoxContainer
## The controls at the top of a WebUIScreen's Inspector: its status and the Edit UI / Refresh Preview
## buttons. A node of its own (not a bundle of lambdas) so that the connection to the node's
## status_changed signal ends with it: the Inspector rebuilds its controls whenever the selection changes,
## and a lambda left connected to a freed control raises "Lambda capture ... was freed".

const OK_COLOR := Color(0.55, 0.9, 0.6)
const WARN_COLOR := Color(1.0, 0.75, 0.35)
const BAD_COLOR := Color(1.0, 0.5, 0.45)
const INFO_COLOR := Color(0.85, 0.85, 0.85)
const STATE_COLORS := {"fresh": OK_COLOR, "manual": OK_COLOR, "stale": WARN_COLOR, "failed": BAD_COLOR, "invalid": BAD_COLOR, "no_page": WARN_COLOR}

var _screen: WebUIScreen
var _open_page := Callable()
var _status: Label
var _notes: Label
var _edit: Button
var _refresh: Button
var _feedback: Label


## `open_page` is called with the node's page path and returns "" when the dock opened it, or why it could not.
func setup(screen: WebUIScreen, open_page: Callable) -> void:
	_screen = screen
	_open_page = open_page
	add_theme_constant_override("separation", 6)

	var title := Label.new()
	title.text = "WebUI screen"
	title.add_theme_font_size_override("font_size", 15)
	add_child(title)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	_notes = Label.new()
	_notes.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notes.add_theme_font_size_override("font_size", 12)
	_notes.modulate = Color(1, 1, 1, 0.65)
	add_child(_notes)

	var row := HBoxContainer.new()
	_edit = Button.new()
	_edit.text = "Edit UI"
	_edit.tooltip_text = "Open this page in the WebUI visual editor dock."
	_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit.pressed.connect(_on_edit_pressed)
	row.add_child(_edit)
	_refresh = Button.new()
	_refresh.text = "Refresh Preview"
	_refresh.tooltip_text = "Make a new picture of the page (a separate program renders it; the game is not started)."
	_refresh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_refresh.pressed.connect(_on_refresh_pressed)
	row.add_child(_refresh)
	add_child(row)

	_feedback = Label.new()
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feedback.modulate = WARN_COLOR
	_feedback.visible = false
	add_child(_feedback)

	_screen.status_changed.connect(_update)  # a method of this node: the connection goes when the node does
	_update()


func _exit_tree() -> void:
	if is_instance_valid(_screen) and _screen.status_changed.is_connected(_update):
		_screen.status_changed.disconnect(_update)


func _update() -> void:
	if not is_instance_valid(_screen):
		return
	var info := _screen.get_status()
	_status.text = str(info.text)
	_status.modulate = STATE_COLORS.get(info.state, INFO_COLOR)
	var note_lines: Array = info.notes
	_notes.text = "Not shown exactly: " + "; ".join(note_lines) if not note_lines.is_empty() else ""
	_notes.visible = not note_lines.is_empty()
	var has_page: bool = _screen.page.strip_edges() != "" and info.state != "invalid"
	_edit.disabled = not has_page
	_refresh.disabled = not has_page or info.state == "capturing"


func _on_edit_pressed() -> void:
	var message: String = _open_page.call(_screen.page) if _open_page.is_valid() else "The WebUI editor is not available."
	_feedback.text = message
	_feedback.visible = message != ""


func _on_refresh_pressed() -> void:
	_feedback.visible = false
	_screen.refresh_preview()
