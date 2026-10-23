extends SceneTree
## Run: godot --headless --path . -s res://tests/editor_dock_test.gd
## Builds the visual editor dock without the editor and drives it through the model: the inspector
## shows different sections and controls for different kinds of element, follows the values the model
## reports, and a change made in a control reaches the model. Exit code = failures.

var failures := 0
var sent: Array = []
const DIR := "user://editor_dock_test/ui"


func check(cond: bool, label: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + label)
	if not cond:
		failures += 1


func _initialize() -> void:
	await process_frame
	DirAccess.make_dir_recursive_absolute(DIR)
	WebUICssPatcher.write_file_atomic(DIR.path_join("s.css"), ".t { color: #05261a; font-size: 14px; margin: 0 4px; }\n.box { display: flex; gap: 8px; }\n.pic { width: 40px; }\n")
	WebUICssPatcher.write_file_atomic(DIR.path_join("p.html"), "<p id=\"t1\" class=\"t\">Hello</p>\n<div id=\"b1\" class=\"box\"></div>\n<img id=\"i1\" class=\"pic\" src=\"a.png\">\n")
	var model := WebUIEditorModel.new()
	var dock := WebUIEditorDock.new()
	root.add_child(dock)
	dock.setup(model, null, Callable())
	model.send = func(op: String, payload: Dictionary) -> void: sent.append([op, payload])
	model.open_page("user://editor_dock_test/ui", "p.html")
	check(dock._pages.size() > 0, "pages are discovered from the project's UI folders (%d)" % dock._pages.size())
	check(dock._rows.is_empty() and dock._save_button.disabled and dock._undo_button.disabled, "nothing is shown or enabled without a selection")

	# a text element
	model.on_page_message(_text())
	var text_keys := dock._rows.keys()
	check(dock._title_label.text == "p#t1.t" and dock._kind_label.text.begins_with("Text element"), "the header names the element and what kind it is: %s / %s" % [dock._title_label.text, dock._kind_label.text])
	check("font-size" in text_keys and "letter-spacing" in text_keys and "line-height" in text_keys and "content:text:#t1" in text_keys, "a text element shows typography and its text")
	check(not ("object-fit" in text_keys) and not ("flex-direction" in text_keys), "but no image or flex controls")
	check((dock._rows["content:text:#t1"].edit as LineEdit).text == "Hello" and (dock._rows["content:text:#t1"].edit as LineEdit).editable, "the text is editable")
	check((dock._rows["font-size"].edit as LineEdit).text == "14px" and (dock._rows["font-size"].edit as LineEdit).editable, "a declared value is shown as authored")
	var picker: ColorPickerButton = dock._rows["color"].picker
	check(is_equal_approx(picker.color.r, 5.0 / 255.0) and is_equal_approx(picker.color.g, 38.0 / 255.0), "the colour swatch follows the value")
	check(dock._rows["margin"].edits.size() == 4 and (dock._rows["margin"].edits[1] as LineEdit).text == "4px", "margin is one row with four sides")

	# a flex container
	model.on_page_message(_box())
	var box_keys := dock._rows.keys()
	check("flex-direction" in box_keys and "justify-content" in box_keys and "gap" in box_keys, "a flex container shows flex controls")
	check(not ("letter-spacing" in box_keys) or dock._collapsed.get("container:typography", false), "typography is not in the way for a container (collapsed)")
	check("content:text:#t1" not in box_keys, "a container has no text row")
	var display: OptionButton = dock._rows["display"].edit
	check(display.get_item_text(display.selected) == "flex", "enum rows select the current value")

	# an image
	model.on_page_message(_image())
	var image_keys := dock._rows.keys()
	check("object-fit" in image_keys and "aspect-ratio" in image_keys and "content:alt" in image_keys and "content:src" in image_keys, "an image shows fit, ratio and its attributes")
	check(not (dock._rows["content:src"].edit as LineEdit).editable and (dock._rows["content:alt"].edit as LineEdit).editable, "the source is read-only, the alt text editable")
	check(not ("font-size" in image_keys) and not ("flex-direction" in image_keys), "and no typography or flex controls")
	check(dock._rows["content:src"].note.visible and dock._rows["content:src"].note.text != "", "a read-only row says why")

	# editing through the controls
	model.on_page_message(_text())
	sent.clear()
	var edit: LineEdit = dock._rows["font-size"].edit
	edit.text = "20px"
	edit.text_submitted.emit("20px")
	check(model.pending.size() == 1 and sent[-1][0] == "apply" and sent[-1][1].value == "20px" and sent[-1][1].prop == "font-size", "typing a value sends it to the preview")
	check(dock._save_button.text == "Save (1)" and not dock._save_button.disabled, "Save shows the number of unsaved changes")
	check((dock._rows["font-size"].edit as LineEdit).modulate.a == 1.0, "an edited value is shown as set")
	var side: LineEdit = dock._rows["margin"].edits[1]
	side.text = "10"
	side.text_submitted.emit("10")
	check(sent[-1][1].prop == "margin-right" and sent[-1][1].value == "10px", "a side field writes its own longhand, bare numbers get px")
	var text_edit: LineEdit = dock._rows["content:text:#t1"].edit
	text_edit.text = "Hi"
	text_edit.text_submitted.emit("Hi")
	check(sent[-1][0] == "apply_text" and sent[-1][1].text == "Hi", "editing the text sends it")
	picker = dock._rows["color"].picker
	picker.color = Color8(255, 0, 0)
	picker.color_changed.emit(picker.color)
	check(sent[-1][1].prop == "color" and sent[-1][1].value == "#ff0000", "picking a colour sends a hex value")
	dock._undo_button.pressed.emit()
	check(model.pending.size() == 3, "Undo takes back the last change (%d left)" % model.pending.size())
	check(dock._status_label.text == model.status, "the status line mirrors the model")

	# scope and sections
	check(dock._scope_values == [-1, -2, 0], "the scope choices are automatic, this element only, and the rules in files: %s" % [dock._scope_values])
	dock._scope_option.item_selected.emit(1)
	check(model.target_rule == -2, "choosing 'this element only' sets the target")
	model.target_rule = -1
	var typography_body: Control = dock._rows["font-size"].edit.get_parent().get_parent().get_parent()
	check(typography_body.visible == not dock._collapsed["text:typography"], "sections show or hide with their collapsed state")
	check(WebUIEditorDock._nudge("14px", 1.0, false, false) == "15px" and WebUIEditorDock._nudge("1.5", 1.0, false, true) == "1.6" and WebUIEditorDock._nudge("10%", -1.0, true, false) == "0%" and WebUIEditorDock._nudge("auto", 1.0, false, false) == "", "arrow keys step numbers and keep their unit")
	check(WebUIEditorDock._to_color("var(--mint)", "rgb(62, 230, 160)").is_equal_approx(Color8(62, 230, 160)) and WebUIEditorDock._to_color("rgba(0, 0, 0, 0.5)", "").a == 0.5, "colours: var() falls back to the computed value, rgba() alpha is parsed")

	# sample state
	check(dock._sample_header.text == "▸ Sample state" and not dock._sample_body.visible, "the sample state block starts collapsed")
	dock._sample_header.pressed.emit()
	check(dock._sample_body.visible and dock._sample_header.text.begins_with("▾"), "and opens")
	var buttons: Array = dock._sample_body.get_child(1).get_children()
	dock._sample_edit.text = "{ broken"
	buttons[0].pressed.emit()
	check(dock._sample_note.visible and dock._sample_note.text.begins_with("Not valid JSON"), "invalid JSON is explained under the box")
	dock._sample_edit.text = "{\"states\": {\"hud\": {\"hp\": \"80\"}}}"
	sent.clear()
	buttons[0].pressed.emit()
	check(not dock._sample_note.visible and sent[-1][0] == "sample" and dock._sample_header.text.ends_with("●"), "a valid sample is applied and marked")
	buttons[1].pressed.emit()
	check(dock._sample_edit.text.contains("\"states\"") and dock._sample_edit.text.contains("\"events\""), "the template button fills in a skeleton")

	DirAccess.remove_absolute(DIR.path_join(".webui-edit").path_join("p.json"))
	DirAccess.remove_absolute(DIR.path_join(".webui-edit").path_join(".gdignore"))
	DirAccess.remove_absolute(DIR.path_join(".webui-edit"))
	DirAccess.remove_absolute(DIR.path_join("s.css"))
	DirAccess.remove_absolute(DIR.path_join("p.html"))
	DirAccess.remove_absolute(DIR)
	quit(failures)


