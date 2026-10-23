extends SceneTree
## Run: godot --headless --path . -s res://tests/editor_dock_test.gd
## Builds the visual editor dock without the editor and drives it through the model: the controls
## exist, follow a selection, and a change in a control reaches the model. Exit code = failures.

var failures := 0
var sent: Array = []


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	await process_frame
	var model := WebUIEditorModel.new()
	var dock := WebUIEditorDock.new()
	root.add_child(dock)
	dock.setup(model, null, Callable())
	model.send = func(op: String, payload: Dictionary) -> void: sent.append([op, payload])
	check(dock._pages.size() > 0, "pages are discovered from the project's UI folders (%d)" % dock._pages.size())
	check(dock._rows.size() == WebUIEditorModel.PROPERTIES.size(), "one row per editable property")
	check(dock._save_button.disabled and dock._undo_button.disabled, "Save and Undo start disabled")
	check(not (dock._rows["color"].edit as LineEdit).editable, "rows are read-only without a selection")

	model.ui_dir = "res://examples/playable_character/ui"
	model.page = "menu.html"
	model.on_page_message({
		"op": "selected", "selector": "#btn-play", "tag": "button", "id": "btn-play", "classes": ["hero"], "text": "Play",
		"computed": {"color": "rgb(5, 38, 26)", "font-size": "16px", "display": "flex", "background-color": "rgb(62, 230, 160)"},
		"rules": [{"file": "menu.css", "inline": false, "path": [40.0], "selector": ".hero", "conditions": [], "declared": {"color": {"value": "#05261a", "important": false}, "display": {"value": "flex", "important": false}}}],
		"targets": {"color": 0, "display": 0}, "fallback": 0,
	})
	check(dock._selection_label.text.begins_with("button#btn-play.hero"), "the selection is shown: %s" % dock._selection_label.text)
	check((dock._rows["color"].edit as LineEdit).editable and (dock._rows["color"].edit as LineEdit).text == "#05261a", "a declared value is shown as authored")
	check((dock._rows["font-size"].edit as LineEdit).text == "16px", "an undeclared value shows the computed one")
	var picker: ColorPickerButton = dock._rows["color"].picker
	check(is_equal_approx(picker.color.r, 5.0 / 255.0) and is_equal_approx(picker.color.g, 38.0 / 255.0), "the colour swatch follows the value")
	check((dock._rows["display"].edit as OptionButton).get_item_text((dock._rows["display"].edit as OptionButton).selected) == "flex", "enum rows select the current value")
	check(WebUIEditorDock._to_color("var(--mint)", "rgb(62, 230, 160)").is_equal_approx(Color8(62, 230, 160)), "a var() value falls back to the computed colour")
	check(WebUIEditorDock._to_color("rgba(0, 0, 0, 0.5)", "").a == 0.5, "rgba() alpha is parsed")

	sent.clear()
	var edit: LineEdit = dock._rows["font-size"].edit
	edit.text = "20px"
	edit.text_submitted.emit("20px")
	check(model.pending.size() == 1 and sent[-1][1].prop == "font-size" and sent[-1][1].value == "20px", "typing a value sends it to the preview")
	check(not dock._save_button.disabled and dock._save_button.text == "Save (1)", "Save shows the number of unsaved changes")

	var option: OptionButton = dock._rows["display"].edit
	option.select(2)  # grid
	option.item_selected.emit(2)
	check(model.pending.size() == 2 and sent[-1][1].value == "grid", "choosing an option sends it")
	picker.color = Color8(255, 0, 0)
	picker.color_changed.emit(picker.color)
	check(sent[-1][1].prop == "color" and sent[-1][1].value == "#ff0000", "picking a colour sends a hex value")

	dock._undo_button.pressed.emit()
	check(model.pending.size() == 2, "Undo takes back the last change (%d left)" % model.pending.size())
	check(dock._status_label.text == model.status, "the status line mirrors the model")
	quit(failures)