func _base(extra: Dictionary) -> Dictionary:
	var out := {
		"op": "selected", "selector": "#t1", "tag": "p", "id": "t1", "id_unique": true, "classes": ["t"], "kind": "text", "attrs": {}, "text": "Hello",
		"text_editable": true, "text_unique": true, "text_mixed": false, "display": "block", "position": "static", "parent_display": "block", "animated": false,
		"children": 0, "computed": {"color": "rgb(5, 38, 26)", "font-size": "14px", "margin-right": "4px", "margin-left": "4px", "margin-top": "0px", "margin-bottom": "0px", "display": "flex"},
		"inline": {}, "inherited": {}, "vars": {}, "fonts": [], "sheets": [{"file": "s.css", "rules": 3}],
		"rules": [{"file": "s.css", "inline": false, "path": [0.0], "selector": ".t", "conditions": [], "specificity": 100, "order": 0, "affects": 1, "declared": {"color": false, "font-size": false, "margin-top": false, "margin-right": false, "margin-bottom": false, "margin-left": false}, "vars": []}],
	}
	out.merge(extra, true)
	return out


func _text() -> Dictionary:
	return _base({})


func _box() -> Dictionary:
	return _base({"selector": "#b1", "tag": "div", "id": "b1", "classes": ["box"], "kind": "container", "text": "", "text_editable": false, "display": "flex",
		"rules": [{"file": "s.css", "inline": false, "path": [1.0], "selector": ".box", "conditions": [], "specificity": 100, "order": 1, "affects": 1, "declared": {"display": false, "gap": false}, "vars": []}]})


func _image() -> Dictionary:
	return _base({"selector": "#i1", "tag": "img", "id": "i1", "classes": ["pic"], "kind": "image", "text": "", "text_editable": false, "display": "inline", "attrs": {"src": "a.png"},
		"rules": [{"file": "s.css", "inline": false, "path": [2.0], "selector": ".pic", "conditions": [], "specificity": 100, "order": 2, "affects": 1, "declared": {"width": false}, "vars": []}]})
